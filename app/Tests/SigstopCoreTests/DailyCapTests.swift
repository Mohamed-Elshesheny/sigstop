import Foundation
import Testing

@testable import SigstopCore

struct DailyCapTests {

    @Test("the cap is a floor derived from the interval, not a flat number")
    func capScalesWithTheInterval() {
        var short = SigstopSettings()
        short.workIntervalMinutes = 5
        short.breakDurationMinutes = 5
        short.maxNotificationsPerDay = 14

        let policy = BreakPolicy(settings: short)
        #expect(policy.dailyNotificationCap == 96, "got \(policy.dailyNotificationCap)")

        var normal = SigstopSettings()
        normal.workIntervalMinutes = 45
        normal.breakDurationMinutes = 5
        normal.maxNotificationsPerDay = 14
        #expect(BreakPolicy(settings: normal).dailyNotificationCap == 19)

        var generous = SigstopSettings()
        generous.workIntervalMinutes = 45
        generous.breakDurationMinutes = 5
        generous.maxNotificationsPerDay = 40
        #expect(BreakPolicy(settings: generous).dailyNotificationCap == 40, "a bigger number still wins")
    }

    @Test("the literal defaults match the settings defaults")
    func literalsAgreeWithSettings() {
        #expect(BreakPolicy().dailyNotificationCap == SigstopSettings.default.maxNotificationsPerDay)
        #expect(BreakPolicy().maxSnoozesPerCycle == SigstopSettings.default.maxSnoozesPerBreak)
    }

    @Test("a spent budget does not open a cycle it would have to close in the same tick")
    func noPhantomCycles() {
        var settings = EngineHarness.ownerSettings
        settings.maxNotificationsPerDay = 1
        var session = EngineHarness.Session(settings: settings)

        session.step()
        session.driver.day.notificationsDelivered = session.driver.engine.policy.dailyNotificationCap
        let before = session.driver.day.nextCycle

        session.step(times: 400)

        let opens = session.log.lines.filter { $0.kind == .breakOpen }
        #expect(opens.isEmpty, "no cycle may be opened once the day is spent, got \(opens.count)")
        #expect(session.driver.day.nextCycle == before, "no cycle id may be burned either")
        #expect(session.driver.day.breakOpportunities == 0, "and none may be counted as an opportunity")
    }

    @Test("a cycle closed by a rate limit takes its prompt off the screen with it")
    func rateLimitWithdrawsTheStandingPrompt() {
        var settings = EngineHarness.ownerSettings
        settings.maxNotificationsPerDay = 60
        var session = EngineHarness.Session(settings: settings)
        session.stepToPrompt()

        session.driver.day.notificationsDelivered = session.driver.engine.policy.dailyNotificationCap
        session.step(times: 40)

        let withdrew = session.driver.effects.contains {
            if case .withdrawPrompt(_, let reason) = $0 { return reason == .dailyCapReached }
            return false
        }
        let closed = session.driver.effects.contains {
            if case .closeCycle(_, let outcome) = $0 { return outcome == .dailyCapReached }
            return false
        }
        #expect(closed, "the cap must close the cycle")
        #expect(withdrew, "and must not leave the panel up for a cycle it has closed")
    }

    @Test("the panel says it is holding off, not that nothing is holding it")
    func theLineDoesNotContradictItself() {
        let capped = WaitingLine.read(
            WaitingLine.Reading(
                state: .quiet(QuietState(cause: .dailyCapReached)),
                now: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        #expect(capped.claim == .holdingOff, "got \(capped.claim)")
        #expect(capped.text.hasPrefix("holding off,"))

        let policy = BreakPolicy()
        let spent = WaitingLine.read(
            WaitingLine.Reading(
                state: .working(WorkingState(armThreshold: 45 * 60)),
                continuousWork: 60,
                now: Date(timeIntervalSince1970: 1_700_000_000),
                policy: policy,
                notificationsDelivered: policy.dailyNotificationCap
            )
        )
        #expect(spent.claim == .holdingOff, "got \(spent.claim): \(spent.text)")
        #expect(!spent.text.contains("of work away"), "no countdown to a prompt that cannot be sent")
    }
}
