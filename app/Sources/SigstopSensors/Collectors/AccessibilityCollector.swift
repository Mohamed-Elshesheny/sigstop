import ApplicationServices
import Foundation

public struct AXWindowInfo: Sendable, Hashable {
    public let title: String?
    public let documentURL: URL?
    public let browserHost: String?

    public init(title: String? = nil, documentURL: URL? = nil, browserHost: String? = nil) {
        self.title = title
        self.documentURL = documentURL
        self.browserHost = browserHost
    }

    public static let empty = AXWindowInfo()
    public var isEmpty: Bool { title == nil && documentURL == nil && browserHost == nil }
}

public enum AXFailure: Sendable, Hashable {
    case notTrusted
    case apiDisabled
    case timedOut
    case noFocusedWindow
    case attributeUnsupported
    case other(Int32)

    public var userFacingSummary: String {
        switch self {
        case .notTrusted, .apiDisabled:
            return "Window titles are off, Accessibility is not granted. Everything still works without it."
        case .timedOut:
            return "That app did not answer in time; skipping its window title."
        case .noFocusedWindow:
            return "That app has no focused window right now."
        case .attributeUnsupported:
            return "That app does not expose a document path."
        case .other(let code):
            return "Accessibility read failed (\(code))."
        }
    }
}

public enum AXEvent: Sendable, Hashable {
    case focusedWindowChanged(pid: pid_t)
    case titleChanged(pid: pid_t)
    case observationFailed(pid: pid_t, failure: AXFailure)
}

public final class AccessibilityCollector: @unchecked Sendable {
    public static let messagingTimeout: Float = 0.25

    private let queue = DispatchQueue(label: "dev.sigstop.ax", qos: .utility)
    private let lock = NSLock()
    private var runLoopThread: AXRunLoopThread?
    private var observers: [pid_t: ObserverRegistration] = [:]
    private var continuations: [UUID: AsyncStream<AXEvent>.Continuation] = [:]
    private var _lastFailure: AXFailure?

    public init() {}

    deinit {
        for registration in observers.values { registration.tearDown() }
        runLoopThread?.stop()
        for c in continuations.values { c.finish() }
    }

    public nonisolated func isTrusted() -> Bool { AXIsProcessTrusted() }

    public var lastFailure: AXFailure? {
        lock.lock(); defer { lock.unlock() }
        return _lastFailure
    }

    public func read(pid: pid_t) async -> AXWindowInfo {
        guard isTrusted() else {
            record(.notTrusted)
            return .empty
        }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: readSync(pid: pid))
            }
        }
    }

    private func readSync(pid: pid_t) -> AXWindowInfo {
        guard pid > 0 else { return .empty }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)

        var windowRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard status == .success else {
            record(Self.failure(for: status))
            return .empty
        }
        guard let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            record(.noFocusedWindow)
            return .empty
        }
        let window = unsafeDowncast(windowRef, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)

        let title = copyString(window, kAXTitleAttribute)
        let document = copyString(window, kAXDocumentAttribute)
        return AXWindowInfo(
            title: title,
            documentURL: document.flatMap(Self.fileURL(from:)),
            browserHost: document.flatMap(Self.host(from:))
        )
    }

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard status == .success else {
            if status != .attributeUnsupported && status != .noValue {
                record(Self.failure(for: status))
            }
            return nil
        }
        guard let string = ref as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func startObserving(pid: pid_t) {
        guard isTrusted(), pid > 0 else { return }
        queue.async { [self] in
            lock.lock()
            let alreadyObserving = observers[pid] != nil
            lock.unlock()
            guard !alreadyObserving else { return }

            guard let thread = ensureRunLoopThread(), let runLoop = thread.runLoop else { return }

            var observer: AXObserver?
            let status = AXObserverCreate(pid, axObserverCallback, &observer)
            guard status == .success, let observer else {
                emit(.observationFailed(pid: pid, failure: Self.failure(for: status)))
                return
            }

            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)

            let token = AXObserverToken(pid: pid) { [weak self] event in self?.emit(event) }
            let refcon = Unmanaged.passRetained(token).toOpaque()

            var attached: [String] = []
            for name in [kAXFocusedWindowChangedNotification, kAXTitleChangedNotification] {
                if AXObserverAddNotification(observer, element, name as CFString, refcon) == .success {
                    attached.append(name)
                }
            }
            guard !attached.isEmpty else {
                Unmanaged<AXObserverToken>.fromOpaque(refcon).release()
                emit(.observationFailed(pid: pid, failure: .apiDisabled))
                return
            }

            CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)

            let registration = ObserverRegistration(
                observer: observer, element: element, notifications: attached,
                refcon: refcon, runLoop: runLoop
            )
            lock.lock()
            observers[pid] = registration
            lock.unlock()
        }
    }

    public func stopObserving(pid: pid_t) {
        queue.async { [self] in
            lock.lock()
            let registration = observers.removeValue(forKey: pid)
            lock.unlock()
            registration?.tearDown()
        }
    }

    public func stopObservingAll() {
        queue.async { [self] in
            lock.lock()
            let all = observers
            observers.removeAll()
            lock.unlock()
            for registration in all.values { registration.tearDown() }
        }
    }

    public var events: AsyncStream<AXEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
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

    fileprivate func emit(_ event: AXEvent) {
        lock.lock()
        let sinks = Array(continuations.values)
        lock.unlock()
        for sink in sinks { sink.yield(event) }
    }

    private func record(_ failure: AXFailure) {
        lock.lock()
        _lastFailure = failure
        lock.unlock()
    }

    private func ensureRunLoopThread() -> AXRunLoopThread? {
        lock.lock()
        defer { lock.unlock() }
        if runLoopThread == nil { runLoopThread = AXRunLoopThread() }
        return runLoopThread
    }

    static func failure(for status: AXError) -> AXFailure {
        switch status {
        case .apiDisabled:           return .apiDisabled
        case .cannotComplete:        return .timedOut
        case .noValue:               return .noFocusedWindow
        case .attributeUnsupported:  return .attributeUnsupported
        case .invalidUIElement:      return .noFocusedWindow
        case .notImplemented:        return .attributeUnsupported
        default:                     return .other(status.rawValue)
        }
    }

    static func host(from raw: String) -> String? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty
        else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func fileURL(from raw: String) -> URL? {
        if let url = URL(string: raw), url.isFileURL { return url }
        guard raw.hasPrefix("/") || raw.hasPrefix("~") else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }
}

private final class AXObserverToken: @unchecked Sendable {
    let pid: pid_t
    let sink: @Sendable (AXEvent) -> Void

    init(pid: pid_t, sink: @escaping @Sendable (AXEvent) -> Void) {
        self.pid = pid
        self.sink = sink
    }
}

private let axObserverCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let token = Unmanaged<AXObserverToken>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    switch name {
    case kAXTitleChangedNotification:
        token.sink(.titleChanged(pid: token.pid))
    case kAXFocusedWindowChangedNotification:
        token.sink(.focusedWindowChanged(pid: token.pid))
    default:
        break
    }
}

private struct ObserverRegistration: @unchecked Sendable {
    let observer: AXObserver
    let element: AXUIElement
    let notifications: [String]
    let refcon: UnsafeMutableRawPointer
    let runLoop: CFRunLoop

    func tearDown() {
        for name in notifications {
            AXObserverRemoveNotification(observer, element, name as CFString)
        }
        CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        Unmanaged<AXObserverToken>.fromOpaque(refcon).release()
    }
}

private final class AXRunLoopThread: @unchecked Sendable {
    private let lock = NSLock()
    private var _runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)
    private var thread: Thread?

    init() {
        let created = Thread { [self] in
            lock.lock()
            _runLoop = CFRunLoopGetCurrent()
            lock.unlock()
            ready.signal()

            let keepAlive = NSMachPort()
            RunLoop.current.add(keepAlive, forMode: .default)
            while !Thread.current.isCancelled {
                _ = RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        created.name = "dev.sigstop.accessibility"
        created.qualityOfService = .utility
        thread = created
        created.start()
        _ = ready.wait(timeout: .now() + 2.0)
    }

    var runLoop: CFRunLoop? {
        lock.lock(); defer { lock.unlock() }
        return _runLoop
    }

    func stop() {
        thread?.cancel()
        if let loop = runLoop { CFRunLoopStop(loop) }
    }
}
