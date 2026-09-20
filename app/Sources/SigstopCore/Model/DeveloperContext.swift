import Foundation

/// The single value the rest of the app reasons about: who you are, what you appear to
/// be doing, and how long you have been at it.
///
/// Produced by the context engine, consumed by the decision engine and the message
/// engine. Deliberately a plain value type with no behaviour, so that every consumer
/// is trivially testable by constructing one literally.
public struct DeveloperContext: Sendable, Codable, Hashable {
    public let timestamp: Date
    public let application: AppIdentity
    public let activity: Activity
    public let confidence: Confidence
    public let evidence: [Evidence]
    public let context: ActivityContext
    public let concurrent: ConcurrentStates
    public let tiersUsed: SignalTierSet

    /// Continuous ACTIVE work — not elapsed wall time. See docs/BREAK-DECISION.md §1.
    public let continuousWork: TimeInterval
    public let timeSinceLastBreak: TimeInterval?
    public let idleSeconds: TimeInterval
    public let applicationSwitches: Int

    public init(
        timestamp: Date,
        application: AppIdentity,
        activity: Activity,
        confidence: Confidence,
        evidence: [Evidence] = [],
        context: ActivityContext = .empty,
        concurrent: ConcurrentStates = .none,
        tiersUsed: SignalTierSet = [.tier0],
        continuousWork: TimeInterval = 0,
        timeSinceLastBreak: TimeInterval? = nil,
        idleSeconds: TimeInterval = 0,
        applicationSwitches: Int = 0
    ) {
        self.timestamp = timestamp
        self.application = application
        self.activity = activity
        self.confidence = confidence
        self.evidence = evidence
        self.context = context
        self.concurrent = concurrent
        self.tiersUsed = tiersUsed
        self.continuousWork = continuousWork
        self.timeSinceLastBreak = timeSinceLastBreak
        self.idleSeconds = idleSeconds
        self.applicationSwitches = applicationSwitches
    }

    public var continuousWorkMinutes: Int { Int(continuousWork / 60) }

    /// The activity the app is allowed to *name out loud*. Degrades to the parent class
    /// below the confidence threshold rather than guessing between siblings.
    public var claimableActivity: Activity {
        confidence.isConfidentEnoughForSpecificClaim ? activity : (activity.parent ?? activity)
    }

    /// The app's own explanation of itself, printed by `sigstop --doctor`.
    public var reasoning: [String] {
        evidence.sorted { abs($0.logOdds) > abs($1.logOdds) }.map(\.summary)
    }
}
