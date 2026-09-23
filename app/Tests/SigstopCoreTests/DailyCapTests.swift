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

    private static func delivered(_ effects: [Effect]) -> [PromptRequest] {
        effects.compactMap { if case .deliverPrompt(let p) = $0 { return p } else { return nil } }
    }

    private static func closes(_ effects: [Effect]) -> [CycleOutcome] {
        effects.compactMap { if case .closeCycle(_, let o) = $0 { return o } else { return nil } }
    }

    private static func takenDown(_ effects: [Effect]) -> Bool {
        effects.contains {
            switch $0 {
            case .withdrawPrompt, .closeCycle: return true
            default: return false
            }
        }
    }

    private static func cappedQuiet(_ state: EngineState) -> Bool {
        if case .quiet(let q) = state { return q.cause == .dailyCapReached }
        return false
    }

    private static func runToTheCap(
        _ driver: inout EngineHarness.Driver, leaving left: Int
    ) -> (at: Double, level: EscalationLevel)? {
        driver.step()
        let cap = driver.engine.policy.dailyNotificationCap
        driver.day.notificationsDelivered = cap - left
        for _ in 0..<1200 {
            let effects = driver.step()
            if let prompt = delivered(effects).last, driver.day.notificationsDelivered >= cap {
                return (driver.monotonic, prompt.level)
            }
        }
        return nil
    }

    private static func runToTheClose(
        _ driver: inout EngineHarness.Driver
    ) -> (at: Double, outcome: CycleOutcome, sentAfterTheCap: Int)? {
        var sent = 0
        for _ in 0..<1200 {
            let effects = driver.step()
            sent += delivered(effects).count
            if let outcome = closes(effects).first { return (driver.monotonic, outcome, sent) }
        }
        return nil
    }

    @Test("a cap reached partway up the ladder ends the cycle once that prompt has had its time")
    func capPartwayUpTheLadder() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        let policy = driver.engine.policy
        guard let capped = Self.runToTheCap(&driver, leaving: 2) else {
            Issue.record("the cap was never reached")
            return
        }
        #expect(capped.level == .second)
        guard let close = Self.runToTheClose(&driver) else {
            Issue.record("the cycle never closed: \(driver.state)")
            return
        }

        #expect(close.outcome == .dailyCapReached, "the cap ended it, not the user")
        #expect(close.sentAfterTheCap == 0)
        #expect(close.at - capped.at >= policy.promptTimeout, "the last prompt still gets its time")
        #expect(close.at - capped.at < policy.promptTimeout + 2 * EngineHarness.Driver.tick,
                "and nothing more: the ladder has nothing left to send")
        #expect(Self.cappedQuiet(driver.state), "got \(driver.state)")
        #expect(driver.day.consecutiveIgnoredCycles == 0, "a ladder the cap cut short is not an ignored cycle")
    }

    @Test("the prompt that reaches the cap stays up for its time")
    func cappingFirstPromptStandsItsTime() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        let policy = driver.engine.policy
        guard let capped = Self.runToTheCap(&driver, leaving: 1) else {
            Issue.record("the cap was never reached")
            return
        }
        #expect(capped.level == .first)

        let standing = Int(policy.promptTimeout / EngineHarness.Driver.tick) - 1
        for _ in 0..<standing {
            let effects = driver.step()
            #expect(!Self.takenDown(effects), "taken down \(driver.monotonic - capped.at)s after it was posted")
        }
        guard let close = Self.runToTheClose(&driver) else {
            Issue.record("the cycle never closed: \(driver.state)")
            return
        }

        #expect(close.outcome == .dailyCapReached)
        #expect(close.at - capped.at >= policy.promptTimeout)
        #expect(Self.cappedQuiet(driver.state), "got \(driver.state)")
        #expect(driver.day.consecutiveIgnoredCycles == 0)
    }

    @Test("a full ladder that reaches the cap on its last rung is still ignored, and then quiet")
    func fullLadderAtTheCap() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        guard let capped = Self.runToTheCap(&driver, leaving: 4) else {
            Issue.record("the cap was never reached")
            return
        }
        #expect(capped.level == .incident)
        guard let close = Self.runToTheClose(&driver) else {
            Issue.record("the cycle never closed: \(driver.state)")
            return
        }

        #expect(close.outcome == .ignoredExhausted, "every rung was sent and waved off")
        #expect(driver.day.consecutiveIgnoredCycles == 1)
        #expect(Self.cappedQuiet(driver.state), "no cooldown to a prompt the day cannot send: \(driver.state)")
    }
}

@Suite("a new day starts with a new budget")
struct DayRolloverBudgetTests {

    @Test("the tick that crosses into a new day does not hold on to yesterday's spent budget")
    func rolloverClearsTheCap() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        driver.calendarSystem = utc
        let policy = BreakPolicy(settings: EngineHarness.ownerSettings)
        let today = LocalDay.index(
            of: driver.now.addingTimeInterval(EngineHarness.Driver.tick), calendar: utc, boundaryHour: policy.dayBoundaryHour
        )
        driver.day.dayIndex = today - 1
        driver.day.notificationsDelivered = policy.dailyNotificationCap
        driver.state = .quiet(QuietState(cause: .dailyCapReached))
        driver.continuousWork = policy.targetContinuousWork + 60

        driver.step()

        if case .quiet(let quiet) = driver.state, quiet.cause == .dailyCapReached {
            Issue.record("the new day went straight back to yesterday's spent budget")
        }
        #expect(driver.day.dayIndex == today)
        #expect(driver.day.notificationsDelivered < policy.dailyNotificationCap, "today's count starts again from zero")
    }
}
