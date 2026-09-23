import Foundation

public struct EngineInput: Sendable {
    public var now: Date
    public var monotonic: Double
    public var context: DeveloperContext
    public var signals: SystemSignals
    public var settings: SigstopSettings
    public var calendarSystem: Calendar
    public var calendar: CalendarSignals?
    public var seams: [Seam]
    public var keystrokeRate: Double
    public var terminalCommandRunning: Bool
    public var secondsSinceFrontmostChange: TimeInterval
    public var focusScore: Double
    public var lastBreakEndedAt: Date?
    public var day: DailyCounters
    public var userAction: UserAction?
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

    public var qualifyingBreakObserved: Bool {
        sessionEvents.contains { if case .breakRecorded = $0 { return true } else { return false } }
    }
}

public struct EngineOutcome: Sendable {
    public let state: EngineState
    public let effects: [Effect]
    public let day: DailyCounters
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
        var input = input
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
            input.day = day
            if wasCapped {
                state = .working(WorkingState(armThreshold: policy.targetContinuousWork, lastWorkSeen: input.context.continuousWork))
            }
        }

        if let action = input.userAction {
            state = handle(action, state: state, input: input, day: &day, effects: &effects)
            return EngineOutcome(state: state, effects: effects, day: day, verdict: nil)
        }

        if input.qualifyingBreakObserved, !isBreakActive(state) {
            if case .quiet(let quiet) = state, stillQuiet(quiet, input: input, day: day) {
                day.consecutiveIgnoredCycles = 0
                effects.append(.setIndicator(.quiet))
                return EngineOutcome(state: state, effects: effects, day: day, verdict: nil)
            }
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
            var escalation = Escalation(
                cycle: d.cycle,
                dueSince: d.dueSince,
                ignoredAt: input.now,
                notificationsThisCycle: d.notificationsThisCycle,
                uncorroboratedAudioElapsed: d.uncorroboratedAudioElapsed,
                totalElapsed: d.totalElapsed,
                lastStepMono: input.monotonic
            )
            escalation.snoozesUsed = d.snoozesUsed
            escalation.snoozeTotal = d.snoozeTotal
            return (.ignored(escalation), verdict)
        }

        switch verdict {
        case .hardBlocked(let block):
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
                if d.promptedAt != nil {
                    effects.append(.withdrawPrompt(cycle: d.cycle, reason: .quietHoursStarted))
                }
                effects.append(.closeCycle(d.cycle, .quietSuppressed))
                day.excludedOpportunities += 1
                effects.append(.setIndicator(.quiet))
                return (.quiet(QuietState(cause: .scheduledQuietHours)), verdict)
            case .dailyCapReached:
                if d.promptedAtMono != nil {
                    effects.append(.setIndicator(.breakDue))
                    return (.breakDue(d), verdict)
                }
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
                d.promptedAt = input.now
                d.promptedAtMono = input.monotonic
                d.notificationsThisCycle += 1
                day.notificationsDelivered += 1
                day.lastNotificationAt = input.now
                let prompt = PromptRequest(
                    cycle: d.cycle,
                    level: .first,
                    channel: channelFor(level: .first, signals: input.signals),
                    at: input.now,
                    continuousWork: input.context.continuousWork,
                    snoozeOffered: interruption.offeredSnoozes(
                        day: day, sentThisCycle: d.notificationsThisCycle,
                        used: d.snoozesUsed, total: d.snoozeTotal
                    )
                )
                effects.append(.deliverPrompt(prompt))
                effects.append(.setIndicator(.breakDue))
                return (.breakDue(d), verdict)
            }
            effects.append(.setIndicator(.breakDue))
            return (.breakDue(d), verdict)
        }
    }

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
                if e.level == .incident
                    || interruption.ladderIsSpent(input, budget: e.budget)
                    || day.notificationsDelivered >= policy.dailyNotificationCap {
                    e.finalDeliveredAt = e.ladderElapsed
                }
            }
        }

        let capped = day.notificationsDelivered >= policy.dailyNotificationCap
        let spent = interruption.ladderIsSpent(input, budget: e.budget)
        let exhausted: Bool = {
            if let delivered = e.finalDeliveredAt { return e.ladderElapsed - delivered >= policy.promptTimeout }
            if spent || capped { return true }
            return e.ladderElapsed >= policy.ladderLevel4 + policy.promptTimeout
        }()
        if exhausted, capped, !spent, !e.deliveredLevels.contains(.incident) {
            effects.append(.withdrawPrompt(cycle: e.cycle, reason: .dailyCapReached))
            effects.append(.closeCycle(e.cycle, .dailyCapReached))
            if e.notificationsThisCycle == 0 { day.excludedOpportunities += 1 }
            effects.append(.setIndicator(.quiet))
            return (.quiet(QuietState(cause: .dailyCapReached)), verdict)
        }
        if exhausted {
            effects.append(.withdrawPrompt(cycle: e.cycle, reason: .cycleExpired))
            effects.append(.closeCycle(e.cycle, .ignoredExhausted))
            day.consecutiveIgnoredCycles += 1
            if capped {
                effects.append(.setIndicator(.quiet))
                return (.quiet(QuietState(cause: .dailyCapReached)), verdict)
            }
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

    static func indicator(for block: HardBlock) -> IndicatorState {
        switch block {
        case .audioInputInUse, .cameraInUse, .recentCallContinuing, .videoEventInProgress:
            return .held
        case .screenBeingShared, .presentationFullscreen, .focusModeActive, .screenLocked,
             .systemSleeping, .fastUserSwitched, .settleInAfterBreak, .imminentMeeting:
            return .breakDue
        }
    }

    private func advanceAudioHold(
        _ elapsed: TimeInterval, by dt: TimeInterval, input: EngineInput
    ) -> TimeInterval {
        guard input.signals.audioInputRunning, !interruption.audioIsCorroborated(input) else { return 0 }
        return elapsed + dt
    }

    private func channelFor(level: EscalationLevel, signals: SystemSignals) -> PromptChannel {
        let quiet = signals.isPowerConstrained || signals.audioInputRunning || signals.cameraRunning
        switch level {
        case .first:    return .notification
        case .second:   return .notification
        case .third:    return quiet ? .notification : .notificationWithSound
        case .incident: return signals.isPowerConstrained ? .notification : .panel
        }
    }

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
        if honored { day.consecutiveIgnoredCycles = 0 }
        if let quiet = active.quietBefore, stillQuiet(quiet, input: input, day: day) {
            effects.append(.setIndicator(.quiet))
            return .quiet(quiet)
        }
        effects.append(.setIndicator(.working))
        return .working(WorkingState(armThreshold: policy.targetContinuousWork, lastWorkSeen: 0))
    }

    private func stillQuiet(_ quiet: QuietState, input: EngineInput, day: DailyCounters) -> Bool {
        switch quiet.cause {
        case .userPaused:
            guard let untilMono = quiet.untilMono else { return true }
            return input.monotonic < untilMono
        case .scheduledQuietHours:
            return input.settings.quietHours.contains(input.now, calendar: input.calendarSystem)
        case .sustainedFocusMode:
            return input.signals.focusModeActive == true
        case .dailyCapReached:
            return day.notificationsDelivered >= policy.dailyNotificationCap
        }
    }

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
        if var e = idle.suspendedEscalation {
            e.totalElapsed += max(0, input.monotonic - e.lastStepMono)
            e.lastStepMono = input.monotonic
            effects.append(.setIndicator(.escalating))
            return .ignored(e)
        }
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

    private func handle(
        _ action: UserAction,
        state: EngineState,
        input: EngineInput,
        day: inout DailyCounters,
        effects: inout [Effect]
    ) -> EngineState {
        if case .breakActive(let b) = state {
            switch action {
            case .endBreak:
                break
            case .pauseApp:
                let elapsed = input.monotonic - b.startedMono
                let ended = finishBreak(b, elapsed: elapsed, input: input, day: &day, effects: &effects)
                return handle(action, state: ended, input: input, day: &day, effects: &effects)
            case .acceptBreak, .startBreakNow, .snooze, .skip, .resumeApp:
                return state
            }
        }
        switch action {
        case .acceptBreak, .startBreakNow:
            let origin: BreakOrigin = (action == .acceptBreak) ? .accepted : .userInitiated
            let cycle = state.openCycle
            if let cycle { effects.append(.withdrawPrompt(cycle: cycle, reason: .breakStarted)) }
            let duration = policy.breakDurationTarget
            let plannedEnd = input.now.addingTimeInterval(duration)
            effects.append(.beginBreak(cycle: cycle, origin: origin, plannedEnd: plannedEnd))
            effects.append(.setIndicator(.onBreak))
            let quietBefore: QuietState? = {
                if case .quiet(let q) = state { return q } else { return nil }
            }()
            return .breakActive(BreakActive(
                cycle: cycle,
                startedAt: input.now,
                plannedEnd: plannedEnd,
                startedMono: input.monotonic,
                plannedDuration: duration,
                origin: origin,
                quietBefore: quietBefore
            ))

        case .snooze:
            guard var d = pendingCycle(state) else { return state }
            let offered = interruption.offeredSnoozes(
                day: day, sentThisCycle: d.notificationsThisCycle,
                used: d.snoozesUsed, total: d.snoozeTotal
            )
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

    private func pendingCycle(_ state: EngineState) -> BreakDue? {
        switch state {
        case .breakDue(let d): return d
        case .snoozed(let s):  return s.due
        case .ignored(let e):
            var d = BreakDue(cycle: e.cycle, dueSince: e.dueSince, lastStepMono: e.lastStepMono)
            d.totalElapsed = e.totalElapsed
            d.notificationsThisCycle = e.notificationsThisCycle
            d.snoozesUsed = e.snoozesUsed
            d.snoozeTotal = e.snoozeTotal
            return d
        case .working, .breakActive, .idle, .quiet: return nil
        }
    }

    private func isBreakActive(_ state: EngineState) -> Bool {
        if case .breakActive = state { return true } else { return false }
    }
}
