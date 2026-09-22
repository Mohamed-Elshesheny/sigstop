import Foundation
import Testing

@testable import SigstopCore

struct RetentionTests {
    static let now = Date(timeIntervalSince1970: 1_758_500_000)
    static var today: CalendarDay { CalendarDay.utc(of: now) }
    static var cutoff: CalendarDay? { PruneMath.cutoffDay(retentionDays: 7, asOf: now) }

    @Test("a day inside the window survives")
    func recentSurvives() {
        #expect(!PruneMath.shouldDrop(Self.today, cutoff: Self.cutoff, today: Self.today))
        #expect(!PruneMath.shouldDrop(Self.today.adding(days: -6), cutoff: Self.cutoff, today: Self.today))
    }

    @Test("a day past the window is dropped")
    func oldDropped() {
        #expect(PruneMath.shouldDrop(Self.today.adding(days: -7), cutoff: Self.cutoff, today: Self.today))
    }

    @Test("a day in the future is dropped, however far the window reaches")
    func futureDropped() {
        #expect(PruneMath.shouldDrop(Self.today.adding(days: 1), cutoff: Self.cutoff, today: Self.today))
        #expect(PruneMath.shouldDrop(CalendarDay(year: 2030, month: 1, day: 14), cutoff: Self.cutoff, today: Self.today),
                "a file dated years ahead is exactly what retention should reach")
        #expect(PruneMath.shouldDrop(Self.today.adding(days: 1), cutoff: nil, today: Self.today))
    }
}
