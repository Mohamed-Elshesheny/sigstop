import AppKit
import Foundation
import Observation
import SigstopCore
import SigstopSensors

/// The loop, and the only place in the process where an `Effect` is executed.
///
/// The shape is deliberate, and it is the reason the engines are testable at all:
///
/// ```
///   sensors ──▶ SessionTracker.tick ──▶ EngineInput ──▶ BreakDecisionEngine.step
///                                                              │
///                                                       [Effect] ──▶ here
/// ```
///
/// `BreakDecisionEngine.step` is a pure function that *returns* what should happen. If
/// any part of this file leaked back into `SigstopCore` — a notification posted from the
/// engine, a window opened from the tracker — the state machine would stop being a table
/// of unit tests and start needing a window server. So every side effect lands in
/// `execute(_:)` below and nowhere else.
///
/// Everything here is `@MainActor`. `NSWorkspace`, the lock/sleep notifications and the
/// AX collectors are already main-actor isolated inside `SigstopSensors`, so a second
/// isolation domain would buy a hop in each direction and nothing else.
@MainActor
@Observable
final class AppModel {

    // MARK: - Tunables

    /// How often the world is sampled. Deliberately **not** the unit of time measurement:
    /// elapsed time is never `ticks × interval` (CLAUDE.md §3.4). Every duration in the
    /// tracker and the engine is a difference of two real monotonic readings, and a tick
    /// that arrives late is classified as a gap rather than credited.
    static let tickInterval: TimeInterval = 5

    /// How much lateness is still "a tick". Past this the tracker treats the sample as a
    /// discontinuity: the process was throttled, the lid was shut, the machine slept.
    static let tickTolerance: TimeInterval = 5

    /// A `focus` line is written when the app or the activity changes, and otherwise at
    /// this cadence. The rollup closes its last segment at the last event in the log, so
    /// a long uninterrupted stretch needs a heartbeat or it credits nothing.
    static let focusHeartbeat: TimeInterval = 5 * 60

    // MARK: - Observable view state
    //
    // Plain values. The views never reach into an engine, a tracker or a collector.

    private(set) var continuousWork: TimeInterval = 0
    private(set) var timeSinceLastBreak: TimeInterval?
    private(set) var activityLabel: String = "starting up"
    private(set) var applicationName: String = "—"
    private(set) var confidence: Double = 0
    private(set) var evidenceLines: [EvidenceLine] = []
    private(set) var caveats: [String] = []
    /// Why a prompt is being held right now, in the user's words. `nil` means nothing is
    /// holding it.
    private(set) var gateReason: String?
    private(set) var indicator: IndicatorState = .working
    private(set) var engineStateName: String = "working"
    private(set) var todaySummary: DailySummary?
    private(set) var todayLine: String = ""
    private(set) var todayDetail: String = ""
    private(set) var breakEndsAt: Date?
    private(set) var breakContent: BreakContent?
    private(set) var snoozeUntil: Date?
    private(set) var pausedUntil: Date?
    private(set) var permissionStatus: PermissionStatus
    private(set) var lastStoreError: String?
    private(set) var notificationState: NotificationAvailability = .notYetNeeded
    private(set) var settings: SigstopSettings

    /// Set by the status item controller so it can re-apply the Dock policy.
    var onSettingsChanged: (() -> Void)?
    private(set) var isRunning = false

    /// 0…1 — how full the menu bar bars are drawn. The fraction of the target interval
    /// that has actually been *worked*, clamped, never extrapolated.
    var workFraction: Double {
        let target = settings.workInterval
        guard target > 0 else { return 0 }
        return min(1, max(0, continuousWork / target))
    }

    var isOnBreak: Bool { breakEndsAt != nil }

    /// True only while a cycle is actually open. Snoozing with nothing pending is a
    /// no-op in the engine, so the menu does not offer it.
    private(set) var canSnooze = false

    struct EvidenceLine: Identifiable, Hashable, Sendable {
        let id: String
        let summary: String
        let logOdds: Double
        let tier: SignalTier
    }

    enum NotificationAvailability: Sendable, Hashable {
        /// Authorization is requested at the first break, never at launch
        /// (docs/PRIVACY.md §3.2).
        case notYetNeeded
        case available
        /// Notifications cannot be used, with the reason. The app falls back to drawing
        /// its own panel, which needs no permission at all.
        case unavailable(String)
    }

    // MARK: - Collaborators (never observed)

    @ObservationIgnored private let time: any TimeSource = SystemTimeSource()
    @ObservationIgnored private let workClock = WorkClockBox()
    @ObservationIgnored private let messages = MessageEngine()
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private let overlay = BreakOverlayController()

    /// The updater. Observed, unlike its neighbours above, because Settings > About draws
    /// its state directly — the progress bar is the object's own `state`, not a copy.
    ///
    /// Constructed at launch rather than when Settings opens, and that is load-bearing in
    /// one direction only: Sparkle's scheduler has to exist for the whole session or the
    /// "check automatically" switch would silently mean "check while this window is open."
    /// Constructing it opens nothing. `SPUUpdater.start()` makes no request; it schedules
    /// one only if automatic checks are on, and they are off unless the user says so.
    let updates = UpdateChecker()
    @ObservationIgnored private var sensors: SensorStack
    @ObservationIgnored private var tracker: SessionTracker
    @ObservationIgnored private var decision: BreakDecisionEngine
    @ObservationIgnored private var store: FileEventStore?

    // MARK: - Loop state (never observed)

    @ObservationIgnored private var engineState: EngineState
    @ObservationIgnored private var day = DailyCounters()
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var observerTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pendingAction: UserAction?
    @ObservationIgnored private var currentCycle: CycleID?
    @ObservationIgnored private var breakStartedAt: Date?
    @ObservationIgnored private var loggedApp: String??
    @ObservationIgnored private var loggedActivity: Activity?
    @ObservationIgnored private var lastFocusLogAt: Date?
    @ObservationIgnored private var idleBeganAt: Date?
    @ObservationIgnored private var seamsForNextStep: Set<Seam> = []
    @ObservationIgnored private var rollupComputedAt: Date?

    // MARK: - Init

    init() {
        let loaded = SettingsStore.load()
        let policy = Self.policy(for: loaded)

        self.settings = loaded
        self.sensors = SensorStack(settings: loaded, time: time, workClock: workClock)
        self.tracker = SessionTracker(time: time, policy: policy)
        self.decision = BreakDecisionEngine(policy: policy)
        self.engineState = .initial(policy: policy)
        self.permissionStatus = sensors.permissions.status()
    }

    /// The product policy, with the app's real sampling cadence written into it.
    ///
    /// Left at the 1 s default, every 5 s sample would look like a discontinuity to the
    /// tracker and the work clock would never credit a second of anything.
    private static func policy(for settings: SigstopSettings) -> BreakPolicy {
        var policy = BreakPolicy(settings: settings)
        policy.tickInterval = tickInterval
        policy.tickTolerance = tickTolerance
        return policy
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        wireNotifier()
        openStore()
        append(.start(at: time.now))

        sensors.context.start()
        subscribeToSystemEvents()
        subscribeToWorkspaceEvents()
        subscribeToPermissionChanges()
        subscribeToTermination()

        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: .seconds(Self.tickInterval))
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        tickTask?.cancel()
        tickTask = nil
        for task in observerTasks { task.cancel() }
        observerTasks.removeAll()
        overlay.dismissAll()
        notifier.withdrawAll()
        sensors.context.stop()
        append(.stop(at: time.now))
    }

    // MARK: - User actions
    //
    // These never mutate the state machine directly. They queue a `UserAction`, and the
    // very next `step` applies it — an explicit action outranks everything the engine
    // might infer, and letting two writers touch `engineState` is how a state machine
    // stops being one.

    func takeBreakNow() { enqueue(.startBreakNow) }
    func acceptBreak() { enqueue(.acceptBreak) }
    func snooze() { enqueue(.snooze) }
    func skip() { enqueue(.skip) }
    func endBreak() { enqueue(.endBreak) }
    func pause(for duration: TimeInterval) { enqueue(.pauseApp(duration)) }
    func resume() { enqueue(.resumeApp) }

    private func enqueue(_ action: UserAction) {
        pendingAction = action
        Task { [weak self] in await self?.tick() }
    }

    /// `SIGHUP` — re-read the config. A changed work interval or tone takes effect on the
    /// next sample, not at the next launch.
    func update(settings newValue: SigstopSettings) {
        guard newValue != settings else { return }
        settings = newValue
        SettingsStore.save(newValue)
        onSettingsChanged?()
        decision = BreakDecisionEngine(policy: Self.policy(for: newValue))
        sensors.context.reloadSettings(newValue)
        permissionStatus = sensors.permissions.status()
        if !newValue.showBreakOverlay { overlay.dismissBreak() }
    }

    // MARK: - The tick

    private func tick() async {
        let sample = await sensors.context.sampleAndPublish()
        let raw = sensors.readSignals()
        let now = time.now
        let monotonic = time.monotonicSeconds

        // 1. The session clock. Tier 0 facts only — the activity is passed for
        //    attribution, never to move the clock.
        let tickSample = TickSample(
            idleSeconds: raw.input.knownIdleSeconds ?? 0,
            screenLocked: raw.session.screenLocked,
            micRunning: raw.audio.contributesToMeeting,
            fastUserSwitched: !raw.session.sessionActive,
            userPaused: isPaused,
            application: sample.context.application,
            activity: sample.context.activity,
            confidence: sample.context.confidence
        )
        let sessionEvents = tracker.tick(tickSample)

        // The tracker owns the clock, so its reading is the authoritative one: publish it
        // for the next context sample, and build the engine's context from it.
        workClock.publish(
            WorkClockReading(
                continuousWork: tracker.session.continuousActiveWork,
                timeSinceLastBreak: tracker.session.timeSinceLastBreak(now: now)
            )
        )
        let context = tracker.makeContext(
            now: now,
            evidence: sample.context.evidence,
            context: sample.context.context,
            concurrent: sample.context.concurrent
        )

        // 2. The decision.
        var signals = raw.systemSignals
        signals.frontmostIsFullscreen = sample.context.concurrent.fullscreen

        let input = EngineInput(
            now: now,
            monotonic: monotonic,
            context: context,
            signals: signals,
            settings: settings,
            calendarSystem: .current,
            // EventKit is declined outright (docs/PRIVACY.md §3.3), so the app knows
            // nothing about the day's events and claims nothing about them.
            calendar: nil,
            seams: Array(seamsForNextStep),
            // Keystroke *rate* would need Input Monitoring, which is declined on
            // principle. Zero here means "cannot tell". The only consequence is that the
            // engine never defers for a typing burst; it never fires extra.
            keystrokeRate: 0,
            terminalCommandRunning: false,
            secondsSinceFrontmostChange: max(0, now.timeIntervalSince(raw.frontmost.frontmostSince)),
            focusScore: tracker.focusScore,
            lastBreakEndedAt: tracker.session.lastBreakEndedAt,
            day: day,
            userAction: pendingAction,
            sessionEvents: sessionEvents
        )
        pendingAction = nil
        seamsForNextStep.removeAll()

        let outcome = decision.step(engineState, input)
        engineState = outcome.state
        day = outcome.day

        // 3. The only place effects happen.
        for effect in outcome.effects {
            execute(effect, context: context, now: now)
        }

        record(sessionEvents: sessionEvents, at: now)
        logFocusIfNeeded(context: context, sample: sample, at: now)
        publishViewState(sample: sample, context: context, outcome: outcome)
    }

    private var isPaused: Bool {
        if case .quiet(let q) = engineState, q.cause == .userPaused { return true }
        return false
    }

    // MARK: - Effects

    private func execute(_ effect: Effect, context: DeveloperContext, now: Date) {
        switch effect {
        case .openCycle(let cycle):
            currentCycle = cycle
            append(.breakOpen(at: now, cycle: cycle))

        case .closeCycle(let cycle, _):
            // The outcome is reconstructed by the rollup from the prompt and break lines.
            // There is no "cycle closed" line in the vocabulary, and inventing one would
            // put a second, disagreeing source of truth in the log.
            if currentCycle == cycle { currentCycle = nil }

        case .deliverPrompt(let request):
            deliver(request, context: context, now: now)

        case .withdrawPrompt(let cycle, _):
            // A withdrawal is not a delivery, and is not logged as one: the line written
            // at delivery already records what reached the screen.
            notifier.withdraw(cycle: cycle)
            overlay.dismissPromptPanel()

        case .setIndicator(let state):
            indicator = state

        case .beginBreak(let cycle, let origin, let plannedEnd):
            tracker.beginBreak(origin: origin)
            breakStartedAt = now
            breakEndsAt = plannedEnd
            breakContent = BreakContent.make(
                for: context,
                settings: settings,
                seed: UInt64(bitPattern: Int64(now.timeIntervalSince1970.rounded()))
            )
            notifier.withdrawAll()
            overlay.dismissPromptPanel()
            if settings.showBreakOverlay { overlay.presentBreak(model: self) }
            append(.breakBegin(at: now, origin: origin, cycle: cycle))
            if let cycle { append(.breakResponse(at: now, cycle: cycle, action: .taken)) }

        case .endBreak(let origin, _):
            tracker.endBreak(origin: origin)
            let duration = max(0, now.timeIntervalSince(breakStartedAt ?? now))
            overlay.dismissBreak()
            breakEndsAt = nil
            breakContent = nil
            breakStartedAt = nil
            append(
                .breakEnd(
                    at: now, origin: origin,
                    durationSeconds: Int(duration.rounded()), cycle: currentCycle
                )
            )
            refreshRollup(force: true)

        case .scheduleWake(let date):
            // No timer is armed for this. The loop already runs every few seconds and the
            // engine decides purely from a monotonic comparison, so a second scheduler
            // here could only ever disagree with it.
            snoozeUntil = date

        case .cancelScheduledWake:
            snoozeUntil = nil

        case .recordVerdict(let verdict):
            gateReason = Self.explain(verdict)

        case .recordSkip:
            tracker.recordSkip()
            if let cycle = currentCycle {
                append(.breakResponse(at: now, cycle: cycle, action: .skipped))
            }

        case .recordIgnoredPrompt:
            tracker.recordIgnoredPrompt()
            if let cycle = currentCycle {
                append(.breakResponse(at: now, cycle: cycle, action: .ignored))
            }

        case .recordSnooze(let duration):
            tracker.recordSnooze()
            if let cycle = currentCycle {
                append(
                    .breakResponse(
                        at: now, cycle: cycle, action: .snoozed,
                        snoozeSeconds: Int(duration.rounded())
                    )
                )
            }

        case .resumeWorkClock:
            // `tracker.endBreak` already resumed it. SIGCONT is a statement about the
            // clock continuing from exactly where it stopped, not a second resume.
            break
        }
    }

    private func deliver(_ request: PromptRequest, context: DeveloperContext, now: Date) {
        let messageContext = MessageContext(
            developer: context,
            escalation: request.level,
            settings: settings,
            streaks: [
                .skippedToday: tracker.session.skippedBreakCount,
                .skippedConsecutive: day.consecutiveIgnoredCycles,
                .takenToday: tracker.session.breakCount,
            ]
        )
        let message = messages.select(for: messageContext).message
        if request.channel == .panel {
            // Escalation 4 — SIGSTOP. The ladder's last rung is a panel the app draws
            // itself, not a louder notification (docs/BREAK-DECISION.md §7.5). It is
            // dismissible, non-modal, never key-window-stealing and never fullscreen, and
            // the engine has already downgraded it to a notification on low battery.
            overlay.presentPromptPanel(request, message: message, model: self)
        } else {
            notifier.deliver(request, message: message)
        }
        append(.breakPrompt(at: now, cycle: request.cycle, reason: request.signal))
    }

    private func wireNotifier() {
        notifier.onResponse = { [weak self] response in
            guard let self else { return }
            switch response {
            case .take:   self.acceptBreak()
            case .snooze: self.snooze()
            case .skip:   self.skip()
            }
        }
        notifier.onStateChange = { [weak self] state in
            self?.notificationState = state
        }
        // docs/PRIVACY.md §3.2: if notifications are unavailable or refused, the app draws
        // its own borderless panel. It needs no permission, and it is strictly more
        // intrusive — so it exists as a fallback and never as the default.
        notifier.onFallbackNeeded = { [weak self] request, message in
            guard let self else { return }
            self.overlay.presentPromptPanel(request, message: message, model: self)
        }
    }

    // MARK: - Logging

    private func openStore() {
        do {
            let store = try FileEventStore(root: AppPaths.storageRoot)
            self.store = store
            // Retention is enforced at launch rather than by a background timer: the only
            // moment that matters is before anything new is written.
            try store.prune(retentionDays: Retention.defaultEventDays, asOf: time.now)
            lastStoreError = nil
        } catch {
            store = nil
            lastStoreError = "Could not open \(AppPaths.storageRoot.path) — \(error)"
        }
    }

    private func append(_ event: LoggedEvent) {
        guard let store else { return }
        do {
            try store.append(event)
        } catch {
            lastStoreError = "Could not write the event log — \(error)"
        }
    }

    /// Maps the tracker's report of the tick onto the log vocabulary.
    ///
    /// Only the transitions the rollup needs are written here. Lock, sleep and session
    /// events are written where they actually happen, from the system collector's stream,
    /// because a notification carries the real timestamp while a tick only carries the
    /// time we noticed.
    private func record(sessionEvents: [SessionEvent], at now: Date) {
        for event in sessionEvents {
            switch event {
            case .clockPaused(let cause, let since):
                guard idleBeganAt == nil, cause != .breakActive, cause != .userPaused else { continue }
                idleBeganAt = since
                append(.idleBegin(at: since))
            case .clockResumed:
                guard let began = idleBeganAt else { continue }
                idleBeganAt = nil
                append(.idleEnd(at: now, idleSeconds: Int(now.timeIntervalSince(began).rounded())))
                // Coming back from a gap is a moment the user has already broken their own
                // concentration — which is exactly what a seam is.
                seamsForNextStep.insert(.idleBlip)
            case .sessionStarted(_, let at):
                append(.start(at: at))
            case .sessionEnded(_, let at):
                append(.stop(at: at))
            default:
                continue
            }
        }
    }

    private func logFocusIfNeeded(context: DeveloperContext, sample: ContextSample, at now: Date) {
        let bundle = context.application.bundleID
        let appChanged = loggedApp.map { $0 != bundle } ?? true
        let activityChanged = loggedActivity != context.activity
        let stale = lastFocusLogAt.map { now.timeIntervalSince($0) >= Self.focusHeartbeat } ?? true
        guard appChanged || activityChanged || stale else { return }

        loggedApp = .some(bundle)
        loggedActivity = context.activity
        lastFocusLogAt = now
        append(
            .focus(
                at: now,
                app: bundle,
                category: Self.category(for: bundle),
                activity: context.activity,
                // `sig` is reserved for the five-value window-title CLASSIFICATION
                // (docs/PRIVACY.md §4.3), and the Tier 1 classifier is not wired up yet.
                // So it stays nil. Writing "readable"/"unavailable" here would have been
                // easy and would have put a private vocabulary into a field whose meaning
                // is documented — a reader would have no way to tell the difference.
                //
                // The title itself is never written under any circumstances: there is no
                // field in `LoggedEvent` that could hold one (CLAUDE.md §4.4).
                titleSignal: nil
            )
        )
        _ = sample
    }

    /// The coarse bucket in the log: the five values from docs/PRIVACY.md §4.3, derived
    /// from the bundle identifier alone, which is a Tier 0 OS fact.
    ///
    /// Design tools land in `other`, not `write`. Figma is not writing, and a bucket that
    /// is wrong is worse than a bucket that admits it does not know.
    static func category(for bundleID: String?) -> String {
        switch AppKey(bundleID: bundleID).family {
        case .aiEditor, .editor, .ide, .terminal, .containers: return "code"
        case .browser:                                         return "browse"
        case .chat:                                            return "meet"
        case .design, .other:                                  return "other"
        }
    }

    // MARK: - View state

    private func publishViewState(
        sample: ContextSample, context: DeveloperContext, outcome: EngineOutcome
    ) {
        continuousWork = context.continuousWork
        timeSinceLastBreak = context.timeSinceLastBreak
        applicationName = context.application.localizedName
        activityLabel = sample.honestLabel ?? context.claimableActivity.displayName
        confidence = context.confidence.value
        evidenceLines = context.evidence
            .sorted { abs($0.logOdds) > abs($1.logOdds) }
            .map { EvidenceLine(id: $0.id.rawValue, summary: $0.summary, logOdds: $0.logOdds, tier: $0.tier) }
        caveats = sample.caveats
        engineStateName = engineState.name
        permissionStatus = sensors.permissions.status()

        // When the decision engine computed no verdict this step, the context engine's own
        // gate is the honest answer: it is where the OS facts are actually read.
        if outcome.verdict == nil {
            gateReason = sample.gate.allowsPrompt ? nil : sample.gate.reason
        }

        if case .quiet(let q) = engineState, q.cause == .userPaused {
            pausedUntil = q.until
        } else {
            pausedUntil = nil
        }

        refreshRollup(force: false)
    }

    /// Recomputes today's summary from the log. Throttled, because it re-reads up to three
    /// day files and only the menu ever looks at it.
    func refreshRollup(force: Bool) {
        let now = time.now
        if !force, let last = rollupComputedAt, now.timeIntervalSince(last) < 60 { return }
        rollupComputedAt = now
        guard let store else { return }
        let today = CalendarDay.local(
            of: now, calendar: .current, boundaryHour: BreakPolicy.default.dayBoundaryHour
        )
        guard let summary = try? DailyRollup.compute(day: today, from: store) else { return }
        todaySummary = summary
        let narrator = SummaryNarrator(tone: settings.tone)
        // Seeded by the day, so reopening the menu does not reshuffle the sentence, and a
        // new day does not repeat yesterday's.
        let seed = UInt64(bitPattern: Int64(today.year * 10_000 + today.month * 100 + today.day))
        todayLine = narrator.line(for: summary, seed: seed)
        todayDetail = narrator.detail(for: summary)
    }

    // MARK: - Data commands, wired to the Store

    func exportData(to destination: URL) -> String {
        guard let store else { return "There is no event log to export." }
        do {
            return try store.export(to: destination).userFacingSummary
        } catch {
            return "Export failed — \(error)"
        }
    }

    func deleteEverything() -> String {
        guard let store else { return "There is nothing stored to delete." }
        do {
            let report = try store.deleteEverything()
            try? FileManager.default.removeItem(at: AppPaths.settingsFile)
            todaySummary = nil
            todayLine = ""
            todayDetail = ""
            refreshRollup(force: true)
            return report.userFacingSummary
        } catch {
            return "Delete failed — \(error)"
        }
    }

    /// Opens System Settings at the Accessibility pane.
    ///
    /// This is the *only* permission affordance in the app, and it deliberately does not
    /// call `AXIsProcessTrustedWithOptions` with the prompt option. macOS shows that alert
    /// once per process, ever; a "Grant" button that silently does nothing the second time
    /// is worse than a button that takes you to the switch. Nothing on any timer or launch
    /// path can reach a system prompt (CLAUDE.md §4.2).
    func openAccessibilitySettings() {
        sensors.permissions.openAccessibilitySettings(.clickedButton("Open System Settings"))
    }

    func refreshPermissions() {
        sensors.permissions.refresh()
        permissionStatus = sensors.permissions.status()
    }

    // MARK: - Event subscriptions

    private func subscribeToSystemEvents() {
        let stream = sensors.system.events
        observerTasks.append(
            Task { [weak self] in
                for await event in stream {
                    guard let self else { return }
                    self.handle(systemEvent: event)
                }
            }
        )
    }

    private func handle(systemEvent event: SystemEvent) {
        let at = event.timestamp
        switch event {
        case .screenLocked:
            append(.system(at: at, .lock))
        case .screenUnlocked:
            append(.system(at: at, .unlock))
            seamsForNextStep.insert(.idleBlip)
        case .willSleep:
            append(.system(at: at, .sleep))
            sensors.audio.setSystemAwake(false)
        case .didWake:
            append(.system(at: at, .wake))
            sensors.audio.setSystemAwake(true)
            sensors.frontmost.reconcile()
            sensors.system.reconcile()
            refreshPermissions()
        case .displaysSlept:
            append(.system(at: at, .sleep))
        case .displaysWoke:
            append(.system(at: at, .wake))
            sensors.system.reconcile()
        case .sessionResignedActive:
            append(.system(at: at, .sessionOut))
        case .sessionBecameActive:
            append(.system(at: at, .sessionIn))
            sensors.system.reconcile()
        case .thermalStateChanged, .powerStateChanged:
            break
        }

        // Anything that invalidates accumulated elapsed time is reported to the tracker, so
        // the next gap is labelled a sleep rather than a starved timer. The durations are
        // identical either way: the tracker diffs monotonic timestamps across the gap and
        // never trusts the tick count (CLAUDE.md §3.4).
        if event.invalidatesElapsedTime {
            tracker.noteSystemWake()
        }

        Task { [weak self] in await self?.tick() }
    }

    private func subscribeToWorkspaceEvents() {
        let stream = sensors.frontmost.events
        observerTasks.append(
            Task { [weak self] in
                for await event in stream {
                    guard let self else { return }
                    if case .activated = event {
                        // Switching app is the cheapest, most reliable seam there is.
                        self.seamsForNextStep.insert(.applicationSwitch)
                        // Accessibility can be revoked at any moment and macOS posts no
                        // notification when it is; re-checking here is a cheap,
                        // non-prompting call.
                        self.refreshPermissions()
                    }
                }
            }
        )
    }

    /// A log that ends without a `stop` line is a log the rollup has to guess about: it
    /// closes the timeline at the last event it saw, which silently drops the final
    /// stretch of the day. Quitting is the one moment we can be sure about, so we say so.
    private func subscribeToTermination() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in self?.stop() }
        }
    }

    private func subscribeToPermissionChanges() {
        let stream = sensors.permissions.stream
        observerTasks.append(
            Task { [weak self] in
                for await _ in stream {
                    guard let self else { return }
                    self.permissionStatus = self.sensors.permissions.status()
                }
            }
        )
    }

    // MARK: - Copy

    /// The verdict, in the user's words. Never a raw enum case: the menu's "why do you
    /// think that?" is the same promise `--doctor` makes.
    static func explain(_ verdict: InterruptionVerdict) -> String? {
        switch verdict {
        case .deliver:
            return nil
        case .hardBlocked(let block):
            switch block {
            case .audioInputInUse:        return "an audio input device is running — you may be on a call"
            case .cameraInUse:            return "the camera is in use"
            case .screenBeingShared:      return "your screen is being shared"
            case .presentationFullscreen: return "something fullscreen looks like a presentation"
            case .focusModeActive:        return "a Focus mode is on"
            case .screenLocked:           return "the screen is locked"
            case .systemSleeping:         return "the machine is asleep"
            case .fastUserSwitched:       return "someone else is signed in at the console"
            case .settleInAfterBreak:     return "you just got back — settling in"
            case .videoEventInProgress:   return "a video meeting is in progress"
            case .imminentMeeting:        return "a meeting starts in a moment"
            }
        case .softDeferred(let reason):
            switch reason {
            case .deepFocus:               return "you look deep in it — waiting for a seam"
            case .typingBurst:             return "you are mid-burst — waiting for a pause"
            case .terminalCommandRunning:  return "a command is still running"
            case .preMeetingWindow:        return "a meeting is close — waiting"
            case .recentAppLaunch:         return "you just switched app — waiting a moment"
            case .inferredMeeting:         return "a conferencing app is up, so you might be in a meeting"
            case .calendarEventInProgress: return "a calendar event is in progress"
            }
        case .rateLimited(let limit):
            switch limit {
            case .quietHours:           return "quiet hours"
            case .dailyCapReached:      return "today's notification budget is spent — passive only from here"
            case .cycleNotificationCap: return "this cycle has had its notifications"
            case .minimumSpacing:       return "too soon after the last one"
            case .ignoreBackoff:        return "these have been going unanswered, so the ladder is shortened"
            }
        }
    }
}
