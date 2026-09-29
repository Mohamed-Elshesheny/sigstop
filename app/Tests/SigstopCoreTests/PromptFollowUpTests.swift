import Foundation
import Testing

@testable import SigstopCore

@Suite("a prompt says what ignoring it costs, and the engine is the one that knows")
struct PromptFollowUpTests {

    private static func delivered(_ effects: [Effect]) -> [PromptRequest] {
        effects.compactMap { if case .deliverPrompt(let r) = $0 { return r } else { return nil } }
    }

    private static func closes(_ effects: [Effect]) -> [CycleOutcome] {
        effects.compactMap { if case .closeCycle(_, let o) = $0 { return o } else { return nil } }
    }

    private static func ignoreEveryPrompt(
        _ session: inout EngineHarness.Session,
        limit: Int = 1200,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> (prompts: [PromptRequest], outcome: CycleOutcome?) {
        var prompts: [PromptRequest] = []
        for _ in 0..<limit {
            let effects = session.step()
            prompts.append(contentsOf: delivered(effects))
            if let outcome = closes(effects).first {
                for (index, prompt) in prompts.enumerated() {
                    let more = index < prompts.count - 1
                    #expect(
                        (prompt.ifIgnored == .anotherRung) == more,
                        "\(prompt.level) said \(prompt.ifIgnored) and was followed by \(prompts.count - 1 - index) more",
                        sourceLocation: sourceLocation
                    )
                }
                return (prompts, outcome)
            }
        }
        Issue.record("the cycle never closed", sourceLocation: sourceLocation)
        return (prompts, nil)
    }

    @Test("a full ladder promises another rung at L1 to L3 and the cooldown at SIGSTOP")
    func fullLadder() {
        var session = EngineHarness.Session()
        let run = Self.ignoreEveryPrompt(&session)
        #expect(run.prompts.map(\.level) == [.first, .second, .third, .incident])
        #expect(run.prompts.map(\.ifIgnored) == [.anotherRung, .anotherRung, .anotherRung, .cooldown])
        #expect(run.outcome == .ignoredExhausted)
    }

    @Test("the backoff's single SIGTSTP knows it is the last one")
    func backedOffFirstRung() {
        var session = EngineHarness.Session()
        session.driver.day.consecutiveIgnoredCycles = 2
        let run = Self.ignoreEveryPrompt(&session)
        #expect(run.prompts.map(\.level) == [.first])
        #expect(run.prompts.map(\.ifIgnored) == [.cooldown])
        #expect(run.prompts.map(\.snoozeOffered) == [[]])
        #expect(run.outcome == .ignoredExhausted)
        guard case .working(let w) = session.driver.state else {
            Issue.record("expected the cooldown, got \(session.driver.state.name)")
            return
        }
        #expect(w.cooldownUntilMono != nil)
    }

    @Test("after a snooze the rung that spends the fourth notification says so")
    func spentBySnooze() {
        var session = EngineHarness.Session()
        let first = Self.delivered(session.stepToPrompt())
        #expect(first.map(\.level) == [.first])
        #expect(first.map(\.ifIgnored) == [.anotherRung])
        let second = Self.delivered(session.stepToPrompt())
        #expect(second.map(\.level) == [.second])
        #expect(second.map(\.ifIgnored) == [.anotherRung])
        session.step(action: .snooze)
        #expect(session.driver.state.name == "snoozed")
        let again = Self.delivered(session.stepToPrompt())
        #expect(again.map(\.level) == [.first])
        #expect(again.map(\.ifIgnored) == [.anotherRung])
        let run = Self.ignoreEveryPrompt(&session)
        #expect(run.prompts.map(\.level) == [.second])
        #expect(run.prompts.map(\.ifIgnored) == [.cooldown])
        #expect(run.outcome == .ignoredExhausted)
    }

    @Test("the prompt that reaches the daily cap says the day is over, not that it cools down")
    func reachesTheDailyCap() {
        var session = EngineHarness.Session()
        session.step()
        let cap = session.driver.engine.policy.dailyNotificationCap
        session.driver.day.notificationsDelivered = cap - 1
        let run = Self.ignoreEveryPrompt(&session)
        #expect(run.prompts.map(\.level) == [.first])
        #expect(run.prompts.map(\.ifIgnored) == [.quietForTheDay])
        #expect(run.outcome == .dailyCapReached)
        guard case .quiet(let q) = session.driver.state else {
            Issue.record("expected the day to be over, got \(session.driver.state.name)")
            return
        }
        #expect(q.cause == .dailyCapReached)
    }

    @Test("SIGSTOP on the prompt that reaches the cap is quiet for the day too")
    func lastRungReachesTheDailyCap() {
        var session = EngineHarness.Session()
        session.step()
        let cap = session.driver.engine.policy.dailyNotificationCap
        session.driver.day.notificationsDelivered = cap - 4
        let run = Self.ignoreEveryPrompt(&session)
        #expect(run.prompts.map(\.level) == [.first, .second, .third, .incident])
        #expect(run.prompts.map(\.ifIgnored) == [.anotherRung, .anotherRung, .anotherRung, .quietForTheDay])
        guard case .quiet(let q) = session.driver.state else {
            Issue.record("expected the day to be over, got \(session.driver.state.name)")
            return
        }
        #expect(q.cause == .dailyCapReached)
    }

    @Test("only the last prompt of a cycle is marked last")
    func lastMeansLast() {
        #expect(!PromptFollowUp.anotherRung.isLastOfCycle)
        #expect(PromptFollowUp.cooldown.isLastOfCycle)
        #expect(PromptFollowUp.quietForTheDay.isLastOfCycle)
    }
}
