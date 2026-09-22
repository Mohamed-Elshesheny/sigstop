import Foundation
import Testing

@testable import SigstopCore

/// The logical day and the file it names have to agree on what year it is.
///
/// Event files are keyed by `CalendarDay.utc(of:)`, which pins a Gregorian UTC calendar.
/// Every reader asks for `CalendarDay.local(of:calendar:)`, which takes `Calendar.current`
/// and reads year, month and day straight out of it. On a Mac whose Region uses a
/// non-Gregorian calendar those numbers are from another era entirely, so the reader asks
/// for a file that was never written and will never exist.
///
/// macOS picks the calendar from the region, so this is the DEFAULT in Saudi Arabia and
/// the Gulf (Islamic Umm al-Qura), in Thailand (Buddhist) and in Japan for anyone using
/// the era calendar. Nothing appears broken: breaks still fire, the menu bar still works.
/// Only the uptime panel and all ten badges read zero, forever, with no error.
@Suite("the logical day and the file key are the same day")
struct CalendarSystemTests {

    static let instant = Date(timeIntervalSince1970: 1_758_500_000)  // 2026-09-22 UTC

    private static func local(_ identifier: Calendar.Identifier) -> CalendarDay {
        var c = Calendar(identifier: identifier)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return CalendarDay.local(of: instant, calendar: c, boundaryHour: 0)
    }

    @Test("a non-Gregorian region names the same instant a different day")
    func calendarsAgreeOnTheDay() {
        let file = CalendarDay.utc(of: Self.instant)

        for identifier in [Calendar.Identifier.islamicUmmAlQura, .buddhist, .japanese, .persian] {
            let logical = Self.local(identifier)
            #expect(
                logical == file,
                "\(identifier) called it \(logical.fileName) while the file is \(file.fileName)"
            )
        }
    }

    @Test("the whole round trip survives a Hijri Mac")
    func roundTripUnderIslamicCalendar() throws {
        // End to end through the real store: write an event the way the app writes one,
        // then read the day back the way the rollup reads it. The unit assertions above
        // would pass on a broken build if only one of the two sides had been fixed.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sigstop-cal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try FileEventStore(root: root)
        let at = Self.instant
        try store.append(.breakBegin(at: at, origin: .accepted, cycle: CycleID.initial))
        try store.append(.breakEnd(at: at.addingTimeInterval(360), origin: .accepted,
                                   durationSeconds: 360, thresholdSeconds: 300,
                                   cycle: CycleID.initial))

        var islamic = Calendar(identifier: .islamicUmmAlQura)
        islamic.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let today = CalendarDay.local(of: at, calendar: islamic, boundaryHour: 0)

        let loaded = try store.events(forLogicalDay: today, calendar: islamic, policy: RollupPolicy())
        #expect(!loaded.events.isEmpty,
                "a Hijri Mac asked for \(today.fileName) and got \(loaded.events.count) events back")
    }

    @Test("the day a reader asks for is the day the writer wrote")
    func readerAndWriterMatch() {
        // What FileStore names the file, from the event's own timestamp.
        let written = CalendarDay.utc(of: Self.instant)
        // What AppModel.refreshRollup asks EventStore for.
        var islamic = Calendar(identifier: .islamicUmmAlQura)
        islamic.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let requested = CalendarDay.local(of: Self.instant, calendar: islamic, boundaryHour: 0)

        #expect(
            requested.fileName == written.fileName,
            "reader asks for \(requested.fileName), writer wrote \(written.fileName)"
        )
    }
}
