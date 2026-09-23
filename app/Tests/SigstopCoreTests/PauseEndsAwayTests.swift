import Foundation
import Testing

@testable import SigstopCore

@Suite("a pause that ends with nobody there")
struct PauseEndsAwayTests {

    private func makeTracker() -> (SessionTracker, MutableTimeSource) {
        let time = MutableTimeSource()
        var policy = BreakPolicy()
        policy.qualifyingBreak = 5 * 60
        policy.tickInterval = 5
        policy.tickTolerance = 5
        return (SessionTracker(time: time, policy: policy), time)
    }

    private func sample(idle: TimeInterval = 0, paused: Bool = false) -> TickSample {
        TickSample(
            idleSeconds: idle,
            userPaused: paused,
            application: AppIdentity(bundleID: "com.apple.dt.Xcode", localizedName: "Xcode", pid: 1),
            activity: .coding,
            confidence: Confidence(0.9)
        )
    }

    private func breaks(_ events: [SessionEvent]) -> [(start: Date, duration: TimeInterval)] {
        events.compactMap {
            if case .breakRecorded(_, let start, _, let d) = $0 { return (start, d) } else { return nil }
        }
    }

    private func walkAwayThroughATenMinutePause(
        _ tracker: inout SessionTracker, _ time: MutableTimeSource
    ) -> (idle: TimeInterval, pauseEnded: Date) {
        for _ in 0..<12 { time.advance(by: 5); _ = tracker.tick(sample()) }
        var idle: TimeInterval = 0
        for _ in 0..<120 {
            time.advance(by: 5)
            idle += 5
            _ = tracker.tick(sample(idle: idle, paused: true))
        }
        return (idle, time.now)
    }

    @Test("staying away after the pause ends is a break, then a session end, counted from the end of the pause")
    func stayingAwayBecomesABreak() {
        var (tracker, time) = makeTracker()
        let walked = walkAwayThroughATenMinutePause(&tracker, time)
        var idle = walked.idle
        let pauseEnded = walked.pauseEnded

        var events: [SessionEvent] = []
        for _ in 0..<(2 * 60 * 12) {
            time.advance(by: 5)
            idle += 5
            events += tracker.tick(sample(idle: idle))
        }

        let recorded = breaks(events)
        let ended = events.contains { if case .sessionEnded = $0 { return true } else { return false } }
        #expect(recorded.count == 1, "the absence after the pause is time away like any other")
        #expect(ended, "and two hours of it ends the session")
        #expect((recorded.first?.duration ?? 0) < 6 * 60, "the ten minutes inside the pause are not part of it")
        #expect(abs((recorded.first?.start ?? .distantPast).timeIntervalSince(pauseEnded)) <= 5)
    }

    @Test("coming back and typing just after the pause ends is not a break")
    func comingBackJustAfterIsNotABreak() {
        var (tracker, time) = makeTracker()
        var idle = walkAwayThroughATenMinutePause(&tracker, time).idle

        var events: [SessionEvent] = []
        time.advance(by: 5)
        idle += 5
        events += tracker.tick(sample(idle: idle))
        time.advance(by: 5)
        events += tracker.tick(sample(idle: 1))
        for _ in 0..<12 { time.advance(by: 5); events += tracker.tick(sample()) }

        #expect(breaks(events).isEmpty, "ten minutes away inside a pause is the pause's, not a break")
        #expect(tracker.session.breakCount == 0)
        #expect(tracker.session.isRunning, "the work clock picks up again")
    }

    @Test("the absence after the pause is logged as idle from the moment the pause ended")
    func theAbsenceIsLoggedAsIdle() {
        var (tracker, time) = makeTracker()
        let walked = walkAwayThroughATenMinutePause(&tracker, time)
        var idle = walked.idle
        let pauseEnded = walked.pauseEnded

        time.advance(by: 5)
        idle += 5
        let events = tracker.tick(sample(idle: idle))

        let paused = events.compactMap {
            if case .clockPaused(let cause, let since) = $0 { return (cause, since) } else { return nil }
        }
        #expect(paused.count == 1)
        #expect(paused.first?.0 == .microIdleExceeded)
        #expect(abs((paused.first?.1 ?? .distantPast).timeIntervalSince(pauseEnded)) <= 5)
        #expect(tracker.session.pauseCause == .microIdleExceeded)
    }
}
