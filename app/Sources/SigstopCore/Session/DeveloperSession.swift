import Foundation

public struct DeveloperSession: Sendable, Codable, Hashable, Identifiable {

    public let id: UUID
    public let startedAt: Date
    public private(set) var endedAt: Date?

    public private(set) var continuousActiveWork: TimeInterval = 0
    public private(set) var totalActiveWork: TimeInterval = 0
    public private(set) var peakContinuousActiveWork: TimeInterval = 0
    public private(set) var clock: WorkClockState = .running
    public private(set) var provisionalGraceCredit: TimeInterval = 0

    public private(set) var observedElapsed: TimeInterval = 0

    public private(set) var lastBreakAt: Date?
    public private(set) var lastBreakEndedAt: Date?
    public private(set) var breakCount: Int = 0
    public private(set) var abandonedBreakCount: Int = 0
    public private(set) var skippedBreakCount: Int = 0
    public private(set) var snoozeCount: Int = 0
    public private(set) var ignoredPromptCount: Int = 0
    public private(set) var resetCount: Int = 0

    public private(set) var lastInputAt: Date
    public private(set) var idleDuration: TimeInterval = 0
    public private(set) var accumulatedIdle: TimeInterval = 0

    public private(set) var activeApplication: AppIdentity?
    public private(set) var activity: Activity = .unknown
    public private(set) var activityConfidence: Confidence = .none
    public private(set) var applicationSwitches: Int = 0
    public private(set) var recentSwitches: [Date] = []
    public private(set) var appActiveSeconds: [String: TimeInterval] = [:]

    private var provisionalByApp: [String: TimeInterval] = [:]

    public init(id: UUID = UUID(), startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
        self.lastInputAt = startedAt
    }

    public var isRunning: Bool { if case .running = clock { return true } else { return false } }
    public var isStopped: Bool { if case .stopped = clock { return true } else { return false } }

    public var pauseCause: PauseCause? {
        if case .paused(let cause, _) = clock { return cause }
        return nil
    }

    public var peakContinuous: TimeInterval { max(peakContinuousActiveWork, continuousActiveWork) }

    public func timeSinceLastBreak(now: Date) -> TimeInterval? {
        lastBreakEndedAt.map { now.timeIntervalSince($0) }
    }

    public func focusScore(now: Date, window: TimeInterval = 600) -> Double {
        let switches = recentSwitches.filter { now.timeIntervalSince($0) <= window }.count
        let switchTerm = max(0, min(1, 1 - Double(switches) / 6.0))
        let total = appActiveSeconds.values.reduce(0, +)
        let dominance = total > 0 ? (appActiveSeconds.values.max() ?? 0) / total : 0
        return 0.6 * switchTerm + 0.4 * dominance
    }

    public func isInDeepFocus(now: Date, policy: BreakPolicy) -> Bool {
        focusScore(now: now) >= 0.70
            && continuousActiveWork >= policy.deepFocusMinimumWork
            && activityConfidence.isConfidentEnoughForSpecificClaim
            && BreakPolicy.deepFocusActivities.contains(activity)
    }

    mutating func observe(elapsed: TimeInterval) {
        observedElapsed += max(0, elapsed)
    }

    mutating func credit(_ amount: TimeInterval, provisional: TimeInterval, bundleID: String?) {
        guard amount > 0, isRunning else { return }
        let prov = max(0, min(provisional, amount))
        continuousActiveWork += amount
        totalActiveWork += amount
        provisionalGraceCredit += prov
        if let bundleID {
            appActiveSeconds[bundleID, default: 0] += amount
            if prov > 0 { provisionalByApp[bundleID, default: 0] += prov }
        }
    }

    mutating func confirmProvisionalCredit() {
        provisionalGraceCredit = 0
        provisionalByApp.removeAll(keepingCapacity: true)
    }

    mutating func revokeProvisionalCredit() {
        let amount = provisionalGraceCredit
        provisionalGraceCredit = 0
        for (bundleID, seconds) in provisionalByApp {
            let current = appActiveSeconds[bundleID] ?? 0
            let next = max(0, current - seconds)
            if next <= 0 {
                appActiveSeconds.removeValue(forKey: bundleID)
            } else {
                appActiveSeconds[bundleID] = next
            }
        }
        provisionalByApp.removeAll(keepingCapacity: true)
        guard amount > 0 else { return }
        continuousActiveWork = max(0, continuousActiveWork - amount)
        totalActiveWork = max(0, totalActiveWork - amount)
        accumulatedIdle += amount
    }

    mutating func pauseClock(cause: PauseCause, since: Date) {
        guard !isStopped else { return }
        if case .paused = clock { return }
        clock = .paused(cause: cause, since: since)
    }

    mutating func resumeClock() {
        guard !isStopped else { return }
        clock = .running
    }

    mutating func reset(reason: ResetReason) {
        peakContinuousActiveWork = max(peakContinuousActiveWork, continuousActiveWork)
        continuousActiveWork = 0
        provisionalGraceCredit = 0
        provisionalByApp.removeAll(keepingCapacity: true)
        resetCount += 1
        _ = reason
    }

    mutating func recordBreak(start: Date, end: Date) {
        breakCount += 1
        lastBreakAt = start
        lastBreakEndedAt = end
    }

    mutating func recordAbandonedBreak() { abandonedBreakCount += 1 }
    mutating func recordSkip() { skippedBreakCount += 1 }
    mutating func recordSnooze() { snoozeCount += 1 }
    mutating func recordIgnoredPrompt() { ignoredPromptCount += 1 }

    mutating func noteIdle(_ seconds: TimeInterval, lastInputAt inputDate: Date) {
        idleDuration = max(0, seconds)
        if inputDate > lastInputAt { lastInputAt = inputDate }
    }

    mutating func accumulateIdle(_ seconds: TimeInterval) {
        accumulatedIdle += max(0, seconds)
    }

    mutating func note(
        application: AppIdentity?,
        activity newActivity: Activity,
        confidence: Confidence,
        at now: Date,
        focusWindow: TimeInterval = 600
    ) {
        if let application {
            if let current = activeApplication {
                if current.bundleID != application.bundleID || current.pid != application.pid {
                    applicationSwitches += 1
                    recentSwitches.append(now)
                    activeApplication = application
                }
            } else {
                activeApplication = application
            }
        }
        recentSwitches.removeAll { now.timeIntervalSince($0) > focusWindow }
        activity = newActivity
        activityConfidence = confidence
    }

    mutating func end(at date: Date) {
        guard endedAt == nil else { return }
        peakContinuousActiveWork = max(peakContinuousActiveWork, continuousActiveWork)
        endedAt = date
        clock = .stopped
    }
}
