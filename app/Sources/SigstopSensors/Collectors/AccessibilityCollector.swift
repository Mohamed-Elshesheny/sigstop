import ApplicationServices
import Foundation

// MARK: - Public shapes

/// What Tier 1 can see. Deliberately two fields, both optional, both `Sendable`.
///
/// `documentURL` is a *real path* (`kAXDocument`) and is worth far more than the title,
/// but Electron apps (VS Code, Cursor, Slack, Discord, Figma) never provide it, so it is
/// a bonus, never a requirement.
public struct AXWindowInfo: Sendable, Hashable {
    public let title: String?
    public let documentURL: URL?
    /// The host of a remote `kAXDocument`, and only ever the host: `github.com`.
    ///
    /// Tier 1b. It costs no new read — `kAXDocument` was already being fetched for file
    /// URLs and a browser answers it with the page URL, measured on Chrome 2026-09-21 as
    /// `https://github.com/Mohamed-Elshesheny/sigstop`. What used to happen to that string
    /// is that `fileURL(from:)` returned nil and it fell on the floor. The path and query
    /// still do: they are dropped inside `host(from:)` and never reach this type, so there
    /// is no field here that could hold them and nothing downstream to redact.
    public let browserHost: String?

    public init(title: String? = nil, documentURL: URL? = nil, browserHost: String? = nil) {
        self.title = title
        self.documentURL = documentURL
        self.browserHost = browserHost
    }

    public static let empty = AXWindowInfo()
    public var isEmpty: Bool { title == nil && documentURL == nil && browserHost == nil }
}

/// Why a Tier 1 read produced nothing. Kept so `--doctor` can explain a blank instead of
/// the UI silently showing less context with no reason given.
public enum AXFailure: Sendable, Hashable {
    /// `AXIsProcessTrusted() == false`. The normal, expected state at zero permissions.
    case notTrusted
    /// `kAXErrorAPIDisabled` (-25211). What the API returns once we ask anyway.
    case apiDisabled
    /// The target app did not answer inside the 0.25 s messaging timeout, beachballed,
    /// or simply slow. Not an error worth surfacing loudly.
    case timedOut
    /// The app has no focused window (a menu-bar-only app, or mid-switch).
    case noFocusedWindow
    /// The attribute is not supported by this app. Normal for Electron + `kAXDocument`.
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

/// Accessibility-related change notifications, as an event stream rather than a poll.
public enum AXEvent: Sendable, Hashable {
    case focusedWindowChanged(pid: pid_t)
    case titleChanged(pid: pid_t)
    case observationFailed(pid: pid_t, failure: AXFailure)
}

// MARK: - Collector

/// Tier 1. The focused window's **title**, and `kAXDocument` where the app provides it.
///
/// This type is an *upgrade*, never a gate. With no Accessibility grant every method here
/// returns `nil` cleanly and the app keeps working at Tier 0, which is the entire privacy
/// promise, so the failure path below is load-bearing, not an afterthought.
///
/// Three rules encoded structurally rather than by convention:
///
/// 1. **Never on the main actor.** AX calls are synchronous IPC into the target process
///    and block until they answer or time out. Everything here runs on a dedicated serial
///    queue; the async API bridges to it.
/// 2. **Always a messaging timeout.** `AXUIElementSetMessagingTimeout(_, 0.25)` on every
///    element we create, so a beachballed target costs us 250 ms, not a hang.
/// 3. **No API can return the value of a text element.** Reading `kAXValue` of a text area
///    would hand us the user's source code and message drafts. There is no method here
///    that does it, the capability is absent, not merely unused. This is the source-level
///    form of "this watches your workflow, not your code" (CLAUDE.md §4.4).
///
/// Electron note: VS Code and Cursor expose a shallow, sometimes-empty AX tree unless the
/// user turns on their own accessibility support, but the **window title on `AXWindow` is
/// always present**. So this collector reads titles and never walks an app's AX tree.
public final class AccessibilityCollector: @unchecked Sendable {
    /// Per docs/ACTIVITY-DETECTION.md §2.2. Non-negotiable.
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

    // MARK: - Trust

    /// The poll-safe, **non-prompting** check. `AXAPIEnabled()` is deprecated; do not use it.
    ///
    /// Cheap enough to call on every app-activation event, which is exactly what we do:
    /// the user can revoke Tier 1 from System Settings at any moment with no notification,
    /// and continuing to emit stale high-confidence observations after that would be a lie.
    public nonisolated func isTrusted() -> Bool { AXIsProcessTrusted() }

    public var lastFailure: AXFailure? {
        lock.lock(); defer { lock.unlock() }
        return _lastFailure
    }

    // MARK: - Reads

    /// Title and document URL in one pass, so a focused-window lookup is not paid twice.
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

    public func focusedWindowTitle(pid: pid_t) async -> String? {
        await read(pid: pid).title
    }

    public func focusedDocumentURL(pid: pid_t) async -> URL? {
        await read(pid: pid).documentURL
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
        /// One read, two readings. A local editor answers `kAXDocument` with a file, a
        /// browser answers it with the page URL; the second used to be discarded entirely.
        let document = copyString(window, kAXDocumentAttribute)
        return AXWindowInfo(
            title: title,
            documentURL: document.flatMap(Self.fileURL(from:)),
            browserHost: document.flatMap(Self.host(from:))
        )
    }

    /// The ONLY attribute reader in this type, and it is used exclusively for `kAXTitle`
    /// and `kAXDocument`. It is deliberately `private`: there is no public path that could
    /// be pointed at `kAXValue`.
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

    // MARK: - Observation

    /// Subscribe to focus and title changes for a pid.
    ///
    /// This is the single biggest reason the subsystem can be energy-negligible: with an
    /// `AXObserver` attached, tracking a window title costs zero wakeups until the title
    /// actually changes. The engine still reconciles on a slow timer, because a missed
    /// notification is a stale context and staleness is indistinguishable from a lie.
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

    // MARK: - Internals

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
        case .apiDisabled:           return .apiDisabled          // -25211
        case .cannotComplete:        return .timedOut             // -25204
        case .noValue:               return .noFocusedWindow      // -25212
        case .attributeUnsupported:  return .attributeUnsupported // -25205
        case .invalidUIElement:      return .noFocusedWindow      // -25202
        case .notImplemented:        return .attributeUnsupported // -25208
        default:                     return .other(status.rawValue)
        }
    }

    /// `kAXDocument` is documented as a URL string but real apps hand back both
    /// `file:///…` and bare POSIX paths. Anything that is not a local file is discarded:
    /// we are not in the business of collecting remote URLs.
    /// The host of an `http`/`https` URL, lowercased, with a leading `www.` removed.
    ///
    /// Everything else about the URL is dropped here, in the one function that ever sees
    /// it: no path, no query, no fragment, no credentials, no port. `URL` is a local and
    /// only `host` escapes, so the rest is not "redacted later", it never has a later.
    ///
    /// Schemes other than http and https return nil, which keeps `file:` on the
    /// `documentURL` path where it belongs and refuses anything exotic outright rather
    /// than trying to understand it.
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

// MARK: - Observer plumbing

/// Retained by the `void *` refcon of an `AXObserver`. Holds only `Sendable` values.
private final class AXObserverToken: @unchecked Sendable {
    let pid: pid_t
    let sink: @Sendable (AXEvent) -> Void

    init(pid: pid_t, sink: @escaping @Sendable (AXEvent) -> Void) {
        self.pid = pid
        self.sink = sink
    }
}

/// C callback. Runs on the AX run-loop thread, never on the main actor.
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

/// A background thread that owns a `CFRunLoop`, because `AXObserver` requires one and the
/// main run loop is not an acceptable host for IPC that can block.
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
