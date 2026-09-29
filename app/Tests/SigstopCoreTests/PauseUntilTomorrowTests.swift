import Foundation
import Testing

@testable import SigstopCore

@Suite("pause until tomorrow ends at the day boundary")
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

    @Test("a second before the boundary the pause is one second")
    func aSecondBefore() throws {
        let almost = try Self.at(Self.losAngeles, 2026, 9, 29, 3, 59, 59)
        #expect(Self.until(almost) == TimeInterval(1))
    }

    @Test("the night the clocks go forward is an hour shorter than the wall clock says")
    func springForwardNight() throws {
        let evening = try Self.at(Self.losAngeles, 2026, 3, 7, 22)
        #expect(Self.until(evening) == TimeInterval(5 * 3600), "22:00 PST to 04:00 PDT is five real hours")
    }

    @Test("the night the clocks go back is an hour longer than the wall clock says")
    func fallBackNight() throws {
        let evening = try Self.at(Self.losAngeles, 2026, 10, 31, 22)
        #expect(Self.until(evening) == TimeInterval(7 * 3600), "22:00 PDT to 04:00 PST is seven real hours")
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

    @Test("across a whole year the wait is always positive and at most twenty-five hours")
    func boundedEveryHourOfTheYear() throws {
        var cursor = try Self.at(Self.losAngeles, 2026, 1, 1, 0, 30)
        let end = try Self.at(Self.losAngeles, 2027, 1, 1, 0, 30)
        while cursor < end {
            let wait = try #require(Self.until(cursor))
            #expect(wait > 0 && wait <= 25 * 3600, "\(cursor) waits \(wait)")
            let boundary = cursor.addingTimeInterval(wait)
            let hour = Self.losAngeles.component(.hour, from: boundary)
            #expect(hour == 4, "\(cursor) lands on \(boundary), not on the 4am boundary")
            cursor = cursor.addingTimeInterval(3600)
        }
    }
}
