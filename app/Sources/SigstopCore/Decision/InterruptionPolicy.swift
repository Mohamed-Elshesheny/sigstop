import Foundation

public struct BreakPolicy: Sendable, Codable, Hashable {

    public var tickInterval: TimeInterval = 1
    public var tickTolerance: TimeInterval = 2
    public var activityEpsilon: TimeInterval = 2
    public var microIdleGrace: TimeInterval = 90
    public var qualifyingBreak: TimeInterval = 5 * 60
    public var longPauseReset: TimeInterval = 20 * 60
    public var sessionGap: TimeInterval = 30 * 60
    public var dayBoundaryHour: Int = 4
    public var wallClockSkewTolerance: TimeInterval = 5

    public var targetContinuousWork: TimeInterval = 45 * 60
    public var absoluteMaxWork: TimeInterval = 90 * 60
    public var breakDurationTarget: TimeInterval = 5 * 60
    public var settleInAfterBreak: TimeInterval = 5 * 60
    public var deepFocusMinimumWork: TimeInterval = 20 * 60

    public var softDeferralWindow: TimeInterval = 8 * 60
    public var deepFocusExtension: TimeInterval = 7 * 60
    public var maxSeamWaitPerCycle: TimeInterval = 15 * 60
    public var seamIdleBlip: TimeInterval = 20
    public var staleBreakCeiling: TimeInterval = 60 * 60
    public var rearmAfterStale: TimeInterval = 10 * 60
    public var rearmAfterSkip: TimeInterval = 20 * 60
    public var cooldownAfterExhausted: TimeInterval = 25 * 60

    public var promptTimeout: TimeInterval = 90
    public var snoozeDurations: [TimeInterval] = [5 * 60, 10 * 60, 15 * 60]
    public var maxSnoozesPerCycle: Int = 2
    public var maxSnoozeTotalPerCycle: TimeInterval = 30 * 60
    public var minNotificationSpacing: TimeInterval = 5 * 60
    public var maxNotificationsPerCycle: Int = 4
    public var dailyNotificationCap: Int = 14

    public var ladderLevel1: TimeInterval = 0
    public var ladderLevel2: TimeInterval = 5 * 60
    public var ladderLevel3Armed: TimeInterval = 12 * 60
    public var ladderLevel3Forced: TimeInterval = 20 * 60
    public var ladderLevel4: TimeInterval = 35 * 60
    public var ignoreBackoffThreshold: Int = 2

    public var uncorroboratedAudioCeiling: TimeInterval = 20 * 60

    public var latchArmDwell: TimeInterval = 45
    public var latchFactHold: TimeInterval = 8 * 60
    public var latchAnchorExtension: TimeInterval = 12 * 60
    public var latchAnchorQuitHold: TimeInterval = 90
    public var latchEpisodeCeiling: TimeInterval = 90 * 60
    public var latchDailyCeiling: TimeInterval = 3 * 3600
    public var latchRearmQuiet: TimeInterval = 10 * 60
    public var latchManualInhibit: TimeInterval = 30 * 60
    public var latchManualHold: TimeInterval = 2 * 3600
    public var latchGapTolerance: TimeInterval = 10
    public var latchColdStartGrace: TimeInterval = 90

    public init() {}

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
        let cyclesInAWakingDay = Int((16 * 3600) / max(60, targetContinuousWork + breakDurationTarget))
        dailyNotificationCap = max(settings.maxNotificationsPerDay, cyclesInAWakingDay)
        absoluteMaxWork = max(absoluteMaxWork, targetContinuousWork * 2)
        qualifyingBreak = max(qualifyingBreak, microIdleGrace + 30)
        sessionGap = max(sessionGap, qualifyingBreak * 2)
        longPauseReset = min(max(longPauseReset, qualifyingBreak), sessionGap)
    }

    public static let `default` = BreakPolicy()

    public static let deepFocusActivities: Set<Activity> = [
        .coding, .debugging, .testing, .terminalWork, .aiCoding,
    ]
}

public enum LocalDay {
    public static func index(of date: Date, calendar: Calendar, boundaryHour: Int) -> Int {
        let shifted = date.addingTimeInterval(-Double(boundaryHour) * 3600)
        let c = calendar.dateComponents([.era, .year, .month, .day], from: shifted)
        let year = c.year ?? 0, month = c.month ?? 0, day = c.day ?? 0
        return year * 10_000 + month * 100 + day
    }
}

public struct SystemSignals: Sendable, Codable, Hashable {
    public var audioInputRunning: Bool
    public var cameraRunning: Bool
    public var displayCaptured: Bool
    public var screenLocked: Bool
    public var systemSleeping: Bool
    public var fastUserSwitched: Bool
    public var focusModeActive: Bool?
    public var frontmostIsFullscreen: Bool
    public var frontmostIsPresentationApp: Bool
    public var batteryFraction: Double?
    public var isCharging: Bool
    public var lowPowerMode: Bool
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

    public var isPowerConstrained: Bool {
        lowPowerMode || (!isCharging && (batteryFraction ?? 1) < 0.20)
    }

    public var isSeverelyPowerConstrained: Bool {
        !isCharging && (batteryFraction ?? 1) < 0.10
    }
}

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

public enum Seam: String, Sendable, Codable, Hashable, CaseIterable {
    case applicationSwitch
    case idleBlip
    case terminalCommandFinished
    case meetingEnded
    case fullscreenExited
    case spaceSwitch
}

public enum InterruptionVerdict: Sendable, Codable, Hashable {
    case deliver
    case hardBlocked(HardBlock)
    case softDeferred(SoftDeferReason)
    case rateLimited(RateLimit)

    public var isHardBlocked: Bool { if case .hardBlocked = self { return true } else { return false } }
    public var isDeliverable: Bool { if case .deliver = self { return true } else { return false } }
}

public enum HardBlock: String, Sendable, Codable, Hashable {
    case audioInputInUse
    case cameraInUse
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

public enum SoftDeferReason: String, Sendable, Codable, Hashable {
    case deepFocus
    case typingBurst
    case terminalCommandRunning
    case preMeetingWindow
    case recentAppLaunch
    case inferredMeeting
    case liveCaptureUnattributed
    case calendarEventInProgress
}

public enum RateLimit: String, Sendable, Codable, Hashable {
    case quietHours
    case dailyCapReached
    case cycleNotificationCap
    case minimumSpacing
    case ignoreBackoff

    public var isTerminalForCycle: Bool {
        switch self {
        case .ignoreBackoff, .cycleNotificationCap: return true
        case .minimumSpacing, .quietHours, .dailyCapReached: return false
        }
    }
}

public struct CycleBudget: Sendable, Codable, Hashable {
    public var seamWaitElapsed: TimeInterval
    public var seamWaitTotal: TimeInterval
    public var deepFocusExtensionUsed: Bool
    public var notificationsThisCycle: Int
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

public struct InterruptionPolicy: Sendable {
    public let policy: BreakPolicy
    public init(policy: BreakPolicy) { self.policy = policy }

    public func verdict(_ input: EngineInput, budget: CycleBudget) -> InterruptionVerdict {
        if let block = hardBlock(input, budget: budget) { return .hardBlocked(block) }
        if let limit = rateLimit(input, budget: budget) { return .rateLimited(limit) }

        if input.context.continuousWork >= policy.absoluteMaxWork { return .deliver }

        if budget.seamWaitElapsed < softBudget(input, budget: budget),
           budget.seamWaitTotal < policy.maxSeamWaitPerCycle {
            if !input.seams.isEmpty { return .deliver }
            if let reason = softDefer(input) { return .softDeferred(reason) }
        }
        return .deliver
    }

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

    public func audioIsCorroborated(_ input: EngineInput) -> Bool {
        let s = input.signals
        if s.cameraRunning { return true }
        if s.meetingLatch.basis == .manual { return true }
        if s.meetingLatch.anchorName != nil { return true }
        if let c = input.calendar, c.eventInProgress, c.inProgressIsBusy { return true }
        return false
    }

    public func ladderIsSpent(_ input: EngineInput, budget: CycleBudget) -> Bool {
        if budget.notificationsThisCycle >= policy.maxNotificationsPerCycle { return true }
        return input.day.consecutiveIgnoredCycles >= policy.ignoreBackoffThreshold
            && budget.notificationsThisCycle >= 1
    }

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

    public func softBudget(_ input: EngineInput, budget: CycleBudget) -> TimeInterval {
        let extended = budget.deepFocusExtensionUsed || isDeepFocus(input)
        return policy.softDeferralWindow + (extended ? policy.deepFocusExtension : 0)
    }

    public func softDefer(_ input: EngineInput) -> SoftDeferReason? {
        if input.keystrokeRate > 2.0 { return .typingBurst }
        if input.terminalCommandRunning { return .terminalCommandRunning }
        if input.secondsSinceFrontmostChange < policy.seamIdleBlip { return .recentAppLaunch }
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

    public func opportunisticEarlyPrompt(_ input: EngineInput) -> Bool {
        guard let minutes = input.calendar?.minutesUntilNextBusyEvent else { return false }
        return input.context.continuousWork >= 0.8 * policy.targetContinuousWork && (6...15).contains(minutes)
    }

    public func offeredSnoozes(used: Int, total: TimeInterval) -> [TimeInterval] {
        guard used < policy.maxSnoozesPerCycle else { return [] }
        let remaining = policy.maxSnoozeTotalPerCycle - total
        guard remaining > 0 else { return [] }
        let fitted = policy.snoozeDurations.map { min($0, remaining) }
        var seen: Set<TimeInterval> = []
        return fitted.filter { $0 > 0 && seen.insert($0).inserted }
    }
}
