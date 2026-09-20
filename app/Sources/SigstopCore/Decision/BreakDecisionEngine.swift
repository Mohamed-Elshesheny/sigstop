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
                day.consecutiveIgnoredCycles = 0
            }
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
        if input.context.continuousWork < w.lastWorkSeen { w.armThreshold = policy.targetContinuousWork }
        w.lastWorkSeen = input.context.continuousWork

        if input.context.idleSeconds >= policy.microIdleGrace || input.signals.screenLocked {
            effects.append(.setIndicator(.idle))
            let cause: PauseCause = input.signals.screenLocked ? .screenLocked : .microIdleExceeded
            return .idle(IdleState(since: input.now.addingTimeInterval(-input.context.idleSeconds), cause: cause))
        }

        if let cooldown = w.cooldownUntilMono {
            if input.monotonic < cooldown {
                effects.append(.setIndicator(.working))
                return .working(w)
            }
            w.cooldownUntilMono = nil
        }

        let due = input.context.continuousWork >= w.armThreshold
        let early = interruption.opportunisticEarlyPrompt(input) && w.armThreshold <= policy.targetContinuousWork
        guard due || early else {
            effects.append(.setIndicator(.working))
            return .working(w)
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
                suspendedCycle: d.cycle
            )), nil)
        }

        if d.totalElapsed >= policy.staleBreakCeiling {
            if d.promptedAt != nil { effects.append(.withdrawPrompt(cycle: d.cycle, reason: .cycleExpired)) }
            effects.append(.closeCycle(d.cycle, .expired))
            day.excludedOpportunities += 1
            effects.append(.setIndicator(.working))
            return (.working(WorkingState(
                armThreshold: input.context.continuousWork + policy.rearmAfterStale,
                lastWorkSeen: input.context.continuousWork
            )), nil)
        }

        let verdict = interruption.verdict(input, budget: d.budget)
        d.lastVerdict = verdict
        effects.append(.recordVerdict(verdict))

        if let promptedMono = d.promptedAtMono,
           !verdict.isHardBlocked,
           input.monotonic - promptedMono >= policy.promptTimeout {
            effects.append(.recordIgnoredPrompt)
            effects.append(.setIndicator(.escalating))
            return (.ignored(Escalation(
                cycle: d.cycle,
                dueSince: d.dueSince,
                ignoredAt: input.now,
                notificationsThisCycle: d.notificationsThisCycle,
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
            case .quietHours:
                effects.append(.closeCycle(d.cycle, .quietSuppressed))
                day.excludedOpportunities += 1
                effects.append(.setIndicator(.quiet))
                return (.quiet(QuietState(cause: .scheduledQuietHours)), verdict)
            case .dailyCapReached:
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
                    channel: .notification,
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
                suspendedCycle: e.cycle
            )), nil)
        }

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

        let ceiling: EscalationLevel = day.consecutiveIgnoredCycles >= policy.ignoreBackoffThreshold ? .second : .incident
        var target = ladderLevel(for: e, input: input)
        if target > ceiling { target = ceiling }
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

        let exhausted: Bool = {
            if let delivered = e.finalDeliveredAt { return e.ladderElapsed - delivered >= policy.promptTimeout }
            return e.ladderElapsed >= policy.ladderLevel4 + policy.promptTimeout
        }()
        if exhausted {
            effects.append(.closeCycle(e.cycle, .ignoredExhausted))
            day.consecutiveIgnoredCycles += 1
            effects.append(.setIndicator(.escalating))
            return (.working(WorkingState(
                armThreshold: policy.targetContinuousWork,
                cooldownUntilMono: input.monotonic + policy.cooldownAfterExhausted,
                lastWorkSeen: input.context.continuousWork
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

    private func channelFor(level: EscalationLevel, signals: SystemSignals) -> PromptChannel {
        switch level {
        case .first:    return .passiveIndicator
        case .second:   return .notification
        case .third:    return signals.isPowerConstrained ? .notification : .notificationWithSound
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
        let honored = elapsed >= policy.qualifyingBreak
        effects.append(.endBreak(origin: active.origin, honored: honored))
        effects.append(.resumeWorkClock)
        if let cycle = active.cycle {
            effects.append(.closeCycle(cycle, honored ? .honored : .skipped))
            if honored {
                day.honoredOpportunities += 1
                day.consecutiveIgnoredCycles = 0
            }
        }
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
            effects.append(.recordSnooze(duration))
            effects.append(.scheduleWake(at: until))
            effects.append(.setIndicator(.breakDue))
            return .snoozed(SnoozedState(cycle: d.cycle, until: until, untilMono: input.monotonic + duration, index: index, due: d))

        case .skip:
            guard let cycle = state.openCycle else { return state }
            effects.append(.withdrawPrompt(cycle: cycle, reason: .breakStarted))
            effects.append(.closeCycle(cycle, .skipped))
            effects.append(.recordSkip)
            effects.append(.setIndicator(.working))
            day.consecutiveIgnoredCycles = 0
            return .working(WorkingState(
                armThreshold: input.context.continuousWork + policy.rearmAfterSkip,
                lastWorkSeen: input.context.continuousWork
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
