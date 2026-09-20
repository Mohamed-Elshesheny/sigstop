import AppKit
import Foundation
import SigstopCore

// MARK: - Prompt gate

/// Whether a break prompt may be shown *right now*, and why not.
///
/// The distinction is the whole invariant from CLAUDE.md §4.1, expressed as a type:
///
/// * `.hardBlocked` is reachable **only** from a real system signal — the screen is
///   actually locked, the displays are actually asleep, another user is actually on the
///   console, an audio input device is actually running. These are facts the kernel or the
///   window server handed us.
/// * `.softDeferred` is reachable from an *inference* — "a conferencing app is running and
///   frontmost, so you are probably in a meeting", "something is fullscreen, so you might
///   be presenting". A guess may delay a prompt. It may never suppress one, because a
///   confident-sounding wrong guess that silently eats the whole feature is worse than an
///   interruption at a slightly awkward moment.
///
/// Confidence therefore gates deferral and never blocking. There is deliberately no API
/// here that turns a `Confidence` into a `.hardBlocked`.
public enum PromptGate: Sendable, Hashable {
    case allowed
    /// Inference-based. The decision engine should wait and re-ask, not give up.
    case softDeferred(reason: String)
    /// OS-fact-based. Showing a prompt now is pointless or actively rude.
    case hardBlocked(reason: String)

    public var allowsPrompt: Bool { self == .allowed }

    public var reason: String? {
        switch self {
        case .allowed: return nil
        case .softDeferred(let r), .hardBlocked(let r): return r
        }
    }
}

// MARK: - Work clock bridge

/// The session clock lives in `SigstopCore` (docs/BREAK-DECISION.md) and is deliberately
/// not reimplemented here. The engine takes a reading rather than owning one, so the two
/// halves stay independently testable and the sensing layer never grows a second, subtly
/// different idea of what "continuous work" means.
public struct WorkClockReading: Sendable, Hashable {
    public let continuousWork: TimeInterval
    public let timeSinceLastBreak: TimeInterval?

    public init(continuousWork: TimeInterval = 0, timeSinceLastBreak: TimeInterval? = nil) {
        self.continuousWork = continuousWork
        self.timeSinceLastBreak = timeSinceLastBreak
    }

    public static let zero = WorkClockReading()
}

// MARK: - Sample

/// One published sample: the value the rest of the app reasons about, plus the two things
/// that do not fit in `DeveloperContext` and must not be smuggled into it.
public struct ContextSample: Sendable {
    public let context: DeveloperContext
    public let gate: PromptGate
    /// Set when the honest label differs from the activity's own name — a desktop AI app
    /// with no corroboration is "AI assistant", not "AI coding". The *label* degrades, not
    /// just the number.
    public let honestLabel: String?
    /// Things a skeptic should be told that are not evidence for the activity: a disabled
    /// microphone signal, an unreadable idle counter, a suppressed app switch.
    public let caveats: [String]
    public let providerID: ProviderID

    public init(
        context: DeveloperContext,
        gate: PromptGate,
        honestLabel: String? = nil,
        caveats: [String] = [],
        providerID: ProviderID
    ) {
        self.context = context
        self.gate = gate
        self.honestLabel = honestLabel
        self.caveats = caveats
        self.providerID = providerID
    }
}

// MARK: - Engine

/// Composes every collector into `SignalContext`, resolves a provider, applies the dwell
/// gate and confidence decay, and publishes `DeveloperContext`.
///
/// **Why `@MainActor` and not an actor.** `NSWorkspace` and the lock/sleep notifications
/// are delivered on the main thread, so `FrontmostAppCollector` and `SystemStateCollector`
/// are already main-actor-isolated. Making the engine its own actor would add a hop in
/// each direction on the hot path and would reorder events relative to the notifications
/// that produced them, in exchange for nothing: the engine does no blocking work. The one
/// call that *can* block — Accessibility IPC — is already confined to its own queue inside
/// `AccessibilityCollector` and is reached with `await`.
///
/// **Why almost nothing is polled.** Every input is an event stream: workspace activation,
/// lock/unlock, sleep/wake, CoreAudio device state, AX title changes. The single
/// `DispatchSourceTimer` exists for exactly two jobs that have no notification — crossing
/// an idle threshold, and reconciling a possibly-missed AX title change — and it is
/// cancelled outright (not merely skipped) whenever the user demonstrably is not there.
@MainActor
public final class ContextEngine {
    public struct Configuration: Sendable {
        /// A new app must hold the front this long before it may change the published
        /// class. Suppresses the flicker of alt-tabbing and of clicking a notification.
        public var dwellGate: TimeInterval
        /// Odds halve every this-many seconds without corroboration (§6.4).
        public var decayHalfLife: TimeInterval
        /// Above this idle, input stops corroborating and confidence starts decaying.
        public var corroboratingInputWindow: TimeInterval
        /// Start of the "reading or thinking, not idle" band.
        public var softIdleFloor: TimeInterval
        /// Above this, `IDLE` is the answer.
        public var idleThreshold: TimeInterval
        /// Guards against an `AXObserver` notification we never received. A missed one
        /// leaves a stale title, and a stale title is indistinguishable from a lie.
        public var axReconcileInterval: TimeInterval
        /// Fraction of the interval given to the OS as timer leeway, so our wakeups
        /// coalesce with other processes' (§8.3).
        public var timerLeewayFraction: Double

        public init(
            dwellGate: TimeInterval = 8,
            decayHalfLife: TimeInterval = 90,
            corroboratingInputWindow: TimeInterval = 60,
            softIdleFloor: TimeInterval = 120,
            idleThreshold: TimeInterval = 300,
            axReconcileInterval: TimeInterval = 60,
            timerLeewayFraction: Double = 0.25
        ) {
            self.dwellGate = dwellGate
            self.decayHalfLife = decayHalfLife
            self.corroboratingInputWindow = corroboratingInputWindow
            self.softIdleFloor = softIdleFloor
            self.idleThreshold = idleThreshold
            self.axReconcileInterval = axReconcileInterval
            self.timerLeewayFraction = timerLeewayFraction
        }

        public static let `default` = Configuration()
    }

    // MARK: Collaborators

    private let time: any TimeSource
    private let configuration: Configuration
    private let permissions: PermissionBroker
    private let frontmostCollector: FrontmostAppCollector
    private let systemCollector: SystemStateCollector
    private let audioCollector: AudioDeviceCollector
    private let accessibilityCollector: AccessibilityCollector
    private let idleCollector: IdleCollector
    private var registry: ProviderRegistry
    private var workClock: @Sendable () -> WorkClockReading

    // MARK: State

    private var running = false
    private var suspended = false
    private var tasks: [Task<Void, Never>] = []
    private var timer: DispatchSourceTimer?
    private var continuations: [UUID: AsyncStream<ContextSample>.Continuation] = [:]

    /// The gated, decayed observation the app is currently standing behind.
    private var publishedObservation: ActivityObservation?
    private var publishedLabel: String?
    /// When the evidence last actually changed, or the user last touched the hardware.
    private var corroboratedAt: Date
    private var evidenceFingerprint: Set<String> = []

    private var titleCache: (pid: pid_t, info: AXWindowInfo, readAt: Date)?
    private var titleDirty = true
    private var observedPID: pid_t?
    private var geometry: WindowGeometrySnapshot?

    /// Set by any event after which accumulated durations are void — wake, unlock, session
    /// switch. The session clock must diff real timestamps across this, never trust ticks
    /// (CLAUDE.md §3.4). Exposed rather than acted on here: the clock is Core's.
    public private(set) var lastElapsedInvalidation: Date?

    public private(set) var lastSample: ContextSample?

    // MARK: Init

    public init(
        time: any TimeSource = SystemTimeSource(),
        configuration: Configuration = .default,
        permissions: PermissionBroker = PermissionBroker(),
        registry: ProviderRegistry = ProviderRegistry(),
        frontmost: FrontmostAppCollector? = nil,
        system: SystemStateCollector? = nil,
        audio: AudioDeviceCollector? = nil,
        accessibility: AccessibilityCollector = AccessibilityCollector(),
        idle: IdleCollector = IdleCollector(),
        workClock: @escaping @Sendable () -> WorkClockReading = { .zero }
    ) {
        self.time = time
        self.configuration = configuration
        self.permissions = permissions
        self.registry = registry
        self.frontmostCollector = frontmost ?? FrontmostAppCollector(time: time)
        self.systemCollector = system ?? SystemStateCollector(time: time)
        self.audioCollector = audio ?? AudioDeviceCollector(time: time)
        self.accessibilityCollector = accessibility
        self.idleCollector = idle
        self.workClock = workClock
        self.corroboratedAt = time.now
    }

    deinit {
        timer?.cancel()
        for c in continuations.values { c.finish() }
    }

    // MARK: Lifecycle

    public func start() {
        guard !running else { return }
        running = true

        permissions.refresh()
        frontmostCollector.start()
        systemCollector.start()
        audioCollector.start()

        subscribeToWorkspace()
        subscribeToSystem()
        subscribeToAudio()
        subscribeToAccessibility()
        subscribeToPermissions()

        refreshGeometry()
        startObservingFrontmostWindow()
        resumeSamplingIfNeeded()
        Task { [weak self] in await self?.sampleAndPublish() }
    }

    public func stop() {
        guard running else { return }
        running = false
        cancelTimer()
        for task in tasks { task.cancel() }
        tasks.removeAll()
        accessibilityCollector.stopObservingAll()
        observedPID = nil
        audioCollector.stop()
        systemCollector.stop()
        frontmostCollector.stop()
    }

    /// `SIGHUP`: re-read settings. A revoked opt-in must take effect on the next sample,
    /// not on the next launch.
    public func reloadSettings(_ settings: SigstopSettings) {
        permissions.apply(settings)
        titleDirty = true
        Task { [weak self] in await self?.sampleAndPublish() }
    }

    public func register(_ provider: any ActivityProvider) {
        registry.register(provider)
    }

    public func setWorkClock(_ reading: @escaping @Sendable () -> WorkClockReading) {
        workClock = reading
    }

    public var samples: AsyncStream<ContextSample> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            continuations[id] = continuation
            if let lastSample { continuation.yield(lastSample) }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in self?.continuations[id] = nil }
            }
        }
    }

    public var permissionStatus: PermissionStatus { permissions.status() }

    /// Everything `make doctor` prints: what we can see, what we think, and why.
    public func doctorReport() -> [String] {
        var lines = permissions.status().explanation
        guard let sample = lastSample else {
            lines.append("No sample taken yet.")
            return lines
        }
        let context = sample.context
        let label = sample.honestLabel ?? context.claimableActivity.displayName
        lines.append(
            "Right now: \(label) @ \(String(format: "%.2f", context.confidence.value)) "
                + "in \(context.application.localizedName)"
        )
        lines.append(contentsOf: context.reasoning.map { "  because \($0)" })
        lines.append(contentsOf: sample.caveats.map { "  caveat: \($0)" })
        if let reason = sample.gate.reason {
            lines.append("  prompts: \(sample.gate.allowsPrompt ? "allowed" : "held") — \(reason)")
        }
        return lines
    }

    // MARK: Sampling

    /// Builds one `SignalContext`, classifies it, and publishes. Async only because of
    /// Accessibility IPC, which is the one call here that can block.
    @discardableResult
    public func sampleAndPublish() async -> ContextSample {
        let sample = await buildSample()
        lastSample = sample
        for continuation in continuations.values { continuation.yield(sample) }
        return sample
    }

    private func buildSample() async -> ContextSample {
        let now = time.now
        let tiers = permissions.currentTiers()
        let snapshot = frontmostCollector.snapshot()
        let session = systemCollector.sessionState()
        let power = systemCollector.powerState()
        let audio = audioCollector.state()
        let input = idleCollector.read()

        var caveats: [String] = []
        if let explanation = audioCollector.unreliabilityExplanation() {
            caveats.append(explanation)
        }
        if input.knownIdleSeconds == nil {
            caveats.append(
                "This Mac is not reporting an idle time, so the app cannot tell whether you are "
                    + "at the keyboard. It will not claim you are."
            )
        }

        let axInfo = await readTitleIfPermitted(tiers: tiers, pid: snapshot.frontmost.pid, input: input, now: now)

        let signals = SignalContext(
            now: now,
            available: tiers,
            frontmost: snapshot.frontmost,
            frontmostSince: snapshot.frontmostSince,
            recentApps: snapshot.recentApps,
            runningBundleIDs: snapshot.runningBundleIDs,
            input: input,
            session: session,
            power: power,
            audioInput: audio,
            windowGeometry: geometry,
            windowTitle: axInfo.title,
            documentURL: axInfo.documentURL,
            // There is no permission-free way to read a browser's current URL. The only
            // routes are Apple Events (an Automation grant, per-app prompts) and Screen
            // Recording, both declined in docs/ACTIVITY-DETECTION.md §2.6/§12. So Tier 1b
            // stays nil here rather than being faked: the opt-in exists, the collector
            // that would honour it does not, and the providers already degrade cleanly.
            browserHost: nil,
            // Tier 2 collectors (process snapshot, `.git/HEAD` watch) are a separate work
            // item. Until they land these are nil and every provider degrades exactly as
            // §7.2 requires — which is why DEBUGGING is currently unreachable and CODING
            // is flagged ambiguous instead of guessed at.
            processes: nil,
            git: nil
        )

        // Classification happens exactly once per sample. The verdict feeds both axes: the
        // primary activity, and the Tier 1 half of the meeting evidence.
        let classified = registry.classify(signals)

        let (concurrent, meetingIsOSFact, meetingCaveat) = concurrentStates(
            signals, tiers: tiers
        )
        if let meetingCaveat { caveats.append(meetingCaveat) }

        let resolved = resolve(signals, classified: classified, concurrent: concurrent)
        let gated = applyDwellGate(resolved.observation, signals: signals, caveats: &caveats)
        let label = gated.wasGated ? publishedLabel : resolved.label

        publishedObservation = gated.observation
        publishedLabel = label
        let reading = workClock()

        let developerContext = DeveloperContext(
            timestamp: now,
            // The frontmost app is an OS fact and is always reported truthfully, even while
            // the dwell gate is holding the previous *activity*. Lying about which app is in
            // front to keep a story tidy is not a trade this app makes.
            application: snapshot.frontmost,
            activity: gated.observation.activity,
            confidence: gated.observation.confidence,
            evidence: gated.observation.evidence,
            context: gated.observation.context,
            concurrent: concurrent,
            tiersUsed: gated.observation.tiersUsed,
            continuousWork: reading.continuousWork,
            timeSinceLastBreak: reading.timeSinceLastBreak,
            // Honest absence is not representable in this field, so unknown idle is
            // reported as 0 and the caveat above says so in words.
            idleSeconds: input.knownIdleSeconds ?? 0,
            applicationSwitches: signals.switchCount(within: 60)
        )

        return ContextSample(
            context: developerContext,
            gate: promptGate(
                session: session,
                audio: signals.audioInput,
                concurrent: concurrent,
                meetingIsOSFact: meetingIsOSFact
            ),
            honestLabel: label,
            caveats: caveats,
            providerID: resolved.providerID
        )
    }

    // MARK: Classification

    private func resolve(
        _ signals: SignalContext,
        classified: (verdict: ProviderVerdict, providerID: ProviderID),
        concurrent: ConcurrentStates
    ) -> (observation: ActivityObservation, label: String?, providerID: ProviderID) {
        // 1. OS facts win outright, and they are the only route to `.certain`.
        if signals.session.userDefinitelyAway {
            let evidence = Ev.make(
                "session.away", .tier0, 3.0, awayReason(signals.session)
            )
            let verdict = ProviderVerdict(activity: .idle, evidence: [evidence])
            let observation = ConfidenceEngine.observation(
                verdict: verdict,
                providerID: ProviderID("dev.sigstop.engine.os"),
                signals: signals,
                concurrent: concurrent,
                isOSFact: true
            )
            return (observation, nil, observation.providerID)
        }

        // 2. Measured idle past the threshold. Deliberately built directly rather than
        //    through the tier ceiling: 0.55 is the ceiling on *guessing what an app means*,
        //    and this number does not come from a guess — it is the OS's own HID idle
        //    counter. It still is not `.certain`, because a person can sit and read.
        if let idle = signals.input.knownIdleSeconds, idle > configuration.idleThreshold {
            let evidence = Ev.make(
                "input.absent", .tier0, 3.0,
                "nothing has touched the keyboard or trackpad for \(Int(idle / 60)) minutes"
            )
            let observation = ActivityObservation(
                timestamp: signals.now,
                activity: .idle,
                confidence: Confidence(0.90),
                evidence: [evidence],
                app: signals.frontmost,
                context: .empty,
                concurrent: concurrent,
                providerID: ProviderID("dev.sigstop.engine.idle"),
                tiersUsed: [.tier0]
            )
            return (observation, nil, observation.providerID)
        }

        // 3. Otherwise a provider owns the verdict.
        let (verdict, providerID) = classified
        var evidence = verdict.evidence

        // The 120–300 s band is NOT idle. Reading code, reading a PR and thinking are all
        // input-idle and all work; calling that "idle" is the most common way a time
        // tracker lies to its user. Keep the class, lower the number, say why.
        if let idle = signals.input.knownIdleSeconds, idle > configuration.softIdleFloor {
            evidence.append(
                Ev.make(
                    "input.quiet", .tier0, log(0.6),
                    "you have not touched the keyboard or trackpad for \(Int(idle))s — you could "
                        + "be reading, or you could have walked away"
                )
            )
        }

        // Decay. Sitting in the same editor for forty minutes with no input and no title
        // change is *less* evidence of coding as time passes, not the same amount. A
        // half-life is a straight line in log-odds, which is the space evidence already
        // lives in, so decay is expressed as evidence and remains visible in "why?".
        // (`ConfidenceEngine` clamps any single item to ±2.0, so decay bottoms out at
        // roughly a seventh of the original odds rather than falling forever. Acceptable:
        // past 300 s of no input the idle rule above takes over entirely.)
        updateCorroboration(verdict: verdict, signals: signals)
        let staleness = signals.now.timeIntervalSince(corroboratedAt)
        if staleness > configuration.decayHalfLife / 4 {
            evidence.append(
                Ev.make(
                    "decay.stale", .tier0,
                    -(staleness / configuration.decayHalfLife) * log(2.0),
                    "nothing has corroborated this for \(Int(staleness / 60)) minutes"
                )
            )
        }

        let decayed = ProviderVerdict(
            activity: verdict.activity,
            evidence: evidence,
            context: verdict.context,
            degradedFromAmbiguity: verdict.degradedFromAmbiguity,
            concurrentHints: verdict.concurrentHints,
            labelOverride: verdict.labelOverride,
            maximumConfidence: verdict.maximumConfidence
        )

        let observation = ConfidenceEngine.observation(
            verdict: decayed,
            providerID: providerID,
            signals: signals,
            concurrent: concurrent
        )
        return (observation, verdict.labelOverride, providerID)
    }

    private func awayReason(_ session: SessionState) -> String {
        if session.screenLocked { return "the screen is locked" }
        if session.displaysAsleep { return "the displays are asleep" }
        return "someone else is signed in at the console"
    }

    /// Corroboration is "something changed, or a human touched the hardware". Without it,
    /// confidence decays.
    private func updateCorroboration(verdict: ProviderVerdict, signals: SignalContext) {
        let fingerprint = Set(verdict.evidence.map(\.id.rawValue))
        let touched = signals.inputWithin(configuration.corroboratingInputWindow)
        if fingerprint != evidenceFingerprint || touched {
            evidenceFingerprint = fingerprint
            corroboratedAt = signals.now
        }
    }

    // MARK: Dwell gate

    /// An app switch does not immediately change the published class (§6.4). A two-second
    /// glance at a browser from an editor is not the start of a browsing session, and the
    /// ring buffer is what lets that stay true.
    ///
    /// Exception: a switch *into* idle publishes immediately. Being away is not something
    /// to be gradual about.
    private func applyDwellGate(
        _ fresh: ActivityObservation,
        signals: SignalContext,
        caveats: inout [String]
    ) -> (observation: ActivityObservation, wasGated: Bool) {
        guard let previous = publishedObservation else { return (fresh, false) }
        if fresh.activity == .idle || previous.activity == .idle { return (fresh, false) }
        if fresh.app == previous.app { return (fresh, false) }
        if fresh.activity == previous.activity { return (fresh, false) }
        if signals.frontmostDwell >= configuration.dwellGate { return (fresh, false) }

        caveats.append(
            "\(signals.frontmost.localizedName) has only been in front for "
                + "\(Int(signals.frontmostDwell))s, so this is still being counted as "
                + "\(previous.activity.displayName)."
        )
        // Re-stamp so downstream consumers see a current sample rather than a frozen one;
        // the claim itself, its evidence and its confidence are untouched.
        return (
            ActivityObservation(
                timestamp: signals.now,
                activity: previous.activity,
                confidence: previous.confidence,
                evidence: previous.evidence,
                app: previous.app,
                context: previous.context,
                concurrent: previous.concurrent,
                providerID: previous.providerID,
                tiersUsed: previous.tiersUsed
            ),
            true
        )
    }

    // MARK: Concurrent states

    /// Meeting lives on its own axis because a meeting overlaps other work. Forcing a
    /// choice between "in a meeting" and "coding" produces wrong answers for everyone who
    /// codes during a standup.
    private func concurrentStates(
        _ signals: SignalContext,
        tiers: SignalTierSet
    ) -> (ConcurrentStates, meetingIsOSFact: Bool, caveat: String?) {
        let (_, providerID) = (0, ProviderID(""))
        _ = providerID

        var meetingEvidence: [Evidence] = []
        var caveat: String?

        let micRunning = signals.audioInput.contributesToMeeting
        if micRunning { meetingEvidence.append(Ev.micRunning()) }

        for bundleID in BundleIDs.conferencing where signals.isRunning(bundleID) {
            meetingEvidence.append(Ev.conferencingRunning(Self.conferencingName(bundleID)))
        }

        // Providers contribute the Tier 1 half: "Zoom Meeting" rather than "Zoom", a
        // browser tab titled "Meet - …".
        let hints = registry.classify(signals).verdict.concurrentHints
        meetingEvidence.append(contentsOf: hints.meetingEvidence)

        let hasTitleEvidence = meetingEvidence.contains { $0.tier == .tier1 }
        if signals.audioInput == .unreliable && !hasTitleEvidence {
            // A permanently-on detector is worse than no detector. Switch the whole axis
            // off and say so, rather than reporting a meeting all day.
            meetingEvidence = []
            caveat = "Meeting detection is off on this Mac — see the microphone note above."
        }

        let confidence = ConfidenceEngine.meetingConfidence(meetingEvidence, tiers: tiers)
        let states = ConcurrentStates(
            inMeeting: confidence.isConfidentEnoughForSpecificClaim,
            meetingConfidence: confidence,
            screenLocked: signals.session.screenLocked,
            onBattery: signals.power.onBattery,
            lowPowerMode: signals.power.lowPowerMode,
            fullscreen: signals.windowGeometry?.hasFullscreenWindow ?? false
        )
        return (states, micRunning, caveat)
    }

    static func conferencingName(_ bundleID: String) -> String {
        switch bundleID {
        case BundleIDs.zoom:    return "Zoom"
        case BundleIDs.teams:   return "Microsoft Teams"
        case BundleIDs.slack:   return "Slack"
        case BundleIDs.discord: return "Discord"
        default:                return bundleID
        }
    }

    // MARK: Gate

    private func promptGate(
        session: SessionState,
        audio: AudioInputState,
        concurrent: ConcurrentStates,
        meetingIsOSFact: Bool
    ) -> PromptGate {
        // --- Hard blocks. Every one of these is a fact, not a guess. ---
        if session.screenLocked { return .hardBlocked(reason: "the screen is locked") }
        if session.displaysAsleep { return .hardBlocked(reason: "the displays are asleep") }
        if !session.sessionActive {
            return .hardBlocked(reason: "someone else is signed in at the console")
        }
        if meetingIsOSFact {
            // The device is genuinely running. We cannot tell *which* app has it, and we
            // never claim to — but "an audio input device is open" is a system signal, not
            // an inference, so it is allowed to block.
            return .hardBlocked(reason: "an audio input device is running — you may be on a call")
        }

        // --- Soft deferrals. Inferences may delay a prompt; they may never kill it. ---
        if concurrent.inMeeting {
            return .softDeferred(
                reason: "a conferencing app is running, so you might be in a meeting — "
                    + "this only postpones the prompt"
            )
        }
        if concurrent.fullscreen {
            return .softDeferred(
                reason: "something is fullscreen, so you might be presenting — this only "
                    + "postpones the prompt"
            )
        }
        return .allowed
    }

    // MARK: Accessibility

    private func readTitleIfPermitted(
        tiers: SignalTierSet,
        pid: pid_t,
        input: InputActivity,
        now: Date
    ) async -> AXWindowInfo {
        guard tiers.contains(.tier1) else {
            titleCache = nil
            return .empty
        }
        // No point paying for IPC into an app nobody is using.
        if let idle = input.knownIdleSeconds, idle > configuration.idleThreshold {
            return titleCache?.pid == pid ? titleCache?.info ?? .empty : .empty
        }
        if let cache = titleCache,
           cache.pid == pid,
           !titleDirty,
           now.timeIntervalSince(cache.readAt) < configuration.axReconcileInterval {
            return cache.info
        }
        let info = await accessibilityCollector.read(pid: pid)
        titleCache = (pid: pid, info: info, readAt: now)
        titleDirty = false
        return info
    }

    private func startObservingFrontmostWindow() {
        guard permissions.currentTiers().contains(.tier1) else { return }
        let pid = frontmostCollector.snapshot().frontmost.pid
        guard pid > 0, pid != observedPID else { return }
        if let previous = observedPID { accessibilityCollector.stopObserving(pid: previous) }
        accessibilityCollector.startObserving(pid: pid)
        observedPID = pid
    }

    // MARK: Subscriptions

    private func subscribeToWorkspace() {
        let stream = frontmostCollector.events
        tasks.append(Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .activated:
                    // Tier 1 can be revoked in System Settings with no notification, so the
                    // (cheap, non-prompting) trust check runs on every activation.
                    self.permissions.refresh()
                    self.titleDirty = true
                    self.refreshGeometry()
                    self.startObservingFrontmostWindow()
                    await self.sampleAndPublish()
                case .terminated(let app, _):
                    if app.pid == self.observedPID {
                        self.accessibilityCollector.stopObserving(pid: app.pid)
                        self.observedPID = nil
                    }
                case .launched, .deactivated:
                    break
                }
            }
        })
    }

    private func subscribeToSystem() {
        let stream = systemCollector.events
        tasks.append(Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                if event.invalidatesElapsedTime {
                    self.lastElapsedInvalidation = event.timestamp
                }
                switch event {
                case .willSleep, .screenLocked, .displaysSlept, .sessionResignedActive:
                    self.audioCollector.setSystemAwake(false)
                    self.suspendSampling()
                case .didWake, .screenUnlocked, .displaysWoke, .sessionBecameActive:
                    // Notifications posted while we were suspended are notifications we did
                    // not get, so wake reconciles every cached view of the world.
                    self.audioCollector.setSystemAwake(true)
                    self.frontmostCollector.reconcile()
                    self.systemCollector.reconcile()
                    self.permissions.refresh()
                    self.audioCollector.refresh()
                    self.titleDirty = true
                    self.corroboratedAt = self.time.now
                    self.resumeSamplingIfNeeded()
                case .thermalStateChanged(let level, _):
                    if level.shouldShedLoad { self.suspendSampling() } else { self.resumeSamplingIfNeeded() }
                case .powerStateChanged:
                    break
                }
                await self.sampleAndPublish()
            }
        })
    }

    private func subscribeToAudio() {
        let stream = audioCollector.events
        tasks.append(Task { [weak self] in
            for await _ in stream {
                await self?.sampleAndPublish()
            }
        })
    }

    private func subscribeToAccessibility() {
        let stream = accessibilityCollector.events
        tasks.append(Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .titleChanged, .focusedWindowChanged:
                    self.titleDirty = true
                    await self.sampleAndPublish()
                case .observationFailed:
                    // Expected at zero permissions and after a revocation. Nothing to do:
                    // the next sample reads the tier set and degrades on its own.
                    self.titleDirty = true
                }
            }
        })
    }

    private func subscribeToPermissions() {
        let stream = permissions.stream
        tasks.append(Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                self.titleDirty = true
                self.startObservingFrontmostWindow()
                await self.sampleAndPublish()
            }
        })
    }

    private func refreshGeometry() {
        // On demand only, never on a timer: this is garnish (a fullscreen hint and two
        // counts), it is on a deprecation path, and nothing may become load-bearing on it.
        geometry = systemCollector.windowGeometry(frontmostPID: frontmostCollector.snapshot().frontmost.pid)
    }

    // MARK: The one timer

    /// A single `DispatchSourceTimer` for the whole subsystem. N timers would be N
    /// independent wakeup trains; one with generous leeway coalesces with whatever else the
    /// machine is already waking for.
    ///
    /// It is scheduled for the moment the user would next cross an idle threshold — not on
    /// a fixed period — so a heads-down editing session costs roughly two wakeups per idle
    /// episode instead of 3,600 an hour. The interval is also floored at the AX
    /// reconciliation interval while Tier 1 is live, because a missed `AXObserver`
    /// notification leaves a stale title behind.
    private func resumeSamplingIfNeeded() {
        guard running else { return }
        let session = systemCollector.sessionState()
        guard !session.userDefinitelyAway else { return }
        guard !SystemStateCollector.readThermal().shouldShedLoad else { return }
        suspended = false
        scheduleNextWake()
    }

    private func suspendSampling() {
        suspended = true
        cancelTimer()
        // Nothing periodic survives suspension — cancelled outright, not merely skipped.
        // A laptop with the lid closed for eight hours must cost exactly zero.
        accessibilityCollector.stopObservingAll()
        observedPID = nil
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    private func scheduleNextWake() {
        cancelTimer()
        guard running, !suspended else { return }

        let idle = idleCollector.read()
        var delay = IdleCollector.secondsUntilNextThreshold(
            idleSeconds: idle.knownIdleSeconds ?? 0,
            maximum: configuration.idleThreshold
        )
        if permissions.currentTiers().contains(.tier1) {
            delay = min(delay, configuration.axReconcileInterval)
        }

        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(
            deadline: .now() + delay,
            leeway: .milliseconds(Int(delay * configuration.timerLeewayFraction * 1000))
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.sampleAndPublish()
                    self.scheduleNextWake()
                }
            }
        }
        timer = source
        source.resume()
    }
}
