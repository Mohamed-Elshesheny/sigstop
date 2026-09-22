import Foundation
import Testing

@testable import SigstopCore

@Suite("nothing is left on screen that the engine has stopped owning")
struct NothingLeftOnScreenTests {

    private static func ended(_ effects: [Effect]) -> Bool {
        effects.contains { if case .endBreak = $0 { return true } else { return false } }
    }

    private static func startBreak(_ driver: inout EngineHarness.Driver) {
        let begun = driver.step(action: .startBreakNow)
        #expect(begun.contains { if case .beginBreak = $0 { return true } else { return false } })
        guard case .breakActive = driver.state else {
            Issue.record("the break did not start")
            return
        }
    }

    @Test("pausing during a break ends the break first, so the overlay and the clock are released")
    func pauseEndsTheBreak() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        Self.startBreak(&driver)
        driver.step()

        let paused = driver.step(action: .pauseApp(3600))
        #expect(Self.ended(paused), "a pause that skips .endBreak leaves the break screen with no way to close it")
        guard case .quiet(let quiet) = driver.state else {
            Issue.record("expected the pause to hold, got \(driver.state)")
            return
        }
        #expect(quiet.cause == .userPaused)
    }

    @Test("skip, resume, snooze and a second break do nothing while a break is running")
    func otherActionsLeaveTheBreakAlone() {
        for action: UserAction in [.skip, .resumeApp, .snooze, .startBreakNow, .acceptBreak] {
            var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
            Self.startBreak(&driver)
            let before = driver.state

            let produced = driver.step(action: action)
            #expect(produced.isEmpty, "\(action) during a break produced \(produced)")
            #expect(driver.state == before, "\(action) moved the engine out of the break without ending it")

            let ended = driver.step(action: .endBreak)
            #expect(Self.ended(ended), "SIGCONT must still end the break after \(action)")
        }
    }

    @Test("an accepted break, with a cycle, cannot be skipped away and pauses by ending first")
    func acceptedBreakWithACycle() {
        var skipped = EngineHarness.Session()
        skipped.stepToPrompt()
        skipped.step(action: .acceptBreak)
        guard case .breakActive(let active) = skipped.driver.state, active.cycle != nil else {
            Issue.record("expected an accepted break that carries its cycle")
            return
        }
        let before = skipped.driver.state
        #expect(skipped.step(action: .skip).isEmpty, "skip during an accepted break closed its cycle")
        #expect(skipped.driver.state == before)

        var paused = EngineHarness.Session()
        paused.stepToPrompt()
        paused.step(action: .acceptBreak)
        let effects = paused.step(action: .pauseApp(3600))
        let end = effects.firstIndex { if case .endBreak = $0 { return true } else { return false } }
        let close = effects.firstIndex { if case .closeCycle = $0 { return true } else { return false } }
        #expect(end != nil, "pausing an accepted break never ended it")
        if let end, let close { #expect(end < close) }
    }

    @Test("a ladder that runs out takes its prompt down with it")
    func exhaustionWithdrawsThePrompt() {
        var session = EngineHarness.Session()
        session.driver.day.consecutiveIgnoredCycles = 2
        session.stepToPrompt()

        let closed = session.step(untilLimit: 900) { effects in
            effects.contains { if case .closeCycle(_, .ignoredExhausted) = $0 { return true } else { return false } }
        }
        let close = closed.firstIndex { if case .closeCycle = $0 { return true } else { return false } }
        let withdraw = closed.firstIndex { if case .withdrawPrompt = $0 { return true } else { return false } }
        #expect(withdraw != nil, "a closed cycle with its prompt still up leaves a full-screen panel nothing removes")
        if let close, let withdraw { #expect(withdraw < close) }
    }
}
