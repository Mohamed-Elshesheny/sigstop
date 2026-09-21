import Foundation
import Testing

@testable import SigstopCore

/// What the app sees when the lid closes.
///
/// CLAUDE.md §3.4: "The machine sleeps, the process gets throttled, the user closes the
/// lid. Always diff real timestamps and classify the gap." The branch that does that
/// classification keys off the monotonic clock, and `DispatchTime` — which is what
/// `SystemTimeSource` uses — is backed by `mach_absolute_time` and is suspended while the
/// machine is asleep. Measured on the machine this was written on: `CLOCK_MONOTONIC` and
/// `CLOCK_UPTIME_RAW` are 1205.6 seconds apart, and that gap is sleep the app never saw.
///
/// So a twelve minute lid-close reaches the tracker as a twelve minute WALL jump with a
/// zero monotonic delta, which is the exact shape of somebody changing their system date.
/// The app reported the user's lunch break as an NTP step.
@Suite("the clock that stops when the lid shuts")
struct SleepingClockTests {

    private func makeTracker() -> (SessionTracker, MutableTimeSource) {
        let time = MutableTimeSource()
        var policy = BreakPolicy()
        policy.tickInterval = 5
        policy.tickTolerance = 5
        policy.wallClockSkewTolerance = 5
        return (SessionTracker(time: time, policy: policy), time)
    }

    private func sample(idle: TimeInterval = 0) -> TickSample {
        TickSample(
            idleSeconds: idle,
            application: AppIdentity(bundleID: "com.apple.dt.Xcode", localizedName: "Xcode", pid: 1),
            activity: .coding,
            confidence: Confidence(0.9)
        )
    }

    @Test("a twelve minute sleep is a gap, not somebody changing their date")
    func sleepIsNotSkew() {
        var (tracker, time) = makeTracker()
        _ = tracker.tick(sample())
        time.advance(by: 5)
        _ = tracker.tick(sample())

        // The lid closes for twelve minutes. Wall time moves; the suspended clock does not.
        time.sleepAndWake(for: 12 * 60)
        let events = tracker.tick(sample())

        let calledItSkew = events.contains {
            if case .wallClockSkewIgnored = $0 { return true }
            return false
        }
        #expect(!calledItSkew, "a lid close is not an NTP step, got \(events)")
    }

    @Test("a throttle and a sleep are told apart")
    func throttleIsNotSleep() {
        var (tracker, time) = makeTracker()
        _ = tracker.tick(sample())

        // App Nap: no sample was taken, but no time was suspended either.
        time.throttle(for: 12 * 60)
        let throttled = tracker.tick(sample())
        #expect(!throttled.contains {
            if case .wallClockSkewIgnored = $0 { return true }
            return false
        }, "a throttle moves both clocks together and is not skew either")
    }
}
