import Foundation
import Testing

@testable import SigstopCore

/// Why the app went quiet for an hour, and why it no longer does.
@Suite("backing off, and the ladder that was already switched off")
struct BackoffTests {

    private static func closedAsIgnored(_ effects: [Effect]) -> Bool {
        effects.contains {
            if case .closeCycle(_, .ignoredExhausted) = $0 { return true } else { return false }
        }
    }

    private static func enteredTheLadder(_ session: inout EngineHarness.Session) {
        session.stepToPrompt()
        session.step(untilLimit: 60) { effects in
            effects.contains { if case .recordIgnoredPrompt = $0 { return true } else { return false } }
        }
    }

    /// The 36 dead minutes, pinned.
    ///
    /// Under the backoff the ceiling is capped to `.second` and `.second` is refused by
    /// `ignoreBackoff` for the rest of the cycle, so nothing could ever be delivered and
    /// the engine sat running `ladderLevel4`'s timer anyway. It now closes as soon as it
    /// enters the ladder, because that is when the fact becomes true.
    @Test("a capped ladder ends when it has nothing left, not 35 minutes later")
    func cappedLadderEndsAtOnce() {
        var session = EngineHarness.Session()
        session.driver.day.consecutiveIgnoredCycles = 2
        session.stepToPrompt()
        let promptedAt = session.driver.monotonic

        let closed = session.step(untilLimit: 900, Self.closedAsIgnored)
        #expect(!closed.isEmpty, "a capped ladder must still close")

        let policy = session.driver.engine.policy
        let waited = session.driver.monotonic - promptedAt
        #expect(
            waited <= policy.promptTimeout + EngineHarness.Driver.tick,
            "closed \(Int(waited))s after the single prompt this cycle was allowed"
        )
        #expect(waited < policy.ladderLevel4, "this is the wait that produced the 63 minute gap")
    }

    /// The regression guard for the other side of it: an uncapped ladder still climbs all
    /// four rungs and still ends `promptTimeout` after the last one, exactly as before.
    @Test("an uncapped ladder still runs every rung")
    func uncappedLadderIsUnchanged() {
        var session = EngineHarness.Session()
        session.stepToPrompt()
        let promptedAt = session.driver.monotonic

        let closed = session.step(untilLimit: 900, Self.closedAsIgnored)
        #expect(!closed.isEmpty)

        let policy = session.driver.engine.policy
        let waited = session.driver.monotonic - promptedAt
        #expect(
            waited >= policy.ladderLevel4,
            "the full ladder must still take its time; it closed after \(Int(waited))s"
        )
        let levels = Set(session.driver.effects.compactMap { effect -> EscalationLevel? in
            if case .deliverPrompt(let p) = effect { return p.level } else { return nil }
        })
        #expect(levels.contains(.incident), "SIGSTOP must still be reached when nothing caps the ladder")
    }

    /// The indicator during the cooldown. `escalating` while the ladder is switched off
    /// is a positive claim that the opposite of the truth is happening, which is worse
    /// than the `working` it was paired with.
    @Test("the cooldown says it has stood down, and never that it is escalating")
    func cooldownIndicatorIsHonest() {
        var session = EngineHarness.Session()
        session.driver.day.consecutiveIgnoredCycles = 2
        Self.enteredTheLadder(&session)
        session.step(untilLimit: 900, Self.closedAsIgnored)

        let before = session.driver.effects.count
        session.step(times: 12)
        let during = session.driver.effects.dropFirst(before).compactMap { effect -> IndicatorState? in
            if case .setIndicator(let i) = effect { return i } else { return nil }
        }
        #expect(!during.isEmpty)
        #expect(during.allSatisfy { $0 == .backedOff }, "saw \(Set(during))")
        #expect(!during.contains(.escalating))
        #expect(!during.contains(.working))
    }

    /// The cooldown carries why, so the panel does not have to guess it from a threshold.
    @Test("the cooldown records that it was the backoff, not just an unanswered one")
    func cooldownCarriesItsCause() {
        var session = EngineHarness.Session()
        session.driver.day.consecutiveIgnoredCycles = 2
        Self.enteredTheLadder(&session)
        session.step(untilLimit: 900, Self.closedAsIgnored)

        guard case .working(let w) = session.driver.state else {
            Issue.record("expected the cooldown")
            return
        }
        #expect(w.standDown == .backedOff)
        #expect(w.cooldownUntilMono != nil)
    }

    /// The way out of the backoff, which for a while there was not one.
    ///
    /// A capped cycle closes `promptTimeout` after its single prompt, which is the point
    /// of capping it. That also takes the cycle away, so a break the user starts even a
    /// minute later begins with `cycle == nil` - and the reset used to live inside
    /// `if let cycle`. Two ignored opportunities therefore put the app into single-prompt
    /// mode for the rest of the day unless the user answered inside ninety seconds, while
    /// `PromptOutlook` told them a break would clear it.
    @Test("a break after a capped cycle has closed still clears the backoff")
    func aLateBreakStillClearsTheBackoff() {
        var session = EngineHarness.Session()
        session.driver.day.consecutiveIgnoredCycles = 2
        session.stepToPrompt()
        session.step(untilLimit: 900, Self.closedAsIgnored)
        #expect(session.driver.day.consecutiveIgnoredCycles == 3)
        #expect(session.driver.state.openCycle == nil, "the capped cycle is gone, which is the point")

        // Three minutes late, which is what "I saw it, let me finish this line" looks like.
        session.step(times: 36)
        session.step(action: .startBreakNow)
        guard case .breakActive(let active) = session.driver.state else {
            Issue.record("the user must be able to start a break during the cooldown")
            return
        }
        #expect(active.cycle == nil, "there is no cycle left to attach it to")

        session.step(untilLimit: 200) { effects in
            effects.contains { if case .endBreak = $0 { return true } else { return false } }
        }
        #expect(
            session.driver.day.consecutiveIgnoredCycles == 0,
            "a qualifying break is what clears the backoff, not the cycle it was attached to"
        )
    }

    /// The other half of it: the break has to be a real one. A break shorter than
    /// `qualifyingBreak` buys the same nothing a snooze does.
    @Test("a break too short to qualify clears nothing")
    func aShortBreakClearsNothing() {
        var session = EngineHarness.Session()
        session.driver.day.consecutiveIgnoredCycles = 2
        session.stepToPrompt()
        session.step(untilLimit: 900, Self.closedAsIgnored)

        session.step(action: .startBreakNow)
        session.step(times: 12)
        session.step(action: .endBreak)
        #expect(session.driver.day.consecutiveIgnoredCycles == 3)
    }

    /// Compliance is not cleared by it, and deliberately. The counter the backoff reads
    /// means "opportunities in a row that went unanswered by a break"; the denominator
    /// the panel divides by only grows when an opportunity was actually opened, so
    /// crediting a break nobody asked for would be a percentage of nothing.
    @Test("a break with no opportunity behind it earns no compliance credit")
    func aSpontaneousBreakIsNotAnHonoredOpportunity() {
        var session = EngineHarness.Session()
        session.driver.day.consecutiveIgnoredCycles = 2
        session.step(action: .startBreakNow)
        session.step(untilLimit: 200) { effects in
            effects.contains { if case .endBreak = $0 { return true } else { return false } }
        }
        #expect(session.driver.day.consecutiveIgnoredCycles == 0)
        #expect(session.driver.day.honoredOpportunities == 0)
    }

    /// One rule, learnable without a legend: a dim mark means the app is not going to
    /// ask. The predicate lives in `Core` because the view layer has no test target.
    @Test("the dim set is exactly the states where nothing is coming")
    func theDimSetIsPinned() {
        #expect(IndicatorState.backedOff.isStoodDown)
        #expect(IndicatorState.idle.isStoodDown)
        #expect(IndicatorState.quiet.isStoodDown)
        #expect(!IndicatorState.working.isStoodDown)
        #expect(!IndicatorState.breakDue.isStoodDown)
        #expect(!IndicatorState.escalating.isStoodDown)
        #expect(!IndicatorState.held.isStoodDown)
        #expect(!IndicatorState.onBreak.isStoodDown)
    }

    /// A terminal limit is one built only from counters that grow. `minimumSpacing` is
    /// not one, and reading it as one would cut a perfectly live ladder short.
    @Test("only the limits that cannot lift are terminal")
    func terminalLimitsAreTheOnesThatCannotLift() {
        #expect(RateLimit.ignoreBackoff.isTerminalForCycle)
        #expect(RateLimit.cycleNotificationCap.isTerminalForCycle)
        #expect(!RateLimit.minimumSpacing.isTerminalForCycle)
        #expect(!RateLimit.quietHours.isTerminalForCycle)
        #expect(!RateLimit.dailyCapReached.isTerminalForCycle)
    }
}

/// An input device that never closes, which is what Krisp, BlackHole, an aggregate device
/// and some headset daemons look like from here.
@Suite("a microphone is a fact, but it is not a call")
struct UncorroboratedAudioTests {

    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    private static func input(
        held: TimeInterval,
        camera: Bool = false,
        latch: MeetingLatchSignal = .closed,
        calendar: CalendarSignals? = nil
    ) -> (EngineInput, CycleBudget) {
        let context = DeveloperContext(
            timestamp: start,
            application: AppIdentity(bundleID: "com.apple.dt.Xcode", localizedName: "Xcode", pid: 1),
            activity: .coding,
            confidence: Confidence(0.8),
            continuousWork: 45 * 60
        )
        let input = EngineInput(
            now: start,
            monotonic: held,
            context: context,
            signals: SystemSignals(
                audioInputRunning: true, cameraRunning: camera, meetingLatch: latch
            ),
            calendar: calendar
        )
        return (input, CycleBudget(uncorroboratedAudioElapsed: held))
    }

    private static let policy = InterruptionPolicy(policy: .default)

    @Test("under the ceiling a running input device still blocks outright")
    func underTheCeilingItBlocks() {
        let (input, budget) = Self.input(held: 19 * 60)
        #expect(Self.policy.hardBlock(input, budget: budget) == .audioInputInUse)
    }

    /// The whole of bug two: on a Mac with a virtual audio device this used to be true
    /// forever, and the only escape was a collector calibration an hour away.
    @Test("past the ceiling, with nothing corroborating it, it stops blocking")
    func pastTheCeilingItStopsBlocking() {
        let (input, budget) = Self.input(held: 21 * 60)
        #expect(Self.policy.hardBlock(input, budget: budget) == nil)
        #expect(Self.policy.softDefer(input) == .liveCaptureUnattributed)
    }

    /// The regression guard, and the more important of the two. A real call is not
    /// interrupted at twenty minutes, because a real call corroborates.
    @Test(
        "corroborated capture is not bounded at all",
        arguments: [
            ("a camera is running too", true, MeetingLatchSignal.closed, CalendarSignals?.none),
            (
                "the latch adopted a call app", false,
                MeetingLatchSignal(anchorName: "Zoom"), CalendarSignals?.none
            ),
            (
                "the user said they are in a meeting", false,
                MeetingLatchSignal(basis: .manual), CalendarSignals?.none
            ),
            (
                "the calendar says a busy event is in progress", false, MeetingLatchSignal.closed,
                CalendarSignals?.some(CalendarSignals(eventInProgress: true, inProgressIsBusy: true))
            ),
        ]
    )
    func corroboratedCaptureIsUnbounded(
        _ what: String, _ camera: Bool, _ latch: MeetingLatchSignal, _ calendar: CalendarSignals?
    ) {
        let (input, budget) = Self.input(held: 3 * 3600, camera: camera, latch: latch, calendar: calendar)
        #expect(Self.policy.hardBlock(input, budget: budget) != nil, "\(what) must still block")
        #expect(Self.policy.audioIsCorroborated(input), "\(what) must count as corroboration")
    }

    /// A run of real short calls must never accumulate towards the bound, which is why
    /// the counter is continuous rather than a total.
    @Test("the counter resets the moment the device releases")
    func theCounterResetsOnRelease() {
        var session = EngineHarness.Session()
        session.micRunning = true
        session.stepToPrompt(limit: 200)
        session.step(times: 200)
        let held = session.driver.state.uncorroboratedAudioElapsed ?? 0
        #expect(held > 15 * 60, "the hold must have accumulated first, saw \(Int(held))s")

        session.micRunning = false
        session.step(times: 2)
        #expect(session.driver.state.uncorroboratedAudioElapsed == 0)
    }

    /// The two hours a stuck Mac used to spend in complete silence.
    @Test("a stuck input device no longer silences the app for hours")
    func aStuckDeviceIsNotSilenceForever() {
        var session = EngineHarness.Session()
        session.micRunning = true
        let prompted = session.step(untilLimit: 1200) { effects in
            effects.contains { if case .deliverPrompt = $0 { return true } else { return false } }
        }
        #expect(!prompted.isEmpty, "never prompted in 100 minutes with a device held open")
        let policy = session.driver.engine.policy
        #expect(
            session.driver.monotonic
                <= policy.targetContinuousWork + policy.uncorroboratedAudioCeiling
                    + policy.maxSeamWaitPerCycle,
            "the wait must be the ceiling plus a seam budget, not the collector's hour"
        )
    }

    /// A rung that arrives while a device is capturing arrives silently. The prompt still
    /// lands; it just does not chime into somebody's recording.
    @Test("live capture suppresses the sound channel")
    func liveCaptureIsSilent() {
        var session = EngineHarness.Session()
        session.micRunning = true
        session.step(times: 900)
        let sounded = session.driver.effects.contains { effect in
            if case .deliverPrompt(let p) = effect { return p.channel == .notificationWithSound }
            return false
        }
        #expect(!sounded, "no rung may make a sound while an input device is live")
    }
}
