import Foundation

// MARK: - Policy thresholds

/// Every threshold the session clock and the decision engine use, in one value.
///
/// `SigstopSettings` is the *user-facing* subset (work interval, micro-idle grace, snooze,
/// caps). Everything else here is a product constant from docs/BREAK-DECISION.md §4.2 that
/// the UI does not expose. Deriving the policy from settings rather than reading settings
/// all over the engine keeps one place to look when a number misbehaves.
public struct BreakPolicy: Sendable, Codable, Hashable {

    public var tickInterval: TimeInterval = 1
    /// A tick that lands later than `tickInterval + tickTolerance` is not a tick, it is a
    /// discontinuity: the process was throttled, suspended, or the machine slept. It is
    /// classified as a gap and credited nothing. See CLAUDE.md §3.4.
    public var tickTolerance: TimeInterval = 2
    /// Idle under this means input just happened.
    public var activityEpsilon: TimeInterval = 2
    /// Reading a diff is work. A gap shorter than this is credited (provisionally).
    public var microIdleGrace: TimeInterval = 90
    public var qualifyingBreak: TimeInterval = 5 * 60
    /// Any pause reaching this resets the clock, the context is gone, but records no break.
    public var longPauseReset: TimeInterval = 20 * 60
    public var sessionGap: TimeInterval = 30 * 60
    public var dayBoundaryHour: Int = 4
    /// Wall-clock movement that disagrees with the monotonic clock by more than this is an
    /// NTP step or a user changing the date. It is never work and never a break.
    public var wallClockSkewTolerance: TimeInterval = 5

    public var targetContinuousWork: TimeInterval = 45 * 60
    /// The floor that makes generosity elsewhere safe: at this much continuous work the
    /// engine fires regardless of deep focus.
    public var absoluteMaxWork: TimeInterval = 90 * 60
    public var breakDurationTarget: TimeInterval = 5 * 60
    /// You do not tell someone who just sat back down to get up.
    public var settleInAfterBreak: TimeInterval = 5 * 60
    public var deepFocusMinimumWork: TimeInterval = 20 * 60

    public var softDeferralWindow: TimeInterval = 8 * 60
    public var deepFocusExtension: TimeInterval = 7 * 60
    /// Hard ceiling on seam-waiting per cycle, "maximum 15 minutes of seam-waiting per
    /// cycle" (§7.2). It holds across a snooze, which resets the *current* seam window, so
    /// snoozing cannot be used to buy a second deep-focus extension.
    public var maxSeamWaitPerCycle: TimeInterval = 15 * 60
    public var seamIdleBlip: TimeInterval = 20
    /// Past this, a "time for a break" is noise. The cycle is abandoned, not fired late.
    public var staleBreakCeiling: TimeInterval = 60 * 60
    public var rearmAfterStale: TimeInterval = 10 * 60
    public var rearmAfterSkip: TimeInterval = 20 * 60
    public var cooldownAfterExhausted: TimeInterval = 25 * 60

    public var promptTimeout: TimeInterval = 90
    public var snoozeDurations: [TimeInterval] = [5 * 60, 10 * 60, 15 * 60]
    /// Equal to `SigstopSettings.maxSnoozesPerBreak`'s default on purpose. `init(settings:)`
    /// overwrites it, so the literal is only what a bare `BreakPolicy()` hands out, and a
    /// literal that disagrees with the settings default means tests and previews run a
    /// policy the app never uses. This one said 3 while the app ran 2.
    public var maxSnoozesPerCycle: Int = 2
    public var maxSnoozeTotalPerCycle: TimeInterval = 30 * 60
    public var minNotificationSpacing: TimeInterval = 5 * 60
    public var maxNotificationsPerCycle: Int = 4
    /// As with `maxSnoozesPerCycle`: equal to the settings default, which is 14. This
    /// said 12, and `docs/BREAK-DECISION.md` did its cap arithmetic against the 12, so the
    /// one number a reader could check was the one number nothing used.
    public var dailyNotificationCap: Int = 14

    /// L1 SIGTSTP. **Not** free and **not** passive, whatever this comment used to say.
    ///
    /// It is delivered as an ordinary notification by `handleBreakDue` and it spends one
    /// unit of both the cycle budget and the day's. `ladderLevel1 = 0` is the rung's timing
    /// offset and nothing more. The old wording ("passive, silent, costs no notification
    /// budget") described `channelFor`'s `.passiveIndicator` arm, which the deliver path
    /// never calls, so three places in the source agreed with each other and disagreed with
    /// what the app does.
    public var ladderLevel1: TimeInterval = 0
    /// L2 SIGINT, quiet repeat.
    public var ladderLevel2: TimeInterval = 5 * 60
    /// L3 SIGTERM, armed here, fires at the first seam.
    public var ladderLevel3Armed: TimeInterval = 12 * 60
    /// L3 forced, seam or no seam.
    public var ladderLevel3Forced: TimeInterval = 20 * 60
    /// L4 SIGSTOP, one assertive, still non-blocking presentation. Then the ladder ends.
    public var ladderLevel4: TimeInterval = 35 * 60
    /// After 2 consecutive fully-ignored cycles the ladder truncates to L1–L2.
    public var ignoreBackoffThreshold: Int = 2

    /// How long a running input device may hold a break on its own evidence.
    ///
    /// `audioInputInUse` is filed under hard blocks, whose contract one line below is
    /// "only a real system signal may hard-block, nothing here is inferred". It does not
    /// meet that contract. The OS fact is *a device is running*; "therefore you are on a
    /// call" is an inference, and an inference in the uncatchable list is how a Mac with
    /// Krisp, BlackHole, an aggregate device or a headset daemon goes silent forever.
    ///
    /// Derived rather than tasted: `latchFactHold + latchAnchorExtension`, which is this
    /// repo's own written answer to "the longest a capture fact alone should be allowed
    /// to mean call". Past it, with nothing independent corroborating, the device stops
    /// hard-blocking and becomes a soft deferral the seam budget bounds. Corroborated
    /// capture is not bounded at all: see `audioIsCorroborated`.
    public var uncorroboratedAudioCeiling: TimeInterval = 20 * 60

    // MARK: The call latch (docs/BREAK-DECISION.md §7.7)

    /// Continuous microphone or camera use before the latch will arm at all. Nothing
    /// briefer than this is a call: a Siri wake word, a "test your microphone" chirp, one
    /// dictated sentence and Photo Booth opening are all far shorter. The dwell costs no
    /// coverage, because while capture is live the pre-existing `audioInputInUse` and
    /// `cameraInUse` blocks are already in force.
    public var latchArmDwell: TimeInterval = 45
    /// How long the latch holds after capture stops, unconditionally. This is the price of
    /// being wrong, set deliberately: a false latch does not suppress a prompt, it delays
    /// one, because the work clock keeps running in the session tracker.
    public var latchFactHold: TimeInterval = 8 * 60
    /// Extra hold while an adopted call-capable app is still running. It can only ever
    /// lengthen the hold to 20 minutes, never carry it.
    public var latchAnchorExtension: TimeInterval = 12 * 60
    /// The hold once an app the latch actually adopted has quit. The call is over.
    public var latchAnchorQuitHold: TimeInterval = 90
    /// Accumulated HOLD seconds in one episode. Past this the latch is wrong about
    /// something, so it closes and says so.
    public var latchEpisodeCeiling: TimeInterval = 90 * 60
    /// Accumulated HOLD seconds in one local day.
    public var latchDailyCeiling: TimeInterval = 3 * 3600
    /// Quiet capture required before the latch may arm again after an episode ceiling.
    public var latchRearmQuiet: TimeInterval = 10 * 60
    /// After the user presses "Not in a meeting".
    public var latchManualInhibit: TimeInterval = 30 * 60
    /// After the user presses "I'm in a meeting". It expires; a manual hold that never
    /// expires is a mute button.
    public var latchManualHold: TimeInterval = 2 * 3600
    /// A step larger than this on either clock is a gap nobody watched, not a tick.
    /// Deliberately its own number rather than `tickInterval + tickTolerance`, which the
    /// app overrides at runtime and tests do not.
    public var latchGapTolerance: TimeInterval = 10
    /// For this long after launch, a running conferencing app is enough to DEFER. The app
    /// may have started in the middle of a call it never saw begin, and at Tier 0 the
    /// inference path cannot say so on its own.
    public var latchColdStartGrace: TimeInterval = 90

    public init() {}

    /// Derive the policy from the user's settings, keeping the product constants.
    public init(settings: SigstopSettings) {
        self.init()
        targetContinuousWork = settings.workInterval
        breakDurationTarget = settings.breakDuration
        microIdleGrace = TimeInterval(settings.microIdleThresholdSeconds)
        qualifyingBreak = TimeInterval(settings.idleCountsAsBreakMinutes * 60)
        dailyNotificationCap = settings.maxNotificationsPerDay
        maxSnoozesPerCycle = settings.maxSnoozesPerBreak
        let unit = TimeInterval(settings.snoozeMinutes * 60)
        snoozeDurations = [unit, unit * 2, unit * 3]
        /// The cap has to know how long an interval is, or it is not a cap on a day.
        ///
        /// Every other constant in this block is derived against its neighbours; this one
        /// was a raw assignment, and it was the only one. 14 is tuned for a 45 to 90 minute
        /// interval, where it is more prompts than a day can produce. At the 5 minute
        /// minimum the app offers, a cycle plus its break is ten minutes, so 14 is spent
        /// after about two hours and the app then says nothing for the rest of the day —
        /// which is a setting one screen away silently switching the product off.
        ///
        /// So the user's number is a floor, not a ceiling: it is raised to whatever a
        /// sixteen hour waking day would actually ask for at the interval they chose.
        /// Someone who wants fewer interruptions turns the interval up, which is the
        /// control that means that; nobody sets a daily cap intending the app to stop.
        let cyclesInAWakingDay = Int((16 * 3600) / max(60, targetContinuousWork + breakDurationTarget))
        dailyNotificationCap = max(settings.maxNotificationsPerDay, cyclesInAWakingDay)
        absoluteMaxWork = max(absoluteMaxWork, targetContinuousWork * 2)
        qualifyingBreak = max(qualifyingBreak, microIdleGrace + 30)
        sessionGap = max(sessionGap, qualifyingBreak * 2)
        longPauseReset = min(max(longPauseReset, qualifyingBreak), sessionGap)
    }

    public static let `default` = BreakPolicy()

    /// The activities that can count as deep focus. Meeting, browsing and chat cannot.
    public static let deepFocusActivities: Set<Activity> = [
        .coding, .debugging, .testing, .terminalWork, .aiCoding,
    ]
}

/// The local day, with the 04:00 boundary of §4.1 row 17 applied. Computed with `Calendar`
/// so DST and time-zone changes behave; never by adding 86_400 to a `Date`.
public enum LocalDay {
    public static func index(of date: Date, calendar: Calendar, boundaryHour: Int) -> Int {
        let shifted = date.addingTimeInterval(-Double(boundaryHour) * 3600)
        let c = calendar.dateComponents([.era, .year, .month, .day], from: shifted)
        let year = c.year ?? 0, month = c.month ?? 0, day = c.day ?? 0
        return year * 10_000 + month * 100 + day
    }
}

// MARK: - System signals (facts, not guesses)

/// Observations that are **facts about the machine**. Only these may hard-block a prompt.
/// Anything inferred about what an app *is* lives in `DeveloperContext` and may, at most,
/// cause a soft deferral. CLAUDE.md §4.1.
public struct SystemSignals: Sendable, Codable, Hashable {
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere`. The mic is actually running.
    public var audioInputRunning: Bool
    /// `kCMIODevicePropertyDeviceIsRunningSomewhere`. A camera device is actually running.
    /// Read permission-free, exactly as the audio bit above is.
    public var cameraRunning: Bool
    public var displayCaptured: Bool
    public var screenLocked: Bool
    public var systemSleeping: Bool
    public var fastUserSwitched: Bool
    /// nil means undetectable, which is not the same as false. See §7.1.
    public var focusModeActive: Bool?
    public var frontmostIsFullscreen: Bool
    public var frontmostIsPresentationApp: Bool
    public var batteryFraction: Double?
    public var isCharging: Bool
    public var lowPowerMode: Bool
    /// The trailing edge of a capture fact. See `MeetingLatch`.
    public var meetingLatch: MeetingLatchSignal

    public init(
        audioInputRunning: Bool = false,
        cameraRunning: Bool = false,
        displayCaptured: Bool = false,
        screenLocked: Bool = false,
        systemSleeping: Bool = false,
        fastUserSwitched: Bool = false,
        focusModeActive: Bool? = nil,
        frontmostIsFullscreen: Bool = false,
        frontmostIsPresentationApp: Bool = false,
        batteryFraction: Double? = nil,
        isCharging: Bool = true,
        lowPowerMode: Bool = false,
        meetingLatch: MeetingLatchSignal = .closed
    ) {
        self.audioInputRunning = audioInputRunning
        self.cameraRunning = cameraRunning
        self.displayCaptured = displayCaptured
        self.screenLocked = screenLocked
        self.systemSleeping = systemSleeping
        self.fastUserSwitched = fastUserSwitched
        self.focusModeActive = focusModeActive
        self.frontmostIsFullscreen = frontmostIsFullscreen
        self.frontmostIsPresentationApp = frontmostIsPresentationApp
        self.batteryFraction = batteryFraction
        self.isCharging = isCharging
        self.lowPowerMode = lowPowerMode
        self.meetingLatch = meetingLatch
    }

    public static let none = SystemSignals()

    /// Overlay channel is unavailable and animations are off. Never changes *whether* a
    /// break is due (§7.6).
    public var isPowerConstrained: Bool {
        lowPowerMode || (!isCharging && (batteryFraction ?? 1) < 0.20)
    }

    public var isSeverelyPowerConstrained: Bool {
        !isCharging && (batteryFraction ?? 1) < 0.10
    }
}

/// Optional, read-only calendar adjacency. Absent when EventKit was never granted, the
/// engine degrades to knowing nothing rather than to guessing.
public struct CalendarSignals: Sendable, Codable, Hashable {
    public var eventInProgress: Bool
    public var inProgressIsBusy: Bool
    public var inProgressHasVideoLink: Bool
    public var minutesUntilNextBusyEvent: Int?

    public init(
        eventInProgress: Bool = false,
        inProgressIsBusy: Bool = false,
        inProgressHasVideoLink: Bool = false,
        minutesUntilNextBusyEvent: Int? = nil
    ) {
        self.eventInProgress = eventInProgress
        self.inProgressIsBusy = inProgressIsBusy
        self.inProgressHasVideoLink = inProgressHasVideoLink
        self.minutesUntilNextBusyEvent = minutesUntilNextBusyEvent
    }
}

/// A moment the user has already broken their own concentration.
public enum Seam: String, Sendable, Codable, Hashable, CaseIterable {
    case applicationSwitch
    case idleBlip
    case terminalCommandFinished
    case meetingEnded
    case fullscreenExited
    case spaceSwitch
}

// MARK: - Verdict

public enum InterruptionVerdict: Sendable, Codable, Hashable {
    case deliver
    case hardBlocked(HardBlock)
    case softDeferred(SoftDeferReason)
    case rateLimited(RateLimit)

    public var isHardBlocked: Bool { if case .hardBlocked = self { return true } else { return false } }
    public var isDeliverable: Bool { if case .deliver = self { return true } else { return false } }
}

/// Never deliver. Derived from a system fact, never from a classification.
public enum HardBlock: String, Sendable, Codable, Hashable {
    case audioInputInUse
    case cameraInUse
    /// A capture device ran continuously for at least `latchArmDwell` and stopped less
    /// than the latch's hold budget ago. Named after what it asserts, not after what a
    /// person might conclude from it: the app does not know you are in a meeting, it
    /// knows a microphone or camera was live and how long ago. See `MeetingLatch`.
    case recentCallContinuing
    case screenBeingShared
    case presentationFullscreen
    case focusModeActive
    case screenLocked
    case systemSleeping
    case fastUserSwitched
    case settleInAfterBreak
    case videoEventInProgress
    case imminentMeeting
}

/// Wait for a seam, but on a budget, and the budget always runs out.
public enum SoftDeferReason: String, Sendable, Codable, Hashable {
    case deepFocus
    case typingBurst
    case terminalCommandRunning
    case preMeetingWindow
    case recentAppLaunch
    /// An *inferred* meeting: a conferencing app is frontmost, the mic is not actually
    /// running. "I think you're in a meeting" is not "the mic is on", so it defers only.
    case inferredMeeting
    /// An input device has been running past `uncorroboratedAudioCeiling` with nothing
    /// independent saying it is a call. The device is still live, so this waits for a
    /// seam and suppresses the sound channel; it no longer blocks outright.
    case liveCaptureUnattributed
    /// A busy calendar event with no corroborating system signal. A calendar entry is a
    /// guess: people leave events on their calendars they are not attending.
    case calendarEventInProgress
}

public enum RateLimit: String, Sendable, Codable, Hashable {
    case quietHours
    case dailyCapReached
    case cycleNotificationCap
    case minimumSpacing
    case ignoreBackoff

    /// True when this limit cannot lift again before the cycle closes.
    ///
    /// Both of these are built from `notificationsThisCycle`, which only ever grows, so
    /// once they fire nothing further can be delivered in this cycle whatever happens
    /// next. `minimumSpacing` lifts on its own and is not one of them; `quietHours` and
    /// `dailyCapReached` close the cycle on their own branch and never reach here.
    public var isTerminalForCycle: Bool {
        switch self {
        case .ignoreBackoff, .cycleNotificationCap: return true
        case .minimumSpacing, .quietHours, .dailyCapReached: return false
        }
    }
}

/// The per-cycle deferral budget the verdict reads and the engine advances.
public struct CycleBudget: Sendable, Codable, Hashable {
    /// Seam-waiting in the current window. A snooze opens a fresh window.
    public var seamWaitElapsed: TimeInterval
    /// Seam-waiting across the whole cycle, windows included. Never resets.
    public var seamWaitTotal: TimeInterval
    public var deepFocusExtensionUsed: Bool
    public var notificationsThisCycle: Int
    /// Continuous seconds this cycle has been held by a running input device that nothing
    /// else corroborates. Reset to zero the moment the device bit drops or something
    /// independent says it is a call, so a run of real short calls never accumulates.
    public var uncorroboratedAudioElapsed: TimeInterval

    public init(
        seamWaitElapsed: TimeInterval = 0,
        seamWaitTotal: TimeInterval = 0,
        deepFocusExtensionUsed: Bool = false,
        notificationsThisCycle: Int = 0,
        uncorroboratedAudioElapsed: TimeInterval = 0
    ) {
        self.seamWaitElapsed = seamWaitElapsed
        self.seamWaitTotal = seamWaitTotal
        self.deepFocusExtensionUsed = deepFocusExtensionUsed
        self.notificationsThisCycle = notificationsThisCycle
        self.uncorroboratedAudioElapsed = uncorroboratedAudioElapsed
    }
}

// MARK: - The policy

/// Is the app allowed to say something *right now*?
///
/// Generous with waiting, strict about never firing into a hard block, but bounded, so
/// politeness cannot become silence. Pure: no clock reads, no I/O.
public struct InterruptionPolicy: Sendable {
    public let policy: BreakPolicy
    public init(policy: BreakPolicy) { self.policy = policy }

    /// Evaluation order is part of the spec (docs/BREAK-DECISION.md §8): hard blocks precede
    /// rate limits (a blocked prompt must not burn the cycle's notification budget), rate
    /// limits precede the absolute-max floor, and a seam beats every soft reason.
    public func verdict(_ input: EngineInput, budget: CycleBudget) -> InterruptionVerdict {
        if let block = hardBlock(input, budget: budget) { return .hardBlocked(block) }
        if let limit = rateLimit(input, budget: budget) { return .rateLimited(limit) }

        if input.context.continuousWork >= policy.absoluteMaxWork { return .deliver }

        if budget.seamWaitElapsed < softBudget(input, budget: budget),
           budget.seamWaitTotal < policy.maxSeamWaitPerCycle {
            if !input.seams.isEmpty { return .deliver }   // a seam beats any soft reason
            if let reason = softDefer(input) { return .softDeferred(reason) }
        }
        return .deliver   // budget spent: fire.
    }

    /// Only a real system signal may hard-block. Nothing here is inferred.
    ///
    /// The one exception used to be the microphone, and it was the exception that made
    /// the app invisible: see `BreakPolicy.uncorroboratedAudioCeiling`. The budget is how
    /// long the current opportunity has already been held by it.
    public func hardBlock(_ input: EngineInput, budget: CycleBudget = CycleBudget()) -> HardBlock? {
        let s = input.signals
        if s.screenLocked { return .screenLocked }
        if s.systemSleeping { return .systemSleeping }
        if s.fastUserSwitched { return .fastUserSwitched }
        if s.audioInputRunning {
            if let c = input.calendar, c.eventInProgress, c.inProgressIsBusy, c.inProgressHasVideoLink {
                return .videoEventInProgress
            }
            if audioIsCorroborated(input)
                || budget.uncorroboratedAudioElapsed < policy.uncorroboratedAudioCeiling {
                return .audioInputInUse
            }
        }
        if s.cameraRunning { return .cameraInUse }
        /// After the two live facts, so that while a device is actually running the more
        /// precise block explains itself. Before `settleInAfterBreak`, so a call is never
        /// mis-explained as "you just got back".
        if s.meetingLatch.isHolding { return .recentCallContinuing }
        if s.displayCaptured { return .screenBeingShared }
        if s.frontmostIsFullscreen && (s.frontmostIsPresentationApp || s.cameraRunning) {
            return .presentationFullscreen
        }
        if s.focusModeActive == true { return .focusModeActive }
        if let ended = input.lastBreakEndedAt,
           input.now.timeIntervalSince(ended) >= 0,
           input.now.timeIntervalSince(ended) < policy.settleInAfterBreak {
            return .settleInAfterBreak
        }
        if let minutes = input.calendar?.minutesUntilNextBusyEvent, minutes <= 2 { return .imminentMeeting }
        return nil
    }

    /// Is anything other than the input device itself saying this is a call?
    ///
    /// Every term is independent of `audioInputRunning`, which is the whole point: the
    /// latch arming on the same microphone bit would be the same evidence counted twice.
    /// Any one of these and the block is unbounded, exactly as it was.
    public func audioIsCorroborated(_ input: EngineInput) -> Bool {
        let s = input.signals
        if s.cameraRunning { return true }
        if s.meetingLatch.basis == .manual { return true }
        if s.meetingLatch.anchorName != nil { return true }
        if let c = input.calendar, c.eventInProgress, c.inProgressIsBusy { return true }
        return false
    }

    /// True when no further rung can reach this cycle, whatever happens next.
    ///
    /// Both clauses mirror `rateLimit` exactly and are built from `notificationsThisCycle`,
    /// which only grows, so neither limit can lift before the cycle closes. Without this
    /// the engine ran `ladderLevel4`'s timer to completion over a ladder whose rungs it
    /// had already switched off, which is where 36 of the reported 63 quiet minutes went.
    public func ladderIsSpent(_ input: EngineInput, budget: CycleBudget) -> Bool {
        if budget.notificationsThisCycle >= policy.maxNotificationsPerCycle { return true }
        return input.day.consecutiveIgnoredCycles >= policy.ignoreBackoffThreshold
            && budget.notificationsThisCycle >= 1
    }

    /// Rate limits do not pause the deferral clocks; they close the cycle instead.
    public func rateLimit(_ input: EngineInput, budget: CycleBudget) -> RateLimit? {
        if input.settings.quietHours.contains(input.now, calendar: input.calendarSystem) { return .quietHours }
        if input.day.notificationsDelivered >= policy.dailyNotificationCap { return .dailyCapReached }
        if budget.notificationsThisCycle >= policy.maxNotificationsPerCycle { return .cycleNotificationCap }
        if let last = input.day.lastNotificationAt,
           input.now.timeIntervalSince(last) >= 0,
           input.now.timeIntervalSince(last) < policy.minNotificationSpacing {
            return .minimumSpacing
        }
        if input.day.consecutiveIgnoredCycles >= policy.ignoreBackoffThreshold, budget.notificationsThisCycle >= 1 {
            return .ignoreBackoff
        }
        return nil
    }

    /// Maximum seam-waiting for the current window.
    ///
    /// `deepFocusExtensionUsed` records that this cycle has already *taken* its one
    /// extension; it must therefore keep granting it, not retract it the moment focus dips
    /// or the flag is set. Read the other way round, as the doc's `!used`, the budget
    /// collapses back to 8 minutes the instant it is recorded and the extension is never
    /// actually spent. What makes it "exactly one" is `maxSeamWaitPerCycle`, checked in
    /// `verdict`, which no snooze can reopen.
    public func softBudget(_ input: EngineInput, budget: CycleBudget) -> TimeInterval {
        let extended = budget.deepFocusExtensionUsed || isDeepFocus(input)
        return policy.softDeferralWindow + (extended ? policy.deepFocusExtension : 0)
    }

    public func softDefer(_ input: EngineInput) -> SoftDeferReason? {
        if input.keystrokeRate > 2.0 { return .typingBurst }
        if input.terminalCommandRunning { return .terminalCommandRunning }
        if input.secondsSinceFrontmostChange < policy.seamIdleBlip { return .recentAppLaunch }
        /// The latch's weak states. Arming means a capture fact exists but has not lasted
        /// long enough to block on; the cold-start window means the app may have launched
        /// in the middle of a call it never saw begin. Both are guesses, so both defer.
        ///
        /// This is also the only meeting deferral a zero-permission user can ever get.
        /// `meetingConfidence` is clamped to the Tier 0 ceiling, which sits below the
        /// specific-claim threshold, so `concurrent.inMeeting` is structurally false
        /// without Accessibility and the branch below it is unreachable. Raising the
        /// ceiling would be fixing an honesty mechanism by breaking it; this gets the
        /// deferral from a fact instead.
        /// Reaching here with the input device still running means `hardBlock` gave up on
        /// it: past the ceiling, uncorroborated. The device is live, so this defers rather
        /// than delivers, which is what keeps the bound off a long call the app cannot
        /// corroborate. It is ordered above the latch on purpose, because the latch
        /// suspecting a call from that same microphone bit is the same evidence twice, and
        /// `inferredMeeting` would name a conferencing app that is not running.
        if input.signals.audioInputRunning { return .liveCaptureUnattributed }
        if input.signals.meetingLatch.suspectsCall { return .inferredMeeting }
        if input.context.concurrent.inMeeting,
           input.context.concurrent.meetingConfidence.isConfidentEnoughForSpecificClaim {
            return .inferredMeeting
        }
        if let c = input.calendar, let minutes = c.minutesUntilNextBusyEvent, (3...6).contains(minutes) {
            return .preMeetingWindow
        }
        if let c = input.calendar, c.eventInProgress, c.inProgressIsBusy { return .calendarEventInProgress }
        if isDeepFocus(input) { return .deepFocus }
        return nil
    }

    public func isDeepFocus(_ input: EngineInput) -> Bool {
        input.focusScore >= 0.70
            && input.context.continuousWork >= policy.deepFocusMinimumWork
            && input.context.confidence.isConfidentEnoughForSpecificClaim
            && BreakPolicy.deepFocusActivities.contains(input.context.activity)
    }

    /// The one case where the app fires early: a natural seam the calendar handed it.
    public func opportunisticEarlyPrompt(_ input: EngineInput) -> Bool {
        guard let minutes = input.calendar?.minutesUntilNextBusyEvent else { return false }
        return input.context.continuousWork >= 0.8 * policy.targetContinuousWork && (6...15).contains(minutes)
    }

    /// Snooze durations still on offer, shrunk to fit the remaining cap. Empty means the
    /// prompt must stop offering snooze, offering a fourth that behaves like the third
    /// is not honest.
    public func offeredSnoozes(used: Int, total: TimeInterval) -> [TimeInterval] {
        guard used < policy.maxSnoozesPerCycle else { return [] }
        let remaining = policy.maxSnoozeTotalPerCycle - total
        guard remaining > 0 else { return [] }
        let fitted = policy.snoozeDurations.map { min($0, remaining) }
        var seen: Set<TimeInterval> = []
        return fitted.filter { $0 > 0 && seen.insert($0).inserted }
    }
}
