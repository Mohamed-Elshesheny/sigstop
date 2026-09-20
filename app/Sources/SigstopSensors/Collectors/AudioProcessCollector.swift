import CoreAudio
import Foundation
import SigstopCore

/// One reading of CoreAudio's process table.
public struct AudioProcessSnapshot: Sendable, Hashable {
    /// Bundle identifiers of the processes reporting `IsRunningInput`.
    ///
    /// `nil` means the process table could not be read at all, which is **not** the same
    /// as empty. Empty means the table *was* read and nobody is running input, which is
    /// evidence of absence and is treated as such. A collector that collapsed those two
    /// into `[]` would turn "I could not look" into "I looked and there was nothing".
    public let inputBundleIDs: Set<String>?
    /// Processes that ARE running input but report no bundle id at all.
    ///
    /// They exist: three CoreAudio process objects on the development machine have empty
    /// bundle ids right now, and every command-line recorder (`ffmpeg`, `sox`, a Python
    /// `sounddevice` script) is in the same class. They used to be dropped, which made an
    /// empty `inputBundleIDs` say "I looked and nobody has the microphone" while somebody
    /// did. That is harmless while the set is only used to name a call, and not harmless
    /// at all now that an empty set is evidence of absence for the hard block.
    public let unnamedInputHolders: Int
    /// How many process objects CoreAudio knows about, for `--doctor`.
    public let processCount: Int
    public let readAt: Date

    public static let unreadable = AudioProcessSnapshot(
        inputBundleIDs: nil, processCount: 0, readAt: .distantPast
    )

    public init(
        inputBundleIDs: Set<String>?,
        unnamedInputHolders: Int = 0,
        processCount: Int,
        readAt: Date
    ) {
        self.inputBundleIDs = inputBundleIDs
        self.unnamedInputHolders = unnamedInputHolders
        self.processCount = processCount
        self.readAt = readAt
    }

    /// nil when the table could not be read; otherwise whether anything at all has input
    /// open, named or not. This is the only form of the question that may carry weight.
    public var anyInputRunning: Bool? {
        guard let ids = inputBundleIDs else { return nil }
        return !ids.isEmpty || unnamedInputHolders > 0
    }
}

/// Tier 0. "Which processes have the microphone open right now."
///
/// **No Microphone permission is required and none is requested.** This reads
/// `kAudioHardwarePropertyProcessObjectList` on the system object and then
/// `kAudioProcessPropertyBundleID` / `kAudioProcessPropertyIsRunningInput` per process
/// object. It is the per-process analogue of the device property `AudioDeviceCollector`
/// already reads, it opens no stream, and it produced no `tccd` activity when probed.
///
/// It exists for two jobs, and for nothing else:
///
///  1. **Naming.** The device bit says "something on this machine has the microphone".
///     The process table says *which bundle*, which is what lets the call latch adopt an
///     anchor honestly instead of guessing from which window is in front.
///  2. **Not being fooled.** Siri's wake word (`com.apple.CoreSpeech`) trips the device
///     bit for a second at a time. Krisp, Loopback and BlackHole trip it permanently,
///     which currently forces the whole microphone signal to `.unreliable` and switches
///     meeting detection off on that Mac entirely. Attribution lets the app discount the
///     offender instead of discarding the signal.
///
/// What this does NOT give us, stated rather than papered over:
///
/// * Audio attributes to helper processes, not to apps: Chrome's is
///   `com.google.Chrome.helper` and Teams' media path is `com.microsoft.vcxpc`, which is
///   not even under the `com.microsoft.teams2` prefix. Matching is therefore by prefix
///   against a hand-checked list, and it will age: a vendor reshuffling helpers degrades
///   this to the unattributed device bit. `--doctor` prints what matched, so the
///   degradation is visible rather than silent.
/// * Safari routes page audio through `com.apple.WebKit.GPU`, which serves every WebKit
///   client on the machine and therefore names no app at all.
/// * A process appears here only once it has touched CoreAudio. This is not a roster of
///   running apps and must never be used as one.
public final class AudioProcessCollector: @unchecked Sendable {
    private let time: any TimeSource
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.sigstop.audioproc", qos: .utility)

    private var started = false
    /// Object id to bundle id. Cached because a bundle-id read is an IPC to `coreaudiod`
    /// and reading all of them costs about 13 ms; the ids do not change under an object.
    private var bundleIDs: [AudioObjectID: String] = [:]
    private var snapshotValue: AudioProcessSnapshot = .unreadable
    private var objectListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var listListener: AudioObjectPropertyListenerBlock?

    public init(time: any TimeSource = SystemTimeSource()) {
        self.time = time
    }

    deinit { removeAllListeners() }

    // MARK: - Lifecycle

    public func start() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()

        registerListListener()
        refresh()
    }

    public func stop() {
        lock.lock()
        started = false
        lock.unlock()
        removeAllListeners()
    }

    /// Re-enumerates the process table, re-caches bundle ids, re-registers listeners and
    /// recomputes the snapshot. Runs at start, on process-list changes, and on wake.
    public func refresh() {
        let objects = Self.processObjects()
        guard !objects.isEmpty else {
            lock.lock()
            snapshotValue = AudioProcessSnapshot(
                inputBundleIDs: nil, processCount: 0, readAt: time.now
            )
            lock.unlock()
            return
        }

        lock.lock()
        var cache = bundleIDs
        lock.unlock()

        let live = Set(objects)
        cache = cache.filter { live.contains($0.key) }
        for object in objects where cache[object] == nil {
            if let id = Self.bundleID(of: object) { cache[object] = id }
        }

        lock.lock()
        bundleIDs = cache
        lock.unlock()

        registerObjectListeners(objects)
        recompute(objects: objects, cache: cache)
    }

    // MARK: - Reading

    public func snapshot() -> AudioProcessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotValue
    }

    // MARK: - Recompute

    private func recompute(objects: [AudioObjectID], cache: [AudioObjectID: String]) {
        var holders: Set<String> = []
        var unnamed = 0
        var anyReadable = false
        for object in objects {
            guard let running = Self.isRunningInput(object) else { continue }
            anyReadable = true
            guard running else { continue }
            guard let id = cache[object] else {
                unnamed += 1
                continue
            }
            holders.insert(id)
        }
        lock.lock()
        snapshotValue = AudioProcessSnapshot(
            inputBundleIDs: anyReadable ? holders : nil,
            unnamedInputHolders: unnamed,
            processCount: objects.count,
            readAt: time.now
        )
        lock.unlock()
    }

    // MARK: - CoreAudio listeners

    private func registerListListener() {
        var address = Self.listAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refresh()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
        if status == noErr {
            lock.lock()
            listListener = block
            lock.unlock()
        }
    }

    private func registerObjectListeners(_ objects: [AudioObjectID]) {
        lock.lock()
        let existing = Set(objectListeners.keys)
        lock.unlock()

        let wanted = Set(objects)

        for gone in existing.subtracting(wanted) {
            lock.lock()
            let block = objectListeners.removeValue(forKey: gone)
            lock.unlock()
            if let block { Self.removeInputListener(gone, block, queue) }
        }

        for added in wanted.subtracting(existing) {
            var address = Self.inputAddress()
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                let objects = Self.processObjects()
                self.lock.lock()
                let cache = self.bundleIDs
                self.lock.unlock()
                self.recompute(objects: objects, cache: cache)
            }
            let status = AudioObjectAddPropertyListenerBlock(added, &address, queue, block)
            if status == noErr {
                lock.lock()
                objectListeners[added] = block
                lock.unlock()
            }
        }
    }

    private func removeAllListeners() {
        lock.lock()
        let objects = objectListeners
        objectListeners.removeAll()
        let list = listListener
        listListener = nil
        lock.unlock()

        for (object, block) in objects { Self.removeInputListener(object, block, queue) }
        if let list {
            var address = Self.listAddress()
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, list
            )
        }
    }

    private static func removeInputListener(
        _ object: AudioObjectID,
        _ block: @escaping AudioObjectPropertyListenerBlock,
        _ queue: DispatchQueue
    ) {
        var address = inputAddress()
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }

    // MARK: - CoreAudio reads

    private static func listAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func inputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func processObjects() -> [AudioObjectID] {
        var address = listAddress()
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
        return ids
    }

    /// The bundle identifier, and nothing else about the process. No name, no path, no
    /// pid is kept: the identifier is matched against a fixed list and discarded.
    static func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        let id = value.takeRetainedValue() as String
        return id.isEmpty ? nil : id
    }

    /// `nil` when the property cannot be read, which is "no information", never `false`.
    static func isRunningInput(_ object: AudioObjectID) -> Bool? {
        var address = inputAddress()
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value != 0
    }
}
