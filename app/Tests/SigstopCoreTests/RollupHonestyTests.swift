import Foundation
import Testing

@testable import SigstopCore

/// The day panel has to be built out of breaks that happened.
struct RollupHonestyTests {
    static let day = Date(timeIntervalSince1970: 1_700_000_000)
    static func at(_ offset: TimeInterval) -> Date { day.addingTimeInterval(offset) }

    static func event(_ kind: EventKind, _ offset: TimeInterval, cycle: Int? = nil) -> LoggedEvent {
        LoggedEvent(at: at(offset), kind: kind, cycle: cycle)
    }

    @Test("a break the process died in the middle of cannot qualify")
    func unterminatedBreakDoesNotQualify() {
        // One begin, no end. The old scorer closed it at the end of the day and called the
        // whole gap a break, so quitting during a break minted a qualifying one.
        let spans = DailyRollup.breakSpans(
            [Self.event(.breakBegin, 100, cycle: 0)],
            dayEnd: Self.at(8 * 3600),
            policy: RollupPolicy()
        )
        #expect(spans.count == 1)
        #expect(spans[0].qualifies == false, "an unterminated break is unknown length, not long")
        #expect(spans[0].measured > 0, "it still appears: something did happen")
    }

    @Test("a break that ended without dur_s is still judged on its timestamps")
    func endWithoutDurationStillCounts() {
        // `measured` is nil here too, which is why termination has to be passed rather than
        // inferred from it.
        let spans = DailyRollup.breakSpans(
            [Self.event(.breakBegin, 0, cycle: 0), Self.event(.breakEnd, 6 * 60, cycle: 0)],
            dayEnd: Self.at(8 * 3600),
            policy: RollupPolicy()
        )
        #expect(spans.count == 1)
        #expect(spans[0].qualifies, "six minutes with an end line is a break")
    }

    @Test("the rollup judges by the user's settings, not by constants")
    func policyFollowsSettings() {
        var settings = SigstopSettings()
        settings.idleCountsAsBreakMinutes = 2
        settings.microIdleThresholdSeconds = 45

        let rollup = RollupPolicy(settings: settings)
        let engine = BreakPolicy(settings: settings)
        #expect(rollup.qualifyingBreak == engine.qualifyingBreak,
                "rollup \(rollup.qualifyingBreak) vs engine \(engine.qualifyingBreak)")
        #expect(rollup.microIdleGrace == engine.microIdleGrace)

        // And the floor is the same one: 2 minutes is above 45 + 30, so it stands.
        #expect(rollup.qualifyingBreak == 120)

        // A two minute break is honoured by the engine, so the summary must agree.
        let spans = DailyRollup.breakSpans(
            [Self.event(.breakBegin, 0, cycle: 0), Self.event(.breakEnd, 130, cycle: 0)],
            dayEnd: Self.at(8 * 3600),
            policy: rollup
        )
        #expect(spans[0].qualifies, "the engine would have honoured this one")
        #expect(DailyRollup.breakSpans(
            [Self.event(.breakBegin, 0, cycle: 0), Self.event(.breakEnd, 130, cycle: 0)],
            dayEnd: Self.at(8 * 3600),
            policy: RollupPolicy()
        )[0].qualifies == false, "and the defaults would not have, which is the bug")
    }
}
