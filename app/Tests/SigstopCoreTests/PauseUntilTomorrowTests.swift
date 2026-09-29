import Foundation
import Testing

@testable import SigstopCore

@Suite("pause until tomorrow ends where the app's day changes")
struct PauseUntilTomorrowTests {

    private static func calendar(_ zone: String, _ identifier: Calendar.Identifier = .gregorian) -> Calendar {
        var c = Calendar(identifier: identifier)
        c.timeZone = TimeZone(identifier: zone) ?? .gmt
        return c
    }

    private static let losAngeles = calendar("America/Los_Angeles")

    private static func at(
        _ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int,
        _ minute: Int = 0, _ second: Int = 0
    ) throws -> Date {
        try #require(calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )))
    }

    private static func until(_ date: Date, _ calendar: Calendar = losAngeles, boundary: Int = 4) -> TimeInterval? {
        LocalDay.secondsUntilNextBoundary(after: date, calendar: calendar, boundaryHour: boundary)
    }

    private static func index(_ date: Date, _ calendar: Calendar = losAngeles, boundary: Int = 4) -> Int {
        LocalDay.index(of: date, calendar: calendar, boundaryHour: boundary)
    }

    @Test("in the morning the next boundary is tomorrow's")
    func morningWaitsForTomorrow() throws {
        let nine = try Self.at(Self.losAngeles, 2026, 9, 29, 9)
        #expect(Self.until(nine) == TimeInterval(19 * 3600))
    }

    @Test("before the boundary it is today's, so a pause at 3am ends at 4")
    func smallHoursEndAtFour() throws {
        let three = try Self.at(Self.losAngeles, 2026, 9, 29, 3)
        #expect(Self.until(three) == TimeInterval(3600))
    }

    @Test("exactly at the boundary the pause lasts a whole day, never zero")
    func atTheBoundaryIsAWholeDay() throws {
        let four = try Self.at(Self.losAngeles, 2026, 9, 29, 4)
        #expect(Self.until(four) == TimeInterval(24 * 3600))
    }

    @Test("a second before the boundary the boundary is one second away")
    func aSecondBefore() throws {
        let almost = try Self.at(Self.losAngeles, 2026, 9, 29, 3, 59, 59)
        #expect(Self.until(almost) == TimeInterval(1))
        let boundary = almost.addingTimeInterval(1)
        #expect(Self.index(almost) != Self.index(boundary))
    }

    @Test("the night the clocks go forward, the day still changes four real hours after midnight")
    func springForwardNight() throws {
        let evening = try Self.at(Self.losAngeles, 2026, 3, 7, 22)
        let wait = try #require(Self.until(evening))
        #expect(wait == TimeInterval(6 * 3600), "22:00 PST to four hours after midnight is six real hours")
        let boundary = evening.addingTimeInterval(wait)
        #expect(Self.losAngeles.component(.hour, from: boundary) == 5, "which the wall clock calls 05:00 PDT")
        #expect(Self.index(boundary.addingTimeInterval(-1)) == Self.index(evening))
        #expect(Self.index(boundary) != Self.index(evening))
    }

    @Test("the night the clocks go back, the day still changes four real hours after midnight")
    func fallBackNight() throws {
        let evening = try Self.at(Self.losAngeles, 2026, 10, 31, 22)
        let wait = try #require(Self.until(evening))
        #expect(wait == TimeInterval(6 * 3600), "22:00 PDT to four hours after midnight is six real hours")
        let boundary = evening.addingTimeInterval(wait)
        #expect(Self.losAngeles.component(.hour, from: boundary) == 3, "which the wall clock calls 03:00 PST")
        #expect(Self.index(boundary.addingTimeInterval(-1)) == Self.index(evening))
        #expect(Self.index(boundary) != Self.index(evening))
    }

    @Test("a midnight boundary works the same way")
    func midnightBoundary() throws {
        let late = try Self.at(Self.losAngeles, 2026, 9, 29, 23, 59, 59)
        #expect(Self.until(late, boundary: 0) == TimeInterval(1))
        let midnight = try Self.at(Self.losAngeles, 2026, 9, 30, 0)
        #expect(Self.until(midnight, boundary: 0) == TimeInterval(24 * 3600))
    }

    @Test("a Hijri Mac gets the same number of seconds")
    func hijriMacAgrees() throws {
        let nine = try Self.at(Self.losAngeles, 2026, 9, 29, 9)
        let islamic = Self.calendar("America/Los_Angeles", .islamicUmmAlQura)
        #expect(Self.until(nine, islamic) == Self.until(nine))
    }

    @Test("across a year in four time zones, the pause ends at the instant the day index changes")
    func endsWhereTheIndexChangesEveryHourOfTheYear() throws {
        let zones = [
            "America/Los_Angeles", "America/Santiago", "Australia/Lord_Howe", "Europe/London",
        ]
        for zone in zones {
            let calendar = Self.calendar(zone)
            var cursor = try Self.at(calendar, 2026, 1, 1, 0, 30)
            let end = try Self.at(calendar, 2027, 1, 1, 0, 30)
            while cursor < end {
                let wait = try #require(Self.until(cursor, calendar))
                #expect(wait > 0 && wait <= 25 * 3600, "\(zone): \(cursor) waits \(wait)")
                let boundary = cursor.addingTimeInterval(wait)
                let before = boundary.addingTimeInterval(-1)
                #expect(
                    Self.index(before, calendar) == Self.index(cursor, calendar),
                    "\(zone): \(cursor) is still the same day a second before \(boundary)"
                )
                #expect(
                    Self.index(boundary, calendar) != Self.index(cursor, calendar),
                    "\(zone): the day did not change at \(boundary) for \(cursor)"
                )
                let midnight = calendar.startOfDay(for: boundary)
                #expect(
                    boundary == midnight.addingTimeInterval(4 * 3600),
                    "\(zone): \(boundary) is not four real hours after \(midnight)"
                )
                if calendar.dateInterval(of: .day, for: boundary)?.duration == 24 * 3600 {
                    #expect(calendar.component(.hour, from: boundary) == 4, "\(zone): \(boundary)")
                }
                cursor = cursor.addingTimeInterval(3600)
            }
        }
    }
}
