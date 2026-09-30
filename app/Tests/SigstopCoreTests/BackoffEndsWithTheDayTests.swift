import Foundation
import Testing

@testable import SigstopCore

@Suite("the ignore backoff lasts the rest of the day, not into the next one")
struct BackoffEndsWithTheDayTests {

    @Test("the day boundary clears the consecutive-ignore count and keeps the cycle numbering")
    func rolloverClearsTheBackoff() {
        let day = DailyCounters(dayIndex: 20260921, consecutiveIgnoredCycles: 2, nextCycle: CycleID(rawValue: 7))
        let next = day.rolledOver(to: 20260922)
        #expect(next.consecutiveIgnoredCycles == 0)
        #expect(next.nextCycle == CycleID(rawValue: 7))
    }

    @Test("a morning after two ignored cycles gets the whole ladder back")
    func morningLadderIsWhole() {
        var bench = TrackerEngineBench()
        let today = LocalDay.index(
            of: bench.time.now, calendar: bench.calendar, boundaryHour: bench.policy.dayBoundaryHour
        )
        bench.day = DailyCounters(dayIndex: today - 1, consecutiveIgnoredCycles: bench.policy.ignoreBackoffThreshold)
        bench.tick()
        #expect(bench.day.dayIndex == today)
        #expect(bench.day.consecutiveIgnoredCycles == 0)
    }
}
