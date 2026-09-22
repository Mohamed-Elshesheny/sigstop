import Foundation
import Testing

@testable import SigstopCore

@Suite("the logical day and the file key are the same day")
struct CalendarSystemTests {

    static let instant = Date(timeIntervalSince1970: 1_758_500_000)

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

    @Test("a day's interval is the same stretch of time on a Hijri Mac")
    func intervalUnderIslamicCalendar() throws {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        var islamic = Calendar(identifier: .islamicUmmAlQura)
        islamic.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        let day = CalendarDay.utc(of: Self.instant)
        let expected = try #require(day.interval(boundaryHour: 0, calendar: gregorian))
        let hijri = try #require(day.interval(boundaryHour: 0, calendar: islamic))

        #expect(hijri == expected, "\(day.fileName) read on a Hijri Mac spans \(hijri), not \(expected)")
        #expect(hijri.contains(Self.instant))
    }

    @Test("the day a reader asks for is the day the writer wrote")
    func readerAndWriterMatch() {
        let written = CalendarDay.utc(of: Self.instant)
        var islamic = Calendar(identifier: .islamicUmmAlQura)
        islamic.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let requested = CalendarDay.local(of: Self.instant, calendar: islamic, boundaryHour: 0)

        #expect(
            requested.fileName == written.fileName,
            "reader asks for \(requested.fileName), writer wrote \(written.fileName)"
        )
    }
}
