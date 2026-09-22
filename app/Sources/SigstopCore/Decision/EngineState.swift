import Foundation

public enum SignalName: String, Sendable, Codable, CaseIterable, Hashable {
    case sigtstp = "SIGTSTP"
    case sigint = "SIGINT"
    case sigterm = "SIGTERM"
    case sigstop = "SIGSTOP"
}

public extension EscalationLevel {
    var signal: SignalName {
        switch self {
        case .first:    return .sigtstp
        case .second:   return .sigint
        case .third:    return .sigterm
        case .incident: return .sigstop
        }
    }

    var signalName: String { signal.rawValue }

    var isBeyondBackoff: Bool { self > .second }
}

public enum SigstopSignal {
    public static let snooze = "SIGALRM"
    public static let resume = "SIGCONT"
    public static let reloadSettings = "SIGHUP"
    public static let dailySummary = "jobs"
}

public enum PromptChannel: String, Sendable, Codable, Hashable {
    case passiveIndicator
    case notification
    case notificationWithSound
    case panel

    public var interrupts: Bool { self != .passiveIndicator }
}

public enum IndicatorState: String, Sendable, Codable, Hashable {
    case working
    case breakDue
    case held
    case escalating
    case backedOff
    case onBreak
    case idle
    case quiet

    public var isStoodDown: Bool {
        switch self {
        case .idle, .quiet, .backedOff: return true
        case .working, .breakDue, .held, .escalating, .onBreak: return false
        }
    }
}

public struct PromptRequest: Sendable, Codable, Hashable {
    public let cycle: CycleID
    public let level: EscalationLevel
    public let signal: String
    public let channel: PromptChannel
    public let at: Date
    public let continuousWork: TimeInterval
    public let snoozeOffered: [TimeInterval]

    public init(
        cycle: CycleID,
        level: EscalationLevel,
        channel: PromptChannel,
        at: Date,
        continuousWork: TimeInterval,
        snoozeOffered: [TimeInterval]
    ) {
        self.cycle = cycle
        self.level = level
        self.signal = level.signalName
        self.channel = channel
        self.at = at
        self.continuousWork = continuousWork
        self.snoozeOffered = snoozeOffered
    }
}

public enum WithdrawReason: String, Sendable, Codable, Hashable {
    case quietHoursStarted
    case userLeft
    case cycleExpired
    case breakStarted
    case userSkipped
    case dailyCapReached
    case userSnoozed
    case blocked
}

public enum CycleOutcome: String, Sendable, Codable, Hashable {
    case honored
    case skipped
    case ignoredExhausted
    case expired
    case quietSuppressed
    case dailyCapReached

    public var isExcludedFromCompliance: Bool {
        switch self {
        case .expired, .quietSuppressed, .dailyCapReached: return true
        case .honored, .skipped, .ignoredExhausted: return false
        }
    }
}

public enum QuietCause: String, Sendable, Codable, CaseIterable, Hashable {
    case scheduledQuietHours
    case userPaused
    case sustainedFocusMode
    case dailyCapReached

    public var title: String {
        switch self {
        case .scheduledQuietHours: return "quiet hours"
        case .userPaused:          return "paused"
        case .sustainedFocusMode:  return "focus mode"
        case .dailyCapReached:     return "daily cap"
        }
    }

    public var summary: String {
        switch self {
        case .scheduledQuietHours:
            return "you are inside your quiet hours"
        case .userPaused:
            return "you paused it"
        case .sustainedFocusMode:
            return "a Focus mode has been on long enough to read as deliberate"
        case .dailyCapReached:
            return "today's notification budget is spent, so nothing more until 4am"
        }
    }
}

public enum StandDownCause: String, Sendable, Codable, CaseIterable, Hashable {
    case ladderExhausted
    case backedOff
    case skipped
    case cycleExpired

    public var summary: String {
        switch self {
        case .ladderExhausted: return "the last one went unanswered"
        case .backedOff:       return "the last few went unanswered"
        case .skipped:         return "you waved the last one off"
        case .cycleExpired:    return "the last one timed out unseen"
        }
    }
}

public struct WorkingState: Sendable, Codable, Hashable {
    public var armThreshold: TimeInterval
    public var cooldownUntilMono: Double?
    public var lastWorkSeen: TimeInterval
    public var standDown: StandDownCause?

    public init(
        armThreshold: TimeInterval,
        cooldownUntilMono: Double? = nil,
        lastWorkSeen: TimeInterval = 0,
        standDown: StandDownCause? = nil
    ) {
        self.armThreshold = armThreshold
        self.cooldownUntilMono = cooldownUntilMono
        self.lastWorkSeen = lastWorkSeen
        self.standDown = standDown
    }
}

public struct BreakDue: Sendable, Codable, Hashable {
    public var cycle: CycleID
    public var dueSince: Date
    public var seamWaitElapsed: TimeInterval = 0
    public var seamWaitTotal: TimeInterval = 0
    public var totalElapsed: TimeInterval = 0
    public var deepFocusExtensionUsed: Bool = false
    public var promptedAt: Date?
    public var promptedAtMono: Double?
    public var snoozesUsed: Int = 0
    public var snoozeTotal: TimeInterval = 0
    public var notificationsThisCycle: Int = 0
    public var uncorroboratedAudioElapsed: TimeInterval = 0
    public var lastVerdict: InterruptionVerdict?
    public var lastStepMono: Double

    public init(cycle: CycleID, dueSince: Date, lastStepMono: Double) {
        self.cycle = cycle
        self.dueSince = dueSince
        self.lastStepMono = lastStepMono
    }

    public var budget: CycleBudget {
        CycleBudget(
            seamWaitElapsed: seamWaitElapsed,
            seamWaitTotal: seamWaitTotal,
            deepFocusExtensionUsed: deepFocusExtensionUsed,
            notificationsThisCycle: notificationsThisCycle,
            uncorroboratedAudioElapsed: uncorroboratedAudioElapsed
        )
    }
}

public struct BreakActive: Sendable, Codable, Hashable {
    public var cycle: CycleID?
    public var startedAt: Date
    public var plannedEnd: Date
    public var startedMono: Double
    public var plannedDuration: TimeInterval
    public var origin: BreakOrigin

    public init(cycle: CycleID?, startedAt: Date, plannedEnd: Date, startedMono: Double, plannedDuration: TimeInterval, origin: BreakOrigin) {
        self.cycle = cycle
        self.startedAt = startedAt
        self.plannedEnd = plannedEnd
        self.startedMono = startedMono
        self.plannedDuration = plannedDuration
        self.origin = origin
    }
}

public struct SnoozedState: Sendable, Codable, Hashable {
    public var cycle: CycleID
    public var until: Date
    public var untilMono: Double
    public var index: Int
    public var due: BreakDue

    public init(cycle: CycleID, until: Date, untilMono: Double, index: Int, due: BreakDue) {
        self.cycle = cycle
        self.until = until
        self.untilMono = untilMono
        self.index = index
        self.due = due
    }
}

public struct Escalation: Sendable, Codable, Hashable {
    public var cycle: CycleID
    public var dueSince: Date
    public var ignoredAt: Date
    public var level: EscalationLevel
    public var ladderElapsed: TimeInterval = 0
    public var totalElapsed: TimeInterval = 0
    public var notificationsThisCycle: Int
    public var uncorroboratedAudioElapsed: TimeInterval = 0
    public var deliveredLevels: Set<EscalationLevel> = []
    public var finalDeliveredAt: TimeInterval?
    public var withdrawnForBlock: Bool = false
    public var snoozesUsed: Int = 0
    public var snoozeTotal: TimeInterval = 0
    public var lastStepMono: Double

    public init(
        cycle: CycleID,
        dueSince: Date,
        ignoredAt: Date,
        level: EscalationLevel = .first,
        notificationsThisCycle: Int,
        uncorroboratedAudioElapsed: TimeInterval = 0,
        totalElapsed: TimeInterval,
        lastStepMono: Double
    ) {
        self.cycle = cycle
        self.dueSince = dueSince
        self.ignoredAt = ignoredAt
        self.level = level
        self.notificationsThisCycle = notificationsThisCycle
        self.uncorroboratedAudioElapsed = uncorroboratedAudioElapsed
        self.totalElapsed = totalElapsed
        self.lastStepMono = lastStepMono
    }

    public var budget: CycleBudget {
        CycleBudget(
            seamWaitElapsed: .greatestFiniteMagnitude,
            seamWaitTotal: .greatestFiniteMagnitude,
            deepFocusExtensionUsed: true,
            notificationsThisCycle: notificationsThisCycle,
            uncorroboratedAudioElapsed: uncorroboratedAudioElapsed
        )
    }
}

public struct IdleState: Sendable, Codable, Hashable {
    public var since: Date
    public var cause: PauseCause
    public var suspendedCycle: CycleID?
    public var suspendedEscalation: Escalation?
    public var suspendedBreakDue: BreakDue?

    public init(
        since: Date,
        cause: PauseCause,
        suspendedCycle: CycleID? = nil,
        suspendedEscalation: Escalation? = nil,
        suspendedBreakDue: BreakDue? = nil
    ) {
        self.since = since
        self.cause = cause
        self.suspendedCycle = suspendedCycle
        self.suspendedEscalation = suspendedEscalation
        self.suspendedBreakDue = suspendedBreakDue
    }
}

public extension EngineState {
    func retargeted(from old: TimeInterval, to new: TimeInterval) -> EngineState {
        guard case .working(var w) = self, old != new else { return self }
        w.armThreshold = max(0, w.armThreshold + (new - old))
        return .working(w)
    }
}

public struct QuietState: Sendable, Codable, Hashable {
    public var until: Date?
    public var untilMono: Double?
    public var cause: QuietCause

    public init(until: Date? = nil, untilMono: Double? = nil, cause: QuietCause) {
        self.until = until
        self.untilMono = untilMono
        self.cause = cause
    }
}

public enum EngineState: Sendable, Codable, Hashable {
    case working(WorkingState)
    case breakDue(BreakDue)
    case breakActive(BreakActive)
    case snoozed(SnoozedState)
    case ignored(Escalation)
    case idle(IdleState)
    case quiet(QuietState)

    public static func initial(policy: BreakPolicy) -> EngineState {
        .working(WorkingState(armThreshold: policy.targetContinuousWork))
    }

    public var openCycle: CycleID? {
        switch self {
        case .breakDue(let d):    return d.cycle
        case .snoozed(let s):     return s.cycle
        case .ignored(let e):     return e.cycle
        case .breakActive(let b): return b.cycle
        case .idle(let i):        return i.suspendedCycle
        case .working, .quiet:    return nil
        }
    }

    public var silence: GateReason? {
        switch self {
        case .snoozed:            return .userSnoozed
        case .idle(let i):        return i.suspendedCycle == nil ? nil : .userAway
        case .breakActive(let b): return b.cycle == nil ? nil : .breakRunning
        case .working, .breakDue, .ignored, .quiet: return nil
        }
    }

    public var uncorroboratedAudioElapsed: TimeInterval? {
        switch self {
        case .breakDue(let d): return d.uncorroboratedAudioElapsed
        case .ignored(let e):  return e.uncorroboratedAudioElapsed
        case .snoozed(let s):  return s.due.uncorroboratedAudioElapsed
        case .working, .breakActive, .idle, .quiet: return nil
        }
    }

    public var name: String {
        switch self {
        case .working:     return "working"
        case .breakDue:    return "breakDue"
        case .breakActive: return "breakActive"
        case .snoozed:     return "snoozed"
        case .ignored:     return "ignored"
        case .idle:        return "idle"
        case .quiet:       return "quiet"
        }
    }

    public var isBreakDue: Bool { if case .breakDue = self { return true } else { return false } }
    public var isWorking: Bool { if case .working = self { return true } else { return false } }
}

public enum Effect: Sendable, Codable, Hashable {
    case openCycle(CycleID)
    case closeCycle(CycleID, CycleOutcome)
    case deliverPrompt(PromptRequest)
    case withdrawPrompt(cycle: CycleID, reason: WithdrawReason)
    case setIndicator(IndicatorState)
    case beginBreak(cycle: CycleID?, origin: BreakOrigin, plannedEnd: Date)
    case endBreak(
        cycle: CycleID?, origin: BreakOrigin, honored: Bool,
        elapsed: TimeInterval, threshold: TimeInterval
    )
    case scheduleWake(at: Date)
    case cancelScheduledWake
    case recordVerdict(InterruptionVerdict)
    case recordSkip(cycle: CycleID)
    case recordIgnoredPrompt(cycle: CycleID)
    case recordSnooze(cycle: CycleID, duration: TimeInterval)
}

public struct DailyCounters: Sendable, Codable, Hashable {
    public var dayIndex: Int
    public var notificationsDelivered: Int
    public var lastNotificationAt: Date?
    public var consecutiveIgnoredCycles: Int
    public var breakOpportunities: Int
    public var honoredOpportunities: Int
    public var excludedOpportunities: Int
    public var nextCycle: CycleID

    public init(
        dayIndex: Int = 0,
        notificationsDelivered: Int = 0,
        lastNotificationAt: Date? = nil,
        consecutiveIgnoredCycles: Int = 0,
        breakOpportunities: Int = 0,
        honoredOpportunities: Int = 0,
        excludedOpportunities: Int = 0,
        nextCycle: CycleID = .initial
    ) {
        self.dayIndex = dayIndex
        self.notificationsDelivered = notificationsDelivered
        self.lastNotificationAt = lastNotificationAt
        self.consecutiveIgnoredCycles = consecutiveIgnoredCycles
        self.breakOpportunities = breakOpportunities
        self.honoredOpportunities = honoredOpportunities
        self.excludedOpportunities = excludedOpportunities
        self.nextCycle = nextCycle
    }

    public var breakCompliance: Double? {
        let denominator = breakOpportunities - excludedOpportunities
        guard denominator > 0 else { return nil }
        return Double(honoredOpportunities) / Double(denominator)
    }

    public func rolledOver(to newDay: Int) -> DailyCounters {
        DailyCounters(dayIndex: newDay, consecutiveIgnoredCycles: consecutiveIgnoredCycles, nextCycle: nextCycle)
    }

    mutating func takeCycle() -> CycleID {
        let id = nextCycle
        nextCycle = nextCycle.next()
        return id
    }
}

public enum UserAction: Sendable, Codable, Hashable {
    case acceptBreak
    case snooze
    case skip
    case startBreakNow
    case endBreak
    case pauseApp(TimeInterval)
    case resumeApp
}
