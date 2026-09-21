import Foundation

// MARK: - The signal vocabulary

/// The escalation ladder, in the vocabulary the product is named after.
///
/// `SIGKILL` appears nowhere: it is unrecoverable and destroys exactly the thing the name
/// promises to preserve. `SIGHUP` is never a rung either, its default disposition is
/// *terminate*, so an L1 labelled SIGHUP would quietly mean "die". It reloads settings.
/// The four rungs, as the four signals the ladder is named after.
///
/// A closed enum rather than four strings, because it is written to the event log and
/// `LoggedEvent` claims, in its own doc comment, that no field of it can hold free text.
/// A `String?` there defeated that claim whatever anybody happened to put in it. The raw
/// values are the same four words that were already on disk, so old logs still parse.
public enum SignalName: String, Sendable, Codable, CaseIterable, Hashable {
    /// Catchable. You are allowed to ignore it.
    case sigtstp = "SIGTSTP"
    /// Catchable, but ignoring it is rude.
    case sigint = "SIGINT"
    /// Catchable. This is your warning.
    case sigterm = "SIGTERM"
    /// Cannot be caught, blocked or ignored.
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

    /// True when this rung may not be reached under the ignore backoff (§11.5).
    var isBeyondBackoff: Bool { self > .second }
}

public enum SigstopSignal {
    /// Snooze. Wake me later.
    public static let snooze = "SIGALRM"
    /// Resume from a break. The resume button is never labelled "Dismiss".
    public static let resume = "SIGCONT"
    /// Re-read the config. Never an escalation rung.
    public static let reloadSettings = "SIGHUP"
    /// Everything you had suspended today.
    public static let dailySummary = "jobs"
}

// MARK: - Channels and presentation

/// Nothing in the app is ever modal, ever blocks input, ever takes keyboard focus, or ever
/// covers the whole screen.
public enum PromptChannel: String, Sendable, Codable, Hashable {
    /// The menu bar mark: ambient, always allowed, including quiet hours, DND, daily cap
    /// and hard blocks.
    ///
    /// No escalation rung selects this. It is the channel the mark itself is on, which is
    /// why it is always live, and for a while `channelFor` handed it to rung one, which
    /// would have meant "deliver a prompt that cannot interrupt" had anything called it.
    case passiveIndicator
    case notification
    /// Escalation level 3 only, and never twice in a cycle.
    case notificationWithSound
    /// Escalation level 4 only. Dismissible, non-modal, never key-window-stealing.
    case panel

    public var interrupts: Bool { self != .passiveIndicator }
}

public enum IndicatorState: String, Sendable, Codable, Hashable {
    case working
    case breakDue
    /// A break is due and the app is deliberately holding it: a live microphone or
    /// camera, or the call latch. Distinct from `.escalating` on purpose, because an
    /// escalating indicator during a call is both wrong and alarming.
    case held
    case escalating
    /// A break is owed and the app has decided not to ask for a while.
    ///
    /// The cooldown after an unanswered opportunity used to draw as `.working` with the
    /// clock still climbing, and the moment before it as `.escalating` while the ladder
    /// had already been switched off. Both are positive claims that the opposite of the
    /// truth is happening, and both left a user who never opens the panel with nothing
    /// to distinguish "counting up towards a break" from "deliberately quiet".
    case backedOff
    case onBreak
    case idle
    case quiet

    /// True when the app has no intention of asking. This is what the menu bar mark's
    /// opacity means, and the only thing it means.
    public var isStoodDown: Bool {
        switch self {
        case .idle, .quiet, .backedOff: return true
        case .working, .breakDue, .held, .escalating, .onBreak: return false
        }
    }
}

/// What the app layer should show. The engine never presents anything itself.
public struct PromptRequest: Sendable, Codable, Hashable {
    public let cycle: CycleID
    public let level: EscalationLevel
    /// The signal this rung is named after, L1 SIGTSTP … L4 SIGSTOP.
    public let signal: String
    public let channel: PromptChannel
    public let at: Date
    /// Continuous active work at the moment of delivery, the only number the copy may use.
    public let continuousWork: TimeInterval
    /// Empty means the prompt must not offer snooze any more.
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

/// Why a prompt that was on screen is being taken down.
///
/// `userSkipped` exists because the skip path used to name `breakStarted`, on a path
/// where no break starts at all. A withdraw reason is the app's own account of what it
/// just did; one that names the wrong event is worse than none.
public enum WithdrawReason: String, Sendable, Codable, Hashable {
    case quietHoursStarted
    case userLeft
    case cycleExpired
    case breakStarted
    case userSkipped
    case dailyCapReached
    case userSnoozed
    /// A hard block began while the prompt was on screen. Without this a notification or
    /// panel delivered one second before a call sat there for the whole call.
    case blocked
}

/// How a cycle ended. Only `honored` counts in the numerator; `expired`, `quietSuppressed`
/// and `dailyCapReached` are *excluded* from compliance entirely, you cannot hold a user
/// to a prompt that was never delivered.
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

    /// The state as the menu bar names it, the way `ps` names a state.
    ///
    /// The panel used to draw every one of these as the literal words "quiet hours".
    /// Three of the four are not quiet hours, so the app could go silent for the rest of
    /// the day and explain it with a lie to a user who has quiet hours switched off. The
    /// words live in `Core` because `SigstopApp` has no test target and a vocabulary kept
    /// there is unchecked.
    ///
    /// `dailyCapReached` used to be described here as "terminal until the day boundary",
    /// which was not what the engine did. Three paths in `step` leave quiet before its own
    /// switch is reached: a user action, a relaunch (engine state is not persisted), and a
    /// qualifying break. What is true, and now enforced in `handleWorking`, is narrower and
    /// worth stating exactly: the *state* is re-entered rather than latched, and a break
    /// still resets the session clock and the ignore counter because those are real, but a
    /// break cannot un-spend the budget, so no prompt is delivered until the day rolls
    /// over. It is the silence that is terminal, not the state.
    public var title: String {
        switch self {
        case .scheduledQuietHours: return "quiet hours"
        case .userPaused:          return "paused"
        case .sustainedFocusMode:  return "focus mode"
        case .dailyCapReached:     return "daily cap"
        }
    }

    /// Why nothing is coming, in the user's words, for the one muted line in the menu.
    public var summary: String {
        switch self {
        case .scheduledQuietHours:
            return "you are inside your quiet hours"
        case .userPaused:
            return "you paused it"
        case .sustainedFocusMode:
            return "a Focus mode has been on long enough to read as deliberate"
        case .dailyCapReached:
            /// Says *when*. "until the day rolls over" reads as midnight to everybody,
            /// and `BreakPolicy.dayBoundaryHour` is 4, so the honest gap is up to four
            /// hours longer than the sentence implied.
            return "today's notification budget is spent, so nothing more until 4am"
        }
    }
}

// MARK: - Engine state

/// Why the engine is quiet while nothing at all is blocking it.
///
/// One enum rather than an inference from `armThreshold > target`, which is what the
/// panel used to do: a raised threshold has two causes and the panel told every user of
/// the second one that they had waved a prompt off, when the opportunity had expired
/// unseen and they had waved off nothing. The words live in `Core` for the reason
/// `QuietCause` already gives: `SigstopApp` has no test target.
public enum StandDownCause: String, Sendable, Codable, CaseIterable, Hashable {
    /// The last opportunity ran its escalations out unanswered.
    case ladderExhausted
    /// The same, often enough in a row that each opportunity now gets one prompt.
    case backedOff
    /// The user waved the last one off.
    case skipped
    /// The last one went stale without ever being answered.
    case cycleExpired

    /// The middle of the sentence, in the user's words. The line that carries it adds
    /// the claim and the deadline, because only the caller knows those.
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
    /// Continuous active work required to open the next cycle. Above `targetContinuousWork`
    /// after a skip (+20 min) or an expired cycle (+10 min), so the user is not re-prompted
    /// the instant they leave the meeting.
    public var armThreshold: TimeInterval
    /// Monotonic deadline before which no new cycle may open (25 min after an exhausted ladder).
    public var cooldownUntilMono: Double?
    /// Last continuous-work value seen, used to notice a clock reset and re-arm at the target.
    public var lastWorkSeen: TimeInterval
    /// Why this working state is quieter than an ordinary one, when it is.
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
    /// Accrues ONLY while not hard-blocked. A two-hour meeting costs the cycle nothing.
    /// Reset to zero when a snooze expires, so the deferral machinery gets a fresh window.
    public var seamWaitElapsed: TimeInterval = 0
    /// Seam-waiting across the whole cycle. A snooze reopens the window, not the budget.
    public var seamWaitTotal: TimeInterval = 0
    /// Wall clock since `dueSince`, including hard-blocked time, this is what the stale
    /// ceiling measures, which is why §7.4 can say the ceiling is reached under sustained
    /// hard blocks at all.
    public var totalElapsed: TimeInterval = 0
    public var deepFocusExtensionUsed: Bool = false
    public var promptedAt: Date?
    public var promptedAtMono: Double?
    public var snoozesUsed: Int = 0
    public var snoozeTotal: TimeInterval = 0
    public var notificationsThisCycle: Int = 0
    /// Continuous seconds this opportunity has been held by a running input device with
    /// nothing else corroborating a call. See `BreakPolicy.uncorroboratedAudioCeiling`.
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

/// SIGALRM. The work clock keeps running: snoozing defers the question, it does not buy credit.
public struct SnoozedState: Sendable, Codable, Hashable {
    public var cycle: CycleID
    public var until: Date
    public var untilMono: Double
    public var index: Int
    /// The cycle is carried intact so `totalElapsed` continues from the original `dueSince`
    /// and snoozing cannot be used to outrun the stale ceiling.
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
    /// t0 for the ladder: the moment the prompt was classified ignored.
    public var ignoredAt: Date
    public var level: EscalationLevel
    /// Accrues only while not hard-blocked: a hard block postpones a rung, it never stacks two.
    public var ladderElapsed: TimeInterval = 0
    public var totalElapsed: TimeInterval = 0
    public var notificationsThisCycle: Int
    /// As on `BreakDue`: this opportunity's continuous uncorroborated input-device hold.
    public var uncorroboratedAudioElapsed: TimeInterval = 0
    public var deliveredLevels: Set<EscalationLevel> = []
    /// `ladderElapsed` at which level 4 was delivered; the ladder ends `promptTimeout` later.
    public var finalDeliveredAt: TimeInterval?
    /// Set once the outstanding prompt has been pulled for a hard block, so the withdraw
    /// fires on the transition rather than on every blocked tick.
    public var withdrawnForBlock: Bool = false
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
    /// The cycle that was open when the user walked away, if any. Walking away on your own
    /// is the success case, so it closes honored once the gap qualifies.
    public var suspendedCycle: CycleID?
    /// The ladder that was climbing when the user stepped away, parked rather than thrown
    /// away.
    ///
    /// The id on its own was not enough, and that was the whole of the bug this field
    /// exists to fix. A gap longer than `microIdleGrace` but shorter than
    /// `qualifyingBreak` is too long to ignore and too short to be a break: it suspended
    /// the cycle, and the resume rebuilt a virgin `BreakDue`, so `level`,
    /// `deliveredLevels`, `ladderElapsed` and `notificationsThisCycle` were all lost and
    /// the next prompt came back at rung one. A user who glanced at their phone for two
    /// minutes mid-escalation got SIGTSTP again instead of SIGINT, and paid another unit
    /// of the day's notification budget for it.
    ///
    /// Only a suspension out of `.ignored` sets this. A suspension out of `.breakDue` has
    /// no ladder to keep and still restores through `suspendedCycle`.
    public var suspendedEscalation: Escalation?
    /// The same, for a cycle suspended before it was ever ignored. Kept rather than
    /// rebuilt so `dueSince` and `totalElapsed` survive, which is what the stale ceiling
    /// measures: rebuilding restarted it and an opportunity could stay open forever.
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

/// `.idle` and `.quiet` are engine states, not session states: the session model keeps
/// measuring throughout. These two only describe what the engine is allowed to *say*.
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

    /// Why a state that holds a cycle open is not producing a verdict.
    ///
    /// `breakDue` and `ignored` ask the gate on every tick, so the ledger always has an
    /// answer to write for them. These three hold `openCycle` and ask nothing: a snooze
    /// defers the question, an idle suspension parks it, and during a break it has already
    /// been answered. Without a name for that, the ledger had nothing to write and an open
    /// cycle could be silent for the whole length of a thirty minute snooze — while the
    /// docs said a quiet log means the app stopped, and nothing else.
    ///
    /// Nil for every state that either has no cycle or has a verdict of its own.
    public var silence: GateReason? {
        switch self {
        case .snoozed:            return .userSnoozed
        case .idle(let i):        return i.suspendedCycle == nil ? nil : .userAway
        case .breakActive(let b): return b.cycle == nil ? nil : .breakRunning
        case .working, .breakDue, .ignored, .quiet: return nil
        }
    }

    /// How long the open opportunity has been held by an uncorroborated input device.
    /// Nil when there is nothing open to be held.
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

// MARK: - Effects

/// What the app layer should do. The engine returns these; it never performs them. That is
/// what makes the whole state machine exhaustively testable without a window server.
public enum Effect: Sendable, Codable, Hashable {
    case openCycle(CycleID)
    case closeCycle(CycleID, CycleOutcome)
    case deliverPrompt(PromptRequest)
    case withdrawPrompt(cycle: CycleID, reason: WithdrawReason)
    case setIndicator(IndicatorState)
    /// The app begins the break UI; the tracker is told separately to pause the clock.
    case beginBreak(cycle: CycleID?, origin: BreakOrigin, plannedEnd: Date)
    /// `honored` false means the break was abandoned under the qualifying threshold: no
    /// reset, no break recorded.
    ///
    /// `elapsed` is measured on the monotonic clock by the engine, so the log carries the
    /// duration that was actually judged rather than a wall-clock difference the app
    /// recomputes from a remembered start.
    /// `threshold` is the number `honored` was decided against, carried so the log line
    /// can be re-judged without knowing what the settings were at the time.
    case endBreak(
        cycle: CycleID?, origin: BreakOrigin, honored: Bool,
        elapsed: TimeInterval, threshold: TimeInterval
    )
    /// SIGALRM.
    case scheduleWake(at: Date)
    case cancelScheduledWake
    case recordVerdict(InterruptionVerdict)
    /// Every effect that records a decision names the cycle it belongs to.
    ///
    /// These three used to carry nothing, which forced the app layer to reconstruct the
    /// id from its own mutable side state. `.closeCycle` clears that state, so a skip,
    /// whose effect list is withdraw, close, record, could never be written down: the
    /// guard that looked up the id ran after the value it needed had been cleared. Snooze
    /// and ignore survived only because no `.closeCycle` happens to precede them. The
    /// payload is what makes that an impossible bug rather than an ordering convention.
    case recordSkip(cycle: CycleID)
    case recordIgnoredPrompt(cycle: CycleID)
    case recordSnooze(cycle: CycleID, duration: TimeInterval)
}

// MARK: - Daily counters

/// Per-day budgets and rollup inputs. Threaded through the engine rather than stored in it,
/// so `step` stays a pure function.
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

    /// nil, never 0 or 1, when there is nothing to measure.
    public var breakCompliance: Double? {
        let denominator = breakOpportunities - excludedOpportunities
        guard denominator > 0 else { return nil }
        return Double(honoredOpportunities) / Double(denominator)
    }

    /// Cycle ids keep climbing across the day boundary; everything else resets.
    public func rolledOver(to newDay: Int) -> DailyCounters {
        DailyCounters(dayIndex: newDay, consecutiveIgnoredCycles: consecutiveIgnoredCycles, nextCycle: nextCycle)
    }

    mutating func takeCycle() -> CycleID {
        let id = nextCycle
        nextCycle = nextCycle.next()
        return id
    }
}

// MARK: - User actions

/// What the developer did to a prompt. Actions are events, not state.
public enum UserAction: Sendable, Codable, Hashable {
    case acceptBreak
    case snooze
    case skip
    case startBreakNow
    case endBreak
    /// Duration in seconds; measurement continues throughout.
    case pauseApp(TimeInterval)
    case resumeApp
}
