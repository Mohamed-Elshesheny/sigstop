import Foundation

public struct DeveloperContext: Sendable, Codable, Hashable {
    public let timestamp: Date
    public let application: AppIdentity
    public let activity: Activity
    public let confidence: Confidence
    public let evidence: [Evidence]
    public let context: ActivityContext
    public let concurrent: ConcurrentStates
    public let tiersUsed: SignalTierSet

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

    public var claimableActivity: Activity {
        confidence.isConfidentEnoughForSpecificClaim ? activity : (activity.parent ?? activity)
    }

    public var siteOrAppName: String {
        context.browserHost ?? application.localizedName
    }

    public var reasoning: [String] {
        evidence.sorted { abs($0.logOdds) > abs($1.logOdds) }.map(\.summary)
    }
}
