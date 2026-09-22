import AppKit
import CoreGraphics
import Foundation
import IOKit.ps
import SigstopCore

public enum SystemEvent: Sendable, Hashable {
    case screenLocked(at: Date)
    case screenUnlocked(at: Date)
    case displaysSlept(at: Date)
    case displaysWoke(at: Date)
    case willSleep(at: Date)
    case didWake(at: Date)
    case sessionResignedActive(at: Date)
    case sessionBecameActive(at: Date)
    case thermalStateChanged(ThermalLevel, at: Date)
    case powerStateChanged(PowerState, at: Date)

    public var timestamp: Date {
        switch self {
        case .screenLocked(let t), .screenUnlocked(let t), .displaysSlept(let t), .displaysWoke(let t),
             .willSleep(let t), .didWake(let t), .sessionResignedActive(let t), .sessionBecameActive(let t),
             .thermalStateChanged(_, let t), .powerStateChanged(_, let t):
            return t
        }
    }

    public var invalidatesElapsedTime: Bool {
        switch self {
        case .didWake, .sessionBecameActive, .screenUnlocked, .displaysWoke: return true
        default: return false
        }
    }
}

@MainActor
public final class SystemStateCollector {
    private let time: any TimeSource
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var defaultObservers: [NSObjectProtocol] = []
    private var continuations: [UUID: AsyncStream<SystemEvent>.Continuation] = [:]

    private var screenLocked = false
    private var displaysAsleep = false
    private var sessionActive = true
    private var systemAsleep = false

    public private(set) var windowGeometryAvailable = true

    public init(time: any TimeSource = SystemTimeSource()) {
        self.time = time
        self.screenLocked = Self.readScreenLockedFromSession() ?? false
        self.sessionActive = Self.readSessionOnConsole() ?? true
    }

    deinit {
        for c in continuations.values { c.finish() }
    }

    public func start() {
        guard workspaceObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(observe(workspace, NSWorkspace.screensDidSleepNotification) { me, at in
            me.displaysAsleep = true
            me.emit(.displaysSlept(at: at))
        })
        workspaceObservers.append(observe(workspace, NSWorkspace.screensDidWakeNotification) { me, at in
            me.displaysAsleep = false
            me.emit(.displaysWoke(at: at))
        })
        workspaceObservers.append(observe(workspace, NSWorkspace.willSleepNotification) { me, at in
            me.systemAsleep = true
            me.emit(.willSleep(at: at))
        })
        workspaceObservers.append(observe(workspace, NSWorkspace.didWakeNotification) { me, at in
            me.systemAsleep = false
            me.reconcile()
            me.emit(.didWake(at: at))
        })
        workspaceObservers.append(observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { me, at in
            me.sessionActive = false
            me.emit(.sessionResignedActive(at: at))
        })
        workspaceObservers.append(observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { me, at in
            me.sessionActive = true
            me.reconcile()
            me.emit(.sessionBecameActive(at: at))
        })

        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(observe(distributed, Notification.Name("com.apple.screenIsLocked")) { me, at in
            me.screenLocked = true
            me.emit(.screenLocked(at: at))
        })
        distributedObservers.append(observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { me, at in
            me.screenLocked = false
            me.emit(.screenUnlocked(at: at))
        })

        let center = NotificationCenter.default
        defaultObservers.append(observe(center, ProcessInfo.thermalStateDidChangeNotification) { me, at in
            me.emit(.thermalStateChanged(Self.readThermal(), at: at))
        })
        defaultObservers.append(observe(center, Notification.Name.NSProcessInfoPowerStateDidChange) { me, at in
            me.emit(.powerStateChanged(Self.readPower(), at: at))
        })
    }

    public func stop() {
        let workspace = NSWorkspace.shared.notificationCenter
        for o in workspaceObservers { workspace.removeObserver(o) }
        workspaceObservers.removeAll()
        let distributed = DistributedNotificationCenter.default()
        for o in distributedObservers { distributed.removeObserver(o) }
        distributedObservers.removeAll()
        for o in defaultObservers { NotificationCenter.default.removeObserver(o) }
        defaultObservers.removeAll()
    }

    public func reconcile() {
        if let locked = Self.readScreenLockedFromSession() { screenLocked = locked }
        if let onConsole = Self.readSessionOnConsole() { sessionActive = onConsole }
    }

    public func sessionState() -> SessionState {
        SessionState(
            screenLocked: screenLocked,
            displaysAsleep: displaysAsleep || systemAsleep,
            sessionActive: sessionActive
        )
    }

    public func powerState() -> PowerState { Self.readPower() }

    public var isSystemAsleep: Bool { systemAsleep }

    public var events: AsyncStream<SystemEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in self?.continuations[id] = nil }
            }
        }
    }

    public func windowGeometry(frontmostPID: pid_t) -> WindowGeometrySnapshot? {
        guard windowGeometryAvailable else { return nil }
        guard let raw = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
              !raw.isEmpty
        else {
            windowGeometryAvailable = false
            return nil
        }

        let screenSizes = NSScreen.screens.map(\.frame.size)
        var frontmostCount = 0
        var fullscreen = false

        for window in raw {
            if let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner == frontmostPID {
                frontmostCount += 1
            }
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            for size in screenSizes
            where abs(bounds.width - size.width) < 2 && abs(bounds.height - size.height) < 2 {
                fullscreen = true
            }
        }

        return WindowGeometrySnapshot(
            onScreenWindowCount: raw.count,
            frontmostWindowCount: frontmostCount,
            hasFullscreenWindow: fullscreen,
            capturedAt: time.now
        )
    }

    private func emit(_ event: SystemEvent) {
        for c in continuations.values { c.yield(event) }
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ body: @escaping @MainActor (SystemStateCollector, Date) -> Void
    ) -> NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                body(self, self.time.now)
            }
        }
    }

    static func readThermal() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return .nominal
        case .fair:     return .fair
        case .serious:  return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    static func readPower() -> PowerState {
        PowerState(
            onBattery: !readOnACPower(),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermal: readThermal()
        )
    }

    static func readOnACPower() -> Bool {
        IOPSGetTimeRemainingEstimate() == kIOPSTimeRemainingUnlimited
    }

    static func readScreenLockedFromSession() -> Bool? {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return dict["CGSSessionScreenIsLocked"] as? Bool
    }

    static func readSessionOnConsole() -> Bool? {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return dict["kCGSSessionOnConsoleKey"] as? Bool
    }
}
