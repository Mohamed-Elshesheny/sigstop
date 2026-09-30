import Foundation
import Testing

@testable import SigstopCore

@Suite("since your last break")
struct SinceLastBreakTests {

    private func makeTracker() -> (SessionTracker, MutableTimeSource) {
        let time = MutableTimeSource()
        var policy = BreakPolicy()
        policy.qualifyingBreak = 5 * 60
        policy.tickInterval = 5
        policy.tickTolerance = 5
        return (SessionTracker(time: time, policy: policy), time)
    }

    private func sample(idle: TimeInterval = 0, locked: Bool = false) -> TickSample {
        TickSample(
            idleSeconds: idle,
            screenLocked: locked,
            application: AppIdentity(bundleID: "com.apple.dt.Xcode", localizedName: "Xcode", pid: 1),
            activity: .coding,
            confidence: Confidence(0.9)
        )
    }

    @Test("twenty minutes away is counted from the return, not from the fifth minute")
    func idleBreakEndsOnReturn() {
        var (tracker, time) = makeTracker()
        for _ in 0..<120 { time.advance(by: 5); _ = tracker.tick(sample()) }
        var idle: TimeInterval = 0
        for _ in 0..<240 {
            time.advance(by: 5)
            idle += 5
            _ = tracker.tick(sample(idle: idle))
        }
        time.advance(by: 5)
        _ = tracker.tick(sample(idle: 0))

        #expect(tracker.session.breakCount == 1)
        #expect((tracker.session.timeSinceLastBreak(now: time.now) ?? .infinity) <= 5)
    }

    @Test("a locked screen is counted from the unlock")
    func lockedBreakEndsOnReturn() {
        var (tracker, time) = makeTracker()
        for _ in 0..<120 { time.advance(by: 5); _ = tracker.tick(sample()) }
        for _ in 0..<240 { time.advance(by: 5); _ = tracker.tick(sample(locked: true)) }
        time.advance(by: 5)
        _ = tracker.tick(sample())

        #expect(tracker.session.breakCount == 1)
        #expect((tracker.session.timeSinceLastBreak(now: time.now) ?? .infinity) <= 5)
    }
}
