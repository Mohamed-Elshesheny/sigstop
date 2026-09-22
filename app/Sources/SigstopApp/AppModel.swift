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
/// any part of this file leaked back into `SigstopCore`, a notification posted from the
/// engine, a window opened from the tracker, the state machine would stop being a table
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

    /// How long "the input device is running and nothing on this Mac has it" has to hold
    /// still before it is allowed to drop the hard block.
    ///
    /// CoreAudio's per-object `IsRunningInput` listener and the device property are two
    /// different notifications and their relative latency is unmeasured. If attribution
    /// lags the device bit by even a second, a rule that reads "running but unheld" would
    /// fire at the start of every real call. Six ticks costs a stuck Mac half a minute
    /// and costs a real call nothing.
    static let unheldDeviceDwell: TimeInterval = 30

    // MARK: - Observable view state

    private(set) var continuousWork: TimeInterval = 0
    /// When `continuousWork` was last measured, on the monotonic clock.
    ///
    /// Sampling runs every five seconds because sampling more often would cost battery for
    /// no extra knowledge. A clock that only moves when a sample lands therefore jumps in
    /// five second steps, which reads as a broken counter rather than a cheap one. The
    /// panel uses this to carry the number forward between samples; the value the engine
    /// acts on is still only ever the measured one.
    private(set) var continuousWorkMeasuredAt: Double = 0
    private(set) var timeSinceLastBreak: TimeInterval?
    private(set) var activityLabel: String = "starting up"
    /// Empty until the first sample lands. The panel draws nothing for it rather than a
    /// placeholder, because there is no application to name yet.
    private(set) var applicationName: String = ""
    private(set) var confidence: Double = 0
    private(set) var evidenceLines: [EvidenceLine] = []
    private(set) var caveats: [String] = []
    /// The last successful branch read, or nil with `gitStatusLine` saying why not.
    private(set) var gitReading: GitReading?
    /// "not sampled yet" until the first tick, which is about five seconds after launch.
    ///
    /// It started at "off, nothing is read", which is a claim rather than an absence, and
    /// the Access pane draws it under a row whose state says *on*. Anyone who opened
    /// Settings in the first few seconds read the app contradicting itself. The sentinel
    /// now says what is actually true at that moment: nothing has been measured.
    private(set) var gitStatusLine: String = "not sampled yet"
    /// The one line the panel always shows: what the app is waiting for, and when.
    ///
    /// Total over the engine's state space, because silence by design and silence by
    /// defect look identical from the outside and the second one is never reported. See
    /// `WaitingLine`, which computes it in `Core` where it can be tested.
    private(set) var waiting: WaitingLine = WaitingLine(.notAskingYet, "starting up")
    /// The middle of `waiting`, kept separately only because `--doctor` prints it.
    private(set) var holdReason: String?
    /// The continuous work the engine is **actually** waiting for, which is not always
    /// the user's interval.
    ///
    /// The header used to divide by `settings.workInterval` unconditionally, so a skip
    /// that privately re-armed at 1505 seconds still drew `18:17 / 5:00` with the mark
    /// pinned full. The number on screen is now the number in force.
    private(set) var workTarget: TimeInterval
    /// `false` when no work threshold is in force at all, which is the cooldown after an
    /// unanswered opportunity: that wait is a wall-clock one and the work clock is not
    /// counting towards anything. The header hides the denominator rather than inventing
    /// a threshold nobody is waiting for; the time is on the line below instead.
    private(set) var workTargetInForce = true
    private(set) var indicator: IndicatorState = .working
    private(set) var engineStateName: String = "working"
    /// Which quiet the engine is in, when it is in one.
    ///
    /// The menu had only `engineStateName`, so all four causes drew as "quiet hours" —
    /// including `dailyCapReached`, which is terminal until the day boundary, for a user
    /// whose quiet hours are off.
    private(set) var quietCause: QuietCause?
    private(set) var todaySummary: DailySummary?
    private(set) var todayLine: String = ""
    private(set) var todayDetail: String = ""
    /// Which of the ten badges have unlocked, and when. Read by Settings → Badges.
    private(set) var badges: BadgeLedger = .empty
    /// The tally behind the ten, so a locked row can say how far along it is. Kept
    /// beside the ledger rather than recomputed in the view: it is the same arithmetic
    /// the evaluator already does, and doing it twice is how the two come to disagree.
    private(set) var badgeEvidence: BadgeEvidence = BadgeEvidence()
    /// One line for the panel footer when something unlocked while the app was running,
    /// cleared once the user has been to look. Deliberately not a panel and not a sound:
    /// this app interrupts for exactly one thing, and a badge is not it.
    private(set) var badgeNote: String?
    private(set) var breakEndsAt: Date?
    private(set) var breakContent: BreakContent?
    private(set) var snoozeUntil: Date?
    private(set) var pausedUntil: Date?
    private(set) var permissionStatus: PermissionStatus
    private(set) var lastStoreError: String?
    /// Why the current prompt could not be put on screen, in the user's words. `nil`
    /// while every prompt this session either reached the screen or is still being
    /// retried within its first attempts.
    private(set) var promptDeliveryFailure: String?
    private(set) var notificationState: NotificationAvailability = .notYetNeeded
    private(set) var settings: SigstopSettings

    /// Set by the status item controller so it can re-apply the Dock policy.
    var onSettingsChanged: (() -> Void)?
    /// Separate from `onSettingsChanged` because only the owner of the status item can
    /// pin its button out of the app-wide appearance, and `AppModel` does not hold it.
    var onAppearanceChanged: ((AppearancePreference) -> Void)?
    private(set) var isRunning = false

    /// 0…1, how full the menu bar bars are drawn. The fraction of the target interval
    /// that has actually been *worked*, clamped, never extrapolated.
    var workFraction: Double {
        guard workTarget > 0 else { return 0 }
        return min(1, max(0, displayedContinuousWork / workTarget))
    }

    /// `continuousWork` carried forward to now, for display only.
    ///
    /// Only advances while the clock is actually running: on a break, idle, paused or in
    /// quiet hours the last measured value is shown unchanged, because inventing seconds
    /// the engine has not credited is exactly the lie this project does not tell.
    var displayedContinuousWork: TimeInterval {
        guard indicator == .working || indicator == .breakDue || indicator == .escalating
            || indicator == .held || indicator == .backedOff else {
            return continuousWork
        }
        guard continuousWorkMeasuredAt > 0 else { return continuousWork }
        let elapsed = time.continuousSeconds - continuousWorkMeasuredAt
        guard elapsed > 0, elapsed < 60 else { return continuousWork }
        return continuousWork + elapsed
    }

    var isOnBreak: Bool { breakEndsAt != nil }

    /// The words the menu bar mark can carry, for anyone who hovers.
    ///
    /// The icon is the only thing visible without opening anything, and one bit of
    /// opacity cannot say *why* it is quiet. This can, it costs nothing, and hovering is
    /// the cheapest thing an irritated person does before deciding an app is broken.
    ///
    /// Every deadline in it is a wall-clock time and the one duration in it is to the
    /// minute. That is deliberate: this string is read inside the icon's
    /// `withObservationTracking` block, so anything ticking per second here would be a
    /// redraw per second.
    var iconTooltip: String {
        "\(MenuBarIcon.label(for: indicator)). \(waiting.text.prefix(1).uppercased())"
            + "\(waiting.text.dropFirst())"
    }

    /// True only while a cycle is actually open. Snoozing with nothing pending is a
    /// no-op in the engine, so the menu does not offer it.
    private(set) var canSnooze = false

    /// What Tier 2 read from `.git/HEAD` last time, in full, for Settings → Access.
    ///
    /// `--doctor` prints the branch as a length rather than a name, because the bug form
    /// asks people to paste `--doctor` into public issues (docs/PRIVACY.md §8.12). That
    /// redaction is only defensible if there is somewhere the user can see what was
    /// actually read, on their own machine, where it is not going anywhere. This is that
    /// place. It existed as a sentence in `--doctor` and in PRIVACY §8.12 for a while
    /// before it existed as a pane, which made both of them false.
    struct GitReading: Hashable, Sendable {
        let folder: String
        /// `nil` is a detached HEAD, which is not a branch and is not shown as one.
        let branch: String?
        let repoState: RepoState?
        let route: String

        var branchText: String { branch ?? "detached HEAD, no branch to name" }
        var stateText: String? {
            guard let repoState, repoState != .clean else { return nil }
            return "mid-\(repoState.rawValue)"
        }
    }

    struct EvidenceLine: Identifiable, Hashable, Sendable {
        let id: String
        let summary: String
        let logOdds: Double
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
    /// its state directly, the progress bar is the object's own `state`, not a copy.
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
    /// The thresholds in force, kept so the view layer can say when the engine is waiting
    /// for something other than the user's interval.
    /// Readable by the settings pane, which has to show what the daily cap came out to
    /// after `BreakPolicy` scaled it against the interval.
    @ObservationIgnored private(set) var policy: BreakPolicy
    @ObservationIgnored private var store: FileEventStore?

    // MARK: - Loop state (never observed)

    @ObservationIgnored private var engineState: EngineState
    /// The day's budgets. Loaded from the store at launch and written back when they
    /// change, because a value reconstructed on every launch is not a daily cap.
    @ObservationIgnored private var day = DailyCounters()
    /// The last counters handed to the store, so a tick that changed nothing does not
    /// rewrite the file.
    @ObservationIgnored private var persistedDay: DailyCounters?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var observerTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pendingAction: UserAction?
    /// True while a pass of the loop is in flight. See `tick()`.
    @ObservationIgnored private var ticking = false
    /// Set when a tick arrives during one, so the running pass repeats rather than a
    /// second pass starting alongside it.
    @ObservationIgnored private var tickAgain = false
    @ObservationIgnored private var currentCycle: CycleID?
    /// Decides when the gate's answer is worth a line. See `VerdictLedger`.
    @ObservationIgnored private var verdicts = VerdictLedger()
    @ObservationIgnored private var loggedApp: String??
    @ObservationIgnored private var loggedActivity: Activity?
    @ObservationIgnored private var lastFocusLogAt: Date?
    @ObservationIgnored private var idleBeganAt: Date?
    @ObservationIgnored private var seamsForNextStep: Set<Seam> = []
    /// The call latch. Owned here rather than on `EngineState` because `verdict` is
    /// handed only an `EngineInput` and a `CycleBudget`, and rather than inside
    /// `InterruptionPolicy` because that struct is stateless and pure. Every transition
    /// still lives in `SigstopCore`, which is what makes it testable at all.
    ///
    /// It is never persisted: a latch restored from disk is a suppression that can
    /// outlive the bug that created it, invisibly. Only the day's accumulated hold
    /// survives a relaunch, because a counter can only ever make the app noisier.
    @ObservationIgnored private var latch = MeetingLatch()
    @ObservationIgnored private var lastPersistedHold: TimeInterval = 0
    /// Monotonic deadline for "I told you this is not a call", which suppresses the live
    /// input-device hard block as well as the latch. Never persisted, for the same reason
    /// the latch is not.
    @ObservationIgnored private var micInhibitUntilMono: Double = 0
    /// The same deadline on the wall clock, so the panel can say when it runs out.
    @ObservationIgnored private var micInhibitUntil: Date?
    /// When the process table first said nothing at all holds the running input device.
    @ObservationIgnored private var unheldDeviceSince: Double?
    /// The raw device bit at the last sample, so the panel can confirm that "not a call"
    /// is doing something while the device is still open.
    @ObservationIgnored private var lastAudioDeviceRunning = false
    /// The verdict the engine last acted on, so the presentation layer cannot put a
    /// prompt on screen that the engine has already refused.
    @ObservationIgnored private var lastVerdict: InterruptionVerdict?
    @ObservationIgnored private var rollupComputedAt: Date?
    /// The last summary handed to the store, so a minute that changed nothing does not
    /// rewrite the month file.
    @ObservationIgnored private var lastWrittenSummary: DailySummary?

    /// The prompt the app is currently responsible for having on screen, and whether the
    /// window server has confirmed it. See `verifyPromptPresentation()`.
    @ObservationIgnored private var presentation: PromptPresentation?

    /// Attempts before the failure is surfaced in the panel. Retries continue on every
    /// tick regardless; the number only decides when to stop being quiet about it.
    private static let promptAttemptsBeforeComplaining = 3

    private struct PromptPresentation {
        let request: PromptRequest
        var attempts: Int
        /// Set when the window server reported the panel on screen, or immediately for a
        /// macOS notification, which the app cannot see and therefore takes on trust.
        var verifiedAt: Date?
    }

    // MARK: - Init

    init() {
        let loaded = SettingsStore.load()
        let policy = Self.policy(for: loaded)

        self.settings = loaded
        self.policy = policy
        self.workTarget = policy.targetContinuousWork
        self.sensors = SensorStack(settings: loaded, time: time, workClock: workClock)
        self.tracker = SessionTracker(time: time, policy: policy)
        self.decision = BreakDecisionEngine(policy: policy)
        self.engineState = .initial(policy: policy)
        self.permissionStatus = sensors.permissions.status()

        let dayIndex = LocalDay.index(
            of: time.now, calendar: .current, boundaryHour: policy.dayBoundaryHour
        )
        self.latch = MeetingLatch
            .started(at: time.continuousSeconds, wall: time.now, dayIndex: dayIndex)
            .restoringDailyHold(seconds: CallHoldLedger.load(dayIndex: dayIndex), dayIndex: dayIndex)
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
        observeAccessibilityGrant()
        guard !isRunning else { return }
        isRunning = true

        wireNotifier()
        openStore()
        append(.start(at: time.now))

        sensors.context.start()
        sensors.startExtraCollectors()
        subscribeToSystemEvents()
        subscribeToWorkspaceEvents()
        subscribeToWindowChanges()
        subscribeToPermissionChanges()
        subscribeToTermination()

        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: .seconds(self.secondsUntilNextTick()))
            }
        }
    }

    /// How long to sleep before the next tick.
    ///
    /// Normally the full interval. But a break ending, a snooze expiring and a pause
    /// running out are **known instants**, and sleeping past one of them means the app
    /// notices it late by up to the whole interval. That is visible, and it was reported:
    /// the overlay sat on 0:00 for a few seconds before closing, and the work counter in
    /// the panel did not start moving again until the tick after the break had already
    /// ended.
    ///
    /// Waking exactly on the deadline instead is not polling and costs nothing: it is the
    /// same number of wakeups, moved. The floor keeps a deadline that has just passed from
    /// spinning the loop.
    private func secondsUntilNextTick() -> TimeInterval {
        let now = time.now
        var deadlines = [breakEndsAt, snoozeUntil, pausedUntil]
            .compactMap { $0 }
            .map { $0.timeIntervalSince(now) }
            .filter { $0 > 0 }

        /// The work target is a known instant too, and it was the one missing.
        ///
        /// The three above are wall-clock deadlines; this one is on the work clock, which
        /// is why it was overlooked. The effect was the same and it was reported the same
        /// way: at a five minute interval the panel sat on `5:04 / 5:00` and the prompt
        /// arrived four seconds after it was due, because the engine only asks whether
        /// `continuousWork >= armThreshold` when it happens to wake, and it was waking on
        /// a five second cadence that has nothing to do with when the target falls.
        ///
        /// The prediction is only right while the user keeps working, which is exactly
        /// when it matters. Go idle and the clock stops, the wake-up finds the target not
        /// met, and it sleeps again — the cost of being wrong is one wake-up that does
        /// nothing, and `max(0.25,)` keeps a deadline that has just passed from spinning.
        if workTargetInForce, continuousWork < workTarget {
            deadlines.append(workTarget - continuousWork)
        }

        guard let soonest = deadlines.min() else { return Self.tickInterval }
        return max(0.25, min(Self.tickInterval, soonest))
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
        sensors.stopExtraCollectors()
        append(.stop(at: time.now))
    }

    // MARK: - User actions

    func takeBreakNow() { enqueue(.startBreakNow) }
    func acceptBreak() { enqueue(.acceptBreak) }
    func snooze() { enqueue(.snooze) }

    /// SIGTSTP, caught. The prompt goes off the screen and the engine is told **nothing**.
    ///
    /// This is what ignoring means in this codebase: the prompt stands, times out after
    /// `promptTimeout`, is recorded as `ignored`, and the ladder climbs. It is the cheap
    /// answer and it costs the user nothing they cannot undo by waiting ninety seconds.
    ///
    /// Escape and the button that says "Ignore it" used to call `skip()` instead, which
    /// is the most expensive response in the state machine: it ends the cycle and buys
    /// twenty minutes of silence. A control labelled ignore that does not ignore is how
    /// the 20:06:51Z incident started.
    func ignorePrompt() { overlay.dismissPromptPanel() }

    /// A deliberate no. Ends this opportunity and re-arms twenty minutes late.
    func skip() { enqueue(.skip) }
    func endBreak() { enqueue(.endBreak) }
    func pause(for duration: TimeInterval) { enqueue(.pauseApp(duration)) }
    func resume() { enqueue(.resumeApp) }

    private func enqueue(_ action: UserAction) {
        pendingAction = action
        Task { [weak self] in await self?.tick() }
    }

    /// `SIGHUP`, re-read the config. A changed work interval or tone takes effect on the
    /// next sample, not at the next launch.
    func update(settings newValue: SigstopSettings) {
        guard newValue != settings else { return }
        settings = newValue
        SettingsStore.save(newValue)
        onSettingsChanged?()
        let previousTarget = policy.targetContinuousWork
        policy = Self.policy(for: newValue)
        decision = BreakDecisionEngine(policy: policy)
        /// The running state holds its own copy of the threshold; move it too, or the
        /// panel keeps counting to the interval you just changed away from.
        engineState = engineState.retargeted(from: previousTarget, to: policy.targetContinuousWork)
        sensors.context.reloadSettings(newValue)
        permissionStatus = sensors.permissions.status()
        if !newValue.showBreakOverlay { overlay.dismissBreak() }
        onAppearanceChanged?(newValue.appearance)
    }

    // MARK: - The tick

    /// One pass of the loop, and never two at once.
    ///
    /// `enqueue` fires an extra tick on top of the five second timer so a button press
    /// takes effect immediately. Being on the main actor is not enough to serialise them:
    /// `tickOnce` awaits `sampleAndPublish()`, and two ticks can interleave across that
    /// suspension. Whichever resumed first consumed `pendingAction` and finished the
    /// break, and the other then ran the working state against a session clock that had
    /// not been reset yet and opened a fresh cycle in the same second.
    ///
    /// That is in the owner's log twice: `break_end dur_s=303` at 18:52:20Z followed by
    /// `break_open` and `break_prompt` at 18:52:20Z, and the identical pattern at
    /// 19:06:40Z. The `breakEndedThisTick` guard in the engine cannot help, because these
    /// are two separate steps.
    ///
    /// A tick that arrives while one is running sets a flag instead of starting a second
    /// pass, and the running one loops again before it returns, so no press is lost.
    private func tick() async {
        if ticking {
            tickAgain = true
            return
        }
        ticking = true
        /// The flag is the one piece of state that can stop the whole app on its own: a
        /// pass that never clears it turns every later tick into an immediate return at
        /// the guard above, the work clock stops advancing, and nothing says so. It is
        /// cleared on every exit from here, and the awaits inside `tickOnce` are each
        /// bounded at their source (AX messaging timeout, the git collector's deadline)
        /// so that "never returns" is not reachable in the first place.
        defer { ticking = false }
        repeat {
            tickAgain = false
            await tickOnce()
        } while tickAgain
    }

    private func tickOnce() async {
        let sample = await sensors.context.sampleAndPublish()
        let raw = sensors.readSignals()
        let now = time.now
        let monotonic = time.continuousSeconds

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

        advanceLatch(raw, now: now, monotonic: monotonic)

        lastAudioDeviceRunning = raw.audio.contributesToMeeting
        var signals = raw.systemSignals
        signals.audioInputRunning = audioBlocks(raw, monotonic: monotonic)
        signals.frontmostIsFullscreen = sample.context.concurrent.fullscreen
        signals.meetingLatch = latchSignal(now: now, monotonic: monotonic)

        let input = EngineInput(
            now: now,
            monotonic: monotonic,
            context: context,
            signals: signals,
            settings: settings,
            calendarSystem: .current,
            calendar: nil,
            seams: Array(seamsForNextStep),
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

        let openBefore = engineState.openCycle
        let outcome = decision.step(engineState, input)
        engineState = outcome.state
        day = outcome.day

        if let line = verdicts.observe(
            outcome.verdict.map(GateReason.init),
            holding: engineState.silence,
            cycle: openBefore, at: now, monotonic: monotonic
        ) {
            append(line)
        }

        for effect in outcome.effects {
            execute(effect, context: context, now: now)
        }
        verifyPromptPresentation()

        record(sessionEvents: sessionEvents, at: now)
        persistCountersIfChanged()
        logFocusIfNeeded(context: context, sample: sample, at: now)
        publishViewState(sample: sample, context: context, outcome: outcome)
    }

    private var isPaused: Bool {
        if case .quiet(let q) = engineState, q.cause == .userPaused { return true }
        return false
    }

    // MARK: - The call latch

    private var latchPolicy: BreakPolicy { Self.policy(for: settings) }

    private func dayIndex(at now: Date) -> Int {
        LocalDay.index(
            of: now, calendar: .current, boundaryHour: latchPolicy.dayBoundaryHour
        )
    }

    private func advanceLatch(_ raw: RawSignals, now: Date, monotonic: Double) {
        let before = latch.heldSecondsToday
        latch = latch.advanced(
            MeetingLatchInput(
                monotonic: monotonic,
                wall: now,
                dayIndex: dayIndex(at: now),
                micLive: raw.micLiveForLatch,
                cameraLive: raw.camera.contributesToMeeting,
                liveCaptureAlreadyBlocks: raw.liveCaptureAlreadyBlocks,
                callCapableRunning: raw.callCapableRunning,
                attributedCallCapable: raw.attributedCallCapable,
                frontmostCallCapable: raw.frontmostCallCapable,
                enabled: settings.holdBreaksDuringCalls,
                screenLocked: raw.session.screenLocked,
                sessionActive: raw.session.sessionActive
            ),
            policy: latchPolicy
        )
        if latch.heldSecondsToday - lastPersistedHold >= 60 || latch.heldSecondsToday < before {
            lastPersistedHold = latch.heldSecondsToday
            CallHoldLedger.save(seconds: latch.heldSecondsToday, dayIndex: latch.dayIndex)
        }
    }

    private func latchSignal(now: Date, monotonic: Double) -> MeetingLatchSignal {
        latch.signal(at: monotonic, wall: now, policy: latchPolicy)
    }

    /// The menu bar's "why?" line, when the app is holding a break for a call.
    var callHoldSummary: String? {
        latchSignal(now: time.now, monotonic: time.continuousSeconds).summary
    }

    /// True while a live input device, and not the latch, is what is holding a break.
    ///
    /// The panel offered "I'm in a meeting" here, which is the opposite of what the line
    /// above it says, because `callHoldSummary` is nil when the latch correctly declined
    /// to arm on a device nobody is using.
    var inputDeviceIsHoldingABreak: Bool {
        guard case .hardBlocked(.audioInputInUse) = lastVerdict else { return false }
        return callHoldSummary == nil
    }

    var ignoreInputDeviceLabel: String {
        "Ignore this input device · \(DurationText.short(latchPolicy.latchManualInhibit))"
    }

    /// "I'm in a meeting". The only answer available for the states no Tier 0 signal can
    /// reach: a Meet call in Safari, a screen share with the microphone muted, and a
    /// phone dial-in while presenting from the Mac.
    func assertMeeting() {
        latch = latch.assertedByUser(at: time.continuousSeconds, policy: latchPolicy)
        Task { [weak self] in await self?.tick() }
    }

    /// "Not in a meeting". Closes the latch and stops it re-opening from the same still
    /// running app for half an hour.
    ///
    /// It also inhibits the live-device hard block for the same half hour, which it used
    /// not to: `hardBlock` tests `audioInputRunning` before it ever reaches the latch, so
    /// on exactly the Mac where this button matters, one with a device held open by a
    /// driver or by Krisp, pressing it changed nothing and said nothing. The bound is the
    /// latch's own `latchManualInhibit`, because a mute button that never expires is what
    /// `MeetingLatch` already refuses to be.
    func clearMeetingHold() {
        latch = latch.clearedByUser(at: time.continuousSeconds, policy: latchPolicy)
        micInhibitUntilMono = time.continuousSeconds + latchPolicy.latchManualInhibit
        micInhibitUntil = time.now.addingTimeInterval(latchPolicy.latchManualInhibit)
        Task { [weak self] in await self?.tick() }
    }

    /// Does a running input device still hold a break?
    ///
    /// Three answers, and the third is the one that ends the invisible hour: a device
    /// that is running while CoreAudio's process table says nothing at all has input open
    /// is a virtual device, not a call, and the app has that table in hand. The dwell is
    /// why "nothing has it" has to stay true for half a minute first.
    private func audioBlocks(_ raw: RawSignals, monotonic: Double) -> Bool {
        switch raw.audioDeviceHold {
        case .notRunning:
            unheldDeviceSince = nil
            return false
        case .held:
            unheldDeviceSince = nil
            return monotonic >= micInhibitUntilMono
        case .runningButUnheld:
            let since = unheldDeviceSince ?? monotonic
            unheldDeviceSince = since
            guard monotonic - since >= Self.unheldDeviceDwell else {
                return monotonic >= micInhibitUntilMono
            }
            return false
        }
    }

    // MARK: - Effects

    /// Every effect, with its log lines written first and its side effects second.
    ///
    /// The mapping from effect to log line is not here any more, it is
    /// `EventLogWriter.lines(for:at:context:)` in `SigstopCore`, where it is an exhaustive
    /// switch a test can drive without a window server. What is left here is only the
    /// things that genuinely need AppKit, the tracker, or this object's own state.
    private func execute(_ effect: Effect, context: DeveloperContext, now: Date) {
        for line in EventLogWriter.lines(for: effect, at: now, context: logContext) {
            append(line)
        }

        switch effect {
        case .openCycle(let cycle):
            currentCycle = cycle

        case .closeCycle(let cycle, _):
            if currentCycle == cycle { currentCycle = nil }
            if presentation?.request.cycle == cycle { presentation = nil }
            verdicts.reset()

        case .deliverPrompt(let request):
            deliver(request, context: context, now: now)

        case .withdrawPrompt(let cycle, _):
            notifier.withdraw(cycle: cycle)
            overlay.dismissPromptPanel()
            if presentation?.request.cycle == cycle { presentation = nil }

        case .setIndicator(let state):
            indicator = state

        case .beginBreak(_, let origin, let plannedEnd):
            tracker.beginBreak(origin: origin)
            breakEndsAt = plannedEnd
            breakContent = BreakContent.make(
                for: context,
                settings: settings,
                seed: UInt64(bitPattern: Int64(now.timeIntervalSince1970.rounded()))
            )
            notifier.withdrawAll()
            overlay.dismissPromptPanel()
            presentation = nil
            if settings.showBreakOverlay { overlay.presentBreak(model: self) }

        case .endBreak(_, let origin, _, _, _):
            tracker.endBreak(origin: origin)
            overlay.dismissBreak()
            breakEndsAt = nil
            breakContent = nil
            refreshRollup(force: true)

        case .scheduleWake(let date):
            snoozeUntil = date

        case .cancelScheduledWake:
            snoozeUntil = nil

        case .recordVerdict(let verdict):
            lastVerdict = verdict

        case .recordSkip:
            tracker.recordSkip()

        case .recordIgnoredPrompt(let cycle):
            guard promptWasPresented(cycle: cycle) else { break }
            tracker.recordIgnoredPrompt()

        case .recordSnooze:
            tracker.recordSnooze()

        }
    }

    /// The only facts anything populates, and the only one derivable from what Tier 2
    /// actually reads. `hasUncommittedChanges` stays absent on purpose: `.git/HEAD` cannot
    /// answer it, and a template that needs it must stay unselectable rather than be fed a
    /// guess (CLAUDE.md §4.1).
    private static let defaultBranchNames: Set<String> = ["main", "master", "trunk"]

    private static func facts(from context: DeveloperContext) -> [FactKey: FactValue] {
        guard let branch = context.context.branch, !branch.isEmpty else { return [:] }
        return [.branchIsDefault: .bool(defaultBranchNames.contains(branch.lowercased()))]
    }

    private func deliver(_ request: PromptRequest, context: DeveloperContext, now: Date) {
        /// Decided before the line is chosen, not after, because it decides which lines
        /// may be chosen at all.
        ///
        /// A panel the app draws is a string in this process. A system notification is a
        /// string handed to `UNUserNotificationCenter`, which copies it into
        /// notificationd's own store, shows it on the lock screen and mirrors it to any
        /// attached display, and there is no API here that takes it back. The branch name
        /// is the one slot the privacy inventory calls memory-only (docs/PRIVACY.md row
        /// 31), so it does not take that route: the two corpus lines that name a branch
        /// become unselectable and something else is picked.
        let goesToTheSystem = request.channel != .panel && settings.useSystemNotifications
        let messageContext = MessageContext(
            developer: context,
            escalation: request.level,
            settings: settings,
            streaks: [
                .skippedToday: tracker.session.skippedBreakCount,
                .skippedConsecutive: day.consecutiveIgnoredCycles,
                .takenToday: tracker.session.breakCount,
            ],
            facts: Self.facts(from: context),
            withheldSlots: goesToTheSystem ? [.branch] : []
        )
        let message = messages.select(for: messageContext).message
        PromptSound.play(for: request.level, enabled: settings.promptSound)
        if !goesToTheSystem {
            presentPanel(request, message: message)
        } else {
            notifier.deliver(request, message: message)
            presentation = PromptPresentation(request: request, attempts: 1, verifiedAt: now)
            append(.breakPrompt(at: now, cycle: request.cycle, reason: request.level.signal))
        }
    }

    /// The app drawing the prompt itself, for every rung when system notifications are
    /// off and always for escalation 4 (docs/BREAK-DECISION.md §7.5). The `break_prompt`
    /// line is **not** written here: it is written by `verifyPromptPresentation()` once
    /// the window server has confirmed the panel is on screen, because the line means
    /// "this reached the screen" and the rollup holds the user to exactly that.
    ///
    /// `presentPromptPanel` returns false when there is no screen at all, which used to
    /// be discarded: the app then retried on every tick forever, never fell back, and
    /// never said so. There is nothing to fall back to in that case, so it says so
    /// instead of pretending to keep trying.
    private func presentPanel(_ request: PromptRequest, message: RenderedMessage) {
        let drawn = overlay.presentPromptPanel(request, message: message, model: self)
        presentation = PromptPresentation(request: request, attempts: 1, verifiedAt: nil)
        if !drawn {
            promptDeliveryFailure =
                "The \(request.signal) prompt has nowhere to go: this Mac reports no screen. "
                + "It is not being counted against you."
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.verifyPromptPresentation()
        }
    }

    /// Confirms the outstanding prompt against the window server, and retries when the
    /// panel is not there.
    ///
    /// Runs shortly after presentation and then on every tick until confirmed. A prompt
    /// that is never confirmed never gets a `break_prompt` line and never counts as
    /// ignored (`execute(.recordIgnoredPrompt)`), so a delivery failure shows up as a
    /// cycle the rollup excludes rather than as a miss held against the user. After a few
    /// attempts the failure is also said out loud in the dropdown.
    private func verifyPromptPresentation() {
        guard var current = presentation, current.verifiedAt == nil else { return }
        /// A correct verdict that the presentation layer ignores fixes nothing. This ran
        /// unconditionally on every tick and re-ordered a full-screen panel to the front
        /// every five seconds, consulting no verdict at all, which meant it kept shoving
        /// the panel in front for the whole of a call.
        guard canPresentNow else { return }
        let now = time.now
        if overlay.promptPanelIsOnScreen {
            current.verifiedAt = now
            presentation = current
            promptDeliveryFailure = nil
            append(
                .breakPrompt(
                    at: now, cycle: current.request.cycle, reason: current.request.level.signal
                )
            )
            return
        }
        current.attempts += 1
        presentation = current
        overlay.reassertPromptPanel()
        if current.attempts > Self.promptAttemptsBeforeComplaining {
            promptDeliveryFailure =
                "The \(current.request.signal) prompt has not reached the screen after "
                + "\(current.attempts) attempts. It is not being counted against you."
        }
    }

    /// May anything be drawn on screen right now?
    ///
    /// A hard block is the engine's answer to "never deliver". It is checked here as well
    /// as in the engine because the two routes that can put a prompt on screen without
    /// going back through `step` (the panel re-assert loop and the notifier's suppressed
    /// banner fallback) both bypass it entirely.
    private var canPresentNow: Bool {
        !(lastVerdict?.isHardBlocked ?? false)
    }

    /// Whether the prompt the engine is judging was actually seen. A prompt the window
    /// server never confirmed is not something the user can have ignored.
    private func promptWasPresented(cycle: CycleID?) -> Bool {
        guard let cycle, let presentation, presentation.request.cycle == cycle else { return false }
        return presentation.verifiedAt != nil
    }

    /// The one fact `EventLogWriter` needs and the engine cannot know.
    private var logContext: EffectLogContext {
        guard let presentation, presentation.verifiedAt != nil else { return EffectLogContext() }
        return EffectLogContext(confirmedPromptCycle: presentation.request.cycle)
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
        notifier.onFallbackNeeded = { [weak self] request, message in
            guard let self else { return }
            /// macOS withholds a banner exactly when someone is screen sharing or has a
            /// Focus on, so this fallback is at its most likely to fire during the thing
            /// the app is trying not to interrupt. It drew a full-screen panel with no
            /// re-check of the verdict; now it checks.
            guard self.canPresentNow else { return }
            self.presentPanel(request, message: message)
        }
    }

    // MARK: - Logging

    private func openStore() {
        do {
            let store = try FileEventStore(root: AppPaths.storageRoot)
            self.store = store
            badges = store.readBadges()
            if let stored = store.readCounters() {
                day = stored
                persistedDay = stored
            }
            lastStoreError = nil
        } catch {
            store = nil
            lastStoreError = "Could not open \(AppPaths.storageRoot.path), \(error)"
            return
        }
        // Pruning gets its own boundary. It ran on the same path as opening the store, so
        // one file that would not delete threw into the catch above and left `store = nil`,
        // taking logging, the badges and the restored day counters down with a cleanup
        // failure. Housekeeping does not get to disable the app; a prune that fails is noted
        // and the store stays open.
        do {
            try store?.prune(retentionDays: Retention.defaultEventDays, asOf: time.now)
        } catch {
            lastStoreError = "Could not prune old logs, \(error)"
        }
    }

    private func append(_ event: LoggedEvent) {
        guard let store else { return }
        do {
            try store.append(event)
        } catch {
            lastStoreError = "Could not write the event log, \(error)"
        }
    }

    /// Writes the day's budgets back when they have moved.
    ///
    /// Without this the counters were a fresh value on every launch, so
    /// `maxNotificationsPerDay`, the minimum spacing between notifications, the ignore
    /// backoff and the cycle numbering all reset every time the app started. On the day
    /// this was found the app had been relaunched 72 times and `break_open {cycle:0}`
    /// appears eleven times in one file. A setting the user can see and set, and which
    /// silently never binds, is worse than no setting.
    ///
    /// The engine still rolls the counters over itself when the logical day changes, so
    /// a file written yesterday cannot spend today's budget.
    private func persistCountersIfChanged() {
        guard let store, day != persistedDay else { return }
        do {
            try store.writeCounters(day)
            persistedDay = day
        } catch {
            lastStoreError = "Could not write the daily counters, \(error)"
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
        continuousWorkMeasuredAt = time.continuousSeconds
        timeSinceLastBreak = context.timeSinceLastBreak
        /// The site when Tier 1b knows one, the app otherwise; the reasoning is on the
        /// property. `--doctor` prints the same one, so it can prove what this line draws.
        applicationName = context.siteOrAppName
        activityLabel = sample.honestLabel ?? context.claimableActivity.displayName
        confidence = context.confidence.value
        evidenceLines = context.evidence
            .sorted { abs($0.logOdds) > abs($1.logOdds) }
            .map { EvidenceLine(id: $0.id.rawValue, summary: $0.summary, logOdds: $0.logOdds) }
        caveats = sample.caveats
        publishGitReading(context: context)
        engineStateName = engineState.name
        permissionStatus = sensors.permissions.status()

        /// Only the engine's own verdict feeds the line. The sensor gate used to fill in
        /// whenever no cycle was open, which meant a Mac with a stuck input device read
        /// "an audio input device is running, you may be on a call" for an hour while the
        /// app held, in the same process, a process table saying nobody had the
        /// microphone. Nothing is being held while the engine is working, so the honest
        /// line there is the work clock.
        publishHold(gate: outcome.verdict.map(GateReason.init))

        if case .quiet(let q) = engineState {
            quietCause = q.cause
            pausedUntil = q.cause == .userPaused ? q.until : nil
        } else {
            quietCause = nil
            pausedUntil = nil
        }

        refreshRollup(force: false)
    }

    /// Settings → Access answers "what did you read?" with the answer, not with a
    /// description of the answer. Every branch that produces no reading says why, because
    /// "blank" and "off" and "the folder did not answer" look identical otherwise.
    private func publishGitReading(context: DeveloperContext) {
        switch sensors.git.lastOutcome {
        case .optedOut:
            gitReading = nil
            gitStatusLine = "off, nothing is read"
        case .skipped(let reason):
            gitReading = nil
            gitStatusLine = "on, not read this sample: \(reason)"
        case .noFoldersRegistered:
            gitReading = nil
            gitStatusLine = "on, but no project folder has been added, so it reads nothing"
        case .noFolderMatched(let reason):
            gitReading = nil
            gitStatusLine = reason
        case .notPermitted(let folder):
            gitReading = nil
            gitStatusLine = "macOS refused the read in \(folder). Files and Folders, not a bug"
        case .noRepository(let folder):
            gitReading = nil
            gitStatusLine = "there is no repository at the root of \(folder)"
        case .timedOut(let folder):
            gitReading = nil
            gitStatusLine = "\(folder) did not answer in time and is being left alone until "
                + "you change the folders below"
        case .read(let folder, _, _, let route):
            gitReading = GitReading(
                folder: folder,
                branch: context.context.branch,
                repoState: context.context.repoState,
                route: route
            )
            gitStatusLine = ""
        }
    }

    /// The target the engine is really waiting for, and the one line that says what it is
    /// waiting for, in every state.
    ///
    /// This used to answer for three states and return `nil` for the rest, which meant
    /// the two worst silences in the app, a backed-off opportunity and an input device
    /// held open by a virtual driver, drew a panel that said RUNNING and nothing else.
    /// The sentence itself now comes from `WaitingLine` in `Core`, where it can be
    /// asserted against the real engine; this is only the wiring.
    private func publishHold(gate: GateReason?) {
        let monotonic = time.continuousSeconds
        workTargetInForce = true
        if case .working(let w) = engineState {
            workTarget = w.armThreshold
            if let cooldown = w.cooldownUntilMono, monotonic < cooldown { workTargetInForce = false }
        } else {
            workTarget = policy.targetContinuousWork
        }
        /// Quiet means no threshold is in force, whichever of the four causes it is.
        ///
        /// The flag was cleared only for the post-exhaustion cooldown, so in `quiet` the
        /// header kept drawing the clock against `/ 5:00` and `markFill` fell through to
        /// `min(1, continuousWork / workTarget)` and pinned the mark full. A screenshot of
        /// this read `DAILY CAP` and `12:22 / 5:00` at once: a denominator nothing was
        /// waiting for, under a heading saying nothing was coming. The wait is carried by
        /// the `waiting` line instead, which names the real reason.
        if case .quiet = engineState { workTargetInForce = false }

        waiting = WaitingLine.read(
            WaitingLine.Reading(
                state: engineState,
                gate: gate,
                continuousWork: continuousWork,
                audioInputRunning: lastAudioDeviceRunning,
                micIgnoredUntil: micInhibitUntilMono > monotonic ? micInhibitUntil : nil,
                now: time.now,
                monotonic: monotonic,
                policy: policy,
                settings: settings,
                calendar: .current,
                notificationsDelivered: day.notificationsDelivered
            )
        )
        /// A hold the user asserted by hand outranks whatever the clock was going to say.
        ///
        /// Without this the panel contradicted itself in two adjacent lines: "not asking
        /// yet, the next one is 3m of work away" above a sentence saying prompts were
        /// held. Both were true in their own terms, the work clock really was three
        /// minutes from the threshold and the hold really was in force, and neither the
        /// engine nor the gate knew about the other, because a manual hold is not a
        /// verdict until something tries to deliver.
        if let hold = latchSignal(now: time.now, monotonic: monotonic).summary,
           waiting.claim != .holdingOff {
            waiting = WaitingLine(.holdingOff, hold)
        }

        holdReason = waiting.body
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
        let seed = UInt64(bitPattern: Int64(today.year * 10_000 + today.month * 100 + today.day))
        todayLine = narrator.line(for: summary, seed: seed)
        todayDetail = narrator.detail(for: summary)
        refreshBadges(today: summary, store: store)
    }

    /// Re-evaluates the ten badges. Called from `refreshRollup` and from nowhere else, so
    /// it runs at most once a minute rather than on every five-second tick.
    ///
    /// Today's summary is persisted here too. `summaries/YYYY-MM.json` has been part of
    /// the storage layout and the privacy inventory from the start but nothing ever wrote
    /// to it; the badges are the first thing that needs a day to still be countable after
    /// its raw events have aged out of the seven-day window, and without it
    /// `[100]+ Stopped` would only ever be reachable by someone taking a hundred breaks
    /// inside one week. The file holds the same aggregates the panel already shows.
    private func refreshBadges(today: DailySummary, store: FileEventStore) {
        if lastWrittenSummary != today {
            do {
                try store.writeSummary(today)
                lastWrittenSummary = today
            } catch {
                lastStoreError = "Could not write the daily summary, \(error)"
            }
        }

        let days = badgeDays(store: store)
        guard !days.isEmpty else { return }
        // Before the guard below, deliberately. Most refreshes unlock nothing, and a
        // counter that only moved when a badge unlocked would sit at the number it had
        // when the last one did.
        badgeEvidence = BadgeEvaluator.evidence(for: days, calendar: .current, policy: .default)

        let updated = BadgeEvaluator.evaluate(
            days: days,
            calendar: .current,
            policy: .default,
            knownUnlocked: badges
        )
        guard updated != badges else { return }

        let fresh = updated.newlyUnlocked(since: badges)
        badges = updated
        try? store.writeBadges(updated)
        if let note = Self.badgeNote(for: fresh) { badgeNote = note }
    }

    /// Every logical day the app can still say anything about: the stored summaries, plus
    /// every day the event log still covers, recomputed so the four event-derived badges
    /// have something to read.
    ///
    /// Each UTC file is read once and the logical days are assembled in memory, because a
    /// logical day straddles up to three files and reading them per day would be three
    /// times the I/O for the same bytes.
    private func badgeDays(store: FileEventStore) -> [BadgeDay] {
        var byDay: [CalendarDay: BadgeDay] = [:]
        for (day, summary) in (try? store.readAllSummaries()) ?? [:] {
            byDay[day] = BadgeDay(summary: summary)
        }

        let fileDays = (try? store.availableDays()) ?? []
        var loaded: [CalendarDay: [LoggedEvent]] = [:]
        for day in fileDays {
            loaded[day] = (try? store.load(day: day).events) ?? []
        }
        var logicalDays: Set<CalendarDay> = []
        for day in fileDays {
            logicalDays.insert(day)
            logicalDays.insert(day.adding(days: -1))
        }
        for day in logicalDays.sorted() {
            let events = [day.adding(days: -1), day, day.adding(days: 1)]
                .flatMap { loaded[$0] ?? [] }
                .sorted { $0.at < $1.at }
            guard !events.isEmpty else { continue }
            byDay[day] = BadgeDay.from(day: day, events: events, policy: .default, calendar: .current)
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// The panel footer line. Names the badge when there is one and counts them when
    /// there are several, and points at where to look rather than describing it.
    private static func badgeNote(for unlocked: [BadgeID]) -> String? {
        guard let first = unlocked.first else { return nil }
        if unlocked.count == 1 {
            return "unlocked: \(Badge.badge(first).title), Settings → Badges"
        }
        return "unlocked: \(unlocked.count) badges, Settings → Badges"
    }

    /// Clears the footer note. Called when the Badges pane appears: the notice is shown
    /// until the user has been to look at it, and then never again.
    func acknowledgeBadges() {
        badgeNote = nil
    }

    // MARK: - Data commands, wired to the Store

    func exportData(to destination: URL) -> String {
        guard let store else { return "There is no event log to export." }
        do {
            return try store.export(to: destination).userFacingSummary
        } catch {
            return "Export failed, \(error)"
        }
    }

    func deleteEverything() -> String {
        guard let store else { return "There is nothing stored to delete." }
        do {
            let report = try store.deleteEverything()
            try? FileManager.default.removeItem(at: AppPaths.settingsFile)
            // Reset the LIVE settings too. Removing the file is not enough: the old value is
            // still in memory, so the next `update(settings:)` writes it straight back to
            // disk and the delete was undone by the first thing the user touched. One button
            // must not have two outcomes depending on what happens next. The callbacks fire
            // so the Dock policy and appearance follow the reset the way they follow any
            // other settings change.
            settings = .default
            onSettingsChanged?()
            onAppearanceChanged?(settings.appearance)
            todaySummary = nil
            todayLine = ""
            todayDetail = ""
            lastWrittenSummary = nil
            badges = .empty
            badgeEvidence = BadgeEvidence()
            badgeNote = nil
            day = DailyCounters()
            persistedDay = nil
            refreshRollup(force: true)
            return report.userFacingSummary
        } catch {
            return "Delete failed, \(error)"
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

    /// Three triggers, because the interesting one is not reliable on its own.
    ///
    /// `com.apple.accessibility.api` is posted when the Accessibility switch is flipped
    /// for any app. It is undocumented, and it did not arrive on the machine where this
    /// was reported: the owner granted the permission, came back, and the pane still read
    /// "not granted" while `--doctor` on the same bundle reported the title as readable.
    /// The pane was the only thing that was wrong, which is the worst version of this bug,
    /// because the user has just done the thing they were asked to do and is being told it
    /// did not work.
    ///
    /// So the state is also re-read on the two moments that actually bracket the grant.
    /// The user leaves for System Settings and comes back, which makes this app active
    /// again, and they click the window, which makes it key. Both are ordinary AppKit
    /// notifications and both are exactly the instant the answer may have changed.
    /// `AXIsProcessTrusted()` is a cheap non-prompting read, so this costs nothing and
    /// does not poll: there is no timer here, and a permission the user never touches
    /// never causes a single extra check.
    private func observeAccessibilityGrant() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                self?.refreshPermissions()
            }
        }

        for name in [
            NSApplication.didBecomeActiveNotification,
            NSWindow.didBecomeKeyNotification,
        ] {
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshPermissions() }
            }
        }
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
            sensors.camera.setSystemAwake(false)
        case .didWake:
            append(.system(at: at, .wake))
            sensors.audio.setSystemAwake(true)
            sensors.camera.setSystemAwake(true)
            sensors.refreshExtraCollectors()
            sensors.frontmost.reconcile()
            sensors.system.reconcile()
            refreshPermissions()
        case .displaysSlept:
            append(.system(at: at, .displaySleep))
        case .displaysWoke:
            append(.system(at: at, .displayWake))
            sensors.system.reconcile()
        case .sessionResignedActive:
            append(.system(at: at, .sessionOut))
        case .sessionBecameActive:
            append(.system(at: at, .sessionIn))
            sensors.system.reconcile()
        case .thermalStateChanged, .powerStateChanged:
            break
        }

        if event.invalidatesElapsedTime {
            tracker.noteSystemWake()
        }

        Task { [weak self] in await self?.tick() }
    }

    /// Resample the moment the focused window or its title changes.
    ///
    /// `AccessibilityCollector` has always run an `AXObserver` for
    /// `kAXFocusedWindowChanged` and `kAXTitleChanged` and published them on `events`, and
    /// nothing consumed the stream. So switching tab was invisible until the next scheduled
    /// tick and the panel lagged by up to the full five seconds — which is most of a glance.
    /// One `await tick()` per event, which is the same work the loop was going to do
    /// anyway, moved to when there is something new to see.
    ///
    /// `observationFailed` is deliberately not a trigger: a failing observer would
    /// otherwise spin the loop on its own failures.
    private func subscribeToWindowChanges() {
        let stream = sensors.accessibility.events
        observerTasks.append(
            Task { [weak self] in
                for await event in stream {
                    guard let self else { return }
                    switch event {
                    case .focusedWindowChanged, .titleChanged:
                        await self.tick()
                    case .observationFailed:
                        break
                    }
                }
            }
        )
    }

    private func subscribeToWorkspaceEvents() {
        let stream = sensors.frontmost.events
        observerTasks.append(
            Task { [weak self] in
                for await event in stream {
                    guard let self else { return }
                    if case .activated = event {
                        self.seamsForNextStep.insert(.applicationSwitch)
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
        let reason = GateReason(verdict)
        return reason == .delivered ? nil : reason.summary
    }
}
