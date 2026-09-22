import Foundation
import Testing

@testable import SigstopCore

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

        time.throttle(for: 12 * 60)
        let throttled = tracker.tick(sample())
        #expect(!throttled.contains {
            if case .wallClockSkewIgnored = $0 { return true }
            return false
        }, "a throttle moves both clocks together and is not skew either")
    }
}
