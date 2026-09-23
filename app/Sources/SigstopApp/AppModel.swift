import AppKit
import Foundation
import Observation
import ServiceManagement
import SigstopCore
import SigstopSensors

@MainActor
@Observable
final class AppModel {

    static let tickInterval: TimeInterval = 5

    static let tickTolerance: TimeInterval = 5

    static let focusHeartbeat: TimeInterval = 5 * 60

    static let unheldDeviceDwell: TimeInterval = 30

    private(set) var continuousWork: TimeInterval = 0
    private(set) var continuousWorkMeasuredAt: Double = 0
    private(set) var timeSinceLastBreak: TimeInterval?
    private(set) var activityLabel: String = "starting up"
    private(set) var applicationName: String = ""
    private(set) var confidence: Double = 0
    private(set) var evidenceLines: [EvidenceLine] = []
    private(set) var caveats: [String] = []
    private(set) var gitReading: GitReading?
    private(set) var gitStatusLine: String = "not sampled yet"
    private(set) var waiting: WaitingLine = WaitingLine(.notAskingYet, "starting up")
    private(set) var holdReason: String?
    private(set) var workTarget: TimeInterval
    private(set) var workTargetInForce = true
    private(set) var indicator: IndicatorState = .working
    private(set) var engineStateName: String = "working"
    private(set) var quietCause: QuietCause?
    private(set) var todaySummary: DailySummary?
    private(set) var todayLine: String = ""
    private(set) var todayDetail: String = ""
    private(set) var badges: BadgeLedger = .empty
    private(set) var badgeEvidence: BadgeEvidence = BadgeEvidence()
    private(set) var badgeNote: String?
    private(set) var breakEndsAt: Date?
    private(set) var breakContent: BreakContent?
    private(set) var snoozeUntil: Date?
    private(set) var pausedUntil: Date?
    private(set) var permissionStatus: PermissionStatus
    private(set) var lastStoreError: String?
    private(set) var promptDeliveryFailure: String?
    private(set) var notificationState: NotificationAvailability = .notYetNeeded
    private(set) var settings: SigstopSettings

    var onSettingsChanged: (() -> Void)?
    var onAppearanceChanged: ((AppearancePreference) -> Void)?
    private(set) var isRunning = false

    var workFraction: Double {
        guard workTarget > 0 else { return 0 }
        return min(1, max(0, displayedContinuousWork / workTarget))
    }

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

    var iconTooltip: String {
        "\(MenuBarIcon.label(for: indicator)). \(waiting.text.prefix(1).uppercased())"
            + "\(waiting.text.dropFirst())"
    }


    struct GitReading: Hashable, Sendable {
        let folder: String
        let branch: String?
        let head: GitHead
        let repoState: RepoState?
        let route: String

        var branchText: String {
            guard let branch else {
                return head == .reftable
                    ? "no branch to name: this repository keeps it in reftable, which sigstop does not read"
                    : "detached HEAD, no branch to name"
            }
            return SlotResolver.outsideText(branch) ?? "a branch whose name is only invisible characters"
        }
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
        case notYetNeeded
        case available
        case unavailable(String)
    }

    @ObservationIgnored private let time: any TimeSource = SystemTimeSource()
    @ObservationIgnored private let workClock = WorkClockBox()
    @ObservationIgnored private let messages = MessageEngine()
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private let overlay = BreakOverlayController()

    let updates = UpdateChecker()
    @ObservationIgnored private var sensors: SensorStack
    @ObservationIgnored private var tracker: SessionTracker
    @ObservationIgnored private var decision: BreakDecisionEngine
    @ObservationIgnored private(set) var policy: BreakPolicy
    @ObservationIgnored private var store: FileEventStore?

    @ObservationIgnored private var engineState: EngineState
    @ObservationIgnored private var day = DailyCounters()
    @ObservationIgnored private var persistedDay: DailyCounters?
    @ObservationIgnored private var badgesLeftAlone = false
    @ObservationIgnored private var countersLeftAlone = false
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var observerTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pendingAction: UserAction?
    @ObservationIgnored private var ticking = false
    @ObservationIgnored private var tickAgain = false
    @ObservationIgnored private var currentCycle: CycleID?
    @ObservationIgnored private var verdicts = VerdictLedger()
    @ObservationIgnored private var loggedApp: String??
    @ObservationIgnored private var loggedActivity: Activity?
    @ObservationIgnored private var lastFocusLogAt: Date?
    @ObservationIgnored private var idleBeganAt: Date?
    @ObservationIgnored private var seamsForNextStep: Set<Seam> = []
    @ObservationIgnored private var latch = MeetingLatch()
    @ObservationIgnored private var lastPersistedHold: TimeInterval = 0
    @ObservationIgnored private var lastPruneMono: Double = 0
    @ObservationIgnored private var micInhibitUntilMono: Double = 0
    @ObservationIgnored private var micInhibitUntil: Date?
    @ObservationIgnored private var unheldDeviceSince: Double?
    @ObservationIgnored private var lastAudioDeviceRunning = false
    @ObservationIgnored private var captureLive = false
    @ObservationIgnored private var breakOrigin: BreakOrigin?
    @ObservationIgnored private var lastVerdict: InterruptionVerdict?
    @ObservationIgnored private var rollupComputedAt: Date?
    @ObservationIgnored private var lastWrittenSummary: DailySummary?
    @ObservationIgnored private var lastSummaryWriteMono: Double = 0
    @ObservationIgnored private var summaryWriteRefused = false
    @ObservationIgnored private var refusedSummaryMonth: Int?
    @ObservationIgnored private var badgesUnsaved = false
    private static let summaryWriteInterval: TimeInterval = 600

    @ObservationIgnored private var presentation: PromptPresentation?

    private static let promptAttemptsBeforeComplaining = 3

    private struct PromptPresentation {
        let request: PromptRequest
        var attempts: Int
        var verifiedAt: Date?
    }

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

    private static func policy(for settings: SigstopSettings) -> BreakPolicy {
        var policy = BreakPolicy(settings: settings)
        policy.tickInterval = tickInterval
        policy.tickTolerance = tickTolerance
        return policy
    }

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

    private func secondsUntilNextTick() -> TimeInterval {
        let now = time.now
        var deadlines = [breakEndsAt, snoozeUntil, pausedUntil]
            .compactMap { $0 }
            .map { $0.timeIntervalSince(now) }
            .filter { $0 > 0 }

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
        windowTickTask?.cancel()
        windowTickTask = nil
        overlay.dismissAll()
        notifier.withdrawAll()
        sensors.context.stop()
        sensors.stopExtraCollectors()
        append(.stop(at: time.now))
        refreshRollup(force: true)
    }

    func takeBreakNow() { enqueue(.startBreakNow) }
    func acceptBreak() { enqueue(.acceptBreak) }
    func snooze() { enqueue(.snooze) }

    func ignorePrompt() { overlay.dismissPromptPanel() }

    func skip() { enqueue(.skip) }
    func endBreak() { enqueue(.endBreak) }
    func pause(for duration: TimeInterval) { enqueue(.pauseApp(duration)) }
    func resume() { enqueue(.resumeApp) }

    private func enqueue(_ action: UserAction) {
        pendingAction = action
        Task { [weak self] in await self?.tick() }
    }

    func update(settings newValue: SigstopSettings) {
        guard newValue != settings else { return }
        if SettingsStore.save(newValue) {
            clearStoreError(prefixed: Self.settingsFailurePrefix)
        } else {
            lastStoreError = "\(Self.settingsFailurePrefix) to \(AppPaths.settingsFile.path), "
                + "so this change lasts only until sigstop quits."
        }
        apply(settings: newValue)
    }

    private func apply(settings newValue: SigstopSettings) {
        settings = newValue
        onSettingsChanged?()
        let previousTarget = policy.targetContinuousWork
        policy = Self.policy(for: newValue)
        decision = BreakDecisionEngine(policy: policy)
        engineState = engineState.retargeted(from: previousTarget, to: policy.targetContinuousWork)
        sensors.context.reloadSettings(newValue)
        permissionStatus = sensors.permissions.status()
        if !newValue.showBreakOverlay { overlay.dismissBreak() }
        onAppearanceChanged?(newValue.appearance)
    }

    private func tick() async {
        if ticking {
            tickAgain = true
            return
        }
        ticking = true
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
        captureLive = raw.audio.contributesToMeeting || raw.camera.contributesToMeeting
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
        closeBreakTheEngineLeft()
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

    var callHoldSummary: String? {
        latchSignal(now: time.now, monotonic: time.continuousSeconds).summary
    }

    var inputDeviceIsHoldingABreak: Bool {
        guard case .hardBlocked(.audioInputInUse) = lastVerdict else { return false }
        return callHoldSummary == nil
    }

    var ignoreInputDeviceLabel: String {
        "Ignore this input device · \(DurationText.short(latchPolicy.latchManualInhibit))"
    }

    func assertMeeting() {
        latch = latch.assertedByUser(at: time.continuousSeconds, policy: latchPolicy)
        Task { [weak self] in await self?.tick() }
    }

    func clearMeetingHold() {
        latch = latch.clearedByUser(at: time.continuousSeconds, policy: latchPolicy)
        micInhibitUntilMono = time.continuousSeconds + latchPolicy.latchManualInhibit
        micInhibitUntil = time.now.addingTimeInterval(latchPolicy.latchManualInhibit)
        Task { [weak self] in await self?.tick() }
    }

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

    private func closeBreakTheEngineLeft() {
        if case .breakActive = engineState { return }
        guard let origin = breakOrigin else { return }
        tracker.endBreak(origin: origin)
        overlay.dismissBreak()
        breakOrigin = nil
        breakEndsAt = nil
        breakContent = nil
    }

    private func execute(_ effect: Effect, context: DeveloperContext, now: Date) {
        for line in EventLogWriter.lines(for: effect, at: now, context: logContext) {
            append(line)
        }

        switch effect {
        case .openCycle(let cycle):
            currentCycle = cycle

        case .closeCycle(let cycle, _):
            if currentCycle == cycle { currentCycle = nil }
            notifier.withdraw(cycle: cycle)
            if presentation?.request.cycle == cycle {
                overlay.dismissPromptPanel()
                presentation = nil
            }
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
            breakOrigin = origin
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
            breakOrigin = nil
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

    private static let defaultBranchNames: Set<String> = ["main", "master", "trunk"]

    private static func facts(from context: DeveloperContext) -> [FactKey: FactValue] {
        guard let branch = context.context.branch, !branch.isEmpty else { return [:] }
        return [.branchIsDefault: .bool(defaultBranchNames.contains(branch.lowercased()))]
    }

    private func deliver(_ request: PromptRequest, context: DeveloperContext, now: Date) {
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
            withheldSlots: goesToTheSystem ? [.branch, .project] : []
        )
        let message = messages.select(for: messageContext).message
        PromptSound.play(for: request.level, enabled: settings.promptSound && !captureLive)
        if !goesToTheSystem {
            presentPanel(request, message: message)
        } else {
            presentation = PromptPresentation(request: request, attempts: 1, verifiedAt: now)
            notifier.deliver(request, message: message)
            append(.breakPrompt(at: now, cycle: request.cycle, reason: request.level.signal))
        }
    }

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

    private func verifyPromptPresentation() {
        guard var current = presentation, current.verifiedAt == nil else { return }
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

    private var canPresentNow: Bool {
        !(lastVerdict?.isHardBlocked ?? false)
    }

    private func promptWasPresented(cycle: CycleID?) -> Bool {
        guard let cycle, let presentation, presentation.request.cycle == cycle else { return false }
        return presentation.verifiedAt != nil
    }

    private var logContext: EffectLogContext {
        guard let presentation, presentation.verifiedAt != nil else { return EffectLogContext() }
        return EffectLogContext(confirmedPromptCycle: presentation.request.cycle)
    }

    private func wireNotifier() {
        notifier.skipQuiet = policy.rearmAfterSkip
        notifier.onResponse = { [weak self] response, cycle in
            guard let self, let cycle, cycle == self.currentCycle else { return }
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
            guard self.canPresentNow, self.presentation?.request == request, !self.isOnBreak else { return }
            self.presentPanel(request, message: message)
        }
    }

    private func openStore() {
        var countersRestored = false
        defer { if !countersRestored { notifier.withdrawEverything() } }
        let store: FileEventStore
        do {
            store = try FileEventStore(root: AppPaths.storageRoot)
        } catch {
            self.store = nil
            lastStoreError = "Could not open \(AppPaths.storageRoot.path), \(error)"
            return
        }
        self.store = store
        lastStoreError = nil
        do {
            badges = try store.readBadges()
            badgesLeftAlone = false
        } catch {
            badgesLeftAlone = true
        }
        do {
            if let stored = try store.readCounters() {
                day = stored
                persistedDay = stored
                countersRestored = true
            }
            countersLeftAlone = false
        } catch {
            countersLeftAlone = true
        }
        surfaceFilesLeftAlone()
        pruneOldLogs()
    }

    private static let pruneFailurePrefix = "Could not prune old logs"
    private static let settingsFailurePrefix = "Could not save your settings"
    private static let leftAlonePrefix = "Could not read, so left as it is:"
    private static let summaryFailurePrefix = "Could not write the daily summary"
    private static let badgesFailurePrefix = "Could not write the badges"

    private func clearStoreError(prefixed prefix: String) {
        guard lastStoreError?.hasPrefix(prefix) == true else { return }
        lastStoreError = nil
        surfaceFilesLeftAlone()
    }

    private func surfaceFilesLeftAlone() {
        guard let store else { return }
        let files = [
            badgesLeftAlone ? store.badgesFile.path : nil,
            countersLeftAlone ? store.countersFile.path : nil,
        ].compactMap { $0 }
        guard !files.isEmpty else { return }
        let message = "\(Self.leftAlonePrefix) \(files.joined(separator: " and ")). "
            + "Nothing is saved over \(files.count == 1 ? "it" : "them") until sigstop can read "
            + "\(files.count == 1 ? "it" : "them") at its next launch."
        guard lastStoreError != message,
              lastStoreError == nil || lastStoreError?.hasPrefix(Self.leftAlonePrefix) == true
        else { return }
        lastStoreError = message
    }

    private func pruneOldLogs() {
        lastPruneMono = time.continuousSeconds
        do {
            try store?.prune(retentionDays: Retention.defaultEventDays, asOf: time.now)
            clearStoreError(prefixed: Self.pruneFailurePrefix)
        } catch {
            if lastStoreError == nil || lastStoreError?.hasPrefix(Self.pruneFailurePrefix) == true {
                lastStoreError = "\(Self.pruneFailurePrefix), \(error)"
            }
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

    private func persistCountersIfChanged() {
        guard let store, day != persistedDay else { return }
        guard !countersLeftAlone else {
            surfaceFilesLeftAlone()
            return
        }
        do {
            try store.writeCounters(day)
            persistedDay = day
        } catch {
            lastStoreError = "Could not write the daily counters, \(error)"
        }
    }

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

    static func category(for bundleID: String?) -> String {
        switch AppKey(bundleID: bundleID).family {
        case .aiEditor, .editor, .ide, .terminal, .containers: return "code"
        case .browser:                                         return "browse"
        case .chat:                                            return "meet"
        case .design, .other:                                  return "other"
        }
    }

    private func publishViewState(
        sample: ContextSample, context: DeveloperContext, outcome: EngineOutcome
    ) {
        continuousWork = context.continuousWork
        continuousWorkMeasuredAt = time.continuousSeconds
        timeSinceLastBreak = context.timeSinceLastBreak
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

        publishHold(gate: outcome.verdict.map(GateReason.init))

        if case .quiet(let q) = engineState {
            quietCause = q.cause
            pausedUntil = q.cause == .userPaused ? q.until : nil
        } else {
            quietCause = nil
            pausedUntil = nil
        }

        refreshRollup(force: false)
        if time.continuousSeconds - lastPruneMono >= 3600 { pruneOldLogs() }
    }

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
        case .read(let folder, _, let head, let route):
            gitReading = GitReading(
                folder: folder,
                branch: context.context.branch,
                head: head,
                repoState: context.context.repoState,
                route: route
            )
            gitStatusLine = ""
        }
    }

    private func publishHold(gate: GateReason?) {
        let monotonic = time.continuousSeconds
        workTargetInForce = true
        if case .working(let w) = engineState {
            workTarget = w.armThreshold
            if let cooldown = w.cooldownUntilMono, monotonic < cooldown { workTargetInForce = false }
        } else {
            workTarget = policy.targetContinuousWork
        }
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
        if let hold = latchSignal(now: time.now, monotonic: monotonic).summary,
           waiting.claim != .holdingOff {
            waiting = WaitingLine(.holdingOff, hold)
        }

        holdReason = waiting.body
    }

    private static let unreadableLogPrefix = "Could not read the event log for"

    func refreshRollup(force: Bool) {
        let now = time.now
        if !force, let last = rollupComputedAt, now.timeIntervalSince(last) < 60 { return }
        rollupComputedAt = now
        guard let store else { return }
        let today = CalendarDay.local(
            of: now, calendar: .current, boundaryHour: BreakPolicy.default.dayBoundaryHour
        )
        let summary: DailySummary
        do {
            summary = try DailyRollup.compute(day: today, from: store)
            clearStoreError(prefixed: Self.unreadableLogPrefix)
        } catch StoreError.unreadable(let days) {
            let list = days.map(\.description).joined(separator: ", ")
            lastStoreError = "\(Self.unreadableLogPrefix) \(list), so today's numbers are not shown."
            todaySummary = nil
            todayLine = ""
            todayDetail = ""
            return
        } catch {
            return
        }
        todaySummary = summary
        let narrator = SummaryNarrator(tone: settings.tone)
        let seed = UInt64(bitPattern: Int64(today.year * 10_000 + today.month * 100 + today.day))
        todayLine = narrator.line(for: summary, seed: seed)
        todayDetail = narrator.detail(for: summary)
        refreshBadges(today: summary, store: store, force: force)
    }

    private func refreshBadges(today: DailySummary, store: FileEventStore, force: Bool) {
        guard lastWrittenSummary != today else { return }
        let due = force
            || (lastWrittenSummary?.day != today.day && !summaryWriteRefused)
            || time.continuousSeconds - lastSummaryWriteMono >= Self.summaryWriteInterval
        guard due else { return }
        lastSummaryWriteMono = time.continuousSeconds
        if let previous = lastWrittenSummary, previous.day != today.day {
            finalize(previous, store: store)
        }
        summaryWriteRefused = !save(today, to: store)
        if !summaryWriteRefused { lastWrittenSummary = today }

        let days = badgeDays(store: store)
        guard !days.isEmpty else { return }
        badgeEvidence = BadgeEvaluator.evidence(for: days, calendar: .current, policy: .default)

        let updated = BadgeEvaluator.evaluate(
            days: days,
            calendar: .current,
            policy: .default,
            knownUnlocked: badges
        )
        guard updated != badges || badgesUnsaved else { return }

        let fresh = updated.newlyUnlocked(since: badges)
        badges = updated
        guard !badgesLeftAlone else {
            surfaceFilesLeftAlone()
            return
        }
        do {
            try store.writeBadges(updated)
            badgesUnsaved = false
            clearStoreError(prefixed: Self.badgesFailurePrefix)
        } catch {
            badgesUnsaved = true
            lastStoreError = "\(Self.badgesFailurePrefix), \(error)"
        }
        if let note = Self.badgeNote(for: fresh) { badgeNote = note }
    }

    private func finalize(_ previous: DailySummary, store: FileEventStore) {
        guard let final = try? DailyRollup.compute(day: previous.day, from: store), final != previous else { return }
        _ = save(final, to: store)
    }

    private func save(_ summary: DailySummary, to store: FileEventStore) -> Bool {
        let month = summary.day.year * 100 + summary.day.month
        do {
            try store.writeSummary(summary)
        } catch {
            refusedSummaryMonth = month
            lastStoreError = "\(Self.summaryFailurePrefix), \(error)"
            return false
        }
        if refusedSummaryMonth == month {
            refusedSummaryMonth = nil
            clearStoreError(prefixed: Self.summaryFailurePrefix)
        }
        return true
    }

    private func badgeDays(store: FileEventStore) -> [BadgeDay] {
        var byDay: [CalendarDay: BadgeDay] = [:]
        for (day, summary) in (try? store.readAllSummaries()) ?? [:] {
            byDay[day] = BadgeDay(summary: summary)
        }

        let fileDays = (try? store.availableDays()) ?? []
        var loaded: [CalendarDay: [LoggedEvent]] = [:]
        var unreadable: Set<CalendarDay> = []
        for day in fileDays {
            guard let load = try? store.load(day: day), !load.unreadable else {
                unreadable.insert(day)
                continue
            }
            loaded[day] = load.events
        }
        var logicalDays: Set<CalendarDay> = []
        for day in fileDays {
            logicalDays.insert(day)
            logicalDays.insert(day.adding(days: -1))
        }
        for day in logicalDays.sorted() {
            let window = [day.adding(days: -1), day, day.adding(days: 1)]
            guard !window.contains(where: unreadable.contains) else { continue }
            let events = window
                .flatMap { loaded[$0] ?? [] }
                .sorted { $0.at < $1.at }
            guard !events.isEmpty else { continue }
            byDay[day] = BadgeDay.from(day: day, events: events, policy: .default, calendar: .current)
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    private static func badgeNote(for unlocked: [BadgeID]) -> String? {
        guard let first = unlocked.first else { return nil }
        if unlocked.count == 1 {
            return "unlocked: \(Badge.badge(first).title), Settings → Badges"
        }
        return "unlocked: \(unlocked.count) badges, Settings → Badges"
    }

    func acknowledgeBadges() {
        badgeNote = nil
    }

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
            _ = InstanceLock.acquire(in: AppPaths.storageRoot)
            notifier.withdrawEverything()
            try? FileManager.default.removeItem(at: AppPaths.settingsFile)
            apply(settings: .default)
            latch = latch.resettingDailyHold()
            lastPersistedHold = 0
            todaySummary = nil
            todayLine = ""
            todayDetail = ""
            lastWrittenSummary = nil
            badges = .empty
            badgeEvidence = BadgeEvidence()
            badgeNote = nil
            day = DailyCounters()
            persistedDay = nil
            badgesLeftAlone = false
            countersLeftAlone = false
            summaryWriteRefused = false
            refusedSummaryMonth = nil
            badgesUnsaved = false
            for prefix in [Self.leftAlonePrefix, Self.summaryFailurePrefix, Self.badgesFailurePrefix] {
                clearStoreError(prefixed: prefix)
            }
            refreshRollup(force: true)
            return report.userFacingSummary + Self.removeLoginItem()
        } catch {
            return "Delete failed, \(error)"
        }
    }

    private static func removeLoginItem() -> String {
        guard AppPaths.isBundled, SMAppService.mainApp.status == .enabled else { return "" }
        do {
            try SMAppService.mainApp.unregister()
            return "\nRemoved: the login item."
        } catch {
            return "\nThe login item is still registered, \(error.localizedDescription). "
                + "Remove it in System Settings → General → Login Items."
        }
    }

    func openAccessibilitySettings() {
        sensors.permissions.openAccessibilitySettings(.clickedButton("Open System Settings"))
    }

    func refreshPermissions() {
        sensors.permissions.refresh()
        permissionStatus = sensors.permissions.status()
    }

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
            refreshRollup(force: true)
        case .screenUnlocked:
            append(.system(at: at, .unlock))
            seamsForNextStep.insert(.idleBlip)
        case .willSleep:
            append(.system(at: at, .sleep))
            refreshRollup(force: true)
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

    @ObservationIgnored private var windowTickTask: Task<Void, Never>?

    private func scheduleWindowTick() {
        guard windowTickTask == nil else { return }
        windowTickTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.windowTickTask = nil
            await self.tick()
        }
    }

    private func subscribeToWindowChanges() {
        let stream = sensors.accessibility.events
        observerTasks.append(
            Task { [weak self] in
                for await event in stream {
                    guard let self else { return }
                    switch event {
                    case .focusedWindowChanged, .titleChanged:
                        self.scheduleWindowTick()
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

    static func explain(_ verdict: InterruptionVerdict) -> String? {
        let reason = GateReason(verdict)
        return reason == .delivered ? nil : reason.summary
    }
}
