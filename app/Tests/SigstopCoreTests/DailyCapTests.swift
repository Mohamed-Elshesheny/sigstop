import Foundation
import Testing

@testable import SigstopCore

/// The daily cap is the app's promise not to become the thing you uninstall: a ceiling on
/// how many times it may interrupt you in one day. These cover the four ways it was
/// getting that wrong, all of them observed in a real session on 2026-09-21.
struct DailyCapTests {

    @Test("the cap is a floor derived from the interval, not a flat number")
    func capScalesWithTheInterval() {
        var short = SigstopSettings()
        short.workIntervalMinutes = 5
        short.breakDurationMinutes = 5
        short.maxNotificationsPerDay = 14

        // 5 + 5 = a ten minute cycle, so a sixteen hour day has room for 96 of them. The
        // user's 14 would have been spent in about two hours and the app would then have
        // said nothing until 4am.
        let policy = BreakPolicy(settings: short)
        #expect(policy.dailyNotificationCap == 96, "got \(policy.dailyNotificationCap)")

        var normal = SigstopSettings()
        normal.workIntervalMinutes = 45
        normal.breakDurationMinutes = 5
        normal.maxNotificationsPerDay = 14
        // At 50 minutes a cycle there is room for 19, which is above the user's 14, so at a
        // sane interval the number they set is the number that governs.
        #expect(BreakPolicy(settings: normal).dailyNotificationCap == 19)

        var generous = SigstopSettings()
        generous.workIntervalMinutes = 45
        generous.breakDurationMinutes = 5
        generous.maxNotificationsPerDay = 40
        #expect(BreakPolicy(settings: generous).dailyNotificationCap == 40, "a bigger number still wins")
    }

    @Test("the literal defaults match the settings defaults")
    func literalsAgreeWithSettings() {
        // `BreakPolicy()` is what a caller gets by omission, so a literal that disagrees
        // with the settings default means tests run a policy the app never uses.
        #expect(BreakPolicy().dailyNotificationCap == SigstopSettings.default.maxNotificationsPerDay)
        #expect(BreakPolicy().maxSnoozesPerCycle == SigstopSettings.default.maxSnoozesPerBreak)
    }

    @Test("a spent budget does not open a cycle it would have to close in the same tick")
    func noPhantomCycles() {
        var settings = EngineHarness.ownerSettings
        settings.maxNotificationsPerDay = 1
        var session = EngineHarness.Session(settings: settings)

        // One tick first: `step` rolls the day over on its first pass, because a fresh
        // `DailyCounters` has no day index yet, and a rollover zeroes the budget.
        session.step()
        // Spend the whole budget.
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

        // The prompt is up. Now spend the budget under it, the way a second cycle would.
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
        // WaitingLine's own doc: "holding off" means something is blocking or rate-limiting
        // a prompt right now; "not asking yet" means nothing is. The cap is the rate limit.
        let capped = WaitingLine.read(
            WaitingLine.Reading(
                state: .quiet(QuietState(cause: .dailyCapReached)),
                now: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        #expect(capped.claim == .holdingOff, "got \(capped.claim)")
        #expect(capped.text.hasPrefix("holding off,"))

        // And while working with the budget gone, it must not count down to a prompt that
        // is never going to be sent.
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
