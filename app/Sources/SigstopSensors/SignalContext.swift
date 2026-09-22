import Foundation
import SigstopCore

public enum IdleSource: String, Sendable, Codable, Hashable {
    case hidSystemState
    case ioRegistry
    case unavailable
}

public struct InputActivity: Sendable, Hashable, Codable {
    public let idleSeconds: TimeInterval
    public let source: IdleSource

    public init(idleSeconds: TimeInterval, source: IdleSource) {
        self.idleSeconds = idleSeconds.isFinite ? max(0, idleSeconds) : 0
        self.source = source
    }

    public var knownIdleSeconds: TimeInterval? {
        source == .unavailable ? nil : idleSeconds
    }

    public static let unknown = InputActivity(idleSeconds: 0, source: .unavailable)
}

public struct SessionState: Sendable, Hashable, Codable {
    public let screenLocked: Bool
    public let displaysAsleep: Bool
    public let sessionActive: Bool

    public init(screenLocked: Bool = false, displaysAsleep: Bool = false, sessionActive: Bool = true) {
        self.screenLocked = screenLocked
        self.displaysAsleep = displaysAsleep
        self.sessionActive = sessionActive
    }

    public var userDefinitelyAway: Bool {
        screenLocked || displaysAsleep || !sessionActive
    }

    public static let active = SessionState()
}

public enum ThermalLevel: Int, Sendable, Codable, Hashable, Comparable, CaseIterable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var shouldShedLoad: Bool { self >= .serious }
}

public struct PowerState: Sendable, Hashable, Codable {
    public let onBattery: Bool
    public let lowPowerMode: Bool
    public let thermal: ThermalLevel

    public init(onBattery: Bool = false, lowPowerMode: Bool = false, thermal: ThermalLevel = .nominal) {
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
        self.thermal = thermal
    }

    public static let plugged = PowerState()
}

public enum AudioInputState: String, Sendable, Codable, Hashable {
    case running
    case notRunning
    case noInputDevice
    case unreliable

    public var contributesToMeeting: Bool { self == .running }
}

public enum CameraInputState: String, Sendable, Codable, Hashable {
    case running
    case notRunning
    case noCameraDevice
    case unreliable

    public var contributesToMeeting: Bool { self == .running }
}

public struct WindowGeometrySnapshot: Sendable, Hashable, Codable {
    public let onScreenWindowCount: Int
    public let frontmostWindowCount: Int
    public let hasFullscreenWindow: Bool
    public let capturedAt: Date

    public init(onScreenWindowCount: Int, frontmostWindowCount: Int, hasFullscreenWindow: Bool, capturedAt: Date) {
        self.onScreenWindowCount = onScreenWindowCount
        self.frontmostWindowCount = frontmostWindowCount
        self.hasFullscreenWindow = hasFullscreenWindow
        self.capturedAt = capturedAt
    }
}

public struct AppSwitch: Sendable, Hashable, Codable {
    public let app: AppIdentity
    public let enteredAt: Date
    public let leftAt: Date?

    public init(app: AppIdentity, enteredAt: Date, leftAt: Date? = nil) {
        self.app = app
        self.enteredAt = enteredAt
        self.leftAt = leftAt
    }

    public func dwell(asOf now: Date) -> TimeInterval {
        max(0, (leftAt ?? now).timeIntervalSince(enteredAt))
    }
}

public enum ToolToken: String, Sendable, Codable, CaseIterable, Hashable {
    case lldb, debugserver, gdb, delve, debugpy, nodeInspect
    case pytest, jest, vitest, xctest, goTest, cargoTest, swiftTesting, rspec, phpunit, playwright
    case vim, nvim, helix, emacs, nano
    case claudeCLI, aider, codexCLI, gooseCLI
    case gitProcess, ghCLI, xcodebuild, gradle, cargo, swiftBuild, tsc, webpack, vite
    case ssh, mosh, kubectl

    public static let debuggers: Set<ToolToken> = [.lldb, .debugserver, .gdb, .delve, .debugpy, .nodeInspect]
    public static let testRunners: Set<ToolToken> = [
        .pytest, .jest, .vitest, .xctest, .goTest, .cargoTest, .swiftTesting, .rspec, .phpunit, .playwright,
    ]
    public static let terminalEditors: Set<ToolToken> = [.vim, .nvim, .helix, .emacs, .nano]
    public static let aiCLIs: Set<ToolToken> = [.claudeCLI, .aider, .codexCLI, .gooseCLI]
    public static let remoteShells: Set<ToolToken> = [.ssh, .mosh, .kubectl]

    public var displayName: String {
        switch self {
        case .nodeInspect:  return "node --inspect"
        case .goTest:       return "go test"
        case .cargoTest:    return "cargo test"
        case .swiftTesting: return "swift test"
        case .gitProcess:   return "git"
        case .ghCLI:        return "gh"
        case .claudeCLI:    return "claude"
        case .codexCLI:     return "codex"
        case .gooseCLI:     return "goose"
        case .swiftBuild:   return "swift build"
        default:            return rawValue
        }
    }
}

public struct ProcessSnapshot: Sendable, Hashable, Codable {
    public let matchedTools: Set<ToolToken>
    public let childrenOfFrontmost: Set<ToolToken>
    public let tracedUnderFrontmost: Bool
    public let tracedElsewhere: Bool
    public let capturedAt: Date

    public init(
        matchedTools: Set<ToolToken>,
        childrenOfFrontmost: Set<ToolToken>,
        tracedUnderFrontmost: Bool = false,
        tracedElsewhere: Bool = false,
        capturedAt: Date
    ) {
        self.matchedTools = matchedTools
        self.childrenOfFrontmost = childrenOfFrontmost
        self.tracedUnderFrontmost = tracedUnderFrontmost
        self.tracedElsewhere = tracedElsewhere
        self.capturedAt = capturedAt
    }

    public func has(_ token: ToolToken) -> Bool { matchedTools.contains(token) }
    public func firstMatch(in group: Set<ToolToken>) -> ToolToken? {
        matchedTools.intersection(group).sorted { $0.rawValue < $1.rawValue }.first
    }
    public func firstChildMatch(in group: Set<ToolToken>) -> ToolToken? {
        childrenOfFrontmost.intersection(group).sorted { $0.rawValue < $1.rawValue }.first
    }
}

public struct GitSignal: Sendable, Hashable, Codable {
    public let branch: String?
    public let repoState: RepoState?
    public let repoName: String?
    public let readAt: Date

    public init(branch: String?, repoState: RepoState?, repoName: String?, readAt: Date) {
        self.branch = branch
        self.repoState = repoState
        self.repoName = repoName
        self.readAt = readAt
    }
}

public struct SignalContext: Sendable {
    public let now: Date
    public let available: SignalTierSet

    public let frontmost: AppIdentity
    public let frontmostSince: Date
    public let recentApps: [AppSwitch]
    public let runningBundleIDs: Set<String>
    public let input: InputActivity
    public let session: SessionState
    public let power: PowerState
    public let audioInput: AudioInputState
    public let windowGeometry: WindowGeometrySnapshot?

    public let windowTitle: String?
    public let documentURL: URL?
    public let browserHost: String?

    public let processes: ProcessSnapshot?
    public let git: GitSignal?

    public init(
        now: Date,
        available: SignalTierSet = [.tier0],
        frontmost: AppIdentity,
        frontmostSince: Date? = nil,
        recentApps: [AppSwitch] = [],
        runningBundleIDs: Set<String> = [],
        input: InputActivity = InputActivity(idleSeconds: 0, source: .hidSystemState),
        session: SessionState = .active,
        power: PowerState = .plugged,
        audioInput: AudioInputState = .notRunning,
        windowGeometry: WindowGeometrySnapshot? = nil,
        windowTitle: String? = nil,
        documentURL: URL? = nil,
        browserHost: String? = nil,
        processes: ProcessSnapshot? = nil,
        git: GitSignal? = nil
    ) {
        self.now = now
        self.available = available
        self.frontmost = frontmost
        self.frontmostSince = frontmostSince ?? now
        self.recentApps = recentApps
        self.runningBundleIDs = runningBundleIDs
        self.input = input
        self.session = session
        self.power = power
        self.audioInput = audioInput
        self.windowGeometry = windowGeometry
        self.windowTitle = windowTitle
        self.documentURL = documentURL
        self.browserHost = browserHost
        self.processes = processes
        self.git = git
    }

    public var frontmostDwell: TimeInterval { max(0, now.timeIntervalSince(frontmostSince)) }

    public var titleIfPermitted: String? {
        guard available.contains(.tier1) else { return nil }
        guard let t = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    public var documentURLIfPermitted: URL? {
        available.contains(.tier1) ? documentURL : nil
    }

    public var browserHostIfPermitted: String? {
        available.contains(.tier1) ? browserHost : nil
    }

    public var processesIfPermitted: ProcessSnapshot? {
        available.contains(.tier2) ? processes : nil
    }

    public var gitIfPermitted: GitSignal? {
        available.contains(.tier2) ? git : nil
    }

    public func inputWithin(_ seconds: TimeInterval) -> Bool {
        guard let idle = input.knownIdleSeconds else { return false }
        return idle < seconds
    }

    public func wasFrontmostRecently(within window: TimeInterval, where predicate: (AppIdentity) -> Bool) -> Bool {
        let cutoff = now.addingTimeInterval(-window)
        if predicate(frontmost) { return true }
        for entry in recentApps where (entry.leftAt ?? now) >= cutoff {
            if predicate(entry.app) { return true }
        }
        return false
    }

    public func switchCount(within window: TimeInterval) -> Int {
        let cutoff = now.addingTimeInterval(-window)
        return recentApps.filter { $0.enteredAt >= cutoff }.count
    }

    public func isRunning(_ bundleID: String) -> Bool { runningBundleIDs.contains(bundleID) }

    public func isAnyRunning(_ bundleIDs: some Sequence<String>) -> Bool {
        bundleIDs.contains { runningBundleIDs.contains($0) }
    }
}
