import AppKit
import ApplicationServices

import Foundation
import SigstopCore


public struct UserGesture: Sendable, Hashable {
    public let origin: String

    private init(origin: String) { self.origin = origin }

    public static func clickedButton(_ label: String) -> UserGesture {
        UserGesture(origin: "button:\(label)")
    }
}

public struct PermissionStatus: Sendable, Hashable {
    public let accessibilityTrusted: Bool
    public let accessibilityEnabledInSettings: Bool
    public let browserHostEnabled: Bool
    public let gitContextEnabled: Bool
    public let processContextEnabled: Bool
    public let projectFoldersRegistered: Int
    public let tiers: SignalTierSet

    public var tier1Active: Bool { tiers.contains(.tier1) }

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

    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case osFacts, windowTitles, browserHost, branchName, toolNames
    }

    public enum SignalState: Sendable, Hashable {
        case reading
        case off
        case held(String)
    }

    public struct Signal: Sendable, Hashable, Identifiable {
        public let kind: Kind
        public let cost: Cost
        public let name: String
        public let state: SignalState
        public let reads: String

        public var id: Kind { kind }

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

    public var signals: [Signal] {
        Kind.allCases.map(signal)
    }

    public subscript(kind: Kind) -> Signal {
        signal(kind)
    }

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

public final class PermissionBroker: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: SigstopSettings
    private var cachedTrusted: Bool
    private var continuations: [UUID: AsyncStream<SignalTierSet>.Continuation] = [:]
    private var lastPublished: SignalTierSet

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

    public func browserHostPermitted() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return settings.browserHostEnabled && lastPublished.contains(.tier1)
    }

    public func processContextPermitted() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return settings.processContextEnabled
    }

    public func gitContextPermitted() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return settings.gitContextEnabled
    }

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

    @MainActor
    public func openAccessibilitySettings(_ gesture: UserGesture) {
        _ = gesture
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    static func tiers(settings: SigstopSettings, trusted: Bool) -> SignalTierSet {
        var set: SignalTierSet = [.tier0]
        if settings.accessibilityEnabled && trusted { set.insert(.tier1) }
        if settings.gitContextEnabled || settings.processContextEnabled { set.insert(.tier2) }
        return set
    }
}
