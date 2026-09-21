import AppKit
import ApplicationServices

import Foundation
import SigstopCore

/// `kAXTrustedCheckOptionPrompt` is imported from C as a mutable global, so Swift 6
/// strict concurrency refuses to read it at all. Its value is the documented, stable
/// constant below, so we name it directly rather than fight the import.
private nonisolated(unsafe) let axPromptOptionKey = "AXTrustedCheckOptionPrompt" as CFString

// MARK: - User gesture

/// Proof that we are inside an explicit user action.
///
/// `AXIsProcessTrustedWithOptions([axPromptOptionKey: true])` shows a system
/// alert. Calling it from a timer, from launch, or from "we noticed you'd get more out of
/// this" is exactly the behaviour that trains people to deny permissions forever, and it
/// would break CLAUDE.md §4.2, which says the app is fully functional at zero permissions
/// and that Tier 1 is an *upgrade*, never a gate.
///
/// Making the gesture a value that only a UI action site can construct means the prompting
/// path cannot be reached by accident: there is no argument-free overload, and grepping for
/// `UserGesture.` lists every place in the codebase that can raise a system prompt.
public struct UserGesture: Sendable, Hashable {
    /// Where the click came from. Recorded so `--doctor` can say which affordance asked.
    public let origin: String

    /// - Important: Construct this **only** in the handler of a control the user clicked.
    private init(origin: String) { self.origin = origin }

    public static func clickedButton(_ label: String) -> UserGesture {
        UserGesture(origin: "button:\(label)")
    }

    public static func selectedMenuItem(_ label: String) -> UserGesture {
        UserGesture(origin: "menu:\(label)")
    }
}

// MARK: - Status

/// What the app can observe right now, and why. The Settings pane draws `signals` and
/// `--doctor` prints them, from the same rows, so the two cannot disagree. Every string
/// here is user-facing.
public struct PermissionStatus: Sendable, Hashable {
    /// `AXIsProcessTrusted()`, the non-prompting check.
    public let accessibilityTrusted: Bool
    /// The user's Tier 1 switch in Settings. Tier 1 needs BOTH this and the grant.
    public let accessibilityEnabledInSettings: Bool
    /// Tier 1b, record the browser host only. A separate opt-in from Tier 1 itself.
    public let browserHostEnabled: Bool
    /// Tier 2, `.git/HEAD`. Explicit opt-in, and its own switch.
    public let gitContextEnabled: Bool
    /// Tier 2, allowlisted process names. A SEPARATE explicit opt-in.
    public let processContextEnabled: Bool
    /// How many folders the branch reader has been handed. Zero with the switch on is a
    /// different fact from the switch being off, and the row says which.
    public let projectFoldersRegistered: Int
    public let tiers: SignalTierSet

    public var tier1Active: Bool { tiers.contains(.tier1) }
    public var tier2Active: Bool { tiers.contains(.tier2) }

    /// What a row costs you, which is the only axis a settings reader cares about.
    ///
    /// "Tier 0" is the vocabulary of `docs/ACTIVITY-DETECTION.md` and it is the right word
    /// there, where the reader is deciding how to add a provider. Here the question is
    /// "what did I pay for this", so the answer is the label: nothing, an Accessibility
    /// grant, or a switch you found and turned on.
    public enum Cost: Sendable, Hashable, CaseIterable {
        case alwaysOn, needsAccessibility, offByDefault

        public var label: String {
            switch self {
            case .alwaysOn: return "Always on"
            case .needsAccessibility: return "Needs Accessibility"
            case .offByDefault: return "Off by default"
            }
        }
    }

    /// The five things the app can read, in the order a skeptic asks about them.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case osFacts, windowTitles, browserHost, branchName, toolNames
    }

    /// Whether a signal is being read right now, and if not, whose choice that was.
    ///
    /// `held` is the state the old one-line-per-tier list could not draw: the switch is
    /// on and nothing is read, because a grant is missing or a folder was never added.
    /// Printing that as "off" hides the one thing the user has to do next.
    public enum SignalState: Sendable, Hashable {
        case reading
        case off
        /// Switched on here and still not read, and the one thing standing in the way.
        case held(String)
    }

    /// One row of the Access pane and one line of `--doctor`.
    ///
    /// `reads` is the whole claim the row makes, in one sentence or two, and it is kept
    /// here rather than in the view so a terminal and a window print the same words.
    /// The reasoning behind each claim is in `docs/PRIVACY.md`, which the pane links to;
    /// a settings row is not the place to argue, only to say what is true.
    public struct Signal: Sendable, Hashable, Identifiable {
        public let kind: Kind
        public let cost: Cost
        public let name: String
        public let state: SignalState
        public let reads: String

        public var id: Kind { kind }

        /// The `--doctor` form: `Cost, name: ON. What it reads.` A terminal has no
        /// columns, so the state is spelled out in the line.
        public var line: String {
            let word: String
            switch state {
            case .reading: word = "ON"
            case .off: word = "OFF"
            case .held(let reason): word = "OFF, switched on here but \(reason)"
            }
            return "\(cost.label), \(name): \(word). \(reads)"
        }
    }

    /// Every row, every time, in one order. A row never appears or disappears with its
    /// state: the previous list dropped the browser host while it was off, so a reader
    /// who had never turned it on could not learn from this pane that it existed.
    public var signals: [Signal] {
        Kind.allCases.map(signal)
    }

    public subscript(kind: Kind) -> Signal {
        signal(kind)
    }

    /// Printed verbatim by `--doctor` under PERMISSIONS.
    public var explanation: [String] {
        signals.map(\.line)
    }

    private func signal(_ kind: Kind) -> Signal {
        switch kind {
        case .osFacts:
            return Signal(
                kind: kind,
                cost: .alwaysOn,
                name: "front app, idle time, screen lock, mic and camera, power",
                state: .reading,
                reads: "No permission and no prompt. Which app and for how long, whether you "
                    + "are at the keyboard, whether a mic or camera is live and which app "
                    + "holds the mic. Never what is in the window."
            )
        case .windowTitles:
            let state: SignalState
            switch (accessibilityEnabledInSettings, accessibilityTrusted) {
            case (false, _): state = .off
            case (true, false): state = .held("not granted")
            case (true, true): state = .reading
            }
            return Signal(
                kind: kind,
                cost: .needsAccessibility,
                name: "window titles",
                state: state,
                reads: "Two attributes of the front window, its title and its document path. "
                    + "Held for one sample; nothing from either reaches the disk."
            )
        case .browserHost:
            let state: SignalState
            switch (browserHostEnabled, tier1Active) {
            case (false, _): state = .off
            case (true, false): state = .held("needs window titles")
            case (true, true): state = .reading
            }
            return Signal(
                kind: kind,
                cost: .needsAccessibility,
                name: "browser host",
                state: state,
                reads: "The host of the page in front, github.com, from the same document "
                    + "attribute. The path and the query are dropped in the function that "
                    + "parses them."
            )
        case .branchName:
            let state: SignalState
            switch (gitContextEnabled, projectFoldersRegistered > 0) {
            case (false, _): state = .off
            case (true, false): state = .held("no project folder added")
            case (true, true): state = .reading
            }
            return Signal(
                kind: kind,
                cost: .offByDefault,
                name: "branch name",
                state: state,
                reads: "One line of .git/HEAD in the folders you added, and whether a rebase, "
                    + "merge or bisect is under way. Never a diff, a commit or a git command."
            )
        case .toolNames:
            return Signal(
                kind: kind,
                cost: .offByDefault,
                name: "tool names",
                state: processContextEnabled ? .reading : .off,
                reads: "Executable names against a fixed list in the source, plus the kernel's "
                    + "under-a-debugger flag. Never a command line. Without it the app says "
                    + "coding rather than guess at debugging."
            )
        }
    }
}

// MARK: - Broker

/// Owns the answer to "which tiers are available *right now*".
///
/// Tier availability is a runtime value, never a constant (docs/ACTIVITY-DETECTION.md
/// §4.4): the user can revoke Accessibility in System Settings at any moment and macOS
/// sends no notification when they do. So the trust check is re-run on every app-activation
/// event, it is a cheap, non-prompting call, and the engine degrades on the very next
/// sample instead of continuing to publish stale, over-confident observations justified by
/// a title it is no longer allowed to read.
///
/// Lock-guarded rather than actor-isolated so collectors and the engine can ask
/// synchronously on the hot path without an `await` for what is a process-local bool.
public final class PermissionBroker: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: SigstopSettings
    private var cachedTrusted: Bool
    private var continuations: [UUID: AsyncStream<SignalTierSet>.Continuation] = [:]
    private var lastPublished: SignalTierSet

    /// Injected so tests can drive the trust bit without a TCC grant. Production uses
    /// `AXIsProcessTrusted`, which never prompts.
    private let trustCheck: @Sendable () -> Bool

    public init(
        settings: SigstopSettings = .default,
        trustCheck: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.settings = settings
        self.trustCheck = trustCheck
        let trusted = trustCheck()
        self.cachedTrusted = trusted
        self.lastPublished = Self.tiers(settings: settings, trusted: trusted)
    }

    deinit {
        for c in continuations.values { c.finish() }
    }

    // MARK: Reading

    /// The cached answer. Cheap enough for every sample.
    public func currentTiers() -> SignalTierSet {
        lock.lock(); defer { lock.unlock() }
        return lastPublished
    }

    public func status() -> PermissionStatus {
        lock.lock(); defer { lock.unlock() }
        return PermissionStatus(
            accessibilityTrusted: cachedTrusted,
            accessibilityEnabledInSettings: settings.accessibilityEnabled,
            browserHostEnabled: settings.browserHostEnabled,
            gitContextEnabled: settings.gitContextEnabled,
            processContextEnabled: settings.processContextEnabled,
            projectFoldersRegistered: settings.projectFolders.count,
            tiers: lastPublished
        )
    }

    /// True only when the user opted into Tier 1b *and* Tier 1 is actually live. The
    /// browser collector asks this before it reduces a URL to a host.
    public func browserHostPermitted() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return settings.browserHostEnabled && lastPublished.contains(.tier1)
    }

    /// True only when the process switch itself is on.
    ///
    /// `.tier2` is now set by *either* Tier 2 switch, so the tier bit is necessary and not
    /// sufficient, exactly as `browserHostPermitted()` already works. Without this, the
    /// person who agreed to have a branch name read would silently get the process table
    /// enumerated as well, which is the kind of thing this project's readers check.
    public func processContextPermitted() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return settings.processContextEnabled
    }

    /// True only when the git switch itself is on. Same argument as above, other side.
    public func gitContextPermitted() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return settings.gitContextEnabled
    }

    /// Re-reads `AXIsProcessTrusted()` and recomputes the tier set. **Never prompts.**
    /// Called on every app activation and on wake.
    @discardableResult
    public func refresh() -> SignalTierSet {
        let trusted = trustCheck()
        lock.lock()
        cachedTrusted = trusted
        let tiers = Self.tiers(settings: settings, trusted: trusted)
        let changed = tiers != lastPublished
        lastPublished = tiers
        let sinks = changed ? Array(continuations.values) : []
        lock.unlock()
        for sink in sinks { sink.yield(tiers) }
        return tiers
    }

    /// `SIGHUP` in the product's vocabulary: re-read the config. A settings change can
    /// *remove* a tier, which must take effect on the very next sample.
    @discardableResult
    public func apply(_ newSettings: SigstopSettings) -> SignalTierSet {
        lock.lock()
        settings = newSettings
        let tiers = Self.tiers(settings: newSettings, trusted: cachedTrusted)
        let changed = tiers != lastPublished
        lastPublished = tiers
        let sinks = changed ? Array(continuations.values) : []
        lock.unlock()
        for sink in sinks { sink.yield(tiers) }
        return tiers
    }

    public var stream: AsyncStream<SignalTierSet> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
            lock.lock()
            continuations[id] = continuation
            let current = lastPublished
            lock.unlock()
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    // MARK: Prompting, the only path that can raise a system alert

    /// Shows the macOS Accessibility prompt. Requires a `UserGesture`, which can only be
    /// built at a click site, so this cannot be reached from a timer or from launch.
    ///
    /// Returns the trust state *at the moment of the call*. It is almost always `false`
    /// even when the user is about to say yes: the grant lands asynchronously, after they
    /// finish in System Settings, and the process may need to be relaunched before macOS
    /// reports it. Callers must treat `false` here as "asked", not as "refused", and pick
    /// the real answer up from a later `refresh()`.
    @discardableResult
    public func requestAccessibility(_ gesture: UserGesture) -> Bool {
        _ = gesture
        let key = axPromptOptionKey as String
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        lock.lock()
        cachedTrusted = trusted
        let tiers = Self.tiers(settings: settings, trusted: trusted)
        let changed = tiers != lastPublished
        lastPublished = tiers
        let sinks = changed ? Array(continuations.values) : []
        lock.unlock()
        for sink in sinks { sink.yield(tiers) }
        return trusted
    }

    /// Opens the Accessibility pane directly. Preferred over the prompt for a *re*-request:
    /// once macOS has shown that alert for a process it will not show it again, so a second
    /// "Grant" button that appears to do nothing is worse than a button that takes the user
    /// to the switch.
    @MainActor
    public func openAccessibilitySettings(_ gesture: UserGesture) {
        _ = gesture
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Composition

    /// Tier 1 requires BOTH the user's switch and the OS grant. Either one missing means no
    /// window titles, and, because `SignalContext` gates its Tier 1 accessors on this set,
    /// no provider can cite a title it was not allowed to read.
    ///
    /// Tier 1b (browser host) is deliberately not a tier of its own: it rides on Tier 1 and
    /// is additionally gated by `browserHostEnabled` at the collector.
    static func tiers(settings: SigstopSettings, trusted: Bool) -> SignalTierSet {
        var set: SignalTierSet = [.tier0]
        if settings.accessibilityEnabled && trusted { set.insert(.tier1) }
        /// Either Tier 2 switch raises the tier. Which of the two collectors may actually
        /// read is decided at the collector, by `gitContextPermitted()` and
        /// `processContextPermitted()`, so one opt-in never implies the other.
        if settings.gitContextEnabled || settings.processContextEnabled { set.insert(.tier2) }
        return set
    }
}
