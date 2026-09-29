import Foundation
import Testing

@testable import SigstopCore

@Suite("the held mark survives silence on a call")
struct HeldWhileIdleTests {

    private static func indicators(_ effects: [Effect]) -> [IndicatorState] {
        effects.compactMap { if case .setIndicator(let s) = $0 { return s } else { return nil } }
    }

    private static func onACallWithABreakDue() -> EngineHarness.Driver {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        driver.micRunning = true
        driver.cameraRunning = true
        driver.step(untilLimit: 200) { Self.indicators($0).last == .held }
        return driver
    }

    @Test("listening on a call keeps the resting dashes, not the dim idle bars")
    func heldThroughSilence() {
        var driver = Self.onACallWithABreakDue()
        #expect(Self.indicators(driver.effects).last == .held)

        driver.idleSeconds = 95
        #expect(Self.indicators(driver.step()).last == .held)
        if case .idle = driver.state {} else { Issue.record("expected the cycle parked as idle, got \(driver.state)") }
        for _ in 0..<24 {
            driver.idleSeconds += 5
            #expect(Self.indicators(driver.step()).last == .held)
        }
    }

    @Test("when the call ends while you are still away, the mark goes idle")
    func idleOnceTheCallEnds() {
        var driver = Self.onACallWithABreakDue()
        driver.idleSeconds = 95
        driver.step()
        driver.micRunning = false
        driver.cameraRunning = false
        #expect(Self.indicators(driver.step()).last == .idle)
    }

    @Test("coming back to the keyboard mid call is still held")
    func backAtTheKeyboard() {
        var driver = Self.onACallWithABreakDue()
        driver.idleSeconds = 95
        driver.step()
        driver.idleSeconds = 0
        #expect(Self.indicators(driver.step()).last == .held)
    }

    @Test("away with nothing due is idle, call or no call")
    func nothingDueIsIdle() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        driver.micRunning = true
        driver.cameraRunning = true
        driver.step()
        driver.idleSeconds = 95
        #expect(Self.indicators(driver.step()).last == .idle)
    }

    @Test("a ladder parked by a call rests the same way")
    func parkedLadderOnACall() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        driver.step(untilLimit: 200) { effects in
            effects.contains { if case .deliverPrompt = $0 { return true } else { return false } }
        }
        for _ in 0..<40 {
            driver.step()
            if case .ignored = driver.state { break }
        }
        guard case .ignored = driver.state else {
            Issue.record("the prompt was never ignored: \(driver.state)")
            return
        }
        driver.micRunning = true
        driver.cameraRunning = true
        #expect(Self.indicators(driver.step()).last == .held)
        driver.idleSeconds = 95
        #expect(Self.indicators(driver.step()).last == .held)
        if case .idle = driver.state {} else { Issue.record("expected the ladder parked as idle, got \(driver.state)") }
    }
}
