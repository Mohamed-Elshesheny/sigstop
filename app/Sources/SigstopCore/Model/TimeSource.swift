import Foundation

/// The only way `SigstopCore` learns what time it is.
///
/// Core must never call `Date()` directly. Production injects `SystemTimeSource`;
/// tests inject `MutableTimeSource` and advance it by hand, which is what makes
/// "45 minutes of continuous work triggers a break" a microsecond unit test instead
/// of a thing we hope works. See CLAUDE.md §3.2.
public protocol TimeSource: Sendable {
    var now: Date { get }
    /// Seconds of uptime, unaffected by wall-clock changes (NTP steps, DST, the user
    /// changing the date). Used for measuring durations; `now` is used for display.
    var monotonicSeconds: Double { get }
}

public struct SystemTimeSource: TimeSource {
    public init() {}
    public var now: Date { Date() }
    public var monotonicSeconds: Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

/// Test clock. Deliberately a reference type so a test can hold one and advance it
/// while the system under test holds the same instance.
public final class MutableTimeSource: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    private var _monotonic: Double

    public init(now: Date = Date(timeIntervalSince1970: 1_700_000_000), monotonic: Double = 0) {
        self._now = now
        self._monotonic = monotonic
    }

    public var now: Date { lock.withLock { _now } }
    public var monotonicSeconds: Double { lock.withLock { _monotonic } }

    /// Advance both clocks together — the normal case.
    public func advance(by seconds: TimeInterval) {
        lock.withLock {
            _now = _now.addingTimeInterval(seconds)
            _monotonic += seconds
        }
    }

    /// Advance wall-clock only, leaving the monotonic clock still. Models an NTP step
    /// or the user changing the system date — the engine must not treat this as work.
    public func skewWallClock(by seconds: TimeInterval) {
        lock.withLock { _now = _now.addingTimeInterval(seconds) }
    }

    /// Model a sleep/wake: both clocks jump, as they do when the lid reopens.
    public func sleepAndWake(for seconds: TimeInterval) {
        advance(by: seconds)
    }
}
