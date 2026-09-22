import Foundation
import Testing

@testable import SigstopCore

@Suite("break accounting")
struct SessionTrackerBreakTests {

    private func makeTracker(qualifying: Int = 5) -> (SessionTracker, MutableTimeSource) {
        let time = MutableTimeSource()
        var policy = BreakPolicy()
        policy.qualifyingBreak = TimeInterval(qualifying * 60)
        policy.tickInterval = 5
        policy.tickTolerance = 5
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

    @Test("A break that is long enough resets the clock even with input throughout")
    func inputDuringBreakDoesNotCancelIt() {
        var (tracker, time) = makeTracker()
        for _ in 0..<72 { time.advance(by: 5); _ = tracker.tick(sample()) }
        #expect(tracker.session.continuousActiveWork > 5 * 60)

        _ = tracker.beginBreak(origin: .accepted)
        for _ in 0..<66 { time.advance(by: 5); _ = tracker.tick(sample()) }
        _ = tracker.endBreak(origin: .accepted)

        #expect(tracker.session.continuousActiveWork == 0, "a 5.5 minute break must reset the clock")
        #expect(tracker.session.breakCount == 1)
    }

    @Test("A break shorter than the threshold still does not count")
    func shortBreakIsNotCredited() {
        var (tracker, time) = makeTracker()
        for _ in 0..<72 { time.advance(by: 5); _ = tracker.tick(sample()) }
        let before = tracker.session.continuousActiveWork

        _ = tracker.beginBreak(origin: .accepted)
        time.advance(by: 20)
        _ = tracker.endBreak(origin: .accepted)

        #expect(tracker.session.continuousActiveWork >= before, "20 seconds is not a break")
        #expect(tracker.session.breakCount == 0)
    }
}
