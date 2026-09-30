import Foundation
import Testing

@testable import SigstopCore

@Suite("time away after a silent call")
struct CallThenAwayTests {

    private func makeTracker() -> (SessionTracker, MutableTimeSource) {
        let time = MutableTimeSource()
        var policy = BreakPolicy()
        policy.qualifyingBreak = 5 * 60
        policy.tickInterval = 5
        policy.tickTolerance = 5
        return (SessionTracker(time: time, policy: policy), time)
    }

    private func sample(idle: TimeInterval = 0, mic: Bool = false, locked: Bool = false) -> TickSample {
        TickSample(
            idleSeconds: idle,
            screenLocked: locked,
            micRunning: mic,
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

    private func ended(_ events: [SessionEvent]) -> Int {
        events.filter { if case .sessionEnded = $0 { return true } else { return false } }.count
    }

    private func workThenSilentCall(
        _ tracker: inout SessionTracker, _ time: MutableTimeSource
    ) -> (idle: TimeInterval, callEnded: Date, events: [SessionEvent]) {
        var events: [SessionEvent] = []
        for _ in 0..<120 { time.advance(by: 5); events += tracker.tick(sample()) }
        var idle: TimeInterval = 0
        for _ in 0..<300 {
            time.advance(by: 5)
            idle += 5
            events += tracker.tick(sample(idle: idle, mic: true))
        }
        return (idle, time.now, events)
    }

    @Test("a silent call is not a break")
    func theCallIsNotABreak() {
        var (tracker, time) = makeTracker()
        let call = workThenSilentCall(&tracker, time)
        #expect(breaks(call.events).isEmpty)
        #expect(tracker.session.pauseCause == .meetingNoInput)
    }

    @Test("locking the screen after a call counts from the lock, not from the start of the call")
    func lockAfterACall() {
        var (tracker, time) = makeTracker()
        let call = workThenSilentCall(&tracker, time)
        var idle = call.idle

        time.advance(by: 5)
        idle += 5
        let lockTick = tracker.tick(sample(idle: idle, locked: true))
        #expect(breaks(lockTick).isEmpty, "twenty-five minutes on a call is not time away")

        var events: [SessionEvent] = []
        for _ in 0..<72 {
            time.advance(by: 5)
            idle += 5
            events += tracker.tick(sample(idle: idle, locked: true))
        }
        let recorded = breaks(events)
        #expect(recorded.count == 1, "six minutes locked is a break")
        #expect((recorded.first?.duration ?? .infinity) < 7 * 60)
        #expect(abs((recorded.first?.start ?? .distantPast).timeIntervalSince(call.callEnded)) <= 5)
    }

    @Test("sleeping the Mac after a call counts from the sleep")
    func sleepAfterACall() {
        var (tracker, time) = makeTracker()
        let call = workThenSilentCall(&tracker, time)

        tracker.noteSystemWake()
        time.sleepAndWake(for: 10 * 60)
        let events = tracker.tick(sample(idle: call.idle + 10 * 60))

        let recorded = breaks(events)
        #expect(recorded.count == 1, "ten minutes asleep is a break")
        #expect((recorded.first?.duration ?? .infinity) <= 10 * 60 + 5)
        #expect(abs((recorded.first?.start ?? .distantPast).timeIntervalSince(call.callEnded)) <= 5)
    }

    @Test("staying away after the call ends is a break and then a session end")
    func awayAfterTheCallEnds() {
        var (tracker, time) = makeTracker()
        let call = workThenSilentCall(&tracker, time)
        var idle = call.idle

        var events: [SessionEvent] = []
        for _ in 0..<(50 * 12) {
            time.advance(by: 5)
            idle += 5
            events += tracker.tick(sample(idle: idle))
        }

        let recorded = breaks(events)
        #expect(recorded.count == 1, "the absence after the call is time away like any other")
        #expect(ended(events) == 1, "and fifty minutes of it ends the session")
        #expect(abs((recorded.first?.start ?? .distantPast).timeIntervalSince(call.callEnded)) <= 5)
        #expect(tracker.session.pauseCause == .microIdleExceeded || tracker.session.isStopped)
    }

    @Test("coming back just after the call ends is not a break")
    func backJustAfterTheCall() {
        var (tracker, time) = makeTracker()
        let call = workThenSilentCall(&tracker, time)

        var events: [SessionEvent] = []
        time.advance(by: 5)
        events += tracker.tick(sample(idle: call.idle + 5))
        time.advance(by: 5)
        events += tracker.tick(sample(idle: 1))
        for _ in 0..<12 { time.advance(by: 5); events += tracker.tick(sample()) }

        #expect(breaks(events).isEmpty)
        #expect(tracker.session.isRunning)
    }
}
