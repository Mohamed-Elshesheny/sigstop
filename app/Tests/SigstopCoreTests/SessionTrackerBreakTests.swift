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

    @Test("A break set shorter than the idle threshold counts once it has run its length")
    func shortPlannedBreakCounts() {
        var (tracker, time) = makeTracker()
        for _ in 0..<72 { time.advance(by: 5); _ = tracker.tick(sample()) }

        _ = tracker.beginBreak(origin: .accepted)
        for _ in 0..<24 { time.advance(by: 5); _ = tracker.tick(sample()) }
        let events = tracker.endBreak(origin: .accepted, threshold: 120)

        #expect(tracker.session.continuousActiveWork == 0, "a two minute break the user set and took resets the clock")
        #expect(tracker.session.breakCount == 1)
        #expect(events.contains { if case .breakRecorded = $0 { return true } else { return false } })
    }


    @Test("a break taken while paused keeps the work clock stopped through a lock and unlock")
    func breakFromAPauseSurvivesALock() {
        var (tracker, time) = makeTracker()
        for _ in 0..<12 { time.advance(by: 5); _ = tracker.tick(sample()) }
        for _ in 0..<12 { time.advance(by: 5); _ = tracker.tick(sample(paused: true)) }

        _ = tracker.beginBreak(origin: .userInitiated)
        #expect(tracker.session.pauseCause == .breakActive, "the break owns the clock, not the pause it replaced")
        for k in 1...24 { time.advance(by: 5); _ = tracker.tick(sample(idle: TimeInterval(k * 5), locked: true)) }
        let before = tracker.session.continuousActiveWork
        for _ in 0..<24 { time.advance(by: 5); _ = tracker.tick(sample()) }

        #expect(tracker.session.pauseCause == .breakActive)
        #expect(tracker.session.continuousActiveWork == before, "typing during a break earns nothing")
    }

    @Test("a lock inside a break is the break, not a second one")
    func lockInsideABreakIsRecordedOnce() {
        var (tracker, time) = makeTracker()
        for _ in 0..<12 { time.advance(by: 5); _ = tracker.tick(sample()) }

        var events = tracker.beginBreak(origin: .userInitiated)
        for k in 1...72 { time.advance(by: 5); events += tracker.tick(sample(idle: TimeInterval(k * 5), locked: true)) }
        time.advance(by: 5)
        events += tracker.tick(sample())
        events += tracker.endBreak(origin: .userInitiated)

        let origins = events.compactMap { if case .breakRecorded(let o, _, _, _) = $0 { return o } else { return nil } }
        #expect(origins == [.userInitiated], "got \(origins)")
        #expect(tracker.session.breakCount == 1)
    }
}
