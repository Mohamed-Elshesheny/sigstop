import Foundation
import Testing

@testable import SigstopCore

@Suite("the call latch")
struct MeetingLatchTests {

    static let policy = BreakPolicy.default
    static let wall0 = Date(timeIntervalSince1970: 1_700_000_000)

    static let slack = CallCapableApp(
        bundleID: "com.tinyspeck.slackmacgap", name: "Slack", isConferencing: true
    )
    static let chrome = CallCapableApp(
        bundleID: "com.google.Chrome", name: "Google Chrome", isConferencing: false
    )

    static func sample(
        _ t: Double,
        mic: Bool = false,
        camera: Bool = false,
        deviceBlocks: Bool = true,
        running: [CallCapableApp] = [],
        attributed: CallCapableApp? = nil,
        frontmost: CallCapableApp? = nil,
        enabled: Bool = true,
        screenLocked: Bool = false,
        sessionActive: Bool = true,
        wall: Date? = nil,
        dayIndex: Int = 0
    ) -> MeetingLatchInput {
        MeetingLatchInput(
            monotonic: t,
            wall: wall ?? wall0.addingTimeInterval(t),
            dayIndex: dayIndex,
            micLive: mic,
            cameraLive: camera,
            liveCaptureAlreadyBlocks: deviceBlocks,
            callCapableRunning: running,
            attributedCallCapable: attributed,
            frontmostCallCapable: frontmost,
            enabled: enabled,
            screenLocked: screenLocked,
            sessionActive: sessionActive
        )
    }

    static func fresh() -> MeetingLatch {
        MeetingLatch.started(at: 0, wall: wall0, dayIndex: 0)
    }

    static func run(
        _ latch: MeetingLatch,
        from: Double,
        to: Double,
        step: Double = 5,
        _ body: (Double) -> MeetingLatchInput
    ) -> MeetingLatch {
        var l = latch
        var t = from
        while t <= to {
            l = l.advanced(body(t), policy: policy)
            t += step
        }
        return l
    }

    @Test("A capture shorter than the dwell never arms the latch")
    func briefCaptureDoesNotArm() {
        var l = Self.fresh()
        l = Self.run(l, from: 5, to: 40) { Self.sample($0, mic: true, running: [Self.slack]) }
        l = l.advanced(Self.sample(45, mic: false, running: [Self.slack]), policy: Self.policy)
        l = l.advanced(Self.sample(50, mic: false, running: [Self.slack]), policy: Self.policy)
        #expect(!l.isHolding, "a voice memo, a mic test or a Siri wake word must not hold a break")
        #expect(l.phase == .closed)
    }

    @Test("Interrupted capture does not accumulate towards the dwell")
    func dwellIsContinuous() {
        var l = Self.fresh()
        l = Self.run(l, from: 5, to: 35) { Self.sample($0, mic: true) }
        l = l.advanced(Self.sample(40, mic: false), policy: Self.policy)
        l = Self.run(l, from: 45, to: 85) { Self.sample($0, mic: true) }
        #expect(l.phase == .arming, "the dwell restarts, it does not resume")
        l = l.advanced(Self.sample(90, mic: true), policy: Self.policy)
        #expect(l.phase == .live)
    }

    @Test("Forty-five continuous seconds arms it, and it holds through mute")
    func armsAndHoldsThroughMute() {
        var l = Self.fresh()
        l = Self.run(l, from: 5, to: 50) { Self.sample($0, mic: true, running: [Self.slack], attributed: Self.slack) }
        #expect(l.phase == .live)
        #expect(!l.isHolding, "while capture is live the existing hard block covers it")

        l = l.advanced(Self.sample(55, running: [Self.slack]), policy: Self.policy)
        #expect(l.isHolding, "muting must not end the hold")

        let budget = Self.policy.latchFactHold + Self.policy.latchAnchorExtension
        l = Self.run(l, from: 60, to: 50 + budget - 10) { Self.sample($0, running: [Self.slack]) }
        #expect(l.isHolding, "still holding one tick before the budget runs out")

        l = Self.run(l, from: 50 + budget - 5, to: 50 + budget + 10) { Self.sample($0, running: [Self.slack]) }
        #expect(!l.isHolding, "and the budget does run out, politeness cannot become silence")
        #expect(l.closeReason == .budgetSpent)
    }

    @Test("A camera alone arms it, which is the muted-on-video posture")
    func cameraAlone() {
        var l = Self.fresh()
        l = Self.run(l, from: 5, to: 50) { Self.sample($0, camera: true, running: [Self.chrome]) }
        l = l.advanced(Self.sample(55, running: [Self.chrome]), policy: Self.policy)
        #expect(l.isHolding)
    }

    @Test("Unmuting resets the hold clock")
    func unmuteResetsTheHold() {
        var l = Self.fresh()
        l = Self.run(l, from: 5, to: 50) { Self.sample($0, mic: true, running: [Self.slack]) }
        l = Self.run(l, from: 55, to: 500) { Self.sample($0, running: [Self.slack]) }
        #expect(l.isHolding)
        l = l.advanced(Self.sample(505, mic: true, running: [Self.slack]), policy: Self.policy)
        #expect(l.phase == .live, "no second dwell inside one episode")
        l = Self.run(l, from: 510, to: 1000) { Self.sample($0, running: [Self.slack]) }
        #expect(l.isHolding, "the hold is measured from the last capture fact, not from the first")
    }

    @Test("With no call-capable app at all the hold is the unconditional eight minutes")
    func unconditionalBaseHold() {
        var l = Self.fresh()
        l = Self.run(l, from: 5, to: 50) { Self.sample($0, mic: true) }
        l = Self.run(l, from: 55, to: 50 + Self.policy.latchFactHold - 10) { Self.sample($0) }
        #expect(l.isHolding, "the base hold rests on the capture fact and on nothing else")
        l = Self.run(l, from: 50 + Self.policy.latchFactHold - 5, to: 50 + Self.policy.latchFactHold + 10) {
            Self.sample($0)
        }
        #expect(!l.isHolding)
    }

    @Test("Quitting an adopted app collapses the hold to ninety seconds")
    func anchorQuitCollapsesTheHold() {
        var l = Self.fresh()
        l = Self.run(l, from: 5, to: 50) {
            Self.sample($0, mic: true, running: [Self.slack], attributed: Self.slack)
        }
        l = Self.run(l, from: 55, to: 200) { Self.sample($0, running: [Self.slack]) }
        #expect(l.isHolding)
        l = l.advanced(Self.sample(205, running: []), policy: Self.policy)
        #expect(!l.isHolding, "the call is over when the app it was attributed to is gone")
        #expect(l.closeReason == .anchorQuit)
    }

    @Test("A browser anchors only through attribution, never through merely running")
    func browserNeedsAttribution() {
        var withAttribution = Self.fresh()
        withAttribution = Self.run(withAttribution, from: 5, to: 50) {
            Self.sample($0, mic: true, running: [Self.chrome], attributed: Self.chrome)
        }
        withAttribution = Self.run(withAttribution, from: 55, to: 50 + Self.policy.latchFactHold + 60) {
            Self.sample($0, running: [Self.chrome])
        }
        #expect(withAttribution.isHolding, "Meet in a background tab is the owner's own case")

        var without = Self.fresh()
        without = Self.run(without, from: 5, to: 50) { Self.sample($0, mic: true, running: [Self.chrome]) }
        without = Self.run(without, from: 55, to: 50 + Self.policy.latchFactHold + 60) {
            Self.sample($0, running: [Self.chrome])
        }
        #expect(!without.isHolding, "a browser being open all day is not evidence of anything")
    }

    @Test("Ninety minutes of accumulated hold trips the episode ceiling and needs quiet to re-arm")
    func episodeCeiling() {
        var l = Self.fresh()
        var t = 5.0
        while t < 12_000, !(l.phase == .closed && l.heldSecondsThisEpisode > 0) {
            l = Self.run(l, from: t, to: t + 60) { Self.sample($0, mic: true, running: [Self.slack]) }
            t += 65
            l = Self.run(l, from: t, to: t + 300) { Self.sample($0, running: [Self.slack]) }
            t += 305
        }
        #expect(!l.isHolding)
        #expect(l.closeReason == .episodeCeiling, "the episode ceiling is what catches the voice-channel idler")

        l = Self.run(l, from: t, to: t + 120) { Self.sample($0, mic: true, running: [Self.slack]) }
        #expect(!l.isHolding, "no re-arm until capture has actually been quiet")

        t += 130
        l = Self.run(l, from: t, to: t + Self.policy.latchRearmQuiet + 10) { Self.sample($0, running: [Self.slack]) }
        t += Self.policy.latchRearmQuiet + 15
        l = Self.run(l, from: t, to: t + 60) { Self.sample($0, mic: true, running: [Self.slack]) }
        l = l.advanced(Self.sample(t + 70, running: [Self.slack]), policy: Self.policy)
        #expect(l.isHolding, "after the quiet period it works again")
    }

    @Test("The day's accumulated hold stops the latch, and the next local day restores it")
    func dailyCeiling() {
        var l = Self.fresh()
        var t = 5.0
        while t < 40_000, l.inhibition != .dailyCeiling {
            l = Self.run(l, from: t, to: t + 60) { Self.sample($0, mic: true, running: [Self.slack]) }
            t += 65
            l = Self.run(l, from: t, to: t + 300) { Self.sample($0, running: [Self.slack]) }
            t += 305
            if l.inhibition == .episodeCeiling {
                l = Self.run(l, from: t, to: t + Self.policy.latchRearmQuiet + 10) { Self.sample($0) }
                t += Self.policy.latchRearmQuiet + 15
            }
        }
        #expect(l.inhibition == .dailyCeiling)
        #expect(l.heldSecondsToday >= Self.policy.latchDailyCeiling)

        l = Self.run(l, from: t, to: t + 60) { Self.sample($0, mic: true, running: [Self.slack]) }
        #expect(!l.isHolding, "and nothing re-arms it for the rest of the day")

        t += 70
        l = Self.run(l, from: t, to: t + 60) {
            Self.sample($0, mic: true, running: [Self.slack], dayIndex: 1)
        }
        l = l.advanced(Self.sample(t + 70, running: [Self.slack], dayIndex: 1), policy: Self.policy)
        #expect(l.isHolding, "a new local day restores the budget")
    }

    @Test("A system sleep longer than the remaining hold closes the latch")
    func longSleepClosesTheLatch() {
        var l = Self.fresh()
        l = Self.run(l, from: 5, to: 50) { Self.sample($0, mic: true, running: [Self.slack]) }
        l = l.advanced(Self.sample(55, running: [Self.slack]), policy: Self.policy)
        #expect(l.isHolding)

        l = l.advanced(
            Self.sample(60, running: [Self.slack], wall: Self.wall0.addingTimeInterval(55 + 4 * 3600)),
            policy: Self.policy
        )
        #expect(!l.isHolding, "a call can end while the lid is shut, and nobody was watching")
        #expect(l.closeReason == .discontinuity)
    }

    @Test("A gap shorter than the remaining hold is not spent on time nobody watched")
    func shortGapCreditsNothing() {
        var l = Self.fresh()
        l = Self.run(l, from: 5, to: 50) { Self.sample($0, mic: true, running: [Self.slack]) }
        l = l.advanced(Self.sample(55, running: [Self.slack]), policy: Self.policy)

        l = l.advanced(
            Self.sample(60, running: [Self.slack], wall: Self.wall0.addingTimeInterval(55 + 120)),
            policy: Self.policy
        )
        #expect(l.isHolding, "a two minute lid-close must not end a call the user is continuing")

        let budget = Self.policy.latchFactHold + Self.policy.latchAnchorExtension
        l = Self.run(l, from: 65, to: 50 + budget) {
            Self.sample($0, running: [Self.slack], wall: Self.wall0.addingTimeInterval($0 + 120))
        }
        #expect(l.isHolding, "and the gap is not charged against the hold either")
    }

    @Test("A throttled process is a gap too, and is treated as one")
    func throttleIsAGap() {
        var l = Self.fresh()
        l = Self.run(l, from: 5, to: 50) { Self.sample($0, mic: true, running: [Self.slack]) }
        l = l.advanced(Self.sample(55, running: [Self.slack]), policy: Self.policy)
        l = l.advanced(Self.sample(55 + 4 * 3600, running: [Self.slack]), policy: Self.policy)
        #expect(!l.isHolding)
        #expect(l.closeReason == .discontinuity)
    }

    @Test("Locking the screen closes the latch")
    func screenLockCloses() {
        var l = Self.fresh()
        l = Self.run(l, from: 5, to: 50) { Self.sample($0, mic: true, running: [Self.slack]) }
        l = l.advanced(Self.sample(55, running: [Self.slack]), policy: Self.policy)
        l = l.advanced(Self.sample(60, running: [Self.slack], screenLocked: true), policy: Self.policy)
        #expect(!l.isHolding)
        #expect(l.closeReason == .sessionEnded)
    }

    @Test("Someone else signing in at the console closes it")
    func fastUserSwitchCloses() {
        var l = Self.fresh()
        l = Self.run(l, from: 5, to: 50) { Self.sample($0, mic: true, running: [Self.slack]) }
        l = l.advanced(Self.sample(55, running: [Self.slack]), policy: Self.policy)
        l = l.advanced(Self.sample(60, running: [Self.slack], sessionActive: false), policy: Self.policy)
        #expect(l.closeReason == .sessionEnded)
    }

    @Test("Clearing it by hand stops it re-opening from the same still-running app")
    func userClearInhibits() {
        var l = Self.fresh()
        l = Self.run(l, from: 5, to: 50) { Self.sample($0, mic: true, running: [Self.slack]) }
        l = l.advanced(Self.sample(55, running: [Self.slack]), policy: Self.policy)
        #expect(l.isHolding)

        l = l.clearedByUser(at: 60, policy: Self.policy)
        #expect(!l.isHolding)

        l = Self.run(l, from: 65, to: 200) { Self.sample($0, mic: true, running: [Self.slack]) }
        #expect(!l.isHolding, "and it stays out of the way for half an hour")

        let after = 60 + Self.policy.latchManualInhibit + 10
        l = Self.run(l, from: after, to: after + 60) { Self.sample($0, mic: true, running: [Self.slack]) }
        l = l.advanced(Self.sample(after + 70, running: [Self.slack]), policy: Self.policy)
        #expect(l.isHolding, "the inhibition expires; it is not an off switch")
    }

    @Test("Asserting a meeting by hand holds, and expires")
    func userAssertExpires() {
        var l = Self.fresh()
        l = l.assertedByUser(at: 10, policy: Self.policy)
        var signal = l.signal(at: 20, wall: Self.wall0, policy: Self.policy)
        #expect(signal.isHolding)
        #expect(signal.basis == .manual)

        l = l.advanced(Self.sample(10 + Self.policy.latchManualHold + 5), policy: Self.policy)
        signal = l.signal(at: 10 + Self.policy.latchManualHold + 5, wall: Self.wall0, policy: Self.policy)
        #expect(!signal.isHolding, "a manual hold that never expires is a mute button")
    }

    @Test("Turning the setting off and on again leaves a working latch")
    func settingOffThenOnReArms() {
        var l = Self.fresh()
        l = l.advanced(Self.sample(5, enabled: false), policy: Self.policy)
        #expect(l.inhibition == .disabled)

        l = Self.run(l, from: 310, to: 600) {
            Self.sample($0, mic: true, running: [Self.slack], attributed: Self.slack)
        }
        #expect(l.phase == .live, "the switch is a switch, not a one-way fuse")
        l = l.advanced(Self.sample(605, running: [Self.slack]), policy: Self.policy)
        #expect(l.isHolding, "and the latch still holds through mute afterwards")
    }

    @Test("Flicking the setting off and on does not buy a fresh daily budget")
    func settingDoesNotResetATrippedCeiling() {
        var l = Self.fresh()
        l = l.restoringDailyHold(seconds: Self.policy.latchDailyCeiling + 60, dayIndex: 0)
        #expect(l.inhibition == .dailyCeiling)

        l = l.advanced(Self.sample(5, enabled: false), policy: Self.policy)
        l = l.advanced(Self.sample(10), policy: Self.policy)
        #expect(l.inhibition == .dailyCeiling, "the switch clears its own footprint and nothing else")

        l = Self.run(l, from: 15, to: 200) {
            Self.sample($0, mic: true, running: [Self.slack], attributed: Self.slack)
        }
        l = l.advanced(Self.sample(205, running: [Self.slack]), policy: Self.policy)
        #expect(!l.isHolding, "the day's budget is spent, and a switch is not a way to refill it")
    }

    @Test("Deleting your data resets the day's hold total and keeps a hold you declared")
    func deletingKeepsADeclaredHold() {
        var l = Self.fresh()
        l = l.restoringDailyHold(seconds: Self.policy.latchDailyCeiling + 60, dayIndex: 0)
        l = l.assertedByUser(at: 10, policy: Self.policy)
        l = l.resettingDailyHold()
        let signal = l.signal(at: 20, wall: Self.wall0, policy: Self.policy)
        #expect(signal.isHolding, "a call you declared is still a call after you delete your history")
        #expect(signal.heldSecondsToday == 0)
        #expect(signal.inhibition == nil)
    }

    @Test("The setting ends a manual hold too, because that is what the row says it does")
    func settingEndsAManualHold() {
        var l = Self.fresh()
        l = l.assertedByUser(at: 10, policy: Self.policy)
        #expect(l.signal(at: 20, wall: Self.wall0, policy: Self.policy).isHolding)

        l = l.advanced(Self.sample(300, enabled: false), policy: Self.policy)
        #expect(
            !l.signal(at: 300, wall: Self.wall0, policy: Self.policy).isHolding,
            "the Settings row claims this switch controls holding, so it has to control all of it"
        )
        l = l.advanced(Self.sample(3900, enabled: false), policy: Self.policy)
        #expect(!l.signal(at: 3900, wall: Self.wall0, policy: Self.policy).isHolding)
    }

    @Test("A sustained throttle cannot refund the hold for ever")
    func sustainedThrottleStillCloses() {
        var l = Self.fresh()
        l = Self.run(l, from: 5, to: 50) {
            Self.sample($0, mic: true, running: [Self.slack], attributed: Self.slack)
        }
        l = l.advanced(Self.sample(55, running: [Self.slack]), policy: Self.policy)
        #expect(l.isHolding)

        l = Self.run(l, from: 67, to: 67 + 6 * 3600, step: 12) { Self.sample($0, running: [Self.slack]) }
        #expect(!l.isHolding, "politeness cannot become silence, and a throttle is not consent")
        #expect(l.closeReason != nil)
    }

    @Test("A lid closed during a live call does not become a fresh hold on wake")
    func longSleepDuringALiveCall() {
        var l = Self.fresh()
        l = Self.run(l, from: 5, to: 120) {
            Self.sample($0, mic: true, running: [Self.slack], attributed: Self.slack)
        }
        #expect(l.phase == .live)

        let wake = Self.wall0.addingTimeInterval(120 + 15 * 3600)
        l = l.advanced(Self.sample(125, running: [Self.slack], wall: wake), policy: Self.policy)
        #expect(
            !l.isHolding,
            "a fifteen-hour-old capture fact must not hard-block the first twenty minutes of the next day"
        )
        #expect(l.heldSecondsToday == 0, "and it must not charge yesterday's call against today's ceiling")
    }

    @Test("Turning the setting off disables the latch and nothing else")
    func settingDisablesOnlyTheLatch() {
        var l = Self.fresh()
        l = Self.run(l, from: 5, to: 200) {
            Self.sample($0, mic: true, running: [Self.slack], enabled: false)
        }
        l = l.advanced(Self.sample(205, running: [Self.slack], enabled: false), policy: Self.policy)
        #expect(!l.isHolding)
        #expect(l.inhibition == .disabled)

        let policy = InterruptionPolicy(policy: Self.policy)
        let input = EngineInput(
            now: Self.wall0, monotonic: 0,
            context: TestContext.make(),
            signals: SystemSignals(audioInputRunning: true)
        )
        #expect(policy.hardBlock(input) == .audioInputInUse)
    }

    @Test("A throttle charges the day's ceiling instead of vanishing from it")
    func throttledHoldStillCostsTheDay() {
        var l = Self.fresh()
        l = Self.run(l, from: 5, to: 50) {
            Self.sample($0, mic: true, running: [Self.slack], attributed: Self.slack)
        }
        l = l.advanced(Self.sample(55, running: [Self.slack]), policy: Self.policy)
        l = Self.run(l, from: 67, to: 900, step: 12) { Self.sample($0, running: [Self.slack]) }
        #expect(
            l.heldSecondsToday > 0,
            "time the latch spent holding is time it spent holding, watched or not"
        )
    }

    @Test("On a Mac whose device signal is unreliable the latch blocks during the call, not after it")
    func unreliableDeviceGetsTheLiveBlockToo() {
        var l = Self.fresh()
        l = Self.run(l, from: 5, to: 120) {
            Self.sample($0, mic: true, deviceBlocks: false, running: [Self.slack], attributed: Self.slack)
        }
        #expect(l.phase == .live)
        #expect(l.isHolding, "nothing else is blocking this call, so the latch has to")

        let signal = l.signal(at: 120, wall: Self.wall0, policy: Self.policy)
        #expect(signal.isHolding)
        #expect(signal.captureLive, "and it says the microphone is live now, not that it just stopped")
        #expect(signal.summary?.contains("is live right now") == true)
        #expect(!signal.suspectsCall, "a block is not a suspicion")

        #expect(l.heldSecondsThisEpisode > 0)
    }

    @Test("A reliable device keeps the live block where it already was")
    func reliableDeviceDoesNotDoubleBlock() {
        var l = Self.fresh()
        l = Self.run(l, from: 5, to: 50) {
            Self.sample($0, mic: true, running: [Self.slack], attributed: Self.slack)
        }
        #expect(l.phase == .live)
        #expect(!l.isHolding, "audioInputInUse explains this one, and explains it better")
        #expect(l.heldSecondsThisEpisode == 0, "so the latch is charged nothing for it")
    }

    @Test("The latch's own live block is bounded by the episode ceiling like every other hold")
    func unreliableLiveBlockIsBounded() {
        var l = Self.fresh()
        l = Self.run(l, from: 5, to: 5 + Self.policy.latchEpisodeCeiling + 300) {
            Self.sample($0, mic: true, deviceBlocks: false, running: [Self.slack], attributed: Self.slack)
        }
        #expect(!l.isHolding, "politeness cannot become silence here either")
        #expect(l.closeReason == .episodeCeiling)
    }

    @Test("Nothing but a capture fact can open the latch")
    func inferenceCannotOpenIt() {
        var l = Self.fresh()
        l = Self.run(l, from: 5, to: 3600) {
            Self.sample(
                $0,
                running: [Self.slack, Self.chrome],
                attributed: Self.slack,
                frontmost: Self.slack
            )
        }
        #expect(!l.isHolding)
        #expect(l.phase == .closed)
    }

    @Test("A fresh latch suspects a call for ninety seconds, and only suspects it")
    func coldStartDefersButNeverBlocks() {
        let l = Self.fresh()
        let early = l
            .advanced(Self.sample(5, running: [Self.slack]), policy: Self.policy)
            .signal(at: 5, wall: Self.wall0, policy: Self.policy)
        #expect(early.suspectsCall, "the app may have launched in the middle of a call")
        #expect(!early.isHolding, "but it did not see it start, so it may only defer")

        let later = l
            .advanced(Self.sample(Self.policy.latchColdStartGrace + 10, running: [Self.slack]), policy: Self.policy)
            .signal(at: Self.policy.latchColdStartGrace + 10, wall: Self.wall0, policy: Self.policy)
        #expect(!later.suspectsCall)
    }

    @Test("Arming defers, because a capture fact that is only seconds old is still a guess")
    func armingDefers() {
        var l = Self.fresh()
        l = l.advanced(Self.sample(5, mic: true), policy: Self.policy)
        let signal = l.signal(at: 10, wall: Self.wall0, policy: Self.policy)
        #expect(signal.suspectsCall)
        #expect(!signal.isHolding)
    }

    @Test("The hold says what it saw, and never that you are in a meeting")
    func summaryNamesTheFact() {
        var l = Self.fresh()
        l = Self.run(l, from: 5, to: 50) {
            Self.sample($0, mic: true, running: [Self.slack], attributed: Self.slack)
        }
        l = l.advanced(Self.sample(55, running: [Self.slack]), policy: Self.policy)
        let summary = l.signal(at: 55, wall: Self.wall0, policy: Self.policy).summary
        #expect(summary?.contains("microphone") == true)
        #expect(summary?.contains("Slack") == true)
        #expect(summary?.lowercased().contains("you are in a meeting") == false)
    }
}

enum TestContext {
    static func make(
        activity: Activity = .coding,
        continuousWork: TimeInterval = 46 * 60,
        idleSeconds: TimeInterval = 1
    ) -> DeveloperContext {
        DeveloperContext(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            application: AppIdentity(bundleID: "com.apple.dt.Xcode", localizedName: "Xcode", pid: 1),
            activity: activity,
            confidence: Confidence(0.9),
            continuousWork: continuousWork,
            idleSeconds: idleSeconds
        )
    }
}
