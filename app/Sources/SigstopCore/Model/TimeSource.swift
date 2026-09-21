import Darwin
import Foundation

/// The only way `SigstopCore` learns what time it is.
///
/// Core must never call `Date()` directly. Production injects `SystemTimeSource`;
/// tests inject `MutableTimeSource` and advance it by hand, which is what makes
/// "45 minutes of continuous work triggers a break" a microsecond unit test instead
/// of a thing we hope works. See CLAUDE.md §3.2.
public protocol TimeSource: Sendable {
    var now: Date { get }
    /// Seconds since an arbitrary epoch, **counting time the machine spent asleep**, and
    /// unaffected by wall-clock changes (NTP steps, DST, the user setting the date).
    ///
    /// This is the clock for "how much time has passed in the world": every duration a
    /// user was promised, every deadline, and every gap classification. Darwin calls it
    /// `CLOCK_MONOTONIC`; the standard library calls this shape `ContinuousClock`.
    ///
    /// It was named `monotonicSeconds` and backed by `DispatchTime`, which is
    /// `CLOCK_UPTIME_RAW` and stops dead while the lid is shut. "Monotonic" is true of
    /// both clocks and is the word a Linux-trained reader reaches for when they mean
    /// continuous, which is how a suspended clock came to measure elapsed time. The name
    /// is gone rather than aliased, so every caller had to be looked at once.
    var continuousSeconds: Double { get }
}

/// **One clock, deliberately, and here is the case against a second one.**
///
/// There is a real argument for also exposing `CLOCK_UPTIME_RAW`: a handful of readers
/// measure how long the app has been *able to watch* rather than how much time has passed,
/// and the clearest is the dwell on an uncorroborated input device — a microphone cannot
/// meaningfully be "running" while the machine is asleep.
///
/// It is not exposed, because both clocks are `Double` and neither is distinguishable from
/// the other at a call site. A value taken from the wrong one compiles, runs, and is wrong
/// only on a machine that has slept, which is the exact failure mode this file just spent
/// a fix escaping. Two indistinguishable clocks is the same trap with twice the surface.
///
/// The one place it is arguably wrong fails safe: an unheld device's dwell counts the sleep,
/// so the app decides sooner that a device is stuck and stops holding breaks for it. Being
/// too willing to interrupt is recoverable; going quiet forever is what the daily cap bug
/// was. If a reader ever genuinely needs suspended time, give it its own *type*, not another
/// `Double` on this protocol.

public struct SystemTimeSource: TimeSource {
    public init() {}
    public var now: Date { Date() }

    /// `CLOCK_MONOTONIC`, which Darwin documents as continuing to increment while the
    /// system is asleep — as opposed to `CLOCK_UPTIME_RAW`, which does not and which is
    /// what `DispatchTime` and `mach_absolute_time` return.
    ///
    /// `clock_gettime` rather than `ContinuousClock`: turning an `Instant` into a `Double`
    /// needs a stored reference instant, so each `SystemTimeSource` would carry its own
    /// epoch, and this process builds two of them. `DispatchTime` was process-global and
    /// they agreed; per-instance epochs would have quietly introduced a second version of
    /// this same bug. `Darwin` is not a UI framework and not a package, so §3.1 and §5
    /// both hold.
    public var continuousSeconds: Double {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
    }
}

/// Test clock. Deliberately a reference type so a test can hold one and advance it
/// while the system under test holds the same instance.
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

    /// Advance both clocks together, the normal case.
    public func advance(by seconds: TimeInterval) {
        lock.withLock {
            _now = _now.addingTimeInterval(seconds)
            _continuous += seconds
        }
    }

    /// Advance wall-clock only, leaving the monotonic clock still. Models an NTP step
    /// or the user changing the system date, the engine must not treat this as work.
    public func skewWallClock(by seconds: TimeInterval) {
        lock.withLock { _now = _now.addingTimeInterval(seconds) }
    }

    /// Model a real macOS sleep. On a continuous clock this is just time passing, which
    /// is the whole point of the fix: both clocks move and the tracker sees a gap rather
    /// than a skew.
    ///
    /// This used to call `advance`, which moved both — a clock production does not have.
    /// `DispatchTime` is backed by `mach_absolute_time`, which is suspended while the
    /// machine sleeps: measured on this machine, `CLOCK_MONOTONIC` and `CLOCK_UPTIME_RAW`
    /// are 1205.6 seconds apart, and that gap is sleep the app has never seen. Modelling
    /// a sleep as an advance is why the sleep path has no coverage: the double agreed with
    /// the test instead of with the system.
    ///
    /// A sleep and a forward NTP step are indistinguishable to this clock, which is
    /// exactly the fact the production bug turns on, so `skewWallClock` is the same
    /// arithmetic under the name that says which one a test means.
    public func sleepAndWake(for seconds: TimeInterval) {
        advance(by: seconds)
    }

    /// App Nap, a starved timer, a throttled process: no sample was taken, but no time was
    /// suspended either, so both clocks move. Identical to `advance`, named so a test says
    /// which of the two it is exercising.
    public func throttle(for seconds: TimeInterval) {
        advance(by: seconds)
    }
}
