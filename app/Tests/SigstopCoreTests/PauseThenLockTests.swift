import Foundation
import Testing

@testable import SigstopCore

@Suite("a lock inside a pause counts only the time away")
struct PauseThenLockTests {

    private func makeTracker() -> (SessionTracker, MutableTimeSource) {
        let time = MutableTimeSource()
        var policy = BreakPolicy()
        policy.qualifyingBreak = 5 * 60
        policy.tickInterval = 5
        policy.tickTolerance = 5
        return (SessionTracker(time: time, policy: policy), time)
    }

    private func sample(idle: TimeInterval = 0, paused: Bool = false, locked: Bool = false) -> TickSample {
        TickSample(
            idleSeconds: idle,
            screenLocked: locked,
            userPaused: paused,
            application: AppIdentity(bundleID: "com.apple.dt.Xcode", localizedName: "Xcode", pid: 1),
            activity: .coding,
            confidence: Confidence(0.9)
        )
    }

    private func recorded(_ events: [SessionEvent]) -> [TimeInterval] {
        events.compactMap { if case .breakRecorded(_, _, _, let d) = $0 { return d } else { return nil } }
    }

    @Test("typing through a pause and then locking the screen records no break at once")
    func lockAfterTypingThroughAPause() {
        var (tracker, time) = makeTracker()
        for _ in 0..<12 { time.advance(by: 5); _ = tracker.tick(sample()) }
        for _ in 0..<120 { time.advance(by: 5); _ = tracker.tick(sample(paused: true)) }

        time.advance(by: 5)
        let events = tracker.tick(sample(idle: 5, paused: true, locked: true))

        #expect(recorded(events).isEmpty, "ten minutes of typing while paused is not a break")
        #expect(tracker.session.breakCount == 0)
    }

    @Test("a lock that lasts long enough is a break of the time locked, not of the whole pause")
    func longLockAfterTypingThroughAPause() {
        var (tracker, time) = makeTracker()
        for _ in 0..<12 { time.advance(by: 5); _ = tracker.tick(sample()) }
        for _ in 0..<120 { time.advance(by: 5); _ = tracker.tick(sample(paused: true)) }

        var durations: [TimeInterval] = []
        for k in 1...72 {
            time.advance(by: 5)
            durations += recorded(tracker.tick(sample(idle: TimeInterval(k * 5), paused: true, locked: true)))
        }

        #expect(durations.count == 1)
        #expect((durations.first ?? 0) < 7 * 60, "the break is the lock, not the ten minutes of typing before it")
        #expect(tracker.session.breakCount == 1)
    }

    @Test("walking away during a pause and then locking still counts the whole time away")
    func lockAfterWalkingAwayDuringAPause() {
        var (tracker, time) = makeTracker()
        for _ in 0..<12 { time.advance(by: 5); _ = tracker.tick(sample()) }
        for k in 1...120 { time.advance(by: 5); _ = tracker.tick(sample(idle: TimeInterval(k * 5), paused: true)) }

        time.advance(by: 5)
        let durations = recorded(tracker.tick(sample(idle: 605, paused: true, locked: true)))

        #expect(durations.count == 1)
        #expect((durations.first ?? 0) >= 10 * 60, "no input since the pause began, so all of it was time away")
    }
}
