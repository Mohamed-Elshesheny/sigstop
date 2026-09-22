import Foundation
import Testing

@testable import SigstopCore

@Suite("the store writes only its own files, never through a link")
struct SymlinkTests {

    private func scratch() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sigstop-links-\(UUID().uuidString)")
    }

    @Test("a linked events folder is refused, and nothing is written into its target")
    func linkedEventsFolderIsRefused() throws {
        let base = scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside")
        let root = base.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("events"), withDestinationURL: outside
        )

        #expect(throws: StoreError.self) { _ = try FileEventStore(root: root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("a linked day file is refused, and the file it points at is untouched")
    func linkedDayFileIsRefused() throws {
        let base = scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try FileEventStore(root: base.appendingPathComponent("store"))
        let victim = base.appendingPathComponent("pre-commit")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: victim)

        let at = Date(timeIntervalSince1970: 1_758_500_000)
        let day = CalendarDay.utc(of: at)
        try FileManager.default.createSymbolicLink(at: store.url(for: day), withDestinationURL: victim)

        #expect(throws: StoreError.self) {
            try store.append(.breakBegin(at: at, origin: .accepted, cycle: CycleID.initial))
        }
        #expect(try String(contentsOf: victim, encoding: .utf8) == "#!/bin/sh\nexit 0\n")
    }

    @Test("a day file that is a link is not read, however small the link is")
    func linkedDayFileIsNotRead() throws {
        let base = scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try FileEventStore(root: base.appendingPathComponent("store"))
        let big = base.appendingPathComponent("big.jsonl")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(FileEventStore.largestDayFile + 1))
        try handle.close()
        let day = CalendarDay.utc(of: Date(timeIntervalSince1970: 1_758_500_000))
        try FileManager.default.createSymbolicLink(at: store.url(for: day), withDestinationURL: big)

        let load = try store.load(day: day)
        #expect(load.unreadable)
        #expect(load.events.isEmpty)
    }

    @Test("an atomic write replaces a link with a file of its own and leaves the target alone")
    func atomicWriteReplacesALink() throws {
        let base = scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let victim = base.appendingPathComponent("hook")
        try Data("original".utf8).write(to: victim)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: victim.path)
        let settings = base.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: victim)

        try SecureFile.write(Data("{}".utf8), to: settings)

        #expect(try String(contentsOf: victim, encoding: .utf8) == "original")
        let victimMode = try FileManager.default.attributesOfItem(atPath: victim.path)[.posixPermissions] as? Int
        #expect(victimMode == 0o755)
        let written = try FileManager.default.attributesOfItem(atPath: settings.path)
        #expect(written[.type] as? FileAttributeType == .typeRegular)
        #expect(written[.posixPermissions] as? Int == 0o600)
    }

    @Test("appending twice keeps one event per line")
    func appendKeepsLines() throws {
        let base = scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try FileEventStore(root: base)
        let at = Date(timeIntervalSince1970: 1_758_500_000)
        try store.append(.breakBegin(at: at, origin: .accepted, cycle: CycleID.initial))
        try store.append(.stop(at: at.addingTimeInterval(1)))
        let load = try store.load(day: CalendarDay.utc(of: at))
        #expect(load.events.count == 2)
        #expect(load.malformedLines == 0)
    }
}
