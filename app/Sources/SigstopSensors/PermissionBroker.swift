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

/// What the app can observe right now, and why. Rendered verbatim by `--doctor` and by
/// the Settings pane, so every string here is user-facing.
public struct PermissionStatus: Sendable, Hashable {
    /// `AXIsProcessTrusted()`, the non-prompting check.
    public let accessibilityTrusted: Bool
    /// The user's Tier 1 switch in Settings. Tier 1 needs BOTH this and the grant.
    public let accessibilityEnabledInSettings: Bool
    /// Tier 1b, record the browser host only. A separate opt-in from Tier 1 itself.
    public let browserHostEnabled: Bool
    /// Tier 2, `.git/HEAD` and allowlisted process names. Explicit opt-in.
    public let gitContextEnabled: Bool
    public let tiers: SignalTierSet

    public var tier1Active: Bool { tiers.contains(.tier1) }
    public var tier2Active: Bool { tiers.contains(.tier2) }

    /// One line per tier, in the order a skeptic would ask about them.
    public var explanation: [String] {
        var lines = [
            "Tier 0, frontmost app, idle time, microphone-in-use, screen lock, thermal: "
                + "ON, and it needs no permission. This is most of the product.",
        ]
        switch (accessibilityEnabledInSettings, accessibilityTrusted) {
        case (false, _):
            lines.append("Tier 1, window titles: OFF, you have not turned it on.")
        case (true, false):
            lines.append(
                "Tier 1, window titles: OFF. You turned it on here, but macOS has not granted "
                    + "Accessibility to this app yet."
            )
        case (true, true):
            lines.append("Tier 1, window titles: ON. Titles are parsed and the raw title is discarded.")
        }
        if tier1Active && browserHostEnabled {
            lines.append("Tier 1b, browser host: ON. The host only, never a path or a query string.")
        }
        lines.append(
            gitContextEnabled
                ? "Tier 2, branch name and allowlisted tool names: ON."
                : "Tier 2, branch name and allowlisted tool names: OFF."
        )
        return lines
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
            tiers: lastPublished
        )
    }

    /// True only when the user opted into Tier 1b *and* Tier 1 is actually live. The
    /// browser collector asks this before it reduces a URL to a host.
    public func browserHostPermitted() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return settings.browserHostEnabled && lastPublished.contains(.tier1)
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
        if settings.gitContextEnabled { set.insert(.tier2) }
        return set
    }
}
