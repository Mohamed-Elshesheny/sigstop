import CoreAudio
import Foundation
import SigstopCore

/// Tier 0. "Some process on this machine is running input I/O on an audio device."
///
/// **No microphone permission is required and none is requested.** We read a device
/// *property*; we never open a stream. The app cannot hear anything, and the capability
/// to do so is absent rather than merely unused.
///
/// What this signal genuinely does NOT tell us, and which we must never pretend:
///
/// * **Who.** There is no permission-free attribution of a running device to a process.
/// * **Why.** Dictation, Voice Control, a voice memo, a browser tab or a game all trip it.
/// * **When it stopped.** Zoom holds the device in a waiting room and for a while after a
///   call, so meeting duration is never billed off this signal alone.
///
/// And the failure mode that makes a four-state enum necessary instead of a `Bool`:
/// Krisp, Loopback, BlackHole and some headset daemons hold an input device open
/// **permanently**. On such a Mac this signal is a constant `true` and is worthless. The
/// calibration guard below detects that and downgrades the signal to `.unreliable`, which
/// contributes *nothing* to meeting detection. A permanently-on detector is worse than no
/// detector, and the UI says so out loud.
public final class AudioDeviceCollector: @unchecked Sendable {
    /// Continuously "running" for longer than this ⇒ this Mac's mic never turns off.
    public static let continuousRunningUnreliableThreshold: TimeInterval = 4 * 3600
    /// Duty cycle over the rolling window above which the signal is worthless.
    public static let unreliableDutyCycle: Double = 0.85
    /// Minimum awake observation before the duty-cycle test is allowed to fire. Below
    /// this we do not have enough evidence to call the signal broken.
    public static let calibrationMinimumObservation: TimeInterval = 3600
    /// Rolling accounting window.
    public static let calibrationWindow: TimeInterval = 24 * 3600

    private let time: any TimeSource
    private let lock = NSLock()
    /// CoreAudio property listeners are delivered on the queue we hand them. Keeping our
    /// own serial queue keeps every device read off the main thread.
    private let queue = DispatchQueue(label: "dev.sigstop.audio", qos: .utility)

    private var isRunningRaw: Bool?           // nil ⇒ no input device at all
    private var runningSince: Date?
    private var windowStart: Date
    private var observedAwakeSeconds: TimeInterval = 0
    private var runningAwakeSeconds: TimeInterval = 0
    private var lastAccountedAt: Date
    private var systemAwake = true
    private var started = false
    private var deviceListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var hardwareListener: AudioObjectPropertyListenerBlock?
    private var continuations: [UUID: AsyncStream<AudioInputState>.Continuation] = [:]

    public init(time: any TimeSource = SystemTimeSource()) {
        self.time = time
        let now = time.now
        self.windowStart = now
        self.lastAccountedAt = now
    }

    deinit {
        removeAllListeners()
        for c in continuations.values { c.finish() }
    }

    // MARK: - Lifecycle

    /// Registers property listeners so this collector is **event-driven, not polled**:
    /// one listener per input device for `DeviceIsRunningSomewhere`, plus one on the
    /// device list itself so hot-plugging a headset re-registers correctly.
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

    /// Re-enumerates devices, re-registers listeners, and recomputes the raw state.
    /// Called at start, on device-list changes, and on wake.
    public func refresh() {
        let devices = Self.inputDevices()
        registerDeviceListeners(devices)
        let raw: Bool? = devices.isEmpty
            ? Self.defaultInputDeviceIsRunning()
            : devices.contains { Self.deviceIsRunningSomewhere($0) == true }
        update(raw: raw)
    }

    /// The accounting window only advances while the machine is awake and the user is at
    /// the console, 8 hours lid-closed must not count as 8 hours of "mic quiet".
    public func setSystemAwake(_ awake: Bool) {
        lock.lock()
        accountLocked(at: time.now)
        systemAwake = awake
        lock.unlock()
        if awake { refresh() }
    }

    // MARK: - Reading

    public func state() -> AudioInputState {
        lock.lock()
        accountLocked(at: time.now)
        let raw = isRunningRaw
        let unreliable = isUnreliableLocked(at: time.now)
        lock.unlock()

        if unreliable { return .unreliable }
        switch raw {
        case .none:        return .noInputDevice
        case .some(true):  return .running
        case .some(false): return .notRunning
        }
    }

    /// Why the signal was disabled, for the UI and for `--doctor`. `nil` when it is fine.
    public func unreliabilityExplanation() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let now = time.now
        accountLocked(at: now)
        guard isUnreliableLocked(at: now) else { return nil }
        if let since = runningSince, now.timeIntervalSince(since) > Self.continuousRunningUnreliableThreshold {
            let hours = Int(now.timeIntervalSince(since) / 3600)
            return "Microphone signal disabled on this Mac, an input device has been "
                + "running continuously for \(hours)h. Something (Krisp, Loopback, a headset "
                + "daemon) is holding it open, so it cannot indicate a meeting."
        }
        let pct = Int((runningAwakeSeconds / max(observedAwakeSeconds, 1)) * 100)
        return "Microphone signal disabled on this Mac, an input device was running for "
            + "\(pct)% of the last day. It never turns off, so it cannot indicate a meeting."
    }

    public var events: AsyncStream<AudioInputState> {
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

    // MARK: - State accounting

    private func update(raw: Bool?) {
        lock.lock()
        let now = time.now
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
        let published: AudioInputState = unreliable
            ? .unreliable
            : (raw == nil ? .noInputDevice : (raw == true ? .running : .notRunning))
        for sink in sinks { sink.yield(published) }
    }

    /// Advances the rolling duty-cycle accounting. Caller holds `lock`.
    private func accountLocked(at now: Date) {
        let elapsed = now.timeIntervalSince(lastAccountedAt)
        lastAccountedAt = now
        guard elapsed > 0 else { return }
        guard systemAwake else { return }

        observedAwakeSeconds += elapsed
        if isRunningRaw == true { runningAwakeSeconds += elapsed }

        if now.timeIntervalSince(windowStart) > Self.calibrationWindow {
            observedAwakeSeconds *= 0.5
            runningAwakeSeconds *= 0.5
            windowStart = now.addingTimeInterval(-Self.calibrationWindow / 2)
        }
    }

    /// Caller holds `lock`.
    private func isUnreliableLocked(at now: Date) -> Bool {
        if let since = runningSince, now.timeIntervalSince(since) > Self.continuousRunningUnreliableThreshold {
            return true
        }
        guard observedAwakeSeconds >= Self.calibrationMinimumObservation else { return false }
        return (runningAwakeSeconds / observedAwakeSeconds) > Self.unreliableDutyCycle
    }

    // MARK: - CoreAudio listeners

    private func registerHardwareListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain   // macOS 12+; NOT ...ElementMaster
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refresh()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
        if status == noErr {
            lock.lock()
            hardwareListener = block
            lock.unlock()
        }
    }

    private func registerDeviceListeners(_ devices: [AudioObjectID]) {
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
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                let devices = Self.inputDevices()
                let raw: Bool? = devices.isEmpty
                    ? Self.defaultInputDeviceIsRunning()
                    : devices.contains { Self.deviceIsRunningSomewhere($0) == true }
                self.update(raw: raw)
            }
            let status = AudioObjectAddPropertyListenerBlock(added, &address, queue, block)
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
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, hardware
            )
        }
    }

    private static func removeRunningListener(
        _ device: AudioObjectID,
        _ block: @escaping AudioObjectPropertyListenerBlock,
        _ queue: DispatchQueue
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
    }

    // MARK: - CoreAudio reads

    /// Every device that has at least one input channel. Output-only devices are skipped
    /// so that playing music does not look like a meeting.
    static func inputDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return OSStatus(-1) }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, base
            )
        }
        guard status == noErr else { return [] }
        return ids.filter { hasInputChannels($0) }
    }

    static func hasInputChannels(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else { return false }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, raw) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        for buffer in list where buffer.mNumberChannels > 0 { return true }
        return false
    }

    /// `nil` when the property cannot be read, treated as "no information", never `false`.
    static func deviceIsRunningSomewhere(_ device: AudioObjectID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value != 0
    }

    /// Fallback path: the default input device alone. Used when full enumeration returns
    /// nothing usable.
    static func defaultInputDeviceIsRunning() -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr, device != AudioObjectID(kAudioObjectUnknown) else {
            return nil   // genuinely no input device
        }
        return deviceIsRunningSomewhere(device)
    }
}
