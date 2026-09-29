import Foundation
import Testing

@testable import SigstopCore

@Suite("a break that runs out on its own is the only one that chimes")
struct BreakEndingTests {

    private static func endsBreak(_ effects: [Effect]) -> Bool {
        effects.contains { if case .endBreak = $0 { return true } else { return false } }
    }

    private static func driverInABreak() -> EngineHarness.Driver {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        let begun = driver.step(action: .startBreakNow)
        precondition(begun.contains { if case .beginBreak = $0 { return true } else { return false } })
        return driver
    }

    private static func ranOut(
        _ driver: EngineHarness.Driver, _ effects: [Effect], from before: EngineState, userAction: UserAction? = nil
    ) -> Bool {
        BreakEnding.ranOut(
            effects, userAction: userAction, from: before,
            monotonic: driver.monotonic, policy: driver.engine.policy
        )
    }

    @Test("when the planned duration passes with nobody pressing anything, it ran out")
    func timeUpRanOut() {
        var driver = Self.driverInABreak()
        let (before, ending) = driver.stepUntilBreakEnds()
        #expect(Self.endsBreak(ending), "the break never ended on its own")
        #expect(Self.ranOut(driver, ending, from: before))
    }

    @Test("SIGCONT pressed early ends the break, and that is not running out")
    func sigcontIsNotRunningOut() {
        var driver = Self.driverInABreak()
        driver.step(times: 3)
        let before = driver.state
        let ending = driver.step(action: .endBreak)
        #expect(Self.endsBreak(ending), "the user's SIGCONT did not end the break")
        #expect(!Self.ranOut(driver, ending, from: before, userAction: .endBreak))
    }

    @Test("pausing the app mid-break ends the break, and that is not running out either")
    func pauseIsNotRunningOut() {
        var driver = Self.driverInABreak()
        driver.step(times: 3)
        let before = driver.state
        let ending = driver.step(action: .pauseApp(3600))
        #expect(Self.endsBreak(ending), "the pause did not end the break")
        #expect(!Self.ranOut(driver, ending, from: before, userAction: .pauseApp(3600)))
    }

    @Test("a tick that ends nothing never chimes")
    func quietTickDoesNotChime() {
        var driver = Self.driverInABreak()
        let before = driver.state
        let middle = driver.step()
        #expect(!Self.endsBreak(middle))
        #expect(!Self.ranOut(driver, middle, from: before))
    }

    @Test("a break that ran out while the Mac slept ends at wake, and that is not a chime")
    func sleepingThroughTheEndIsSilent() {
        var driver = Self.driverInABreak()
        driver.step(times: 3)
        driver.sleepAndWake(for: 2 * 3600)
        let before = driver.state
        let ending = driver.step()
        #expect(Self.endsBreak(ending), "the break did not end on the first tick after waking")
        #expect(!Self.ranOut(driver, ending, from: before), "Glass played hours after the break ended")
    }

    @Test("a tick that lands within a tick's tolerance of the planned end still chimes")
    func aLateTickStillChimes() {
        var driver = Self.driverInABreak()
        let slack = driver.engine.policy.tickInterval + driver.engine.policy.tickTolerance
        driver.stepToTheLastTick()
        driver.sleepAndWake(for: slack)
        let before = driver.state
        let ending = driver.step()
        #expect(Self.endsBreak(ending), "the break did not end on the last tick")
        #expect(Self.ranOut(driver, ending, from: before))
    }

    @Test("a tick later than that is a discontinuity, and the ending is silent")
    func aDiscontinuityIsSilent() {
        var driver = Self.driverInABreak()
        let slack = driver.engine.policy.tickInterval + driver.engine.policy.tickTolerance
        driver.stepToTheLastTick()
        driver.sleepAndWake(for: slack + 1)
        let before = driver.state
        let ending = driver.step()
        #expect(Self.endsBreak(ending), "the break did not end on the last tick")
        #expect(!Self.ranOut(driver, ending, from: before))
    }
}

private extension EngineHarness.Driver {
    mutating func step(times: Int) {
        for _ in 0..<times { step() }
    }

    mutating func sleepAndWake(for seconds: TimeInterval) {
        monotonic += seconds
        now = now.addingTimeInterval(seconds)
    }

    mutating func stepToTheLastTick(limit: Int = 200) {
        for _ in 0..<limit {
            guard case .breakActive(let active) = state else { return }
            if monotonic + Self.tick >= active.startedMono + active.plannedDuration { return }
            step()
        }
    }

    mutating func stepUntilBreakEnds(limit: Int = 200) -> (before: EngineState, effects: [Effect]) {
        for _ in 0..<limit {
            let before = state
            let produced = step()
            if produced.contains(where: { if case .endBreak = $0 { return true } else { return false } }) {
                return (before, produced)
            }
        }
        return (state, [])
    }
}
