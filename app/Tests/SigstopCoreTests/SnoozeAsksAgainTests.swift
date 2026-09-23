import Foundation
import Testing

@testable import SigstopCore

@Suite("a snooze is offered only when the cycle can ask again")
struct SnoozeAsksAgainTests {

    private static func firstPrompt(_ driver: inout EngineHarness.Driver) -> PromptRequest? {
        for _ in 0..<400 {
            let effects = driver.step()
            if let prompt = effects.compactMap({ effect -> PromptRequest? in
                if case .deliverPrompt(let p) = effect { return p } else { return nil }
            }).first {
                return prompt
            }
        }
        return nil
    }

    private static func closes(_ effects: [Effect]) -> [CycleOutcome] {
        effects.compactMap { if case .closeCycle(_, let o) = $0 { return o } else { return nil } }
    }

    @Test("in the backoff the single prompt offers no snooze, and a snooze sent anyway is refused")
    func backoffOffersNoSnooze() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        driver.day.consecutiveIgnoredCycles = driver.engine.policy.ignoreBackoffThreshold
        guard let prompt = Self.firstPrompt(&driver) else {
            Issue.record("no prompt was ever sent")
            return
        }
        #expect(prompt.snoozeOffered.isEmpty, "a snooze here would wait for a prompt the backoff refuses")

        driver.step(action: .snooze)
        #expect(driver.state.name == "breakDue", "got \(driver.state)")

        var outcome: CycleOutcome?
        var waited: TimeInterval = 0
        for _ in 0..<800 {
            let effects = driver.step()
            waited += EngineHarness.Driver.tick
            if let o = Self.closes(effects).first { outcome = o; break }
        }
        #expect(outcome == .ignoredExhausted, "the single prompt runs out as a backed-off cycle should")
        #expect(waited < 10 * 60, "and not an hour later at the stale ceiling")
    }

    @Test("outside the backoff the first prompt still offers a snooze, and it asks again")
    func snoozeStillWorksOutsideTheBackoff() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        guard let prompt = Self.firstPrompt(&driver) else {
            Issue.record("no prompt was ever sent")
            return
        }
        #expect(!prompt.snoozeOffered.isEmpty)

        driver.step(action: .snooze)
        #expect(driver.state.name == "snoozed")
        let again = Self.firstPrompt(&driver)
        #expect(again?.level == .first, "the snooze sends level 1 again")
    }

    @Test("the prompt that reaches the daily cap offers no snooze")
    func cappingPromptOffersNoSnooze() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        driver.step()
        driver.day.notificationsDelivered = driver.engine.policy.dailyNotificationCap - 1
        guard let prompt = Self.firstPrompt(&driver) else {
            Issue.record("no prompt was ever sent")
            return
        }
        #expect(prompt.snoozeOffered.isEmpty, "nothing can be sent after it today")
    }

    @Test("the fourth prompt of a cycle offers no snooze, however many snoozes are allowed")
    func fourthPromptOffersNoSnooze() {
        var settings = EngineHarness.ownerSettings
        settings.maxSnoozesPerBreak = 10
        var driver = EngineHarness.Driver(settings: settings)
        var offered: [[TimeInterval]] = []
        for _ in 0..<4 {
            guard let prompt = Self.firstPrompt(&driver) else { break }
            offered.append(prompt.snoozeOffered)
            driver.step(action: .snooze)
        }

        #expect(offered.count == 4, "got \(offered.count) prompts")
        #expect(offered.dropLast().allSatisfy { !$0.isEmpty })
        #expect(offered.last?.isEmpty == true, "a fifth could never be sent: \(offered)")
    }
}
