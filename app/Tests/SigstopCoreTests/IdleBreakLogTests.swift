import Foundation
import Testing

@testable import SigstopCore

private struct Bench {
    static let app = AppIdentity(bundleID: "com.apple.dt.Xcode", localizedName: "Xcode", pid: 1)
    static let calendar = CalendarDay.utcCalendar

    var session: EngineHarness.Session
    var tracker: SessionTracker
    let time: MutableTimeSource

    init(settings: SigstopSettings = EngineHarness.ownerSettings) {
        session = EngineHarness.Session(settings: settings)
        time = MutableTimeSource(now: session.driver.now, monotonic: session.driver.monotonic)
        var policy = BreakPolicy(settings: settings)
        policy.tickInterval = EngineHarness.Driver.tick
        policy.tickTolerance = EngineHarness.Driver.tick
        tracker = SessionTracker(time: time, policy: policy)
        session.note(.start(at: time.now))
        session.note(.focus(at: time.now, app: Self.app.bundleID, activity: .coding))
    }

    @discardableResult
    mutating func tick(idle: TimeInterval = 0, locked: Bool = false, jump: TimeInterval = 0) -> [Effect] {
        if jump > 0 {
            time.advance(by: jump)
            tracker.noteSystemWake()
        } else {
            time.advance(by: EngineHarness.Driver.tick)
        }
        let events = tracker.tick(
            TickSample(
                idleSeconds: idle, screenLocked: locked, application: Self.app,
                activity: .coding, confidence: Confidence(0.9)
            )
        )
        session.driver.idleSeconds = idle
        var work = tracker.session.continuousActiveWork
        if case .breakActive = session.driver.state {} else {
            work = max(0, work - EngineHarness.Driver.tick)
        }
        session.driver.continuousWork = work
        if jump > 0 {
            session.driver.now = session.driver.now.addingTimeInterval(jump - EngineHarness.Driver.tick)
            session.driver.monotonic += jump - EngineHarness.Driver.tick
        }
        return session.step(sessionEvents: events)
    }

    mutating func work(minutes: Double) {
        for _ in 0..<Int(minutes * 12) { tick() }
    }

    mutating func away(minutes: Double, locked: Bool = false) {
        var idle: TimeInterval = 0
        for _ in 0..<Int(minutes * 12) {
            idle += EngineHarness.Driver.tick
            tick(idle: idle, locked: locked)
        }
    }

    mutating func promptArrives(limit: Int = 200) -> Bool {
        for _ in 0..<limit {
            let effects = tick()
            if effects.contains(where: { if case .deliverPrompt = $0 { return true } else { return false } }) {
                return true
            }
        }
        return false
    }

    var lines: [LoggedEvent] { session.log.lines }

    func breakLines(_ kind: EventKind) -> [LoggedEvent] {
        lines.filter { $0.kind == kind && $0.origin == .idleInferred }
    }

    func rollup() -> DailySummary {
        let day = CalendarDay.local(of: time.now, calendar: Self.calendar, boundaryHour: 4)
        return DailyRollup.compute(day: day, events: lines, policy: .default, calendar: Self.calendar)
    }
}

@Suite("walking away is a break the day's numbers can see")
struct IdleBreakLogTests {

    @Test("twelve minutes away after a prompt is one break, kept, of twelve minutes")
    func walkingAwayIsLoggedAndCounted() throws {
        var bench = Bench()
        let asked = bench.promptArrives()
        #expect(asked)
        bench.away(minutes: 12)
        bench.work(minutes: 1)

        let begin = try #require(bench.breakLines(.breakBegin).first)
        let end = try #require(bench.breakLines(.breakEnd).first)
        #expect(bench.breakLines(.breakBegin).count == 1)
        #expect(bench.breakLines(.breakEnd).count == 1)
        #expect(end.thresholdSeconds == 300)
        let away = end.at.timeIntervalSince(begin.at)
        #expect((12 * 60 ... 12 * 60 + 15).contains(away), "began at last input, ended at first input back: \(away)")
        #expect(end.durationSeconds == Int(away.rounded()))
        #expect(bench.lines.contains { $0.kind == .cycleClose && $0.outcome == .honored })

        let s = bench.rollup()
        #expect(s.breakCount == 1)
        #expect(s.breaksIdleInferred == 1)
        #expect(s.breaksAbandoned == 0)
        #expect(s.totalBreakTime == away)
        #expect(s.averageBreakLength == away)
        #expect(s.breakOpportunities == 1)
        #expect(s.honoredOpportunities == 1, "the engine closed the cycle honored, so the day must agree")
    }

    @Test("closing the lid for ten minutes is a ten minute break")
    func sleepingThroughABreak() throws {
        var bench = Bench()
        bench.work(minutes: 3)
        bench.tick(idle: 600, jump: 600)
        bench.work(minutes: 1)

        let end = try #require(bench.breakLines(.breakEnd).first)
        #expect((600...610).contains(end.durationSeconds ?? 0), "got \(String(describing: end.durationSeconds))")
        let s = bench.rollup()
        #expect(s.breakCount == 1)
        #expect(s.breaksIdleInferred == 1)
        #expect(s.averageBreakLength == end.durationSeconds.map(TimeInterval.init))
    }

    @Test("a lock that outgrows a break into a session end is one break, measured to the session gap")
    func aLongLockIsOneBreakThenTheSessionEnd() throws {
        var settings = EngineHarness.ownerSettings
        settings.workIntervalMinutes = 45
        var bench = Bench(settings: settings)
        bench.work(minutes: 5)
        bench.away(minutes: 40, locked: true)
        bench.work(minutes: 1)

        let kinds = bench.lines.map(\.kind).filter { [.breakBegin, .breakEnd, .stop, .start].contains($0) }
        #expect(kinds == [.start, .breakBegin, .stop, .breakEnd, .start], "got \(kinds)")
        let end = try #require(bench.breakLines(.breakEnd).first)
        #expect(end.durationSeconds == 30 * 60, "the break ran to the session gap, not to the unlock")

        let s = bench.rollup()
        #expect(s.breakCount == 1)
        #expect(s.breaksIdleInferred == 1)
        #expect(s.breaksAbandoned == 0)
        #expect(s.totalBreakTime == TimeInterval(30 * 60))
        #expect(s.sessionCount == 2)
    }

    @Test("three minutes away is not a break and writes no break line")
    func aShortAbsenceIsNotABreak() {
        var bench = Bench()
        bench.work(minutes: 2)
        bench.away(minutes: 3)
        bench.work(minutes: 1)

        #expect(bench.breakLines(.breakBegin).isEmpty)
        #expect(bench.breakLines(.breakEnd).isEmpty)
        #expect(bench.lines.contains { $0.kind == .idleEnd })
        let s = bench.rollup()
        #expect(s.breakCount == 0)
        #expect(s.breaksAbandoned == 0)
    }
}
