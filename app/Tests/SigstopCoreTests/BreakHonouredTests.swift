import Foundation
import Testing

@testable import SigstopCore

@Suite("A completed break is honoured")
struct BreakHonouredTests {

    private static func settings(breakMinutes: Int, idleCountsAs: Int) -> SigstopSettings {
        var s = EngineHarness.ownerSettings
        s.workIntervalMinutes = 1
        s.breakDurationMinutes = breakMinutes
        s.idleCountsAsBreakMinutes = idleCountsAs
        return s
    }

    private static func takeOneBreak(_ settings: SigstopSettings) -> [Effect] {
        var driver = EngineHarness.Driver(settings: settings)
        var accepted = false
        for _ in 0..<400 {
            if !accepted, driver.effects.contains(where: {
                if case .deliverPrompt = $0 { return true } else { return false }
            }) {
                driver.step(action: .acceptBreak)
                accepted = true
                continue
            }
            driver.step()
            if driver.effects.contains(where: {
                if case .closeCycle = $0 { return true } else { return false }
            }) { break }
        }
        return driver.effects
    }

    private static func outcome(in effects: [Effect]) -> CycleOutcome? {
        for effect in effects {
            if case .closeCycle(_, let outcome) = effect { return outcome }
        }
        return nil
    }

    @Test("A one minute break, sat through, is not a skip")
    func shortBreakCounts() {
        let effects = Self.takeOneBreak(Self.settings(breakMinutes: 1, idleCountsAs: 5))
        #expect(Self.outcome(in: effects) == .honored)
    }

    @Test("The break the app asked for counts whatever the idle threshold is")
    func anyConfiguredLengthCounts() {
        for breakMinutes in [1, 2, 3, 5] {
            let effects = Self.takeOneBreak(Self.settings(breakMinutes: breakMinutes, idleCountsAs: 5))
            #expect(
                Self.outcome(in: effects) == .honored,
                "a \(breakMinutes) minute break was not honoured"
            )
        }
    }

    @Test("The default five minute break is not decided on a boundary")
    func defaultsAreNotOnTheBoundary() {
        let effects = Self.takeOneBreak(Self.settings(breakMinutes: 5, idleCountsAs: 5))
        #expect(Self.outcome(in: effects) == .honored)
    }

    @Test("The day counts it as an opportunity honoured")
    func dayCountsIt() {
        var driver = EngineHarness.Driver(settings: Self.settings(breakMinutes: 1, idleCountsAs: 5))
        var accepted = false
        for _ in 0..<400 {
            if !accepted, driver.effects.contains(where: {
                if case .deliverPrompt = $0 { return true } else { return false }
            }) {
                driver.step(action: .acceptBreak)
                accepted = true
                continue
            }
            driver.step()
            if driver.effects.contains(where: {
                if case .closeCycle = $0 { return true } else { return false }
            }) { break }
        }
        #expect(driver.day.honoredOpportunities == 1)
    }
}
