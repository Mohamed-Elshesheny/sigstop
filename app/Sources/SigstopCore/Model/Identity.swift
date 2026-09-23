import Foundation

public struct AppIdentity: Sendable, Codable, Hashable {
    public let bundleID: String?
    public let localizedName: String
    public let pid: pid_t

    public init(bundleID: String?, localizedName: String, pid: pid_t) {
        self.bundleID = bundleID
        self.localizedName = localizedName
        self.pid = pid
    }
}

public struct ProviderID: Sendable, Codable, Hashable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ s: String) { self.rawValue = s }
}

public enum RepoState: String, Sendable, Codable, Hashable {
    case clean, rebaseInProgress, mergeInProgress, bisecting, detachedHead

    public var displayName: String {
        switch self {
        case .clean:            return "clean"
        case .rebaseInProgress: return "mid-rebase"
        case .mergeInProgress:  return "mid-merge"
        case .bisecting:        return "mid-bisect"
        case .detachedHead:     return "on a detached HEAD"
        }
    }
}

public struct ActivityContext: Sendable, Codable, Hashable {
    public var projectName: String?
    public var fileName: String?
    public var fileExtension: String?
    public var documentURL: URL?
    public var branch: String?
    public var repoState: RepoState?
    public var browserHost: String?

    public init(
        projectName: String? = nil,
        fileName: String? = nil,
        fileExtension: String? = nil,
        documentURL: URL? = nil,
        branch: String? = nil,
        repoState: RepoState? = nil,
        browserHost: String? = nil
    ) {
        self.projectName = projectName
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.documentURL = documentURL
        self.branch = branch
        self.repoState = repoState
        self.browserHost = browserHost
    }

    public static let empty = ActivityContext()
}

public struct ConcurrentStates: Sendable, Codable, Hashable {
    public var inMeeting: Bool
    public var meetingConfidence: Confidence
    public var screenLocked: Bool
    public var onBattery: Bool
    public var lowPowerMode: Bool
    public var fullscreen: Bool

    public init(
        inMeeting: Bool = false,
        meetingConfidence: Confidence = .none,
        screenLocked: Bool = false,
        onBattery: Bool = false,
        lowPowerMode: Bool = false,
        fullscreen: Bool = false
    ) {
        self.inMeeting = inMeeting
        self.meetingConfidence = meetingConfidence
        self.screenLocked = screenLocked
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
        self.fullscreen = fullscreen
    }

    public static let none = ConcurrentStates()
}

public struct ActivityObservation: Sendable, Codable, Hashable {
    public let timestamp: Date
    public let activity: Activity
    public let confidence: Confidence
    public let evidence: [Evidence]
    public let app: AppIdentity
    public let context: ActivityContext
    public let concurrent: ConcurrentStates
    public let providerID: ProviderID
    public let tiersUsed: SignalTierSet

    public init(
        timestamp: Date,
        activity: Activity,
        confidence: Confidence,
        evidence: [Evidence] = [],
        app: AppIdentity,
        context: ActivityContext = .empty,
        concurrent: ConcurrentStates = .none,
        providerID: ProviderID,
        tiersUsed: SignalTierSet = [.tier0]
    ) {
        self.timestamp = timestamp
        self.activity = activity
        self.confidence = confidence
        self.evidence = evidence.sorted { abs($0.logOdds) > abs($1.logOdds) }
        self.app = app
        self.context = context
        self.concurrent = concurrent
        self.providerID = providerID
        self.tiersUsed = tiersUsed
    }

    public var claimableActivity: Activity {
        confidence.isConfidentEnoughForSpecificClaim ? activity : (activity.parent ?? activity)
    }
}
