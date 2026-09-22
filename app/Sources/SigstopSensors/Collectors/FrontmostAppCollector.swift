import AppKit
import Foundation
import SigstopCore

public enum WorkspaceEvent: Sendable, Hashable {
    case activated(AppIdentity, at: Date)
    case deactivated(AppIdentity, at: Date)
    case launched(AppIdentity, at: Date)
    case terminated(AppIdentity, at: Date)

    public var app: AppIdentity {
        switch self {
        case .activated(let a, _), .deactivated(let a, _), .launched(let a, _), .terminated(let a, _): return a
        }
    }

    public var timestamp: Date {
        switch self {
        case .activated(_, let t), .deactivated(_, let t), .launched(_, let t), .terminated(_, let t): return t
        }
    }
}

public struct FrontmostSnapshot: Sendable, Hashable {
    public let frontmost: AppIdentity
    public let frontmostSince: Date
    public let recentApps: [AppSwitch]
    public let runningBundleIDs: Set<String>
    public let switchCount: Int

    public init(
        frontmost: AppIdentity,
        frontmostSince: Date,
        recentApps: [AppSwitch],
        runningBundleIDs: Set<String>,
        switchCount: Int
    ) {
        self.frontmost = frontmost
        self.frontmostSince = frontmostSince
        self.recentApps = recentApps
        self.runningBundleIDs = runningBundleIDs
        self.switchCount = switchCount
    }
}

@MainActor
public final class FrontmostAppCollector {
    public static let historyDepth = 20

    private let time: any TimeSource
    private var observers: [NSObjectProtocol] = []

    private var current: AppIdentity
    private var currentSince: Date
    private var history: [AppSwitch] = []
    private var running: Set<String> = []
    private var switches: Int = 0
    private var continuations: [UUID: AsyncStream<WorkspaceEvent>.Continuation] = [:]

    public static let unknownApp = AppIdentity(bundleID: nil, localizedName: "Unknown", pid: 0)

    public init(time: any TimeSource = SystemTimeSource()) {
        self.time = time
        let now = time.now
        self.current = Self.readFrontmost() ?? Self.unknownApp
        self.currentSince = now
        self.running = Self.readRunningBundleIDs()
    }

    deinit {
        for c in continuations.values { c.finish() }
    }

    public func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        observers.append(observe(center, NSWorkspace.didActivateApplicationNotification) { me, app, at in
            me.handleActivation(app, at: at)
        })
        observers.append(observe(center, NSWorkspace.didDeactivateApplicationNotification) { me, app, at in
            me.emit(.deactivated(app, at: at))
        })
        observers.append(observe(center, NSWorkspace.didLaunchApplicationNotification) { me, app, at in
            if let id = app.bundleID { me.running.insert(id) }
            me.emit(.launched(app, at: at))
        })
        observers.append(observe(center, NSWorkspace.didTerminateApplicationNotification) { me, app, at in
            if let id = app.bundleID { me.running.remove(id) }
            me.emit(.terminated(app, at: at))
        })

        reconcile()
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for o in observers { center.removeObserver(o) }
        observers.removeAll()
    }

    public func reconcile() {
        running = Self.readRunningBundleIDs()
        guard let actual = Self.readFrontmost() else { return }
        if actual != current {
            handleActivation(actual, at: time.now)
        }
    }

    public func snapshot() -> FrontmostSnapshot {
        FrontmostSnapshot(
            frontmost: current,
            frontmostSince: currentSince,
            recentApps: history,
            runningBundleIDs: running,
            switchCount: switches
        )
    }

    public var events: AsyncStream<WorkspaceEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in self?.continuations[id] = nil }
            }
        }
    }

    private func handleActivation(_ app: AppIdentity, at: Date) {
        guard app != current else { return }
        history.append(AppSwitch(app: current, enteredAt: currentSince, leftAt: at))
        if history.count > Self.historyDepth { history.removeFirst(history.count - Self.historyDepth) }
        current = app
        currentSince = at
        switches += 1
        if let id = app.bundleID { running.insert(id) }
        emit(.activated(app, at: at))
    }

    private func emit(_ event: WorkspaceEvent) {
        for c in continuations.values { c.yield(event) }
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ body: @escaping @MainActor (FrontmostAppCollector, AppIdentity, Date) -> Void
    ) -> NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let identity = raw.map(Self.identity(of:))
            MainActor.assumeIsolated {
                guard let self, let identity else { return }
                body(self, identity, self.time.now)
            }
        }
    }

    private nonisolated static func identity(of app: NSRunningApplication) -> AppIdentity {
        AppIdentity(
            bundleID: app.bundleIdentifier,
            localizedName: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
            pid: app.processIdentifier
        )
    }

    private nonisolated static func readFrontmost() -> AppIdentity? {
        if let app = NSWorkspace.shared.frontmostApplication {
            return identity(of: app)
        }
        if let owner = NSWorkspace.shared.runningApplications.first(where: { $0.ownsMenuBar }) {
            return identity(of: owner)
        }
        return nil
    }

    private nonisolated static func readRunningBundleIDs() -> Set<String> {
        var ids: Set<String> = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier else { continue }
            ids.insert(id)
        }
        return ids
    }
}
