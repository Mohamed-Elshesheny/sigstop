import Foundation
import Testing

@testable import SigstopCore

@Suite("a short break the app asked for counts in the day's numbers")
struct ShortBreakRollupTests {

    private static let calendar = CalendarDay.utcCalendar

    private static func twoMinuteBreak() -> (lines: [LoggedEvent], day: CalendarDay) {
        var settings = EngineHarness.ownerSettings
        settings.workIntervalMinutes = 1
        settings.breakDurationMinutes = 2
        settings.idleCountsAsBreakMinutes = 5
        var session = EngineHarness.Session(settings: settings)
        session.stepToPrompt()
        session.step(action: .acceptBreak)
        session.step(untilLimit: 100) { effects in
            effects.contains { if case .closeCycle = $0 { return true } else { return false } }
        }
        let day = CalendarDay.local(of: session.driver.now, calendar: calendar, boundaryHour: 4)
        return (session.log.lines, day)
    }

    @Test("the engine honoured it, so the rollup counts it under the default five minute cutoff")
    func honouredTwoMinuteBreakCounts() throws {
        let (lines, day) = Self.twoMinuteBreak()
        let end = try #require(lines.first { $0.kind == .breakEnd })
        #expect(end.thresholdSeconds == 120)
        #expect((120...130).contains(end.durationSeconds ?? 0), "got \(String(describing: end.durationSeconds))")
        #expect(lines.contains { $0.kind == .cycleClose && $0.outcome == .honored })

        let s = DailyRollup.compute(day: day, events: lines, policy: .default, calendar: Self.calendar)
        #expect(s.breakCount == 1)
        #expect(s.breaksAbandoned == 0)
        #expect(s.breaksAccepted == 1)
        #expect(s.honoredOpportunities == 1)
        #expect(s.missedOpportunities == 0)
        #expect(s.averageBreakLength == end.durationSeconds.map(TimeInterval.init))
    }

    @Test("dur_s against plan_s is the verdict, and a line without plan_s keeps the policy cutoff")
    func planDecides() {
        let begin = Date(timeIntervalSince1970: 1_700_000_000)
        func spans(_ end: LoggedEvent) -> [DailyRollup.BreakSpan] {
            DailyRollup.breakSpans(
                [.breakBegin(at: begin, origin: .accepted), end],
                dayEnd: begin.addingTimeInterval(8 * 3600),
                policy: RollupPolicy()
            )
        }
        let judgedShort = spans(
            .breakEnd(at: begin.addingTimeInterval(120), origin: .accepted, durationSeconds: 120, thresholdSeconds: 120)
        )
        #expect(judgedShort.first?.qualifies == true, "two minutes planned and two minutes taken is a break")

        let cutShort = spans(
            .breakEnd(at: begin.addingTimeInterval(100), origin: .accepted, durationSeconds: 100, thresholdSeconds: 120)
        )
        #expect(cutShort.first?.qualifies == false, "planned two minutes, left after one hundred seconds")

        let older = spans(
            .breakEnd(at: begin.addingTimeInterval(120), origin: .accepted, durationSeconds: 120)
        )
        #expect(older.first?.qualifies == false, "no plan_s means the five minute policy cutoff")
    }
}
