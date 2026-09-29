import Foundation
import Testing

@testable import SigstopCore

@Suite("a break that crosses the day boundary belongs to the day it began in")
struct StraddlingBreakTests {

    private static let calendar = CalendarDay.utcCalendar
    private static let policy = RollupPolicy(qualifyingBreak: 5 * 60, dayBoundaryHour: 4)
    private static let dayA = CalendarDay(year: 2026, month: 9, day: 20)
    private static let dayB = CalendarDay(year: 2026, month: 9, day: 21)
    private static let xcode = "com.apple.dt.Xcode"

    private static func at(_ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute)))
    }

    private static func nightShift() throws -> [LoggedEvent] {
        [
            .start(at: try at(20, 22, 0)),
            .focus(at: try at(20, 22, 0), app: xcode, activity: .coding),
            .breakOpen(at: try at(21, 3, 52), cycle: .initial),
            .breakPrompt(at: try at(21, 3, 52), cycle: .initial, reason: .sigtstp),
            .breakBegin(at: try at(21, 3, 57), origin: .accepted, cycle: .initial),
            .breakEnd(
                at: try at(21, 4, 4), origin: .accepted, durationSeconds: 7 * 60,
                thresholdSeconds: 300, cycle: .initial
            ),
            .cycleClose(at: try at(21, 4, 4), cycle: .initial, outcome: .honored),
            .focus(at: try at(21, 4, 4), app: xcode, activity: .coding),
            .stop(at: try at(21, 10, 0)),
        ]
    }

    @Test("the first day counts it, with its full length, and as the opportunity kept")
    func countedOnTheDayItBegan() throws {
        let s = DailyRollup.compute(day: Self.dayA, events: try Self.nightShift(), policy: Self.policy, calendar: Self.calendar)
        #expect(s.breakCount == 1)
        #expect(s.breaksAbandoned == 0)
        #expect(s.totalBreakTime == TimeInterval(7 * 60))
        #expect(s.breakOpportunities == 1)
        #expect(s.honoredOpportunities == 1)
    }

    @Test("the second day does not count it again, and does not count its tail as work")
    func notCountedTwice() throws {
        let s = DailyRollup.compute(day: Self.dayB, events: try Self.nightShift(), policy: Self.policy, calendar: Self.calendar)
        #expect(s.breakCount == 0)
        #expect(s.breaksAbandoned == 0)
        #expect(s.totalBreakTime == 0)
        #expect(s.breakOpportunities == 0)
        #expect(s.totalActiveWork == 6 * 3600 - 4 * 60)
    }

    @Test("the store hands the rollup the line that closes a break open at the day's end")
    func throughTheStore() throws {
        let store = InMemoryEventStore()
        try store.append(contentsOf: try Self.nightShift())
        let a = try DailyRollup.compute(day: Self.dayA, from: store, policy: Self.policy, calendar: Self.calendar)
        #expect(a.breakCount == 1)
        #expect(a.totalBreakTime == TimeInterval(7 * 60))
        #expect(a.honoredOpportunities == 1)
        let b = try DailyRollup.compute(day: Self.dayB, from: store, policy: Self.policy, calendar: Self.calendar)
        #expect(b.breakCount == 0)
        #expect(b.breaksAbandoned == 0)
    }
}
