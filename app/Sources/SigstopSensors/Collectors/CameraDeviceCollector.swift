import CoreMediaIO
import Foundation
import SigstopCore

public final class CameraDeviceCollector: @unchecked Sendable {
    public static let continuousRunningUnreliableThreshold: TimeInterval = 4 * 3600
    public static let unreliableDutyCycle: Double = 0.85
    public static let calibrationMinimumObservation: TimeInterval = 3600
    public static let calibrationWindow: TimeInterval = 24 * 3600

    private let time: any TimeSource
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.sigstop.camera", qos: .utility)

    private var isRunningRaw: Bool?
    private var runningSince: Double?
    private var windowStart: Double
    private var observedAwakeSeconds: TimeInterval = 0
    private var runningAwakeSeconds: TimeInterval = 0
    private var lastAccountedAt: Double
    private var systemAwake = true
    private var started = false
    private var deviceNames: [String] = []
    private var deviceListeners: [CMIOObjectID: CMIOObjectPropertyListenerBlock] = [:]
    private var hardwareListener: CMIOObjectPropertyListenerBlock?
    private var continuations: [UUID: AsyncStream<CameraInputState>.Continuation] = [:]

    public init(time: any TimeSource = SystemTimeSource()) {
        self.time = time
        let now = time.continuousSeconds
        self.windowStart = now
        self.lastAccountedAt = now
    }

    deinit {
        removeAllListeners()
        for c in continuations.values { c.finish() }
    }

    public func start() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()

        registerHardwareListener()
        refresh()
    }

    public func stop() {
        lock.lock()
        started = false
        lock.unlock()
        removeAllListeners()
    }

    public func refresh() {
        let devices = Self.cameraDevices()
        registerDeviceListeners(devices)
        let names = devices.map { Self.name(of: $0) ?? "unnamed camera" }
        let raw: Bool? = devices.isEmpty
            ? nil
            : devices.contains { Self.deviceIsRunningSomewhere($0) == true }
        lock.lock()
        deviceNames = names
        lock.unlock()
        update(raw: raw)
    }

    public func setSystemAwake(_ awake: Bool) {
        lock.lock()
        accountLocked(at: time.continuousSeconds)
        systemAwake = awake
        lock.unlock()
        if awake { refresh() }
    }

    public func state() -> CameraInputState {
        lock.lock()
        accountLocked(at: time.continuousSeconds)
        let raw = isRunningRaw
        let unreliable = isUnreliableLocked(at: time.continuousSeconds)
        lock.unlock()

        if unreliable { return .unreliable }
        switch raw {
        case .none:        return .noCameraDevice
        case .some(true):  return .running
        case .some(false): return .notRunning
        }
    }

    public func devices() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return deviceNames
    }

    public func unreliabilityExplanation() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let now = time.continuousSeconds
        accountLocked(at: now)
        guard isUnreliableLocked(at: now) else { return nil }
        if let since = runningSince, (now - since) > Self.continuousRunningUnreliableThreshold {
            let hours = Int((now - since) / 3600)
            return "Camera signal disabled on this Mac, a camera device has been running "
                + "continuously for \(hours)h. Something (OBS, a virtual camera, a docked "
                + "phone) is holding it open, so it cannot indicate a call."
        }
        let pct = Int((runningAwakeSeconds / max(observedAwakeSeconds, 1)) * 100)
        return "Camera signal disabled on this Mac, a camera device was running for "
            + "\(pct)% of the last day. It never turns off, so it cannot indicate a call."
    }

    public var events: AsyncStream<CameraInputState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    private func update(raw: Bool?) {
        lock.lock()
        let now = time.continuousSeconds
        accountLocked(at: now)
        let changed = raw != isRunningRaw
        isRunningRaw = raw
        if raw == true {
            if runningSince == nil { runningSince = now }
        } else {
            runningSince = nil
        }
        let sinks = changed ? Array(continuations.values) : []
        let unreliable = isUnreliableLocked(at: now)
        lock.unlock()

        guard changed else { return }
        let published: CameraInputState = unreliable
            ? .unreliable
            : (raw == nil ? .noCameraDevice : (raw == true ? .running : .notRunning))
        for sink in sinks { sink.yield(published) }
    }

    private func accountLocked(at now: Double) {
        let elapsed = (now - lastAccountedAt)
        lastAccountedAt = now
        guard elapsed > 0 else { return }
        guard systemAwake else { return }

        observedAwakeSeconds += elapsed
        if isRunningRaw == true { runningAwakeSeconds += elapsed }

        if (now - windowStart) > Self.calibrationWindow {
            observedAwakeSeconds *= 0.5
            runningAwakeSeconds *= 0.5
            windowStart = now - Self.calibrationWindow / 2
        }
    }

    private func isUnreliableLocked(at now: Double) -> Bool {
        if let since = runningSince, (now - since) > Self.continuousRunningUnreliableThreshold {
            return true
        }
        guard observedAwakeSeconds >= Self.calibrationMinimumObservation else { return false }
        return (runningAwakeSeconds / observedAwakeSeconds) > Self.unreliableDutyCycle
    }

    private func registerHardwareListener() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refresh()
        }
        let status = CMIOObjectAddPropertyListenerBlock(
            CMIOObjectID(kCMIOObjectSystemObject), &address, queue, block
        )
        if status == noErr {
            lock.lock()
            hardwareListener = block
            lock.unlock()
        }
    }

    private func registerDeviceListeners(_ devices: [CMIOObjectID]) {
        lock.lock()
        let existing = Set(deviceListeners.keys)
        lock.unlock()

        let wanted = Set(devices)

        for gone in existing.subtracting(wanted) {
            lock.lock()
            let block = deviceListeners.removeValue(forKey: gone)
            lock.unlock()
            if let block { Self.removeRunningListener(gone, block, queue) }
        }

        for added in wanted.subtracting(existing) {
            var address = Self.runningAddress()
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                let devices = Self.cameraDevices()
                let raw: Bool? = devices.isEmpty
                    ? nil
                    : devices.contains { Self.deviceIsRunningSomewhere($0) == true }
                self.update(raw: raw)
            }
            let status = CMIOObjectAddPropertyListenerBlock(added, &address, queue, block)
            if status == noErr {
                lock.lock()
                deviceListeners[added] = block
                lock.unlock()
            }
        }
    }

    private func removeAllListeners() {
        lock.lock()
        let devices = deviceListeners
        deviceListeners.removeAll()
        let hardware = hardwareListener
        hardwareListener = nil
        lock.unlock()

        for (device, block) in devices { Self.removeRunningListener(device, block, queue) }
        if let hardware {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            CMIOObjectRemovePropertyListenerBlock(
                CMIOObjectID(kCMIOObjectSystemObject), &address, queue, hardware
            )
        }
    }

    private static func removeRunningListener(
        _ device: CMIOObjectID,
        _ block: @escaping CMIOObjectPropertyListenerBlock,
        _ queue: DispatchQueue
    ) {
        var address = runningAddress()
        CMIOObjectRemovePropertyListenerBlock(device, &address, queue, block)
    }

    private static func runningAddress() -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    static func cameraDevices() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        let status = ids.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return OSStatus(-1) }
            return CMIOObjectGetPropertyData(
                CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, dataSize, &used, base
            )
        }
        guard status == noErr else { return [] }
        return ids
    }

    static func deviceIsRunningSomewhere(_ device: CMIOObjectID) -> Bool? {
        var address = runningAddress()
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<UInt32>.size) else { return nil }
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            device, &address, 0, nil, dataSize, &used, &value
        ) == noErr else { return nil }
        return value != 0
    }

    static func name(of device: CMIOObjectID) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr else {
            return nil
        }
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            device, &address, 0, nil, dataSize, &used, &value
        ) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
