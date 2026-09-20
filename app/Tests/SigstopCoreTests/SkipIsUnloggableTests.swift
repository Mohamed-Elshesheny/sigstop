import Foundation
import Testing

@testable import SigstopCore

/// The 20:06:51Z incident, reproduced against the shipping engine.
///
/// The owner sat in front of a panel reading RUNNING for eighteen minutes with a five
/// minute work interval and never saw a prompt. The event log for that window contains
/// exactly two lines, `break_open` and `break_prompt`, and then nothing at all until a
/// second cycle opened 1205 seconds later.
///
/// The cycle was never wedged. The L1 prompt was drawn, dismissed within one tick, and
/// the dismissal re-armed the engine for twenty minutes. None of that reached the log,
/// because the one transition the app is structurally incapable of writing down is the
/// one that costs the most.
@Suite("a dismissed prompt leaves a trace")
struct SkipIsUnloggableTests {

    // MARK: - The reproduction

    /// The regression itself. Drive the engine to a prompt, dismiss it on the next tick,
    /// and replay the effect stream through the shipping log writer.
    ///
    /// Before the fix this produced exactly `["break_open", "break_prompt"]`, which is
    /// character for character the entire trace cycle 0 left in the owner's file.
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

    /// The same decision, asserted on the payload rather than on the index.
    ///
    /// A pure reorder of the skip's effect list would have made the test above pass and
    /// left the next edit free to silently undo it. What actually fixes the defect is
    /// that the effect names its own cycle, so this pins that instead.
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

    /// Snooze and ignore carry the same payload, so neither survives on ordering luck.
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

    /// The timeout path that did not fire at 20:06:51Z. Left standing, an L1 prompt is
    /// classified ignored ninety seconds later and the ladder starts climbing.
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

    /// The twenty minutes of silence that follow, pinned as policy rather than accident.
    ///
    /// The observed gap between `break_open {cycle:0}` at 20:06:51Z and
    /// `break_open {cycle:1}` at 20:26:56Z is 1205 seconds. A skip at 305 seconds of
    /// continuous work sets `armThreshold` to 305 + 1200 = 1505, and 1505 - 300 is 1205.
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
