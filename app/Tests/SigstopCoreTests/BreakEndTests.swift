import Foundation
import Testing

@testable import SigstopCore

@Suite("the tick that ends a break")
struct BreakEndTests {

    @Test("Ending a break does not open a new cycle in the same tick")
    func endingABreakDoesNotImmediatelyReprompt() {
        var settings = SigstopSettings()
        settings.workIntervalMinutes = 5
        settings.breakDurationMinutes = 5

        let engine = BreakDecisionEngine(settings: settings)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        var state = EngineState.breakActive(
            .init(
                cycle: CycleID.initial,
                startedAt: start,
                plannedEnd: start.addingTimeInterval(300),
                startedMono: 0,
                plannedDuration: 300,
                origin: .accepted
            )
        )
        var day = DailyCounters()

        let input = EngineInput(
            now: start.addingTimeInterval(302),
            monotonic: 302,
            context: DeveloperContext(
                timestamp: start.addingTimeInterval(302),
                application: AppIdentity(bundleID: "com.apple.dt.Xcode", localizedName: "Xcode", pid: 1),
                activity: .coding,
                confidence: Confidence(0.9),
                continuousWork: 6 * 60
            ),
            settings: settings
        )

        let outcome = engine.step(state, input)
        state = outcome.state
        day = outcome.day

        let openedACycle = outcome.effects.contains { if case .openCycle = $0 { return true } else { return false } }
        let prompted = outcome.effects.contains { if case .deliverPrompt = $0 { return true } else { return false } }

        #expect(!openedACycle, "the tick that ends a break must not open the next cycle")
        #expect(!prompted, "and it certainly must not prompt")
        #expect(day.breakOpportunities >= 0)
    }
}
