import Foundation
import Testing

@testable import SigstopCore

@Suite("a dismissed prompt leaves a trace")
struct SkipIsUnloggableTests {

    @Test("dismissing a prompt records that it was dismissed")
    func skipIsRecorded() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        var log = EngineHarness.LogReplay()

        let opened = driver.step(untilLimit: 200) { effects in
            effects.contains { if case .deliverPrompt = $0 { return true } else { return false } }
        }
        #expect(!opened.isEmpty, "the engine must prompt at all before anything else is meaningful")
        log.execute(driver.effects, at: driver.now)
        #expect(log.kinds == ["break_open", "break_prompt"], "the prompt reached the screen")

        let dismissal = driver.step(action: .skip)
        log.execute(dismissal, at: driver.now)

        let responses = log.lines.filter { $0.kind == .breakResponse }
        #expect(
            responses.contains { $0.action == .skipped },
            """
            the app wrote nothing when the user answered the prompt.
            log was \(log.kinds)
            """
        )
        #expect(
            log.lines.contains { $0.kind == .cycleClose && $0.outcome == .skipped },
            "and the opportunity must say how it ended"
        )
    }

    @Test("a user decision names the cycle it belongs to, whatever the effect order")
    func decisionsCarryTheirCycle() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        driver.step(untilLimit: 200) { effects in
            effects.contains { if case .deliverPrompt = $0 { return true } else { return false } }
        }
        let open = driver.state.openCycle
        let dismissal = driver.step(action: .skip)

        let recorded: CycleID? = dismissal.compactMap {
            if case .recordSkip(let cycle) = $0 { return cycle } else { return nil }
        }.first
        #expect(recorded != nil, "a skip must emit a record effect")
        #expect(recorded == open, "and it must name the cycle that was open")

        let closedBefore = dismissal.firstIndex {
            if case .closeCycle = $0 { return true } else { return false }
        }
        let recordedAt = dismissal.firstIndex {
            if case .recordSkip = $0 { return true } else { return false }
        }
        #expect(
            closedBefore != nil && recordedAt != nil && closedBefore! < recordedAt!,
            "the close still precedes the record; the payload is what makes that safe"
        )
    }

    @Test("snooze names its cycle too")
    func snoozeCarriesItsCycle() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        driver.step(untilLimit: 200) { effects in
            effects.contains { if case .deliverPrompt = $0 { return true } else { return false } }
        }
        let open = driver.state.openCycle
        let snoozed = driver.step(action: .snooze)

        let recorded: (CycleID, TimeInterval)? = snoozed.compactMap {
            if case .recordSnooze(let cycle, let duration) = $0 { return (cycle, duration) } else { return nil }
        }.first
        guard let recorded else {
            Issue.record("a snooze must emit a record effect")
            return
        }
        #expect(recorded.0 == open)
        #expect(recorded.1 == TimeInterval(5 * 60))
    }

    @Test("an unanswered prompt still times out at ninety seconds")
    func unansweredPromptTimesOut() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        driver.step(untilLimit: 200) { effects in
            effects.contains { if case .deliverPrompt = $0 { return true } else { return false } }
        }
        let promptedAt = driver.monotonic

        let ignored = driver.step(untilLimit: 60) { effects in
            effects.contains { if case .recordIgnoredPrompt = $0 { return true } else { return false } }
        }
        #expect(!ignored.isEmpty, "the prompt must be classified ignored on its own")
        #expect(driver.monotonic - promptedAt == 90, "promptTimeout is 90 seconds")

        let recorded: CycleID? = ignored.compactMap {
            if case .recordIgnoredPrompt(let cycle) = $0 { return cycle } else { return nil }
        }.first
        #expect(recorded == CycleID.initial)

        var levels: [EscalationLevel] = []
        for _ in 0..<400 {
            for effect in driver.step() {
                if case .deliverPrompt(let p) = effect { levels.append(p.level) }
            }
        }
        #expect(levels.contains(.second), "and the ladder must climb")
    }

    @Test("a skip re-arms for twenty minutes, to the second")
    func skipRearmsForTwentyMinutes() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)

        driver.step(untilLimit: 200) { effects in
            effects.contains { if case .deliverPrompt = $0 { return true } else { return false } }
        }
        let openedAt = driver.continuousWork
        driver.step(action: .skip)

        guard case .working(let w) = driver.state else {
            Issue.record("a skip must return the engine to working, got \(driver.state.name)")
            return
        }
        #expect(w.armThreshold == driver.continuousWork + 20 * 60)

        var opens = 0
        for _ in 0..<400 {
            let produced = driver.step()
            if produced.contains(where: { if case .openCycle = $0 { return true } else { return false } }) {
                opens += 1
                break
            }
        }
        #expect(opens == 1, "a second cycle must eventually open")
        #expect(driver.continuousWork - openedAt == 1205, "the gap the owner measured")
    }
}
