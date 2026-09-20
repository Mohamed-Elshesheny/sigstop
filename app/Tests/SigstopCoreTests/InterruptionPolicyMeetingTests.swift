import Foundation
import Testing

@testable import SigstopCore

/// The first coverage `InterruptionPolicy` has ever had.
///
/// Before this file nothing in the test target constructed a `SystemSignals`, called the
/// policy, or exercised a seam, the cycle budget or the escalation ladder. That mattered
/// less while every meeting-shaped block was unreachable; it is the whole game now that
/// one of them fires.
@Suite("a call blocks a prompt")
struct InterruptionPolicyMeetingTests {

    static let policy = BreakPolicy.default
    static let interruption = InterruptionPolicy(policy: policy)
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static var holding: MeetingLatchSignal {
        MeetingLatchSignal(isHolding: true, basis: .microphone, anchorName: "Slack")
    }

    static func input(
        signals: SystemSignals = .none,
        seams: [Seam] = [],
        continuousWork: TimeInterval = 46 * 60,
        lastBreakEndedAt: Date? = nil,
        day: DailyCounters = DailyCounters()
    ) -> EngineInput {
        EngineInput(
            now: now,
            monotonic: 0,
            context: TestContext.make(continuousWork: continuousWork),
            signals: signals,
            seams: seams,
            lastBreakEndedAt: lastBreakEndedAt,
            day: day
        )
    }

    // MARK: The hard block, and everything it has to beat

    @Test("A holding latch beats a seam, which is how a prompt reached a meeting most often")
    func beatsASeam() {
        /// Alt-tabbing out of the call for two seconds is the single most common thing
        /// anyone does in a meeting, and `verdict` returns `.deliver` for any non-empty
        /// seam before the soft reasons are even consulted. Only a hard block survives it.
        let verdict = Self.interruption.verdict(
            Self.input(signals: SystemSignals(meetingLatch: Self.holding), seams: [.applicationSwitch]),
            budget: CycleBudget()
        )
        #expect(verdict == .hardBlocked(.recentCallContinuing))
    }

    @Test("It beats the absolute-max-work floor")
    func beatsTheFloor() {
        let verdict = Self.interruption.verdict(
            Self.input(signals: SystemSignals(meetingLatch: Self.holding), continuousWork: 95 * 60),
            budget: CycleBudget()
        )
        #expect(verdict == .hardBlocked(.recentCallContinuing))
    }

    @Test("It beats a spent soft budget, which is what a deferral cannot do")
    func beatsASpentBudget() {
        let verdict = Self.interruption.verdict(
            Self.input(signals: SystemSignals(meetingLatch: Self.holding)),
            budget: CycleBudget(seamWaitElapsed: 900, seamWaitTotal: 900)
        )
        #expect(verdict == .hardBlocked(.recentCallContinuing))
    }

    @Test("It beats the escalation budget, so no level 4 panel paints across a screen share")
    func beatsTheEscalationBudget() {
        let escalation = Escalation(
            cycle: .initial, dueSince: Self.now, ignoredAt: Self.now,
            notificationsThisCycle: 1, totalElapsed: 0, lastStepMono: 0
        )
        let verdict = Self.interruption.verdict(
            Self.input(signals: SystemSignals(meetingLatch: Self.holding)),
            budget: escalation.budget
        )
        #expect(verdict == .hardBlocked(.recentCallContinuing))
    }

    @Test("A running camera hard-blocks on its own")
    func cameraBlocks() {
        /// One line, and it is the first assertion in this repository's history that
        /// would have failed before this change: `cameraRunning` was hardcoded false and
        /// `HardBlock.cameraInUse` was unreachable.
        #expect(
            Self.interruption.hardBlock(Self.input(signals: SystemSignals(cameraRunning: true)))
                == .cameraInUse
        )
    }

    @Test("A live device explains itself before the latch does")
    func liveFactWins() {
        let signals = SystemSignals(audioInputRunning: true, meetingLatch: Self.holding)
        #expect(Self.interruption.hardBlock(Self.input(signals: signals)) == .audioInputInUse)
    }

    @Test("A call is never mis-explained as having just got back from a break")
    func latchBeforeSettleIn() {
        let block = Self.interruption.hardBlock(
            Self.input(
                signals: SystemSignals(meetingLatch: Self.holding),
                lastBreakEndedAt: Self.now.addingTimeInterval(-60)
            )
        )
        #expect(block == .recentCallContinuing)
    }

    @Test("The latch's weak states defer, at tier 0, where nothing else can")
    func suspicionDefers() {
        /// `ConcurrentStates.inMeeting` is structurally false without Accessibility,
        /// because `meetingConfidence` is clamped to the tier 0 ceiling and that ceiling
        /// sits below the specific-claim threshold. So this is the ONLY meeting deferral
        /// a zero-permission user can ever receive, and it is derived from a capture fact
        /// rather than from a confidence number.
        let signals = SystemSignals(meetingLatch: MeetingLatchSignal(suspectsCall: true))
        let verdict = Self.interruption.verdict(Self.input(signals: signals), budget: CycleBudget())
        #expect(verdict == .softDeferred(.inferredMeeting))
    }

    @Test("Suspicion only defers, and the deferral runs out")
    func suspicionIsNotABlock() {
        let signals = SystemSignals(meetingLatch: MeetingLatchSignal(suspectsCall: true))
        #expect(Self.interruption.hardBlock(Self.input(signals: signals)) == nil)
        let spent = Self.interruption.verdict(
            Self.input(signals: signals),
            budget: CycleBudget(seamWaitElapsed: 900, seamWaitTotal: 900)
        )
        #expect(spent == .deliver)
    }
}

@Suite("what the engine does while a call blocks it")
struct BreakDecisionCallBlockTests {

    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    static let engine = BreakDecisionEngine(policy: .default)

    static func due(prompted: Bool, at mono: Double = 0) -> BreakDue {
        var d = BreakDue(cycle: .initial, dueSince: now, lastStepMono: mono)
        if prompted {
            d.promptedAt = now
            d.promptedAtMono = mono
            d.notificationsThisCycle = 1
        }
        return d
    }

    static func input(
        mono: Double,
        holding: Bool,
        seams: [Seam] = [],
        day: DailyCounters = DailyCounters()
    ) -> EngineInput {
        EngineInput(
            now: now.addingTimeInterval(mono),
            monotonic: mono,
            context: TestContext.make(),
            signals: SystemSignals(
                meetingLatch: holding ? MeetingLatchSignal(isHolding: true) : .closed
            ),
            seams: seams,
            day: day
        )
    }

    @Test("A prompt already on screen is pulled when the call block begins")
    func withdrawsOnBlock() {
        let outcome = Self.engine.step(
            .breakDue(Self.due(prompted: true)), Self.input(mono: 5, holding: true)
        )
        let withdrawn = outcome.effects.contains {
            if case .withdrawPrompt(_, let reason) = $0 { return reason == .blocked }
            return false
        }
        #expect(withdrawn, "otherwise the joke sits on a screen share for the whole call")
        if case .breakDue(let d) = outcome.state {
            #expect(d.promptedAt == nil)
            #expect(d.promptedAtMono == nil)
        } else {
            Issue.record("expected to stay in breakDue")
        }
    }

    @Test("Leaving a meeting does not charge the user an ignored prompt")
    func noUnearnedIgnore() {
        /// `promptedAtMono` is an absolute stamp and the ninety-second prompt timeout is
        /// only gated on not being hard-blocked, so before this change the first tick
        /// after a call had already satisfied the timeout: the user was recorded as
        /// having ignored a prompt they were never allowed to answer during, and two of
        /// those silently truncate the ladder to L1 and L2.
        var state = EngineState.breakDue(Self.due(prompted: true))
        var day = DailyCounters()
        var mono = 5.0
        while mono <= 600 {
            let outcome = Self.engine.step(state, Self.input(mono: mono, holding: true, day: day))
            state = outcome.state
            day = outcome.day
            mono += 5
        }
        let after = Self.engine.step(state, Self.input(mono: mono, holding: false, day: day))
        let ignored = after.effects.contains {
            if case .recordIgnoredPrompt = $0 { return true } else { return false }
        }
        #expect(!ignored)
        #expect(after.state.isBreakDue, "the cycle is still due, not escalating")
    }

    @Test("The ladder does not climb while a call blocks it")
    func ladderFreezes() {
        var state = EngineState.ignored(
            Escalation(
                cycle: .initial, dueSince: Self.now, ignoredAt: Self.now,
                notificationsThisCycle: 1, totalElapsed: 0, lastStepMono: 0
            )
        )
        var day = DailyCounters()
        var mono = 5.0
        var prompts = 0
        while mono <= 40 * 60 {
            let outcome = Self.engine.step(state, Self.input(mono: mono, holding: true, day: day))
            state = outcome.state
            day = outcome.day
            prompts += outcome.prompts.count
            mono += 5
        }
        #expect(prompts == 0, "forty minutes of call must not buy four rungs of ladder")
        if case .ignored(let e) = state {
            #expect(e.level == .first)
            #expect(e.ladderElapsed == 0)
        } else {
            Issue.record("expected to stay in ignored")
        }
    }

    @Test("The owner's complaint, end to end")
    func theOwnersScenario() {
        /// Forty-five minutes of work, then a call: the microphone runs long enough to
        /// arm the latch, the user mutes, alt-tabs twice to keep working, and sits there.
        /// Nothing may be delivered. Then the hold runs out and the prompt arrives,
        /// because politeness is not allowed to become silence.
        let policy = BreakPolicy.default
        var latch = MeetingLatch.started(at: 0, wall: Self.now, dayIndex: 0)
        let slack = CallCapableApp(
            bundleID: "com.tinyspeck.slackmacgap", name: "Slack", isConferencing: true
        )

        var state = EngineState.breakDue(Self.due(prompted: false))
        var day = DailyCounters()
        var prompts = 0
        var mono = 5.0
        let holdEnds = 50 + policy.latchFactHold + policy.latchAnchorExtension

        while mono <= holdEnds + 120 {
            let micLive = mono <= 50
            latch = latch.advanced(
                MeetingLatchInput(
                    monotonic: mono,
                    wall: Self.now.addingTimeInterval(mono),
                    micLive: micLive,
                    callCapableRunning: [slack],
                    attributedCallCapable: micLive ? slack : nil
                ),
                policy: policy
            )
            var signals = SystemSignals(audioInputRunning: micLive)
            signals.meetingLatch = latch.signal(
                at: mono, wall: Self.now.addingTimeInterval(mono), policy: policy
            )
            /// Two alt-tabs during the call, at the moments that used to deliver.
            let seams: [Seam] = (mono == 120 || mono == 400) ? [.applicationSwitch] : []
            let outcome = Self.engine.step(
                state,
                EngineInput(
                    now: Self.now.addingTimeInterval(mono),
                    monotonic: mono,
                    context: TestContext.make(),
                    signals: signals,
                    seams: seams,
                    day: day
                )
            )
            state = outcome.state
            day = outcome.day
            if mono < holdEnds { prompts += outcome.prompts.count }
            mono += 5
        }

        #expect(prompts == 0, "not one prompt reached the call")
        #expect(day.notificationsDelivered >= 1, "and it does arrive once the hold is spent")
    }

    @Test("The same scenario on a Mac with a virtual audio driver installed")
    func theOwnersScenarioOnAnUnreliableMac() {
        /// Krisp / Loopback / BlackHole downgrade the device signal to `.unreliable`, so
        /// `audioInputRunning` is false for the whole of a genuinely live call and the
        /// `audioInputInUse` hard block never fires. Attribution still names the app.
        ///
        /// Before the latch blocked in `.live` this delivered: the call's forty-five
        /// minutes produced only `SoftDeferReason.inferredMeeting`, soft deferrals are
        /// capped at fifteen minutes, and the prompt landed in the meeting — which is
        /// the one state this whole feature exists to prevent.
        let policy = BreakPolicy.default
        var latch = MeetingLatch.started(at: 0, wall: Self.now, dayIndex: 0)
        let teams = CallCapableApp(
            bundleID: "com.microsoft.teams2", name: "Microsoft Teams", isConferencing: true
        )

        var state = EngineState.breakDue(Self.due(prompted: false))
        var day = DailyCounters()
        var prompts = 0
        var mono = 5.0
        let callEnds = 45.0 * 60

        while mono <= callEnds {
            latch = latch.advanced(
                MeetingLatchInput(
                    monotonic: mono,
                    wall: Self.now.addingTimeInterval(mono),
                    micLive: true,
                    liveCaptureAlreadyBlocks: false,
                    callCapableRunning: [teams],
                    attributedCallCapable: teams
                ),
                policy: policy
            )
            /// Both device-level facts stay false for the whole call. That is the bug.
            var signals = SystemSignals(audioInputRunning: false)
            signals.meetingLatch = latch.signal(
                at: mono, wall: Self.now.addingTimeInterval(mono), policy: policy
            )
            let outcome = Self.engine.step(
                state,
                EngineInput(
                    now: Self.now.addingTimeInterval(mono),
                    monotonic: mono,
                    context: TestContext.make(continuousWork: 46 * 60 + mono),
                    signals: signals,
                    seams: mono == 600 ? [.applicationSwitch] : [],
                    day: day
                )
            )
            state = outcome.state
            day = outcome.day
            prompts += outcome.prompts.count
            mono += 5
        }

        #expect(prompts == 0, "forty-five minutes of call, and not one prompt in it")
    }
}
