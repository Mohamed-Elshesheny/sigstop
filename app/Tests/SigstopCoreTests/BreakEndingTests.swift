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

    @Test("when the planned duration passes with nobody pressing anything, it ran out")
    func timeUpRanOut() {
        var driver = Self.driverInABreak()
        let ending = driver.step(untilLimit: 200) { Self.endsBreak($0) }
        #expect(Self.endsBreak(ending), "the break never ended on its own")
        #expect(BreakEnding.ranOut(ending, userAction: nil))
    }

    @Test("SIGCONT pressed early ends the break, and that is not running out")
    func sigcontIsNotRunningOut() {
        var driver = Self.driverInABreak()
        driver.step(times: 3)
        let ending = driver.step(action: .endBreak)
        #expect(Self.endsBreak(ending), "the user's SIGCONT did not end the break")
        #expect(!BreakEnding.ranOut(ending, userAction: .endBreak))
    }

    @Test("pausing the app mid-break ends the break, and that is not running out either")
    func pauseIsNotRunningOut() {
        var driver = Self.driverInABreak()
        driver.step(times: 3)
        let ending = driver.step(action: .pauseApp(3600))
        #expect(Self.endsBreak(ending), "the pause did not end the break")
        #expect(!BreakEnding.ranOut(ending, userAction: .pauseApp(3600)))
    }

    @Test("a tick that ends nothing never chimes")
    func quietTickDoesNotChime() {
        var driver = Self.driverInABreak()
        let middle = driver.step()
        #expect(!Self.endsBreak(middle))
        #expect(!BreakEnding.ranOut(middle, userAction: nil))
    }
}

private extension EngineHarness.Driver {
    mutating func step(times: Int) {
        for _ in 0..<times { step() }
    }
}
