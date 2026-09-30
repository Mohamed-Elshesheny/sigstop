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

    @Test("taking the offered break and staying away past it is one break, not two")
    func stayingAwayAfterAnAcceptedBreak() {
        var (tracker, time) = makeTracker()
        var log = SessionLogLedger()
        var events: [SessionEvent] = []
        for _ in 0..<(46 * 12) { time.advance(by: 5); events += tracker.tick(sample()) }

        events += tracker.beginBreak(origin: .accepted)
        var idle: TimeInterval = 0
        for _ in 0..<60 {
            time.advance(by: 5)
            idle += 5
            events += tracker.tick(sample(idle: idle))
        }
        events += tracker.endBreak(origin: .accepted, threshold: 5 * 60)
        for _ in 0..<(10 * 12) {
            time.advance(by: 5)
            idle += 5
            events += tracker.tick(sample(idle: idle))
        }
        time.advance(by: 5)
        events += tracker.tick(sample(idle: 0))

        let lines = events.flatMap { log.lines(for: $0, at: time.now, qualifyingBreak: 5 * 60) }
        let inferred = events.filter {
            if case .breakRecorded(.idleInferred, _, _, _) = $0 { return true } else { return false }
        }
        #expect(tracker.session.breakCount == 1, "five minutes offered and fifteen taken is still one break")
        #expect(inferred.isEmpty)
        #expect(!lines.contains { $0.kind == .breakBegin })
        #expect(tracker.session.isRunning)
        #expect((tracker.session.timeSinceLastBreak(now: time.now) ?? .infinity) <= 5)
    }

    @Test("staying away half an hour after a break still ends the session")
    func longAbsenceAfterABreakEndsTheSession() {
        var (tracker, time) = makeTracker()
        var events: [SessionEvent] = []
        for _ in 0..<(46 * 12) { time.advance(by: 5); events += tracker.tick(sample()) }
        events += tracker.beginBreak(origin: .accepted)
        var idle: TimeInterval = 0
        for _ in 0..<60 { time.advance(by: 5); idle += 5; events += tracker.tick(sample(idle: idle)) }
        events += tracker.endBreak(origin: .accepted, threshold: 5 * 60)
        for _ in 0..<(31 * 12) { time.advance(by: 5); idle += 5; events += tracker.tick(sample(idle: idle)) }

        #expect(events.contains { if case .sessionEnded = $0 { return true } else { return false } })
        #expect(tracker.session.breakCount == 1)
    }
}
