import CoreAudio
import Foundation
import SigstopCore

public struct AudioProcessSnapshot: Sendable, Hashable {
    public let inputBundleIDs: Set<String>?
    public let unnamedInputHolders: Int
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

    public var anyInputRunning: Bool? {
        guard let ids = inputBundleIDs else { return nil }
        return !ids.isEmpty || unnamedInputHolders > 0
    }
}

public final class AudioProcessCollector: @unchecked Sendable {
    private let time: any TimeSource
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.sigstop.audioproc", qos: .utility)

    private var started = false
    private var bundleIDs: [AudioObjectID: String] = [:]
    private var snapshotValue: AudioProcessSnapshot = .unreadable
    private var objectListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var listListener: AudioObjectPropertyListenerBlock?

    public init(time: any TimeSource = SystemTimeSource()) {
        self.time = time
    }

    deinit { removeAllListeners() }

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

    public func snapshot() -> AudioProcessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotValue
    }

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
