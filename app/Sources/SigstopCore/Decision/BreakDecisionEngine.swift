import Foundation

// MARK: - Engine input

/// Everything the engine is allowed to know, at one instant.
///
/// The engine reads nothing else: no clock, no defaults, no singletons. `now` and
/// `monotonic` both come from the caller's `TimeSource`, `now` for anything a human will
/// see or that a calendar must interpret, `monotonic` for every duration, because the wall
/// clock steps and the monotonic clock does not.
public struct EngineInput: Sendable {
    public var now: Date
    public var monotonic: Double
    public var context: DeveloperContext
    /// Facts about the machine. The only things allowed to hard-block.
    public var signals: SystemSignals
    public var settings: SigstopSettings
    /// The calendar used for quiet hours and the day boundary. Injected so tests are not
    /// at the mercy of the machine's time zone.
    public var calendarSystem: Calendar
    /// Optional EventKit adjacency; nil means the app knows nothing about the day's events.
    public var calendar: CalendarSignals?
    public var seams: [Seam]
    public var keystrokeRate: Double
    public var terminalCommandRunning: Bool
    public var secondsSinceFrontmostChange: TimeInterval
    public var focusScore: Double
    public var lastBreakEndedAt: Date?
    public var day: DailyCounters
    /// What the developer just did, if anything. Actions are events, not state.
    public var userAction: UserAction?
    /// What the session tracker reported for this tick.
    public var sessionEvents: [SessionEvent]

    public init(
        now: Date,
        monotonic: Double,
        context: DeveloperContext,
        signals: SystemSignals = .none,
        settings: SigstopSettings = .default,
        calendarSystem: Calendar = .current,
        calendar: CalendarSignals? = nil,
        seams: [Seam] = [],
        keystrokeRate: Double = 0,
        terminalCommandRunning: Bool = false,
        secondsSinceFrontmostChange: TimeInterval = .greatestFiniteMagnitude,
        focusScore: Double = 0,
        lastBreakEndedAt: Date? = nil,
        day: DailyCounters = DailyCounters(),
        userAction: UserAction? = nil,
        sessionEvents: [SessionEvent] = []
    ) {
        self.now = now
        self.monotonic = monotonic
        self.context = context
        self.signals = signals
        self.settings = settings
        self.calendarSystem = calendarSystem
        self.calendar = calendar
        self.seams = seams
        self.keystrokeRate = keystrokeRate
        self.terminalCommandRunning = terminalCommandRunning
        self.secondsSinceFrontmostChange = secondsSinceFrontmostChange
        self.focusScore = focusScore
        self.lastBreakEndedAt = lastBreakEndedAt
        self.day = day
        self.userAction = userAction
        self.sessionEvents = sessionEvents
    }

    /// The tracker recorded a real break: the user took one without being asked, or the
    /// accepted one ran long enough to count.
    public var qualifyingBreakObserved: Bool {
        sessionEvents.contains { if case .breakRecorded = $0 { return true } else { return false } }
    }
}

public struct EngineOutcome: Sendable {
    public let state: EngineState
    public let effects: [Effect]
    public let day: DailyCounters
    /// The verdict computed this step, when one was computed at all.
    public let verdict: InterruptionVerdict?

    public init(state: EngineState, effects: [Effect], day: DailyCounters, verdict: InterruptionVerdict? = nil) {
        self.state = state
        self.effects = effects
        self.day = day
        self.verdict = verdict
    }

    public var prompts: [PromptRequest] {
        effects.compactMap { if case .deliverPrompt(let p) = $0 { return p } else { return nil } }
    }
}

// MARK: - The engine

/// `(state, context, settings, time) -> (newState, [Effect])`, and nothing else.
///
/// The engine performs no side effects: it returns them. That is not tidiness, it is what
/// makes every row of the transition table in docs/BREAK-DECISION.md §5.1 a unit test that
/// runs in microseconds with no window server, which matters here because there is no Xcode
/// and therefore no UI test harness.
public struct BreakDecisionEngine: Sendable {

    public let policy: BreakPolicy
    public let interruption: InterruptionPolicy

    public init(policy: BreakPolicy = .default) {
        self.policy = policy
        self.interruption = InterruptionPolicy(policy: policy)
    }

    public init(settings: SigstopSettings) {
        self.init(policy: BreakPolicy(settings: settings))
    }

    public func step(_ state: EngineState, _ input: EngineInput) -> EngineOutcome {
        var day = input.day
        var effects: [Effect] = []
        var verdict: InterruptionVerdict?
        var state = state

        let today = LocalDay.index(of: input.now, calendar: input.calendarSystem, boundaryHour: policy.dayBoundaryHour)
        if day.dayIndex != today {
            let wasCapped: Bool = {
                if case .quiet(let q) = state, q.cause == .dailyCapReached { return true }
                return false
            }()
            day = day.rolledOver(to: today)
            if wasCapped {
                state = .working(WorkingState(armThreshold: policy.targetContinuousWork, lastWorkSeen: input.context.continuousWork))
            }
        }

        if let action = input.userAction {
            state = handle(action, state: state, input: input, day: &day, effects: &effects)
            return EngineOutcome(state: state, effects: effects, day: day, verdict: nil)
        }

        if input.qualifyingBreakObserved, !isBreakActive(state) {
            if let cycle = state.openCycle {
                effects.append(.withdrawPrompt(cycle: cycle, reason: .userLeft))
                effects.append(.closeCycle(cycle, .honored))
                day.honoredOpportunities += 1
            }
            day.consecutiveIgnoredCycles = 0
            effects.append(.setIndicator(.working))
            let working = WorkingState(armThreshold: policy.targetContinuousWork, lastWorkSeen: input.context.continuousWork)
            return EngineOutcome(state: .working(working), effects: effects, day: day, verdict: nil)
        }

        let inQuietWindow = input.settings.quietHours.contains(input.now, calendar: input.calendarSystem)
        if inQuietWindow, !isBreakActive(state), !state.isWorking {
            if case .quiet = state {
                effects.append(.setIndicator(.quiet))
                return EngineOutcome(state: state, effects: effects, day: day, verdict: nil)
            }
            if let cycle = state.openCycle {
                effects.append(.withdrawPrompt(cycle: cycle, reason: .quietHoursStarted))
                effects.append(.closeCycle(cycle, .quietSuppressed))
                day.excludedOpportunities += 1
            }
            effects.append(.setIndicator(.quiet))
            return EngineOutcome(state: .quiet(QuietState(cause: .scheduledQuietHours)), effects: effects, day: day, verdict: nil)
        }

        /// True when this tick is the one that ends a break.
        ///
        /// `input` was built before the break ended, so `input.context.continuousWork`
        /// still holds the pre-break figure: the app resets the session clock when it
        /// executes the `.endBreak` effect, which happens after this function returns.
        /// Evaluating `handleWorking` with that stale figure opened a new cycle in the same
        /// second the break finished, which is what a user saw as a second break arriving
        /// the instant the first one ended.
        var breakEndedThisTick = false

        switch state {
        case .breakActive(let b):
            let before = state
            state = handleBreakActive(b, input: input, day: &day, effects: &effects)
            if case .breakActive = before, case .working = state { breakEndedThisTick = true }
        case .idle(let i):
            state = handleIdle(i, input: input, day: &day, effects: &effects)
        case .quiet(let q):
            state = handleQuiet(q, input: input, inQuietWindow: inQuietWindow, day: &day, effects: &effects)
        case .snoozed(let s):
            state = handleSnoozed(s, input: input, day: &day, effects: &effects)
        case .working, .breakDue, .ignored:
            break
        }

        if case .working(let w) = state, !breakEndedThisTick {
            state = handleWorking(w, input: input, day: &day, effects: &effects)
        }
        if case .breakDue(let d) = state {
            let (next, v) = handleBreakDue(d, input: input, day: &day, effects: &effects)
            state = next
            verdict = v
        }
        if case .ignored(let e) = state {
            let (next, v) = handleIgnored(e, input: input, day: &day, effects: &effects)
            state = next
            verdict = verdict ?? v
        }

        return EngineOutcome(state: state, effects: effects, day: day, verdict: verdict)
    }

    // MARK: - working

    private func handleWorking(
        _ working: WorkingState,
        input: EngineInput,
        day: inout DailyCounters,
        effects: inout [Effect]
    ) -> EngineState {
        var w = working
        if input.context.continuousWork < w.lastWorkSeen {
            w.armThreshold = policy.targetContinuousWork
            w.standDown = nil
        }
        w.lastWorkSeen = input.context.continuousWork

        if input.context.idleSeconds >= policy.microIdleGrace || input.signals.screenLocked {
            effects.append(.setIndicator(.idle))
            let cause: PauseCause = input.signals.screenLocked ? .screenLocked : .microIdleExceeded
            return .idle(IdleState(since: input.now.addingTimeInterval(-input.context.idleSeconds), cause: cause))
        }

        if let cooldown = w.cooldownUntilMono {
            if input.monotonic < cooldown {
                /// A break is owed and the app has decided not to ask for it yet. Saying
                /// `.working` here drew a full bright mark and a clock climbing against a
                /// threshold nothing was waiting for.
                effects.append(.setIndicator(.backedOff))
                return .working(w)
            }
            w.cooldownUntilMono = nil
            w.standDown = nil
        }

        let due = input.context.continuousWork >= w.armThreshold
        let early = interruption.opportunisticEarlyPrompt(input) && w.armThreshold <= policy.targetContinuousWork
        guard due || early else {
            effects.append(.setIndicator(.working))
            return .working(w)
        }

        /// An opportunity the day cannot pay for is not an opportunity.
        ///
        /// The budget was only ever discovered one tick later, inside `handleBreakDue`,
        /// which meant every re-arm after the cap took a cycle id, logged a `break_open`,
        /// hit the rate limit and logged a `cycle_close` in the same second. The owner's
        /// log has two of those (cycles 15 and 16) and `nextCycle` had reached 17 for 14
        /// real opportunities. They also reach the rollup, where the denominator counts
        /// opens, so a break nobody was offered was being scored.
        if input.day.notificationsDelivered >= policy.dailyNotificationCap {
            effects.append(.setIndicator(.quiet))
            return .quiet(QuietState(cause: .dailyCapReached))
        }

        let cycle = day.takeCycle()
        day.breakOpportunities += 1
        effects.append(.openCycle(cycle))
        effects.append(.setIndicator(.breakDue))
        return .breakDue(BreakDue(cycle: cycle, dueSince: input.now, lastStepMono: input.monotonic))
    }

    // MARK: - breakDue

    private func handleBreakDue(
        _ due: BreakDue,
        input: EngineInput,
        day: inout DailyCounters,
        effects: inout [Effect]
    ) -> (EngineState, InterruptionVerdict?) {
        var d = due
        let dt = max(0, input.monotonic - d.lastStepMono)
        d.lastStepMono = input.monotonic
        d.totalElapsed += dt

        if input.context.idleSeconds >= policy.microIdleGrace {
            if d.promptedAt != nil { effects.append(.withdrawPrompt(cycle: d.cycle, reason: .userLeft)) }
            effects.append(.setIndicator(.idle))
            return (.idle(IdleState(
                since: input.now.addingTimeInterval(-input.context.idleSeconds),
                cause: .microIdleExceeded,
                suspendedCycle: d.cycle,
                suspendedBreakDue: d
            )), nil)
        }

        if d.totalElapsed >= policy.staleBreakCeiling {
            if d.promptedAt != nil { effects.append(.withdrawPrompt(cycle: d.cycle, reason: .cycleExpired)) }
            effects.append(.closeCycle(d.cycle, .expired))
            day.excludedOpportunities += 1
            effects.append(.setIndicator(.working))
            return (.working(WorkingState(
                armThreshold: input.context.continuousWork + policy.rearmAfterStale,
                lastWorkSeen: input.context.continuousWork,
                standDown: .cycleExpired
            )), nil)
        }

        d.uncorroboratedAudioElapsed = advanceAudioHold(d.uncorroboratedAudioElapsed, by: dt, input: input)
        let verdict = interruption.verdict(input, budget: d.budget)
        d.lastVerdict = verdict
        effects.append(.recordVerdict(verdict))

        if let promptedMono = d.promptedAtMono,
           !verdict.isHardBlocked,
           input.monotonic - promptedMono >= policy.promptTimeout {
            effects.append(.recordIgnoredPrompt(cycle: d.cycle))
            effects.append(.setIndicator(.escalating))
            return (.ignored(Escalation(
                cycle: d.cycle,
                dueSince: d.dueSince,
                ignoredAt: input.now,
                notificationsThisCycle: d.notificationsThisCycle,
                uncorroboratedAudioElapsed: d.uncorroboratedAudioElapsed,
                totalElapsed: d.totalElapsed,
                lastStepMono: input.monotonic
            )), verdict)
        }

        switch verdict {
        case .hardBlocked(let block):
            /// A prompt that was already on screen when the block began is pulled, and
            /// the prompt stamp is cleared with it. Both halves matter. Leaving the panel
            /// up means the joke sits on a screen share for the whole call; leaving
            /// `promptedAtMono` set means the 90-second prompt timeout has already
            /// elapsed the instant the block lifts, so the user is charged an ignored
            /// prompt for a meeting they were never allowed to answer during, and two of
            /// those silently truncate the ladder.
            if d.promptedAt != nil {
                effects.append(.withdrawPrompt(cycle: d.cycle, reason: .blocked))
                d.promptedAt = nil
                d.promptedAtMono = nil
            }
            effects.append(.setIndicator(Self.indicator(for: block)))
            return (.breakDue(d), verdict)

        case .rateLimited(let limit):
            switch limit {
            /// Both of these close a cycle, so both have to withdraw a prompt that is
            /// still on the screen, the way every other exit from `breakDue` does: idle,
            /// the stale ceiling and a hard block all check `promptedAt` and withdraw
            /// first. These two did not, which left a panel up for a cycle the engine had
            /// already closed, answerable to nothing. `WithdrawReason.dailyCapReached` was
            /// declared for exactly this and had never been constructed anywhere.
            case .quietHours:
                if d.promptedAt != nil {
                    effects.append(.withdrawPrompt(cycle: d.cycle, reason: .quietHoursStarted))
                }
                effects.append(.closeCycle(d.cycle, .quietSuppressed))
                day.excludedOpportunities += 1
                effects.append(.setIndicator(.quiet))
                return (.quiet(QuietState(cause: .scheduledQuietHours)), verdict)
            case .dailyCapReached:
                if d.promptedAt != nil {
                    effects.append(.withdrawPrompt(cycle: d.cycle, reason: .dailyCapReached))
                }
                effects.append(.closeCycle(d.cycle, .dailyCapReached))
                day.excludedOpportunities += 1
                effects.append(.setIndicator(.quiet))
                return (.quiet(QuietState(cause: .dailyCapReached)), verdict)
            case .cycleNotificationCap, .minimumSpacing, .ignoreBackoff:
                effects.append(.setIndicator(.breakDue))
                return (.breakDue(d), verdict)
            }

        case .softDeferred:
            d.seamWaitElapsed += dt
            d.seamWaitTotal += dt
            if interruption.isDeepFocus(input) { d.deepFocusExtensionUsed = true }
            effects.append(.setIndicator(.breakDue))
            return (.breakDue(d), verdict)

        case .deliver:
            if d.promptedAt == nil {
                let prompt = PromptRequest(
                    cycle: d.cycle,
                    level: .first,
                    /// `channelFor`, not a hardcoded `.notification`, so one function
                    /// decides the channel for all four rungs. Hardcoding it here is how
                    /// the `.first` arm of `channelFor` became unreachable and how three
                    /// comments came to describe a passive rung the engine never sends.
                    channel: channelFor(level: .first, signals: input.signals),
                    at: input.now,
                    continuousWork: input.context.continuousWork,
                    snoozeOffered: interruption.offeredSnoozes(used: d.snoozesUsed, total: d.snoozeTotal)
                )
                effects.append(.deliverPrompt(prompt))
                effects.append(.setIndicator(.breakDue))
                d.promptedAt = input.now
                d.promptedAtMono = input.monotonic
                d.notificationsThisCycle += 1
                day.notificationsDelivered += 1
                day.lastNotificationAt = input.now
                return (.breakDue(d), verdict)
            }
            effects.append(.setIndicator(.breakDue))
            return (.breakDue(d), verdict)
        }
    }

    // MARK: - ignored / the ladder

    /// The escalation ladder, and the ceiling that bounds it.
    ///
    /// `handleBreakDue` has always checked `staleBreakCeiling`; this did not, and because
    /// `ladderElapsed` only accrues below the hard-block early return, a sustained block
    /// froze the ladder so `exhausted` could never become true. An `.ignored` cycle under
    /// a long meeting was therefore unbounded: it could not escalate, could not exhaust,
    /// and could only ever leave via idle. `totalElapsed` accrues regardless of blocking,
    /// which is exactly why it, and not `ladderElapsed`, is what the ceiling measures.
    private func handleIgnored(
        _ escalation: Escalation,
        input: EngineInput,
        day: inout DailyCounters,
        effects: inout [Effect]
    ) -> (EngineState, InterruptionVerdict?) {
        var e = escalation
        let dt = max(0, input.monotonic - e.lastStepMono)
        e.lastStepMono = input.monotonic
        e.totalElapsed += dt

        if input.context.idleSeconds >= policy.microIdleGrace {
            effects.append(.withdrawPrompt(cycle: e.cycle, reason: .userLeft))
            effects.append(.setIndicator(.idle))
            return (.idle(IdleState(
                since: input.now.addingTimeInterval(-input.context.idleSeconds),
                cause: .microIdleExceeded,
                suspendedCycle: e.cycle,
                suspendedEscalation: e
            )), nil)
        }

        if e.totalElapsed >= policy.staleBreakCeiling {
            effects.append(.withdrawPrompt(cycle: e.cycle, reason: .cycleExpired))
            effects.append(.closeCycle(e.cycle, .expired))
            day.excludedOpportunities += 1
            effects.append(.setIndicator(.working))
            return (.working(WorkingState(
                armThreshold: input.context.continuousWork + policy.rearmAfterStale,
                lastWorkSeen: input.context.continuousWork,
                standDown: .cycleExpired
            )), nil)
        }

        e.uncorroboratedAudioElapsed = advanceAudioHold(e.uncorroboratedAudioElapsed, by: dt, input: input)
        let verdict = interruption.verdict(input, budget: e.budget)
        effects.append(.recordVerdict(verdict))

        if case .hardBlocked(let block) = verdict {
            if !e.withdrawnForBlock {
                e.withdrawnForBlock = true
                effects.append(.withdrawPrompt(cycle: e.cycle, reason: .blocked))
            }
            effects.append(.setIndicator(Self.indicator(for: block)))
            return (.ignored(e), verdict)
        }
        e.withdrawnForBlock = false
        e.ladderElapsed += dt

        /// `ladderIsSpent` is the single statement of the backoff rule.
        ///
        /// There used to be a second one here, capping the rung at `.second` under backoff.
        /// It never ran: under backoff `ladderIsSpent` is already true on the first
        /// `.ignored` tick, because `consecutiveIgnoredCycles >= 2` and
        /// `notificationsThisCycle >= 1` both hold on entry, so the cycle is closed
        /// exhausted before `ladderElapsed` can reach `ladderLevel2` at all. The rung never
        /// left `.first`, which means the truncation the gate summary and the docs both
        /// describe as "levels 1-2" is really "level 1". Two statements of one rule drift,
        /// and this pair already had.
        var target = ladderLevel(for: e, input: input)
        if target > e.level { e.level = target }

        if e.level != .first, !e.deliveredLevels.contains(e.level), verdict.isDeliverable {
            let channel = channelFor(level: e.level, signals: input.signals)
            if channel.interrupts {
                let prompt = PromptRequest(
                    cycle: e.cycle,
                    level: e.level,
                    channel: channel,
                    at: input.now,
                    continuousWork: input.context.continuousWork,
                    snoozeOffered: []
                )
                effects.append(.deliverPrompt(prompt))
                e.deliveredLevels.insert(e.level)
                e.notificationsThisCycle += 1
                day.notificationsDelivered += 1
                day.lastNotificationAt = input.now
                if e.level == .incident { e.finalDeliveredAt = e.ladderElapsed }
            }
        }

        /// The ladder ends when it has nothing left to deliver, not when a four-rung
        /// timer runs out over rungs that were switched off.
        ///
        /// Under the ignore backoff the ceiling is capped to `.second` and `.second` is
        /// then refused by `ignoreBackoff` for the rest of the cycle, so the engine used
        /// to sit for `ladderLevel4 + promptTimeout` waiting on a ladder it had already
        /// disabled. That was 36 of the 63 minutes a user was left alone after two
        /// ignored opportunities; nobody chose it, and the cooldown that follows is
        /// untouched. `ladderIsSpent` states the same fact `rateLimit` states.
        let exhausted: Bool = {
            if let delivered = e.finalDeliveredAt { return e.ladderElapsed - delivered >= policy.promptTimeout }
            if interruption.ladderIsSpent(input, budget: e.budget) { return true }
            return e.ladderElapsed >= policy.ladderLevel4 + policy.promptTimeout
        }()
        if exhausted {
            effects.append(.closeCycle(e.cycle, .ignoredExhausted))
            day.consecutiveIgnoredCycles += 1
            effects.append(.setIndicator(.backedOff))
            let backedOff = day.consecutiveIgnoredCycles >= policy.ignoreBackoffThreshold
            return (.working(WorkingState(
                armThreshold: policy.targetContinuousWork,
                cooldownUntilMono: input.monotonic + policy.cooldownAfterExhausted,
                lastWorkSeen: input.context.continuousWork,
                standDown: backedOff ? .backedOff : .ladderExhausted
            )), verdict)
        }

        effects.append(.setIndicator(.escalating))
        return (.ignored(e), verdict)
    }

    private func ladderLevel(for e: Escalation, input: EngineInput) -> EscalationLevel {
        if e.ladderElapsed >= policy.ladderLevel4 { return .incident }
        if e.ladderElapsed >= policy.ladderLevel3Forced { return .third }
        if e.ladderElapsed >= policy.ladderLevel3Armed, !input.seams.isEmpty { return .third }
        if e.ladderElapsed >= policy.ladderLevel2 { return .second }
        return .first
    }

    /// A call block gets its own indicator. The three that mean "you are probably on a
    /// call" say `held`, so a user who is never prompted for twenty minutes can see that
    /// the app is holding rather than broken.
    static func indicator(for block: HardBlock) -> IndicatorState {
        switch block {
        case .audioInputInUse, .cameraInUse, .recentCallContinuing, .videoEventInProgress:
            return .held
        case .screenBeingShared, .presentationFullscreen, .focusModeActive, .screenLocked,
             .systemSleeping, .fastUserSwitched, .settleInAfterBreak, .imminentMeeting:
            return .breakDue
        }
    }

    /// How long this opportunity has been held by an input device nothing else
    /// corroborates. Zero the instant the device stops, or the instant anything
    /// independent says it is a call, so short real calls never accumulate towards the
    /// ceiling and a long corroborated one never reaches it at all.
    private func advanceAudioHold(
        _ elapsed: TimeInterval, by dt: TimeInterval, input: EngineInput
    ) -> TimeInterval {
        guard input.signals.audioInputRunning, !interruption.audioIsCorroborated(input) else { return 0 }
        return elapsed + dt
    }

    /// Live capture suppresses the sound channel for the same reason low power does: the
    /// rung still arrives, it just does not chime into somebody's recording.
    private func channelFor(level: EscalationLevel, signals: SystemSignals) -> PromptChannel {
        let quiet = signals.isPowerConstrained || signals.audioInputRunning || signals.cameraRunning
        switch level {
        /// `.notification`, which is what the engine has always actually sent for rung
        /// one, and now what this function says it sends. It returned `.passiveIndicator`,
        /// whose `interrupts` is false, and got away with it only because the deliver path
        /// hardcoded its own channel and never called here. Routing rung one through this
        /// function without also correcting the arm would have shipped a first prompt that
        /// never appears. The passive indicator is the menu bar mark, which is ambient and
        /// always live; it is not a rung's channel.
        case .first:    return .notification
        case .second:   return .notification
        case .third:    return quiet ? .notification : .notificationWithSound
        case .incident: return signals.isPowerConstrained ? .notification : .panel
        }
    }

    // MARK: - snoozed

    private func handleSnoozed(
        _ snoozed: SnoozedState,
        input: EngineInput,
        day: inout DailyCounters,
        effects: inout [Effect]
    ) -> EngineState {
        var s = snoozed
        let dt = max(0, input.monotonic - s.due.lastStepMono)
        s.due.lastStepMono = input.monotonic
        s.due.totalElapsed += dt

        guard input.monotonic >= s.untilMono else {
            effects.append(.setIndicator(.breakDue))
            return .snoozed(s)
        }

        var d = s.due
        d.seamWaitElapsed = 0
        d.promptedAt = nil
        d.promptedAtMono = nil
        effects.append(.cancelScheduledWake)
        return .breakDue(d)
    }

    // MARK: - breakActive

    private func handleBreakActive(
        _ active: BreakActive,
        input: EngineInput,
        day: inout DailyCounters,
        effects: inout [Effect]
    ) -> EngineState {
        let elapsed = input.monotonic - active.startedMono
        guard elapsed >= active.plannedDuration else {
            effects.append(.setIndicator(.onBreak))
            return .breakActive(active)
        }
        return finishBreak(active, elapsed: elapsed, input: input, day: &day, effects: &effects)
    }

    private func finishBreak(
        _ active: BreakActive,
        elapsed: TimeInterval,
        input: EngineInput,
        day: inout DailyCounters,
        effects: inout [Effect]
    ) -> EngineState {
        /// A break that ran the length the app itself asked for is honoured, full stop.
        ///
        /// `qualifyingBreak` exists to judge breaks nobody scheduled: a gap in the input
        /// stream long enough to have been a real one. Judging a deliberate break by it
        /// too meant the app set the duration, watched the user sit through all of it,
        /// and then recorded it as skipped, because the two numbers come from different
        /// settings and nothing tied them together. At the defaults they are both 300
        /// seconds and the comparison is on the boundary, so a tick landing a hair early
        /// lost the break; with any break shorter than `idleCountsAsBreakMinutes` no
        /// break could ever count, the day read "0 of N kept" forever, and no badge for
        /// taking breaks could unlock.
        ///
        /// Ending one early still has to clear the bar, which is the case the bar is for.
        let threshold = min(policy.qualifyingBreak, active.plannedDuration)
        let honored = elapsed >= threshold
        effects.append(
            .endBreak(
                cycle: active.cycle, origin: active.origin, honored: honored,
                elapsed: elapsed, threshold: threshold
            )
        )
        if let cycle = active.cycle {
            effects.append(.closeCycle(cycle, honored ? .honored : .skipped))
            if honored { day.honoredOpportunities += 1 }
        }
        /// The backoff is cleared by the break, not by the cycle the break happened to be
        /// attached to. Under the backoff a cycle gets one prompt and closes
        /// `promptTimeout` later, so a user who answers even a minute late starts their
        /// break with `cycle == nil` — and while this reset lived inside `if let cycle`
        /// that break bought them nothing. `consecutiveIgnoredCycles` never fell back
        /// under the threshold, every later opportunity was still a single prompt, and
        /// `PromptOutlook`'s "taking a break clears that and the full ladder comes back"
        /// was a sentence the engine did not honour. The only exit was answering inside
        /// the 90 second window, which is the window the backoff exists to shorten.
        ///
        /// A spontaneous break with no opportunity behind it clears it too, deliberately:
        /// the counter means "opportunities in a row that went unanswered by a break", and
        /// it is the nagging that stands down, not the accounting. `honoredOpportunities`
        /// stays inside the `if let` for exactly the opposite reason — crediting a break
        /// nobody asked for would inflate compliance against a denominator that never
        /// grew, and the ledger the panel actually reads would disagree with it.
        if honored { day.consecutiveIgnoredCycles = 0 }
        effects.append(.setIndicator(.working))
        return .working(WorkingState(armThreshold: policy.targetContinuousWork, lastWorkSeen: 0))
    }

    // MARK: - idle

    private func handleIdle(
        _ idle: IdleState,
        input: EngineInput,
        day: inout DailyCounters,
        effects: inout [Effect]
    ) -> EngineState {
        guard input.context.idleSeconds < policy.microIdleGrace, !input.signals.screenLocked else {
            effects.append(.setIndicator(.idle))
            return .idle(idle)
        }
        /// Back to the rung it was on, not back to the bottom.
        ///
        /// The gap ages the opportunity but not the ladder, and the two clocks are
        /// separate for exactly this reason: `totalElapsed` is wall clock since
        /// `dueSince` and is what the stale ceiling measures, so time away still counts
        /// toward giving up on an opportunity. `ladderElapsed` is how long a prompt has
        /// stood in front of you unanswered, so it must not accrue while you were not
        /// there to answer it. Crediting the gap to both would hand a user who stepped
        /// away for four minutes an instant SIGINT on their return.
        ///
        /// `step` re-enters `.ignored` on this same tick, where `dt` then comes out zero
        /// because `lastStepMono` has just been moved forward. Nothing is counted twice.
        if var e = idle.suspendedEscalation {
            e.totalElapsed += max(0, input.monotonic - e.lastStepMono)
            e.lastStepMono = input.monotonic
            effects.append(.setIndicator(.escalating))
            return .ignored(e)
        }
        /// A cycle suspended out of `.breakDue` keeps its age too.
        ///
        /// This rebuilt the opportunity with `dueSince: input.now` and `totalElapsed = 0`,
        /// which restarted the one clock the stale ceiling measures. A user who crosses the
        /// 90 second idle grace more often than once an hour could therefore hold an
        /// opportunity open forever: it could never reach `staleBreakCeiling`, never close
        /// `.expired`, and never be counted in `excludedOpportunities`. The log has four
        /// cycles that open and never close.
        ///
        /// `handleSnoozed` had this right all along and the doc states it for that case —
        /// BREAK-DECISION.md:474, "`seamWaitElapsed = 0`; `totalElapsed` continues" — so
        /// this is the idle path being brought into line with the one beside it: only what
        /// a genuine absence invalidates is cleared, which is the standing prompt.
        if let suspended = idle.suspendedBreakDue {
            var d = suspended
            d.totalElapsed += max(0, input.monotonic - d.lastStepMono)
            d.lastStepMono = input.monotonic
            d.seamWaitElapsed = 0
            d.promptedAt = nil
            d.promptedAtMono = nil
            effects.append(.setIndicator(.breakDue))
            return .breakDue(d)
        }
        if let cycle = idle.suspendedCycle {
            var d = BreakDue(cycle: cycle, dueSince: input.now, lastStepMono: input.monotonic)
            d.totalElapsed = 0
            effects.append(.setIndicator(.breakDue))
            return .breakDue(d)
        }
        effects.append(.setIndicator(.working))
        return .working(WorkingState(armThreshold: policy.targetContinuousWork, lastWorkSeen: input.context.continuousWork))
    }

    // MARK: - quiet

    private func handleQuiet(
        _ quiet: QuietState,
        input: EngineInput,
        inQuietWindow: Bool,
        day: inout DailyCounters,
        effects: inout [Effect]
    ) -> EngineState {
        switch quiet.cause {
        case .scheduledQuietHours:
            guard !inQuietWindow else {
                effects.append(.setIndicator(.quiet))
                return .quiet(quiet)
            }
            return .working(WorkingState(armThreshold: policy.targetContinuousWork, lastWorkSeen: input.context.continuousWork))
        case .userPaused:
            if let untilMono = quiet.untilMono, input.monotonic >= untilMono {
                return .working(WorkingState(armThreshold: policy.targetContinuousWork, lastWorkSeen: input.context.continuousWork))
            }
            effects.append(.setIndicator(.quiet))
            return .quiet(quiet)
        case .sustainedFocusMode:
            if input.signals.focusModeActive != true {
                return .working(WorkingState(armThreshold: policy.targetContinuousWork, lastWorkSeen: input.context.continuousWork))
            }
            effects.append(.setIndicator(.quiet))
            return .quiet(quiet)
        case .dailyCapReached:
            effects.append(.setIndicator(.quiet))
            return .quiet(quiet)
        }
    }

    // MARK: - user actions

    /// What the developer did to a prompt. Actions are events, not state.
    ///
    /// One rule worth stating because it was wrong: `.skip` neither increments nor resets
    /// `consecutiveIgnoredCycles`. It is not an ignore, the user answered, but it used to
    /// reset the counter, which made waving a prompt off worth exactly as much to the
    /// ladder backoff as taking the break, while `CycleOutcome.skipped` still counts
    /// against compliance. Clearing the backoff is what a break earns. A skip already
    /// costs the user twenty minutes of quiet; it should buy nothing on top.
    private func handle(
        _ action: UserAction,
        state: EngineState,
        input: EngineInput,
        day: inout DailyCounters,
        effects: inout [Effect]
    ) -> EngineState {
        switch action {
        case .acceptBreak, .startBreakNow:
            let origin: BreakOrigin = (action == .acceptBreak) ? .accepted : .userInitiated
            let cycle = state.openCycle
            if let cycle { effects.append(.withdrawPrompt(cycle: cycle, reason: .breakStarted)) }
            let duration = policy.breakDurationTarget
            let plannedEnd = input.now.addingTimeInterval(duration)
            effects.append(.beginBreak(cycle: cycle, origin: origin, plannedEnd: plannedEnd))
            effects.append(.setIndicator(.onBreak))
            return .breakActive(BreakActive(
                cycle: cycle,
                startedAt: input.now,
                plannedEnd: plannedEnd,
                startedMono: input.monotonic,
                plannedDuration: duration,
                origin: origin
            ))

        case .snooze:
            guard var d = pendingCycle(state) else { return state }
            let offered = interruption.offeredSnoozes(used: d.snoozesUsed, total: d.snoozeTotal)
            guard let duration = offered.first else {
                return state
            }
            let index = d.snoozesUsed
            d.snoozesUsed += 1
            d.snoozeTotal += duration
            d.lastStepMono = input.monotonic
            let until = input.now.addingTimeInterval(duration)
            effects.append(.withdrawPrompt(cycle: d.cycle, reason: .userSnoozed))
            effects.append(.recordSnooze(cycle: d.cycle, duration: duration))
            effects.append(.scheduleWake(at: until))
            effects.append(.setIndicator(.breakDue))
            return .snoozed(SnoozedState(cycle: d.cycle, until: until, untilMono: input.monotonic + duration, index: index, due: d))

        case .skip:
            guard let cycle = state.openCycle else { return state }
            effects.append(.withdrawPrompt(cycle: cycle, reason: .userSkipped))
            effects.append(.closeCycle(cycle, .skipped))
            effects.append(.recordSkip(cycle: cycle))
            effects.append(.setIndicator(.working))
            return .working(WorkingState(
                armThreshold: input.context.continuousWork + policy.rearmAfterSkip,
                lastWorkSeen: input.context.continuousWork,
                standDown: .skipped
            ))

        case .endBreak:
            guard case .breakActive(let b) = state else { return state }
            let elapsed = input.monotonic - b.startedMono
            return finishBreak(b, elapsed: elapsed, input: input, day: &day, effects: &effects)

        case .pauseApp(let duration):
            if let cycle = state.openCycle {
                effects.append(.withdrawPrompt(cycle: cycle, reason: .quietHoursStarted))
                effects.append(.closeCycle(cycle, .quietSuppressed))
                day.excludedOpportunities += 1
            }
            effects.append(.setIndicator(.quiet))
            return .quiet(QuietState(
                until: input.now.addingTimeInterval(duration),
                untilMono: input.monotonic + duration,
                cause: .userPaused
            ))

        case .resumeApp:
            effects.append(.setIndicator(.working))
            return .working(WorkingState(armThreshold: policy.targetContinuousWork, lastWorkSeen: input.context.continuousWork))
        }
    }

    // MARK: - helpers

    private func pendingCycle(_ state: EngineState) -> BreakDue? {
        switch state {
        case .breakDue(let d): return d
        case .snoozed(let s):  return s.due
        case .ignored(let e):
            var d = BreakDue(cycle: e.cycle, dueSince: e.dueSince, lastStepMono: e.lastStepMono)
            d.totalElapsed = e.totalElapsed
            d.notificationsThisCycle = e.notificationsThisCycle
            return d
        case .working, .breakActive, .idle, .quiet: return nil
        }
    }

    private func isBreakActive(_ state: EngineState) -> Bool {
        if case .breakActive = state { return true } else { return false }
    }
}
