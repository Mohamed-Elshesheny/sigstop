import Foundation
import Testing

@testable import SigstopCore

@Suite("the store does not invent an answer")
struct StoreHonestyTests {

    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return c
    }

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

        let before = try store.load(day: day)
        #expect(!before.events.isEmpty)
        #expect(before.unreadable == false)

        let path = root.appendingPathComponent("events/\(day.fileName)")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }

        let after = try store.load(day: day)
        #expect(after.unreadable, "a file that will not open must say so, not report an empty day")

        #expect(throws: StoreError.self, "the rollup must refuse, not report a day with no work") {
            _ = try DailyRollup.compute(day: day, from: store, calendar: Self.utc)
        }
        let export = try store.exportText()
        #expect(export.contains("would not open: \(day)"), "the export must name the day it could not read")

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

        try Data("{\"v\":1,\"days\":{\"2026-09-21\":{\"totalActiveWork\":12}}}".utf8).write(to: path)

        try store.writeSummary(DailySummary(day: CalendarDay(year: 2026, month: 9, day: 23)))

        let aside = root.appendingPathComponent("summaries/2026-09.json.unreadable")
        #expect(FileManager.default.fileExists(atPath: aside.path),
                "the month that would not decode must still be on disk to recover by hand")

        let rewritten = try store.readSummaries(year: 2026, month: 9)
        #expect(rewritten.count == 1, "the new month starts from today, which is the only honest option")
    }
}
