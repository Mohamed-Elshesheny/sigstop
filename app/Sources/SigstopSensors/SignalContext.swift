import Foundation
import SigstopCore

// MARK: - Input

/// Where the idle number came from. Surfaced so the UI can be honest about it:
/// `.ioRegistry` is a fallback and `.unavailable` means we genuinely do not know.
public enum IdleSource: String, Sendable, Codable, Hashable {
    /// `CGEventSource.secondsSinceLastEventType(.hidSystemState, …)`, real human HID input.
    case hidSystemState
    /// `IOHIDSystem` → `HIDIdleTime`. Used when the CoreGraphics path is unavailable.
    case ioRegistry
    /// Neither path answered. Callers must treat this as "no information", never as zero.
    case unavailable
}

public struct InputActivity: Sendable, Hashable, Codable {
    public let idleSeconds: TimeInterval
    public let source: IdleSource

    public init(idleSeconds: TimeInterval, source: IdleSource) {
        self.idleSeconds = idleSeconds.isFinite ? max(0, idleSeconds) : 0
        self.source = source
    }

    /// When the idle number is unavailable we must not pretend the user is present.
    /// Consumers treat `nil` as "unknown" and decline to make a presence claim.
    public var knownIdleSeconds: TimeInterval? {
        source == .unavailable ? nil : idleSeconds
    }

    public static let unknown = InputActivity(idleSeconds: 0, source: .unavailable)
}

// MARK: - Session

/// Things the kernel/window server told us. Every field here is an OS fact, which is
/// the only category permitted to reach `Confidence.certain` (CLAUDE.md §4.1) and the
/// only category permitted to HARD-BLOCK a prompt.
public struct SessionState: Sendable, Hashable, Codable {
    public let screenLocked: Bool
    public let displaysAsleep: Bool
    /// False during fast user switching, someone else is on the console.
    public let sessionActive: Bool

    public init(screenLocked: Bool = false, displaysAsleep: Bool = false, sessionActive: Bool = true) {
        self.screenLocked = screenLocked
        self.displaysAsleep = displaysAsleep
        self.sessionActive = sessionActive
    }

    /// True when the OS says the human cannot be looking at this screen.
    public var userDefinitelyAway: Bool {
        screenLocked || displaysAsleep || !sessionActive
    }

    public static let active = SessionState()
}

// MARK: - Power

/// A local mirror of `ProcessInfo.ThermalState` so the signal model does not depend on
/// the Sendable-conformance of a Foundation enum we do not control.
public enum ThermalLevel: Int, Sendable, Codable, Hashable, Comparable, CaseIterable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Above this the sampling subsystem suspends itself entirely (§8.4).
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

// MARK: - Audio

/// Four states, not a `Bool`, see docs/ACTIVITY-DETECTION.md §2.3.
///
/// `.unreliable` is the important one: on a Mac with Krisp / Loopback / BlackHole /
/// certain headset daemons, an input device is "running somewhere" permanently. On such
/// a machine the signal is a constant `true` and contributes NOTHING to meeting
/// detection. A permanently-on detector is worse than no detector.
public enum AudioInputState: String, Sendable, Codable, Hashable {
    case running
    case notRunning
    case noInputDevice
    case unreliable

    /// Only `.running` is a usable positive. `.unreliable` deliberately is not.
    public var contributesToMeeting: Bool { self == .running }
}

// MARK: - Window geometry (garnish only)

/// Geometry from `CGWindowListCopyWindowInfo`, **no titles**, no Screen Recording.
/// Feature-detected, optional everywhere, and never load-bearing (§2.4).
public struct WindowGeometrySnapshot: Sendable, Hashable, Codable {
    public let onScreenWindowCount: Int
    /// Windows owned by the frontmost PID.
    public let frontmostWindowCount: Int
    /// A layer-0 window covers a whole display. A weak presentation/fullscreen hint.
    public let hasFullscreenWindow: Bool
    public let capturedAt: Date

    public init(onScreenWindowCount: Int, frontmostWindowCount: Int, hasFullscreenWindow: Bool, capturedAt: Date) {
        self.onScreenWindowCount = onScreenWindowCount
        self.frontmostWindowCount = frontmostWindowCount
        self.hasFullscreenWindow = hasFullscreenWindow
        self.capturedAt = capturedAt
    }
}

// MARK: - App switch history

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

// MARK: - Tier 2 signal shapes

/// Allowlisted tool names. The ONLY thing ever extracted from `KERN_PROCARGS2`.
/// Raw argv is matched against this list and immediately discarded, argv routinely
/// contains secrets (`psql "postgres://user:password@…"`). See §4.3.
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

    /// The token as a human would say it, for evidence summaries.
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
    /// Allowlist-matched tool tokens only. Raw argv is never stored here.
    public let matchedTools: Set<ToolToken>
    /// Tools whose parent process is the frontmost app, a much stronger signal, because
    /// it distinguishes "I am debugging" from "a debugger is running in another project".
    public let childrenOfFrontmost: Set<ToolToken>
    public let capturedAt: Date

    public init(matchedTools: Set<ToolToken>, childrenOfFrontmost: Set<ToolToken>, capturedAt: Date) {
        self.matchedTools = matchedTools
        self.childrenOfFrontmost = childrenOfFrontmost
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

// MARK: - SignalContext

/// Everything a provider is allowed to look at, for one sample.
///
/// This is the *entire* input to classification. Providers are pure functions of this
/// value: no state, no I/O, no clock reads. That is what makes every rule in
/// docs/ACTIVITY-DETECTION.md §7 testable by writing a literal, which matters more than
/// usual here, because there is no Xcode and therefore no UI test harness.
public struct SignalContext: Sendable {
    public let now: Date
    /// Which tiers are available *right now*. Tier 1 can be revoked from System Settings
    /// at any moment with no notification, so this is a runtime value, never a constant.
    public let available: SignalTierSet

    public let frontmost: AppIdentity
    public let frontmostSince: Date
    /// Ring buffer, most recent last. Lets a provider see "this is a 3-second lookup
    /// inside a 25-minute editor session" instead of treating it as a new session.
    public let recentApps: [AppSwitch]
    public let runningBundleIDs: Set<String>
    public let input: InputActivity
    public let session: SessionState
    public let power: PowerState
    public let audioInput: AudioInputState
    public let windowGeometry: WindowGeometrySnapshot?

    public let windowTitle: String?
    public let documentURL: URL?
    /// Tier 1b, separately opted in. HOST ONLY, never a path, never a query string.
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

    // MARK: Derived conveniences

    public var frontmostDwell: TimeInterval { max(0, now.timeIntervalSince(frontmostSince)) }

    /// Tier 1 values are only visible when Tier 1 is actually granted. Reading these
    /// through the accessors (rather than the stored properties) makes it impossible for
    /// a provider to cite a title that arrived before the grant was revoked.
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

    /// True when a human demonstrably touched the hardware recently. Unknown idle
    /// (`.unavailable`) is NOT treated as active.
    public func inputWithin(_ seconds: TimeInterval) -> Bool {
        guard let idle = input.knownIdleSeconds else { return false }
        return idle < seconds
    }

    /// Was any app matching `predicate` frontmost within the last `window` seconds?
    /// Used for the AI-corroboration rule (§7.6) and for sticky editor sessions.
    public func wasFrontmostRecently(within window: TimeInterval, where predicate: (AppIdentity) -> Bool) -> Bool {
        let cutoff = now.addingTimeInterval(-window)
        if predicate(frontmost) { return true }
        for entry in recentApps where (entry.leftAt ?? now) >= cutoff {
            if predicate(entry.app) { return true }
        }
        return false
    }

    /// Number of frontmost-app changes in the last `window` seconds. Feeds the weak
    /// "rapid alternation" debugging hint and `DeveloperContext.applicationSwitches`.
    public func switchCount(within window: TimeInterval) -> Int {
        let cutoff = now.addingTimeInterval(-window)
        return recentApps.filter { $0.enteredAt >= cutoff }.count
    }

    public func isRunning(_ bundleID: String) -> Bool { runningBundleIDs.contains(bundleID) }

    public func isAnyRunning(_ bundleIDs: some Sequence<String>) -> Bool {
        bundleIDs.contains { runningBundleIDs.contains($0) }
    }
}
