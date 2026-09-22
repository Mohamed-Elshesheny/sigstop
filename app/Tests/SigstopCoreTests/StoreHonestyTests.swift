import Foundation
import Testing

@testable import SigstopCore

/// "Nothing happened" and "I could not look" are different answers, and only one of them
/// is about the user. `docs/PRIVACY.md` promises a corrupt file never silently changes
/// your history; these are what make that a property rather than a sentence.
@Suite("the store does not invent an answer")
struct StoreHonestyTests {

    private func scratch() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sigstop-store-\(UUID().uuidString)")
    }

    @Test("a day whose file will not open is not reported as a day you did nothing")
    func unreadableIsNotEmpty() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileEventStore(root: root)

        let at = Date(timeIntervalSince1970: 1_758_500_000)
        try store.append(.breakBegin(at: at, origin: .accepted, cycle: CycleID.initial))
        let day = CalendarDay.utc(of: at)

        // Readable: the events come back and nothing is flagged.
        let before = try store.load(day: day)
        #expect(!before.events.isEmpty)
        #expect(before.unreadable == false)

        // Now make it unreadable the way a permissions problem would.
        let path = root.appendingPathComponent("events/\(day.fileName)")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }

        let after = try store.load(day: day)
        #expect(after.unreadable, "a file that will not open must say so, not report an empty day")

        // And a day that genuinely has no file is still plain empty.
        let absent = try store.load(day: day.adding(days: -30))
        #expect(absent.events.isEmpty)
        #expect(absent.unreadable == false, "a missing day is empty, not unreadable")
    }

    @Test("a summaries file that will not decode is set aside, not overwritten")
    func corruptSummaryIsKept() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileEventStore(root: root)

        let day = CalendarDay(year: 2026, month: 9, day: 22)
        let summary = DailySummary(day: day)
        try store.writeSummary(summary)

        let path = root.appendingPathComponent("summaries/2026-09.json")
        let original = try Data(contentsOf: path)
        #expect(!original.isEmpty)

        // A month that will not decode: one field of one day gone, which is what a schema
        // change between versions looks like.
        try Data("{\"v\":1,\"days\":{\"2026-09-21\":{\"totalActiveWork\":12}}}".utf8).write(to: path)

        try store.writeSummary(DailySummary(day: CalendarDay(year: 2026, month: 9, day: 23)))

        let aside = root.appendingPathComponent("summaries/2026-09.json.unreadable")
        #expect(FileManager.default.fileExists(atPath: aside.path),
                "the month that would not decode must still be on disk to recover by hand")

        let rewritten = try store.readSummaries(year: 2026, month: 9)
        #expect(rewritten.count == 1, "the new month starts from today, which is the only honest option")
    }
}
