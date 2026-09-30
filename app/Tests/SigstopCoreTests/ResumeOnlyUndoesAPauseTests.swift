import Foundation
import Testing

@testable import SigstopCore

@Suite("Resume undoes a pause and does nothing else")
struct ResumeOnlyUndoesAPauseTests {

    typealias Bench = TrackerEngineBench

    @Test("a Resume that lands after the pause ran out leaves the skip's quiet time alone")
    func lateResumeKeepsTheSkip() throws {
        var bench = Bench()
        let prompt = bench.workUntilPrompt()
        _ = try #require(prompt)
        bench.tick(action: .skip)
        let skippedAt = bench.continuousWork
        bench.tick(action: .pauseApp(60))
        bench.work(minutes: 2)
        let before = try #require(bench.working, "the pause did not run out: \(bench.state)")

        let produced = bench.tick(action: .resumeApp)
        let working = try #require(bench.working, "expected working, got \(bench.state)")
        #expect(produced.isEmpty, "a Resume with nothing paused produced \(produced)")
        #expect(working == before)
        #expect(working.standDown == .skipped)
        #expect(working.armThreshold == skippedAt + bench.policy.rearmAfterSkip)
    }

    @Test("a Resume while a prompt is up leaves the cycle open")
    func resumeLeavesAPromptAlone() throws {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        driver.step { effects in
            effects.contains { if case .deliverPrompt = $0 { return true } else { return false } }
        }
        let before = driver.state
        #expect(before.openCycle != nil, "no prompt came up: \(before)")

        let produced = driver.step(action: .resumeApp)
        #expect(produced.isEmpty, "a Resume with nothing paused produced \(produced)")
        #expect(driver.state == before, "the open cycle was dropped without being closed: \(driver.state)")
    }

    @Test("a Resume in quiet hours or with the day's cap spent does not end them",
          arguments: [QuietCause.scheduledQuietHours, .dailyCapReached])
    func resumeLeavesOtherQuietAlone(_ cause: QuietCause) {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        driver.state = .quiet(QuietState(cause: cause))
        let before = driver.state

        let produced = driver.step(action: .resumeApp)
        #expect(produced.isEmpty)
        #expect(driver.state == before)
    }

    @Test("a Resume inside the pause still ends it")
    func resumeEndsAPause() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        driver.step(action: .pauseApp(3600))
        let produced = driver.step(action: .resumeApp)
        #expect(driver.state.isWorking, "\(driver.state)")
        #expect(produced.contains(.setIndicator(.working)))
    }
}
