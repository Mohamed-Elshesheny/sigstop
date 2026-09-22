import Foundation
import Testing

@testable import SigstopCore

@Suite("the log can explain the silence")
struct ObservabilityTests {

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

    @Test("a snooze does not make an open cycle go silent")
    func aSnoozedCycleIsNeverSilent() {
        var settings = EngineHarness.ownerSettings
        settings.snoozeMinutes = 30
        var session = EngineHarness.Session(settings: settings)
        session.stepToPrompt()
        session.step(action: .snooze)
        session.step(times: 300)

        #expect(session.driver.state.name == "snoozed", "the snooze must still be running")
        #expect(session.driver.state.openCycle != nil, "and it must still hold the cycle")
        let worst = Self.longestSilence(session.log.lines, now: session.driver.now)
        #expect(worst <= 600, "the log was silent for \(Int(worst))s with a cycle open")
    }

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
