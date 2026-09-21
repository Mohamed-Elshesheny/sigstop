import Foundation

// MARK: - Input

/// One sample of the world, as the sensor layer sees it. Everything here is a Tier 0 fact
/// except `activity`/`confidence`, which are an inference and are never allowed to move the
/// clock on their own.
public struct TickSample: Sendable, Hashable {
    /// `CGEventSource.secondsSinceLastEventType`, keyboard, mouse, trackpad, tablet, all
    /// apps, no permission required.
    public var idleSeconds: TimeInterval
    public var screenLocked: Bool
    /// The audio input device is actually running. A fact, not a guess about an app.
    public var micRunning: Bool
    public var fastUserSwitched: Bool
    public var userPaused: Bool
    public var application: AppIdentity?
    public var activity: Activity
    public var confidence: Confidence

    public init(
        idleSeconds: TimeInterval = 0,
        screenLocked: Bool = false,
        micRunning: Bool = false,
        fastUserSwitched: Bool = false,
        userPaused: Bool = false,
        application: AppIdentity? = nil,
        activity: Activity = .unknown,
        confidence: Confidence = .none
    ) {
        self.idleSeconds = idleSeconds
        self.screenLocked = screenLocked
        self.micRunning = micRunning
        self.fastUserSwitched = fastUserSwitched
        self.userPaused = userPaused
        self.application = application
        self.activity = activity
        self.confidence = confidence
    }
}

/// What a tick did. The tracker reports; it never notifies, presents, or decides.
public enum SessionEvent: Sendable, Codable, Hashable {
    case sessionStarted(id: UUID, at: Date)
    case sessionEnded(id: UUID, at: Date)
    case gapClassified(GapClassificationKind, duration: TimeInterval, cause: PauseCause)
    case clockPaused(cause: PauseCause, since: Date)
    /// SIGCONT: the clock continues from exactly where it stopped.
    case clockResumed(at: Date)
    case clockReset(reason: ResetReason)
    case breakRecorded(origin: BreakOrigin, start: Date, end: Date, duration: TimeInterval)
    case graceRevoked(seconds: TimeInterval)
    /// The wall clock moved without the monotonic clock: an NTP step, or the user changed
    /// the date. It is neither work nor a break, and it is never allowed to touch the clock.
    case wallClockSkewIgnored(seconds: TimeInterval)
}

/// `GapClassification` carries a `PauseCause` payload, which makes it awkward to report in a
/// flat event. This is the same taxonomy without the payload.
public enum GapClassificationKind: String, Sendable, Codable, Hashable {
    case microIdle
    case pause
    case qualifyingBreak
    case sessionEnd

    init(_ classification: GapClassification) {
        switch classification {
        case .microIdle:        self = .microIdle
        case .pause:            self = .pause
        case .qualifyingBreak:  self = .qualifyingBreak
        case .sessionEnd:       self = .sessionEnd
        }
    }
}

// MARK: - Tracker

/// The work clock: continuous **active** work, which is not elapsed wall time.
///
/// Two rules carry the whole design:
///
/// 1. **Durations come from `TimeSource.continuousSeconds`, never from `now`.** The wall clock
///    steps (NTP, DST, a user setting the date) and a stepped wall clock must not be able to
///    fabricate work or a break. `now` is used for timestamps and for calendar questions only.
/// 2. **A tick never trusts its own interval.** A tick that lands later than
///    `tickInterval + tickTolerance` is a discontinuity, not a tick; it is classified as a gap
///    and credited nothing. Credited work can therefore never exceed observed elapsed time.
public struct SessionTracker: Sendable {

    public let policy: BreakPolicy
    private let time: any TimeSource
    private let calendar: Calendar

    public private(set) var session: DeveloperSession
    public private(set) var sessionCount: Int = 1

    private var lastTickMono: Double
    private var lastTickWall: Date
    /// Monotonic timestamp of the most recent input event we know about.
    private var lastInputMono: Double
    private var dayIndex: Int
    private var gap: ActiveGap?

    /// When the current break started, tracked apart from the idle gap.
    ///
    /// The gap is closed by input, which is correct for idleness and wrong for a break: a
    /// break does not end because you moved the mouse, it ends when the app says it ends.
    /// Measuring the break from the gap meant any input during it wiped the start marker,
    /// `endBreak` then measured roughly zero, the break failed the qualifying threshold,
    /// the work clock was never reset, and the engine re-prompted in the same second the
    /// break finished.
    private var breakStart: (mono: Double, wall: Date)?
    private var pendingWakeCause: PauseCause?
    private var awaitingNewSession: Bool = false

    private struct ActiveGap: Sendable {
        var cause: PauseCause
        var startMono: Double
        var startWall: Date
        var paused: Bool = false
        var didReset: Bool = false
        var didRecordBreak: Bool = false
        var didEndSession: Bool = false
        var lastReportedKind: GapClassificationKind?
    }

    public init(time: any TimeSource, policy: BreakPolicy = .default, calendar: Calendar = .current) {
        self.time = time
        self.policy = policy
        self.calendar = calendar
        let now = time.now
        let mono = time.continuousSeconds
        self.session = DeveloperSession(startedAt: now)
        self.lastTickMono = mono
        self.lastTickWall = now
        self.lastInputMono = mono
        self.dayIndex = LocalDay.index(of: now, calendar: calendar, boundaryHour: policy.dayBoundaryHour)
    }

    // MARK: - Notifications from the app layer

    /// The machine slept and has just woken. Labels the next discontinuity `.systemSleep`
    /// instead of "the timer was starved"; the duration bands are identical either way.
    public mutating func noteSystemWake() { pendingWakeCause = .systemSleep }

    /// The user accepted (or started) a break. The clock pauses, it does not reset. A break
    /// that turns out to be too short must cost nothing.
    @discardableResult
    public mutating func beginBreak(origin: BreakOrigin) -> [SessionEvent] {
        let now = time.now
        let mono = time.continuousSeconds
        session.revokeProvisionalCredit()
        session.pauseClock(cause: .breakActive, since: now)
        gap = ActiveGap(cause: .breakActive, startMono: mono, startWall: now, paused: true)
        breakStart = (mono: mono, wall: now)
        return [.clockPaused(cause: .breakActive, since: now)]
    }

    /// End a break. Long enough and it is a real break: reset and record. Too short and it
    /// is nothing at all, counting it would make the compliance number a lie the user can farm.
    @discardableResult
    public mutating func endBreak(origin: BreakOrigin) -> [SessionEvent] {
        let now = time.now
        let mono = time.continuousSeconds
        var events: [SessionEvent] = []
        let start = breakStart?.wall ?? gap?.startWall ?? now
        let duration = mono - (breakStart?.mono ?? gap?.startMono ?? mono)
        if duration >= policy.qualifyingBreak {
            session.reset(reason: .qualifyingBreak)
            session.recordBreak(start: start, end: now)
            events.append(.clockReset(reason: .qualifyingBreak))
            events.append(.breakRecorded(origin: origin, start: start, end: now, duration: duration))
        } else {
            session.recordAbandonedBreak()
        }
        gap = nil
        breakStart = nil
        lastInputMono = mono
        session.resumeClock()
        events.append(.clockResumed(at: now))
        return events
    }

    public mutating func recordSkip() { session.recordSkip() }
    public mutating func recordSnooze() { session.recordSnooze() }
    public mutating func recordIgnoredPrompt() { session.recordIgnoredPrompt() }

    // MARK: - The tick

    @discardableResult
    public mutating func tick(_ sample: TickSample) -> [SessionEvent] {
        var events: [SessionEvent] = []
        let now = time.now
        let mono = time.continuousSeconds

        let delta = max(0, mono - lastTickMono)
        let wallDelta = now.timeIntervalSince(lastTickWall)
        let skew = wallDelta - delta
        let skewed = abs(skew) > policy.wallClockSkewTolerance
        if skewed {
            dayIndex = LocalDay.index(of: now, calendar: calendar, boundaryHour: policy.dayBoundaryHour)
            events.append(.wallClockSkewIgnored(seconds: skew))
        }
        lastTickMono = mono
        lastTickWall = now

        session.observe(elapsed: delta)
        session.note(application: sample.application, activity: sample.activity, confidence: sample.confidence, at: now)

        let discontinuity = delta > policy.tickInterval + policy.tickTolerance
        let idle = max(0, sample.idleSeconds)
        let inputMono = mono - idle

        if !discontinuity, inputMono > lastInputMono + 0.001 {
            session.confirmProvisionalCredit()
            lastInputMono = inputMono
        }
        session.noteIdle(idle, lastInputAt: now.addingTimeInterval(-idle))

        if !skewed {
            let today = LocalDay.index(of: now, calendar: calendar, boundaryHour: policy.dayBoundaryHour)
            if today != dayIndex {
                dayIndex = today
                session.reset(reason: .dayBoundary)
                events.append(.clockReset(reason: .dayBoundary))
                events.append(contentsOf: endSession(at: now))
            }
        }

        let cause = pauseCause(for: sample, discontinuity: discontinuity, idle: idle)

        if let cause {
            openOrUpdateGap(cause: cause, now: now, mono: mono, discontinuity: discontinuity, events: &events)
        } else if gap != nil {
            closeGap(now: now, mono: mono, events: &events)
        }

        creditIfPossible(delta: discontinuity ? 0 : delta, mono: mono, bundleID: sample.application?.bundleID)

        if gap != nil {
            applyGapThresholds(now: now, mono: mono, micRunning: sample.micRunning, events: &events)
        }

        if awaitingNewSession, cause == nil {
            startNewSession(at: now, mono: mono, events: &events)
        }

        return events
    }

    // MARK: - Gap machinery

    /// Why the clock should not be crediting right now, or nil if it should.
    private func pauseCause(for sample: TickSample, discontinuity: Bool, idle: TimeInterval) -> PauseCause? {
        if sample.screenLocked { return .screenLocked }
        if sample.userPaused { return .userPaused }
        if sample.fastUserSwitched { return .fastUserSwitch }
        if session.pauseCause == .breakActive { return .breakActive }
        if discontinuity { return pendingWakeCause ?? (sample.micRunning ? .meetingNoInput : .microIdleExceeded) }
        if idle >= policy.microIdleGrace {
            return sample.micRunning ? .meetingNoInput : .microIdleExceeded
        }
        return nil
    }

    private mutating func openOrUpdateGap(
        cause: PauseCause,
        now: Date,
        mono: Double,
        discontinuity: Bool,
        events: inout [SessionEvent]
    ) {
        if gap == nil {
            let startMono: Double
            switch cause {
            case .microIdleExceeded, .meetingNoInput:
                startMono = lastInputMono
            default:
                startMono = min(lastInputMono, lastTickMonoBefore(mono: mono, discontinuity: discontinuity))
            }
            let clamped = min(startMono, mono)
            gap = ActiveGap(
                cause: cause,
                startMono: clamped,
                startWall: now.addingTimeInterval(-(mono - clamped))
            )
        } else if var existing = gap, existing.cause != cause {
            if cause != .microIdleExceeded { existing.cause = cause }
            gap = existing
        }
        if cause == .systemSleep { pendingWakeCause = nil }
    }

    private func lastTickMonoBefore(mono: Double, discontinuity: Bool) -> Double {
        mono
    }

    private mutating func closeGap(now: Date, mono: Double, events: inout [SessionEvent]) {
        guard let existing = gap else { return }
        guard existing.cause != .breakActive else { return }
        let duration = mono - existing.startMono
        if existing.lastReportedKind == nil {
            events.append(.gapClassified(.microIdle, duration: duration, cause: existing.cause))
        }
        gap = nil
        if existing.paused, !session.isStopped {
            session.resumeClock()
            events.append(.clockResumed(at: now))
        }
    }

    private mutating func applyGapThresholds(now: Date, mono: Double, micRunning: Bool, events: inout [SessionEvent]) {
        guard var current = gap else { return }
        let duration = mono - current.startMono
        let classification = classify(duration: duration, cause: current.cause)
        let kind = GapClassificationKind(classification)

        if current.lastReportedKind != kind {
            current.lastReportedKind = kind
            events.append(.gapClassified(kind, duration: duration, cause: current.cause))
        }

        switch classification {
        case .microIdle:
            break

        case .pause(let cause):
            if !current.paused {
                let revoked = session.provisionalGraceCredit
                session.revokeProvisionalCredit()
                if revoked > 0 { events.append(.graceRevoked(seconds: revoked)) }
                session.pauseClock(cause: cause, since: current.startWall)
                current.paused = true
                events.append(.clockPaused(cause: cause, since: current.startWall))
            }
            if duration >= policy.longPauseReset, !current.didReset {
                current.didReset = true
                session.reset(reason: .longPause)
                events.append(.clockReset(reason: .longPause))
            }

        case .qualifyingBreak:
            if !current.paused {
                let revoked = session.provisionalGraceCredit
                session.revokeProvisionalCredit()
                if revoked > 0 { events.append(.graceRevoked(seconds: revoked)) }
                session.pauseClock(cause: current.cause, since: current.startWall)
                current.paused = true
                events.append(.clockPaused(cause: current.cause, since: current.startWall))
            }
            if !current.didRecordBreak {
                current.didRecordBreak = true
                current.didReset = true
                session.reset(reason: .qualifyingBreak)
                session.recordBreak(start: current.startWall, end: now)
                session.accumulateIdle(duration)
                events.append(.clockReset(reason: .qualifyingBreak))
                events.append(.breakRecorded(origin: .idleInferred, start: current.startWall, end: now, duration: duration))
            }

        case .sessionEnd:
            if !current.paused {
                let revoked = session.provisionalGraceCredit
                session.revokeProvisionalCredit()
                if revoked > 0 { events.append(.graceRevoked(seconds: revoked)) }
                session.pauseClock(cause: current.cause, since: current.startWall)
                current.paused = true
                events.append(.clockPaused(cause: current.cause, since: current.startWall))
            }
            if !current.didEndSession {
                current.didEndSession = true
                if !current.didReset {
                    current.didReset = true
                    session.reset(reason: .longPause)
                    events.append(.clockReset(reason: .longPause))
                }
                events.append(contentsOf: endSession(at: current.startWall))
            }
        }

        gap = current
    }

    /// The authoritative table of docs/BREAK-DECISION.md §4.1, as one function.
    public func classify(duration: TimeInterval, cause: PauseCause) -> GapClassification {
        switch cause {
        case .meetingNoInput, .userPaused, .breakActive:
            return .pause(cause)
        case .screenLocked, .systemSleep, .displaySleep, .fastUserSwitch:
            if duration < policy.qualifyingBreak { return .pause(cause) }
            if duration < policy.sessionGap { return .qualifyingBreak }
            return .sessionEnd
        case .microIdleExceeded:
            if duration < policy.microIdleGrace { return .microIdle }
            if duration < policy.qualifyingBreak { return .pause(.microIdleExceeded) }
            if duration < policy.sessionGap { return .qualifyingBreak }
            return .sessionEnd
        }
    }

    // MARK: - Crediting

    private mutating func creditIfPossible(delta: TimeInterval, mono: Double, bundleID: String?) {
        guard delta > 0, session.isRunning else { return }
        let start = mono - delta
        var creditEnd = min(mono, lastInputMono + policy.microIdleGrace)
        if let gap { creditEnd = min(creditEnd, gap.startMono) }
        let credited = max(0, creditEnd - start)
        guard credited > 0 else { return }
        let provisional = max(0, creditEnd - max(start, lastInputMono))
        session.credit(credited, provisional: provisional, bundleID: bundleID)
    }

    // MARK: - Session lifecycle

    private mutating func endSession(at date: Date) -> [SessionEvent] {
        guard !session.isStopped else { return [] }
        let id = session.id
        session.end(at: date)
        awaitingNewSession = true
        return [.sessionEnded(id: id, at: date)]
    }

    private mutating func startNewSession(at now: Date, mono: Double, events: inout [SessionEvent]) {
        awaitingNewSession = false
        session = DeveloperSession(startedAt: now)
        sessionCount += 1
        lastInputMono = mono
        gap = nil
        events.append(.sessionStarted(id: session.id, at: now))
    }

    // MARK: - Handing the session to the decision engine

    /// The snapshot the decision and message engines consume.
    public func makeContext(now: Date, evidence: [Evidence] = [], context: ActivityContext = .empty, concurrent: ConcurrentStates = .none) -> DeveloperContext {
        DeveloperContext(
            timestamp: now,
            application: session.activeApplication ?? AppIdentity(bundleID: nil, localizedName: "unknown", pid: 0),
            activity: session.activity,
            confidence: session.activityConfidence,
            evidence: evidence,
            context: context,
            concurrent: concurrent,
            continuousWork: session.continuousActiveWork,
            timeSinceLastBreak: session.timeSinceLastBreak(now: now),
            idleSeconds: session.idleDuration,
            applicationSwitches: session.applicationSwitches
        )
    }

    public var focusScore: Double { session.focusScore(now: time.now) }
}
