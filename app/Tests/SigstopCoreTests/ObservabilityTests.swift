import Foundation
import Testing

@testable import SigstopCore

/// The deeper defect behind the 20:06:51Z incident: a state machine that can go silent
/// without recording why.
///
/// CLAUDE.md §4.1 requires the app to always be able to answer "why do you think that",
/// and `--doctor` exists so a sceptic can check. A cycle that closes without a trace, and
/// a fourteen minute hold that computes 168 identical verdicts and keeps none of them,
/// are both that invariant broken rather than a missing feature.
@Suite("the log can explain the silence")
struct ObservabilityTests {

    // MARK: - Nothing may be added unlogged

    /// Names every `Effect` case in an exhaustive switch with no `default`.
    ///
    /// This is the compile-time half of the guarantee: a fifteenth effect stops the test
    /// target building until somebody comes here and says what it is. The assertion below
    /// is the run-time half, and checks that the sample list was extended too.
    private static func name(_ effect: Effect) -> String {
        switch effect {
        case .openCycle:           return "openCycle"
        case .closeCycle:          return "closeCycle"
        case .deliverPrompt:       return "deliverPrompt"
        case .withdrawPrompt:      return "withdrawPrompt"
        case .setIndicator:        return "setIndicator"
        case .beginBreak:          return "beginBreak"
        case .endBreak:            return "endBreak"
        case .scheduleWake:        return "scheduleWake"
        case .cancelScheduledWake: return "cancelScheduledWake"
        case .recordVerdict:       return "recordVerdict"
        case .recordSkip:          return "recordSkip"
        case .recordIgnoredPrompt: return "recordIgnoredPrompt"
        case .recordSnooze:        return "recordSnooze"
        }
    }

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private static var everyEffect: [Effect] {
        let cycle = CycleID.initial
        let request = PromptRequest(
            cycle: cycle, level: .first, channel: .notification,
            at: epoch, continuousWork: 300, snoozeOffered: []
        )
        return [
            .openCycle(cycle),
            .closeCycle(cycle, .skipped),
            .deliverPrompt(request),
            .withdrawPrompt(cycle: cycle, reason: .userSkipped),
            .setIndicator(.working),
            .beginBreak(cycle: cycle, origin: .accepted, plannedEnd: epoch),
            .endBreak(cycle: cycle, origin: .accepted, honored: true, elapsed: 303, threshold: 300),
            .scheduleWake(at: epoch),
            .cancelScheduledWake,
            .recordVerdict(.deliver),
            .recordSkip(cycle: cycle),
            .recordIgnoredPrompt(cycle: cycle),
            .recordSnooze(cycle: cycle, duration: 300),
        ]
    }

    @Test("every effect states what it writes, and none can be added silently")
    func everyEffectIsAccountedFor() {
        let names = Set(Self.everyEffect.map(Self.name))
        #expect(
            names.count == Self.everyEffect.count,
            "two samples share a case; the list is not one of each"
        )
        #expect(
            names == [
                "openCycle", "closeCycle", "deliverPrompt", "withdrawPrompt", "setIndicator",
                "beginBreak", "endBreak", "scheduleWake", "cancelScheduledWake",
                "recordVerdict", "recordSkip", "recordIgnoredPrompt", "recordSnooze",
            ],
            "a new Effect was added; say here what it writes"
        )

        for effect in Self.everyEffect {
            _ = EventLogWriter.lines(
                for: effect, at: Self.epoch,
                context: EffectLogContext(confirmedPromptCycle: .initial)
            )
        }
    }

    /// Three files state the size of this vocabulary in words: `GateReason` itself,
    /// `LoggedEvent.gate`, and docs/PRIVACY.md §4.3. A count in prose drifts silently, so
    /// it is asserted here.
    @Test("the gate vocabulary is the size the docs say it is")
    func gateVocabularyIsTwentyNine() {
        #expect(
            GateReason.allCases.count == 29,
            "GateReason changed size; update GateReason.swift, EventLog.swift and PRIVACY.md §4.3"
        )
        for reason in GateReason.allCases {
            #expect(!reason.summary.isEmpty, "\(reason.rawValue as String) has no words for the user")
        }
    }

    /// Persisting the daily counters made `.quiet(.dailyCapReached)` reachable for the
    /// first time: before it, every rebuild reset the counter, so the state existed and
    /// nobody ever sat in it. It is terminal until the day boundary, emits no verdict and
    /// therefore no `gate` line, and the panel drew every quiet state with the literal
    /// title "quiet hours" — so the app could go silent for the rest of the day and
    /// explain it with a lie, to a user whose quiet hours are switched off.
    ///
    /// The words live here rather than in the view for the usual reason: `SigstopApp` has
    /// no test target, so a vocabulary kept there cannot be checked at all.
    @Test("every quiet state says which quiet it is")
    func everyQuietCauseHasItsOwnWords() {
        let causes = QuietCause.allCases
        #expect(causes.count == 4, "a new quiet cause needs words of its own")
        #expect(Set(causes.map(\.title)).count == causes.count, "two causes share a title")
        for cause in causes {
            #expect(!cause.title.isEmpty)
            #expect(!cause.summary.isEmpty)
        }
        for cause in causes where cause != .scheduledQuietHours {
            #expect(
                !cause.title.contains("quiet hours"),
                "\(cause.rawValue as String) is not quiet hours and must not claim to be"
            )
        }
        #expect(QuietCause.dailyCapReached.summary.contains("budget"))
    }

    // MARK: - Every cycle says how it ended

    @Test("every cycle outcome produces exactly one line that carries it", arguments: [
        CycleOutcome.honored, .skipped, .ignoredExhausted, .expired, .quietSuppressed, .dailyCapReached,
    ])
    func everyOutcomeIsWritten(_ outcome: CycleOutcome) {
        let lines = EventLogWriter.lines(
            for: .closeCycle(CycleID(rawValue: 7), outcome), at: Self.epoch
        )
        #expect(lines.count == 1)
        #expect(lines.first?.kind == .cycleClose)
        #expect(lines.first?.outcome == outcome)
        #expect(lines.first?.cycle == 7)
    }

    /// The outcome round-trips through the file as a typed value, not a sentence.
    @Test("a cycle close survives the codec with its outcome typed")
    func cycleCloseRoundTrips() throws {
        let line = LoggedEvent.cycleClose(at: Self.epoch, cycle: CycleID(rawValue: 3), outcome: .ignoredExhausted)
        let encoded = try EventLogCodec.encode(line)
        let decoded = try #require(EventLogCodec.decode(encoded))
        #expect(decoded.kind == .cycleClose)
        #expect(decoded.outcome == .ignoredExhausted)
        #expect(encoded.contains("\"e\":\"cycle_close\""))
        #expect(encoded.contains("\"outcome\":\"ignoredExhausted\""))
    }

    /// The whole reason the incident was undiagnosable: five cycles in the owner's day
    /// stop existing mid-file. Run a skip and an exhausted ladder and assert both leave a
    /// close behind.
    @Test("a skipped cycle and an exhausted ladder both leave a close")
    func closesAreWrittenInAnActualRun() {
        var skipped = EngineHarness.Session()
        skipped.stepToPrompt()
        skipped.step(action: .skip)
        #expect(skipped.log.lines.contains { $0.kind == .cycleClose && $0.outcome == .skipped })

        var ignored = EngineHarness.Session()
        ignored.stepToPrompt()
        ignored.step(untilLimit: 1000) { effects in
            effects.contains {
                if case .closeCycle(_, let outcome) = $0 { return outcome == .ignoredExhausted }
                return false
            }
        }
        #expect(ignored.log.lines.contains { $0.kind == .cycleClose && $0.outcome == .ignoredExhausted })
    }

    // MARK: - The verdict, on transition

    @Test("the gate writes on change, not on sample")
    func gateWritesOnChange() {
        var ledger = VerdictLedger(debounce: 2, heartbeat: 600)
        let cycle = CycleID.initial
        var mono: Double = 0
        func observe(_ reason: GateReason?) -> LoggedEvent? {
            mono += 5
            return ledger.observe(reason, cycle: cycle, at: Self.epoch.addingTimeInterval(mono), monotonic: mono)
        }

        #expect(observe(.delivered) != nil, "the first answer of a run is worth a line")
        #expect(observe(.delivered) == nil)
        #expect(observe(.delivered) == nil)

        #expect(observe(.audioInputInUse) == nil, "one tick is not a transition")
        let written = observe(.audioInputInUse)
        #expect(written?.gate == .audioInputInUse, "two consecutive ticks is")
        #expect(written?.cycle == 0)
        #expect(observe(.audioInputInUse) == nil)
    }

    @Test("a verdict that flickers for one tick writes nothing")
    func flickerIsDebounced() {
        var ledger = VerdictLedger(debounce: 2, heartbeat: 600)
        var mono: Double = 0
        func observe(_ reason: GateReason) -> LoggedEvent? {
            mono += 5
            return ledger.observe(reason, cycle: .initial, at: Self.epoch, monotonic: mono)
        }
        _ = observe(.deepFocus)
        #expect(observe(.recentAppLaunch) == nil)
        #expect(observe(.deepFocus) == nil)
        #expect(observe(.recentAppLaunch) == nil)
        #expect(observe(.deepFocus) == nil)
    }

    @Test("a closed cycle forgets, so the next one states its opening position")
    func resetOnClose() {
        var ledger = VerdictLedger()
        var mono: Double = 0
        _ = ledger.observe(.audioInputInUse, cycle: .initial, at: Self.epoch, monotonic: mono)
        ledger.reset()
        mono += 5
        let line = ledger.observe(.audioInputInUse, cycle: CycleID(rawValue: 1), at: Self.epoch, monotonic: mono)
        #expect(line?.gate == .audioInputInUse)
    }

    /// The longest the file goes without a line, `now` included as the closing bound.
    private static func longestSilence(_ lines: [LoggedEvent], now: Date) -> TimeInterval {
        var worst: TimeInterval = 0
        var previous: Date?
        for stamp in lines.map(\.at) {
            if let previous { worst = max(worst, stamp.timeIntervalSince(previous)) }
            previous = stamp
        }
        if let previous { worst = max(worst, now.timeIntervalSince(previous)) }
        return worst
    }

    /// The property the incident actually violated. Hold the microphone on for the whole
    /// fourteen minutes the owner sat there and assert the file is never silent for longer
    /// than the heartbeat.
    ///
    /// Before this, those ticks produced only `setIndicator` and `recordVerdict`, neither
    /// of which the log could carry, so a held cycle and a crashed tick loop looked
    /// identical on disk.
    @Test("an open cycle never goes ten minutes without writing something")
    func anOpenCycleIsNeverSilent() {
        var session = EngineHarness.Session()
        session.stepToPrompt()
        session.micRunning = true
        session.step(times: 168)

        #expect(session.driver.state.isBreakDue, "the mic must still be holding the cycle open")

        let worst = Self.longestSilence(session.log.lines, now: session.driver.now)
        #expect(worst <= 600, "the log was silent for \(Int(worst))s with a cycle open")
        #expect(session.log.lines.filter { $0.kind == .gate }.count >= 2)
    }

    /// `anOpenCycleIsNeverSilent` above only exercises the microphone, and a hard-blocked
    /// cycle stays in `breakDue`, which *does* compute a verdict every tick. `snoozed`
    /// holds the cycle open and computes none, so the ledger reset its candidate and wrote
    /// nothing at all.
    ///
    /// A snooze clamps at thirty minutes per cycle, so the documented rule — an open cycle
    /// is never silent for longer than the heartbeat, and a log that goes quiet means the
    /// app stopped and nothing else — was false for half an hour at a stretch, on the one
    /// path the user reaches by pressing a button.
    @Test("a snooze does not make an open cycle go silent")
    func aSnoozedCycleIsNeverSilent() {
        var settings = EngineHarness.ownerSettings
        settings.snoozeMinutes = 30
        var session = EngineHarness.Session(settings: settings)
        session.stepToPrompt()
        session.step(action: .snooze)
        session.step(times: 300) // 25 minutes, still inside the snooze

        #expect(session.driver.state.name == "snoozed", "the snooze must still be running")
        #expect(session.driver.state.openCycle != nil, "and it must still hold the cycle")
        let worst = Self.longestSilence(session.log.lines, now: session.driver.now)
        #expect(worst <= 600, "the log was silent for \(Int(worst))s with a cycle open")
    }

    /// The same hole, reached by walking away rather than by pressing SIGALRM. `idle` also
    /// holds a suspended cycle and also computes no verdict.
    @Test("an idle-suspended cycle does not make the log go silent")
    func anIdleSuspendedCycleIsNeverSilent() {
        var session = EngineHarness.Session()
        session.stepToPrompt()
        session.driver.idleSeconds = 120
        session.step(times: 200)

        guard session.driver.state.openCycle != nil else { return }
        let worst = Self.longestSilence(session.log.lines, now: session.driver.now)
        #expect(worst <= 600, "the log was silent for \(Int(worst))s with a cycle open")
    }

    /// The counterfactual that ruled out the hard-block reading, kept so it stays ruled
    /// out. A hard-blocked `breakDue` returns itself every tick and never reaches
    /// `handleWorking`, which is the only place a cycle id is taken. A second `break_open`
    /// in the owner's file is therefore proof the engine was back in `.working`.
    ///
    /// Corroborated, because this is a claim about what a HARD BLOCK does and a lone
    /// microphone stops being one after `uncorroboratedAudioCeiling`.
    @Test("a sustained call block never opens a second cycle")
    func sustainedBlockNeverOpensASecondCycle() {
        var session = EngineHarness.Session()
        session.stepToPrompt()
        session.startCorroboratedCall()
        session.step(times: 320)

        let opens = session.log.lines.filter { $0.kind == .breakOpen }
        #expect(opens.count == 1, "a blocked cycle must not re-arm")
        #expect(session.driver.state.isBreakDue)
    }

    /// An escalating cycle under a sustained block used to be unbounded: `ladderElapsed`
    /// accrues below the hard-block early return, so the ladder froze and `exhausted`
    /// could never become true, and unlike `breakDue` this state had no ceiling at all.
    ///
    /// The block here is a *corroborated* one, mic and camera together, because that is
    /// the only kind that is still unbounded and therefore the only kind the stale
    /// ceiling has to catch. A microphone on its own now stops blocking after
    /// `uncorroboratedAudioCeiling`, which is what a virtual audio device looks like and
    /// is covered by `uncorroboratedMicrophoneStopsBlocking` below.
    @Test("an escalating cycle cannot outlive the stale ceiling")
    func escalatingCycleIsBounded() {
        var session = EngineHarness.Session()
        session.stepToPrompt()
        session.step(untilLimit: 60) { effects in
            effects.contains { if case .recordIgnoredPrompt = $0 { return true } else { return false } }
        }
        #expect(session.driver.state.name == "ignored", "the ladder must have started")

        session.startCorroboratedCall()
        let closed = session.step(untilLimit: 900) { effects in
            effects.contains { if case .closeCycle = $0 { return true } else { return false } }
        }
        #expect(!closed.isEmpty, "a blocked ladder must still end")
        #expect(
            session.log.lines.contains { $0.kind == .cycleClose && $0.outcome == .expired },
            "and it ends as expired, which is excluded from compliance"
        )
        #expect(session.driver.state.isWorking)
    }
}
