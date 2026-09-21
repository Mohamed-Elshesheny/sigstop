import Foundation

/// Why the app was, or was not, allowed to speak. One closed vocabulary.
///
/// `InterruptionVerdict` is the engine's answer and carries three different payload types.
/// This is that answer flattened into a single fixed enum so it can be written to the
/// event log as one short field. Nothing here is free text and nothing here is derived
/// from a window title, a URL or a file path: there are twenty-nine values, they are
/// listed below, and a reader can check that by reading this file (CLAUDE.md §4.4).
///
/// The initialiser is an exhaustive switch, so adding a `HardBlock`, `SoftDeferReason` or
/// `RateLimit` case stops this file compiling until the vocabulary is extended to match.
///
/// Three of the values are **not** verdicts and `init(_:)` never returns them. They name
/// the states that hold a cycle open while the gate is not being asked at all, so that
/// those states can still break the silence on the heartbeat. See `silence`.
public enum GateReason: String, Sendable, Codable, CaseIterable, Hashable {
    /// Nothing is holding a prompt.
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

    // Not verdicts. A cycle is open and the gate was never asked, because the user
    // answered, walked away, or is on the break already.
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

    /// True when the reason is an OS fact rather than something inferred. Only these may
    /// suppress a prompt outright (CLAUDE.md §4.1).
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

    /// The reason in the user's words, for the dropdown and for `--doctor`.
    ///
    /// It lives here rather than in the app layer because the vocabulary is the engine's
    /// and two copies of it would drift. Never a raw enum case: the menu's "why do you
    /// think that?" is the same promise `--doctor` makes.
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
        /// "a single prompt", not "one or two". The ladder cannot reach rung two under
        /// backoff: the cycle closes exhausted on the first ignored tick, so the rung
        /// never leaves `.first`. The old wording matched a ceiling that never ran.
        case .ignoreBackoff:          return "these have been going unanswered, so each one now gets a single prompt"
        case .userSnoozed:            return "you snoozed it"
        case .userAway:               return "you are away from the keyboard"
        case .breakRunning:           return "a break is running"
        }
    }
}

/// Decides when the gate's answer is worth a line in the event log.
///
/// The verdict is recomputed every five seconds and is the same value for minutes at a
/// time. Writing it on every tick would turn a 555 line day into a 17,000 line one and
/// stop `cat` being an audit tool; writing it never, which is what the app did, meant a
/// fourteen minute hold produced 168 identical answers and kept none of them.
///
/// So: on transition, debounced, with a floor.
///
///   * a change is written only once it has survived `debounce` consecutive observations,
///     so a verdict that flickers between two values for one tick writes nothing;
///   * the first answer after a reset is written immediately, because the opening of a
///     cycle is exactly when a reader wants to know;
///   * and while a cycle is open the ledger writes at least once every `heartbeat`, so an
///     open cycle can never be silent for longer than that. A log that goes quiet must
///     mean the app stopped, and nothing else.
///
/// That last rule needs `holding`, and needed it to be true rather than documented. Three
/// states hold a cycle open and ask the gate nothing — snoozed, idle-suspended, and on a
/// break — so `reason` is nil on every one of their ticks and the ledger used to write
/// nothing for the whole thirty minutes a snooze can last. `holding` is the name of that
/// silence, and it is written on the heartbeat only: the transition into those states
/// already has a line of its own (`break_response`, `idle_begin`, `break_begin`) and does
/// not need a second one.
public struct VerdictLedger: Sendable, Hashable {
    public var debounce: Int
    public var heartbeat: TimeInterval

    private var candidate: GateReason?
    private var candidateCount = 0
    private var written: GateReason?
    private var writtenAtMono: Double?

    /// The shipping heartbeat. Named, because `PromptOutlook` bounds its present-tense
    /// claims by it: a gap longer than this with a cycle open is the app not running.
    public static let defaultHeartbeat: TimeInterval = 10 * 60

    public init(debounce: Int = 2, heartbeat: TimeInterval = VerdictLedger.defaultHeartbeat) {
        self.debounce = max(1, debounce)
        self.heartbeat = heartbeat
    }

    /// Feed the ledger one tick's answer.
    ///
    /// `reason` is nil when the engine computed no verdict. `holding` is `EngineState`'s
    /// name for why it computed none while a cycle was open, and is nil when there is no
    /// cycle to keep speaking for.
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

    /// Forget what was written. Called when a cycle closes, so the next cycle states its
    /// opening position rather than inheriting the last one's.
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
