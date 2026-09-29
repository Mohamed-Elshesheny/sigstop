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

    private static func atLeastAnHour(_ date: Date, _ calendar: Calendar = losAngeles) -> TimeInterval? {
        LocalDay.secondsUntilNextBoundary(atLeast: 3600, after: date, calendar: calendar, boundaryHour: 4)
    }

    @Test("with the hour floor, a second before the boundary waits for the boundary after it")
    func aSecondBeforeWithTheFloor() throws {
        let almost = try Self.at(Self.losAngeles, 2026, 9, 29, 3, 59, 59)
        #expect(Self.atLeastAnHour(almost) == TimeInterval(24 * 3600 + 1))
    }

    @Test("exactly an hour before the boundary is allowed, a second less is not")
    func theFloorIsInclusive() throws {
        let hour = try Self.at(Self.losAngeles, 2026, 9, 29, 3)
        #expect(Self.atLeastAnHour(hour) == TimeInterval(3600))
        let under = try Self.at(Self.losAngeles, 2026, 9, 29, 3, 0, 1)
        #expect(Self.atLeastAnHour(under) == TimeInterval(3599 + 24 * 3600))
    }

    @Test("in the evening the floor changes nothing")
    func theFloorIsInvisibleInTheEvening() throws {
        let ten = try Self.at(Self.losAngeles, 2026, 9, 28, 22)
        #expect(Self.atLeastAnHour(ten) == Self.until(ten))
    }

    @Test("the morning the clocks went forward, the boundary after next is a real day later")
    func theFloorOnTheSpringForwardMorning() throws {
        let early = try Self.at(Self.losAngeles, 2026, 3, 8, 4, 30)
        #expect(Self.until(early) == TimeInterval(30 * 60), "the day changes at 05:00 PDT that morning")
        #expect(Self.atLeastAnHour(early) == TimeInterval(30 * 60 + 23 * 3600))
    }

    @Test("across a year the floored wait is never under an hour nor over a day and an hour")
    func theFloorIsBoundedEveryHourOfTheYear() throws {
        var cursor = try Self.at(Self.losAngeles, 2026, 1, 1, 0, 30)
        let end = try Self.at(Self.losAngeles, 2027, 1, 1, 0, 30)
        while cursor < end {
            let wait = try #require(Self.atLeastAnHour(cursor))
            #expect(wait >= 3600 && wait <= 26 * 3600, "\(cursor) waits \(wait)")
            cursor = cursor.addingTimeInterval(3600)
        }
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
