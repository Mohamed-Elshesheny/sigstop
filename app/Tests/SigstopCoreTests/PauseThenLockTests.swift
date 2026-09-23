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

    @Test("a second lock inside the same pause is a break of its own")
    func secondLockInsideOnePause() {
        var (tracker, time) = makeTracker()
        for _ in 0..<12 { time.advance(by: 5); _ = tracker.tick(sample()) }
        for _ in 0..<24 { time.advance(by: 5); _ = tracker.tick(sample(paused: true)) }

        var first: [TimeInterval] = []
        for k in 1...96 {
            time.advance(by: 5)
            first += recorded(tracker.tick(sample(idle: TimeInterval(k * 5), paused: true, locked: true)))
        }
        #expect(first.count == 1)
        let firstEnded = tracker.session.lastBreakEndedAt

        for _ in 0..<24 { time.advance(by: 5); _ = tracker.tick(sample(paused: true)) }
        var second: [TimeInterval] = []
        for k in 1...120 {
            time.advance(by: 5)
            second += recorded(tracker.tick(sample(idle: TimeInterval(k * 5), paused: true, locked: true)))
        }
        for _ in 0..<3 { time.advance(by: 5); second += recorded(tracker.tick(sample(paused: true))) }

        #expect(second.count == 1, "the second lock is time away too, and nothing had recorded it")
        #expect((second.first ?? 0) < 7 * 60, "measured from the typing before it, not from the first lock")
        #expect(tracker.session.breakCount == 2)
        #expect(tracker.session.lastBreakEndedAt != firstEnded)
    }

    @Test("a lock inside a pause records nothing into a session that has already ended")
    func noBreakIntoAnEndedSession() {
        var (tracker, time) = makeTracker()
        for _ in 0..<12 { time.advance(by: 5); _ = tracker.tick(sample()) }
        for _ in 0..<12 { time.advance(by: 5); _ = tracker.tick(sample(paused: true)) }

        var ended = false
        for k in 1...(35 * 12) {
            time.advance(by: 5)
            let events = tracker.tick(sample(idle: TimeInterval(k * 5), paused: true, locked: true))
            ended = ended || events.contains { if case .sessionEnded = $0 { return true } else { return false } }
        }
        #expect(ended)
        let breaks = tracker.session.breakCount

        for _ in 0..<12 { time.advance(by: 5); _ = tracker.tick(sample(paused: true)) }
        var later: [TimeInterval] = []
        for k in 1...72 {
            time.advance(by: 5)
            later += recorded(tracker.tick(sample(idle: TimeInterval(k * 5), paused: true, locked: true)))
        }

        #expect(later.isEmpty, "the session is over; the next one starts when the user is back")
        #expect(tracker.session.isStopped)
        #expect(tracker.session.breakCount == breaks)
    }
}
