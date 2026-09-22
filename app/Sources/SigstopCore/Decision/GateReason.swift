import Foundation

public enum GateReason: String, Sendable, Codable, CaseIterable, Hashable {
    case delivered

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

    case deepFocus
    case typingBurst
    case terminalCommandRunning
    case preMeetingWindow
    case recentAppLaunch
    case inferredMeeting
    case calendarEventInProgress
    case liveCaptureUnattributed

    case quietHours
    case dailyCapReached
    case cycleNotificationCap
    case minimumSpacing
    case ignoreBackoff

    case userSnoozed
    case userAway
    case breakRunning

    public init(_ verdict: InterruptionVerdict) {
        switch verdict {
        case .deliver:
            self = .delivered
        case .hardBlocked(let block):
            switch block {
            case .audioInputInUse:        self = .audioInputInUse
            case .cameraInUse:            self = .cameraInUse
            case .recentCallContinuing:   self = .recentCallContinuing
            case .screenBeingShared:      self = .screenBeingShared
            case .presentationFullscreen: self = .presentationFullscreen
            case .focusModeActive:        self = .focusModeActive
            case .screenLocked:           self = .screenLocked
            case .systemSleeping:         self = .systemSleeping
            case .fastUserSwitched:       self = .fastUserSwitched
            case .settleInAfterBreak:     self = .settleInAfterBreak
            case .videoEventInProgress:   self = .videoEventInProgress
            case .imminentMeeting:        self = .imminentMeeting
            }
        case .softDeferred(let reason):
            switch reason {
            case .deepFocus:               self = .deepFocus
            case .typingBurst:             self = .typingBurst
            case .terminalCommandRunning:  self = .terminalCommandRunning
            case .preMeetingWindow:        self = .preMeetingWindow
            case .recentAppLaunch:         self = .recentAppLaunch
            case .inferredMeeting:         self = .inferredMeeting
            case .calendarEventInProgress: self = .calendarEventInProgress
            case .liveCaptureUnattributed: self = .liveCaptureUnattributed
            }
        case .rateLimited(let limit):
            switch limit {
            case .quietHours:           self = .quietHours
            case .dailyCapReached:      self = .dailyCapReached
            case .cycleNotificationCap: self = .cycleNotificationCap
            case .minimumSpacing:       self = .minimumSpacing
            case .ignoreBackoff:        self = .ignoreBackoff
            }
        }
    }

    public var isHardBlock: Bool {
        switch self {
        case .audioInputInUse, .cameraInUse, .recentCallContinuing, .screenBeingShared, .presentationFullscreen,
             .focusModeActive, .screenLocked, .systemSleeping, .fastUserSwitched,
             .settleInAfterBreak, .videoEventInProgress, .imminentMeeting:
            return true
        default:
            return false
        }
    }

    public var summary: String {
        switch self {
        case .delivered:              return "nothing is holding it"
        case .audioInputInUse:        return "an audio input device is running, you may be on a call"
        case .cameraInUse:            return "a camera is running, you may be on a call"
        case .recentCallContinuing:   return "a microphone or camera was live until a moment ago, so this may still be a call"
        case .screenBeingShared:      return "your screen is being shared"
        case .presentationFullscreen: return "something fullscreen looks like a presentation"
        case .focusModeActive:        return "a Focus mode is on"
        case .screenLocked:           return "the screen is locked"
        case .systemSleeping:         return "the machine is asleep"
        case .fastUserSwitched:       return "someone else is signed in at the console"
        case .settleInAfterBreak:     return "you just got back, settling in"
        case .videoEventInProgress:   return "a video meeting is in progress"
        case .imminentMeeting:        return "a meeting starts in a moment"
        case .deepFocus:              return "you look deep in it, waiting for a seam"
        case .typingBurst:            return "you are mid-burst, waiting for a pause"
        case .terminalCommandRunning: return "a command is still running"
        case .preMeetingWindow:       return "a meeting is close, waiting"
        case .recentAppLaunch:        return "you just switched app, waiting a moment"
        case .inferredMeeting:        return "a conferencing app is up, so you might be in a meeting"
        case .calendarEventInProgress: return "a calendar event is in progress"
        case .liveCaptureUnattributed:
            return "the mic here looks stuck on, so it waits for a pause instead of blocking"
        case .quietHours:             return "quiet hours"
        case .dailyCapReached:        return "today's notification budget is spent, passive only from here"
        case .cycleNotificationCap:   return "this cycle has had its notifications"
        case .minimumSpacing:         return "too soon after the last one"
        case .ignoreBackoff:          return "these have been going unanswered, so each one now gets a single prompt"
        case .userSnoozed:            return "you snoozed it"
        case .userAway:               return "you are away from the keyboard"
        case .breakRunning:           return "a break is running"
        }
    }
}

public struct VerdictLedger: Sendable, Hashable {
    public var debounce: Int
    public var heartbeat: TimeInterval

    private var candidate: GateReason?
    private var candidateCount = 0
    private var written: GateReason?
    private var writtenAtMono: Double?

    public static let defaultHeartbeat: TimeInterval = 10 * 60

    public init(debounce: Int = 2, heartbeat: TimeInterval = VerdictLedger.defaultHeartbeat) {
        self.debounce = max(1, debounce)
        self.heartbeat = heartbeat
    }

    public mutating func observe(
        _ reason: GateReason?,
        holding: GateReason? = nil,
        cycle: CycleID?,
        at now: Date,
        monotonic: Double
    ) -> LoggedEvent? {
        guard let reason else {
            candidate = nil
            candidateCount = 0
            guard let holding, cycle != nil else { return nil }
            guard let last = writtenAtMono else {
                return emit(holding, cycle: cycle, at: now, monotonic: monotonic)
            }
            guard monotonic - last >= heartbeat else { return nil }
            return emit(holding, cycle: cycle, at: now, monotonic: monotonic)
        }
        guard let last = writtenAtMono else {
            return emit(reason, cycle: cycle, at: now, monotonic: monotonic)
        }
        if cycle != nil, monotonic - last >= heartbeat {
            return emit(reason, cycle: cycle, at: now, monotonic: monotonic)
        }
        guard reason != written else {
            candidate = nil
            candidateCount = 0
            return nil
        }
        if reason == candidate {
            candidateCount += 1
        } else {
            candidate = reason
            candidateCount = 1
        }
        guard candidateCount >= debounce else { return nil }
        return emit(reason, cycle: cycle, at: now, monotonic: monotonic)
    }

    public mutating func reset() {
        candidate = nil
        candidateCount = 0
        written = nil
        writtenAtMono = nil
    }

    private mutating func emit(
        _ reason: GateReason, cycle: CycleID?, at now: Date, monotonic: Double
    ) -> LoggedEvent {
        written = reason
        writtenAtMono = monotonic
        candidate = nil
        candidateCount = 0
        return .gate(at: now, reason: reason, cycle: cycle)
    }
}
