import Darwin
import Foundation

public protocol TimeSource: Sendable {
    var now: Date { get }
    var continuousSeconds: Double { get }
}

public struct SystemTimeSource: TimeSource {
    public init() {}
    public var now: Date { Date() }

    public var continuousSeconds: Double {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
    }
}

public final class MutableTimeSource: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    private var _continuous: Double

    public init(now: Date = Date(timeIntervalSince1970: 1_700_000_000), monotonic: Double = 0) {
        self._now = now
        self._continuous = monotonic
    }

    public var now: Date { lock.withLock { _now } }
    public var continuousSeconds: Double { lock.withLock { _continuous } }

    public func advance(by seconds: TimeInterval) {
        lock.withLock {
            _now = _now.addingTimeInterval(seconds)
            _continuous += seconds
        }
    }

    public func sleepAndWake(for seconds: TimeInterval) {
        advance(by: seconds)
    }

    public func throttle(for seconds: TimeInterval) {
        advance(by: seconds)
    }
}
