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

    // MARK: - The world

    /// The owner's settings, read from
    /// `~/Library/Application Support/dev.sigstop.app/settings.json` on the machine that
    /// produced the log. Five minute interval, quiet hours off, panel delivery.
    static var ownerSettings: SigstopSettings {
        var s = SigstopSettings()
        s.workIntervalMinutes = 5
        s.breakDurationMinutes = 5
        s.microIdleThresholdSeconds = 90
        s.maxNotificationsPerDay = 14
        s.maxSnoozesPerBreak = 2
        s.snoozeMinutes = 5
        s.idleCountsAsBreakMinutes = 5
        s.useSystemNotifications = false
        s.tone = .nuclear
        s.quietHours = QuietHours(enabled: false)
        return s
    }

    /// The shipping engine, stepped at the shipping five second cadence with the clock
    /// injected. Nothing is mocked but time and the machine's signals.
    struct Driver {
        static let tick: TimeInterval = 5

        let engine: BreakDecisionEngine
        let settings: SigstopSettings
        var state: EngineState
        var day = DailyCounters()
        var now: Date
        var monotonic: Double = 0
        var continuousWork: TimeInterval = 0
        var micRunning = false

        private(set) var effects: [Effect] = []

        init(settings: SigstopSettings, start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
            self.settings = settings
            self.engine = BreakDecisionEngine(settings: settings)
            self.now = start
            self.state = .working(
                WorkingState(armThreshold: TimeInterval(settings.workIntervalMinutes) * 60)
            )
        }

        /// One tick. Returns the effects this step produced, and also appends them to the
        /// running stream so a whole scenario can be asserted on at the end.
        @discardableResult
        mutating func step(action: UserAction? = nil) -> [Effect] {
            monotonic += Self.tick
            now = now.addingTimeInterval(Self.tick)
            if case .breakActive = state {} else { continuousWork += Self.tick }

            let context = DeveloperContext(
                timestamp: now,
                application: AppIdentity(bundleID: "com.apple.dt.Xcode", localizedName: "Xcode", pid: 1),
                activity: .coding,
                confidence: Confidence(0.8),
                continuousWork: continuousWork,
                idleSeconds: 0
            )
            let input = EngineInput(
                now: now,
                monotonic: monotonic,
                context: context,
                signals: SystemSignals(audioInputRunning: micRunning),
                settings: settings,
                day: day,
                userAction: action
            )

            let outcome = engine.step(state, input)
            state = outcome.state
            day = outcome.day
            effects.append(contentsOf: outcome.effects)
            return outcome.effects
        }

        /// Steps until `predicate` holds, up to `limit` ticks. Returns the tick's effects.
        @discardableResult
        mutating func step(untilLimit limit: Int = 600, _ predicate: ([Effect]) -> Bool) -> [Effect] {
            for _ in 0..<limit {
                let produced = step()
                if predicate(produced) { return produced }
            }
            return []
        }
    }

    // MARK: - The app's cycle bookkeeping, transcribed

    /// A faithful transcription of the only part of `AppModel.execute` that decides
    /// whether a decision reaches the event log: `AppModel.swift:370-376` nils
    /// `currentCycle` on `.closeCycle`, and `:429-451` reconstructs the id from it.
    ///
    /// This lives in the test rather than in the app because `SigstopApp` has no test
    /// target: there is no Xcode and no window server in CI, which is exactly why the
    /// defect could not be caught where it lives. Replacing this transcription with the
    /// real code is the point of `EventLogWriter`.
    struct CycleBookkeeping {
        private(set) var log: [String] = []
        private var currentCycle: CycleID?

        mutating func execute(_ effect: Effect) {
            switch effect {
            case .openCycle(let cycle):
                currentCycle = cycle
                log.append("break_open")

            case .closeCycle(let cycle, _):
                if currentCycle == cycle { currentCycle = nil }

            case .deliverPrompt:
                log.append("break_prompt")

            case .recordSkip:
                log.append("break_response.skipped")

            case .recordIgnoredPrompt:
                log.append("break_response.ignored")

            case .recordSnooze:
                log.append("break_response.snoozed")

            case .beginBreak(let cycle, _, _):
                log.append("break_begin")
                if cycle != nil { log.append("break_response.taken") }

            case .endBreak:
                log.append("break_end")

            case .withdrawPrompt, .setIndicator, .scheduleWake, .cancelScheduledWake,
                 .recordVerdict, .resumeWorkClock:
                break
            }
        }

        mutating func execute(_ effects: [Effect]) {
            for effect in effects { execute(effect) }
        }
    }

    // MARK: - The reproduction

    /// THE FAILING TEST. Drive the engine to a prompt, dismiss it on the next tick, and
    /// replay the effect stream through the app's cycle bookkeeping.
    ///
    /// Today this produces `["break_open", "break_prompt"]`, which is character for
    /// character the entire trace cycle 0 left in the owner's log.
    @Test("dismissing a prompt records that it was dismissed")
    func skipIsRecorded() {
        var driver = Driver(settings: Self.ownerSettings)
        var app = CycleBookkeeping()

        let opened = driver.step(untilLimit: 200) { effects in
            effects.contains { if case .deliverPrompt = $0 { return true } else { return false } }
        }
        #expect(!opened.isEmpty, "the engine must prompt at all before anything else is meaningful")
        app.execute(driver.effects)
        #expect(app.log == ["break_open", "break_prompt"], "the prompt reached the screen")

        let dismissal = driver.step(action: .skip)
        app.execute(dismissal)

        #expect(
            app.log.contains("break_response.skipped"),
            """
            the app wrote nothing when the user answered the prompt.
            log was \(app.log)
            """
        )
    }

    /// The same decision, asserted on the payload rather than on the index.
    ///
    /// A pure reorder of the skip's effect list would have made the test above pass and
    /// left the next edit free to silently undo it. What actually fixes the defect is
    /// that the effect names its own cycle, so this pins that instead.
    @Test("a user decision names the cycle it belongs to, whatever the effect order")
    func decisionsCarryTheirCycle() {
        var driver = Driver(settings: Self.ownerSettings)
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
        var driver = Driver(settings: Self.ownerSettings)
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
        var driver = Driver(settings: Self.ownerSettings)
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
        var driver = Driver(settings: Self.ownerSettings)

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
