import Foundation
import Testing

@testable import SigstopCore

@Suite("time away while the app is paused is logged as idle")
struct PausedIdleLogTests {

    private static let xcode = AppIdentity(bundleID: "com.apple.dt.Xcode", localizedName: "Xcode", pid: 1)
    private static let start = Date(timeIntervalSince1970: 1_700_039_400)
    private static let day = CalendarDay(year: 2023, month: 11, day: 15)
    private static let rollup = RollupPolicy(
        microIdleGrace: 90, qualifyingBreak: 5 * 60, longPauseReset: 20 * 60,
        complianceWindow: 10 * 60, dayBoundaryHour: 4
    )

    private struct Desk {
        let time: MutableTimeSource
        var tracker: SessionTracker
        var ledger = IdleLedger()
        var log = EngineHarness.LogReplay()
        var paused = false
        private var idle: TimeInterval = 0
        private var lastFocusAt: Date

        init() {
            time = MutableTimeSource(now: PausedIdleLogTests.start)
            var policy = BreakPolicy()
            policy.tickInterval = 5
            policy.tickTolerance = 5
            tracker = SessionTracker(time: time, policy: policy)
            log.append(.start(at: time.now))
            log.append(.focus(at: time.now, app: PausedIdleLogTests.xcode.bundleID, activity: .coding))
            lastFocusAt = time.now
        }

        mutating func run(minutes: Double, away: Bool) {
            for _ in 0..<Int(minutes * 12) {
                time.advance(by: 5)
                idle = away ? idle + 5 : 0
                let sample = TickSample(
                    idleSeconds: idle, userPaused: paused,
                    application: PausedIdleLogTests.xcode, activity: .coding, confidence: Confidence(0.9)
                )
                let events = tracker.tick(sample)
                let lines = ledger.observe(
                    events, idleSeconds: idle, paused: paused, grace: 90, at: time.now
                )
                for line in lines { log.append(line) }
                if time.now.timeIntervalSince(lastFocusAt) >= 300 {
                    log.append(.focus(at: time.now, app: PausedIdleLogTests.xcode.bundleID, activity: .coding))
                    lastFocusAt = time.now
                }
            }
        }

        mutating func summary() -> DailySummary {
            log.append(.stop(at: time.now))
            return DailyRollup.compute(
                day: PausedIdleLogTests.day, events: log.lines,
                policy: PausedIdleLogTests.rollup, calendar: CalendarDay.utcCalendar
            )
        }

        func minutes(of kind: EventKind) -> [Double] {
            log.lines.filter { $0.kind == kind }
                .map { $0.at.timeIntervalSince(PausedIdleLogTests.start) / 60 }
        }
    }

    @Test("an hour's pause spent away is idle from the last input, through the end of the pause")
    func anHourAwayIsIdle() {
        var desk = Desk()
        desk.run(minutes: 10, away: false)
        desk.paused = true
        desk.run(minutes: 2, away: false)
        desk.run(minutes: 58, away: true)
        desk.paused = false
        desk.run(minutes: 5, away: true)
        desk.run(minutes: 5, away: false)

        let begins = desk.minutes(of: .idleBegin)
        let ends = desk.minutes(of: .idleEnd)
        #expect(begins.count == 1 && ends.count == 1, "\(desk.log.kinds)")
        #expect(abs((begins.first ?? 0) - 12) <= 0.2, "idle began at \(begins)")
        #expect(abs((ends.first ?? 0) - 75) <= 0.2, "idle ended at \(ends)")

        let credited = desk.summary().totalActiveWork / 60
        #expect(credited >= 15 && credited <= 19, "the pause was credited as \(credited) minutes of work")
    }

    @Test("pausing for the rest of the day and going home is not a ten hour work day")
    func theRestOfTheDayAwayIsIdle() {
        var desk = Desk()
        desk.run(minutes: 10, away: false)
        desk.paused = true
        desk.run(minutes: 10 * 60, away: true)
        desk.run(minutes: 5, away: false)

        let begins = desk.minutes(of: .idleBegin)
        let ends = desk.minutes(of: .idleEnd)
        #expect(begins.count == 1 && ends.count == 1, "\(desk.log.kinds)")
        #expect(abs((begins.first ?? 0) - 10) <= 0.2, "idle began at \(begins)")
        #expect(abs((ends.first ?? 0) - 610) <= 0.2, "idle ended at \(ends)")

        let credited = desk.summary().totalActiveWork / 60
        #expect(credited >= 13 && credited <= 17, "the evening was credited as \(credited) minutes of work")
    }

    @Test("working through a pause logs no idle at all")
    func workingThroughAPauseIsNotIdle() {
        var desk = Desk()
        desk.run(minutes: 10, away: false)
        desk.paused = true
        desk.run(minutes: 30, away: false)
        desk.paused = false
        desk.run(minutes: 5, away: false)

        #expect(desk.minutes(of: .idleBegin).isEmpty, "\(desk.log.kinds)")
        #expect(desk.minutes(of: .idleEnd).isEmpty)
        let credited = desk.summary().totalActiveWork / 60
        #expect(credited >= 44 && credited <= 46, "\(credited)")
    }

    @Test("a look out of the window inside a pause is under the grace and logs nothing")
    func aShortAbsenceInsideAPauseIsNotIdle() {
        var desk = Desk()
        desk.paused = true
        desk.run(minutes: 5, away: false)
        desk.run(minutes: 1, away: true)
        desk.run(minutes: 5, away: false)

        #expect(desk.minutes(of: .idleBegin).isEmpty, "\(desk.log.kinds)")
    }

    @Test("pressing Resume while away and coming back closes the span once")
    func resumingAfterAnAbsenceClosesOnce() {
        var desk = Desk()
        desk.paused = true
        desk.run(minutes: 5, away: false)
        desk.run(minutes: 20, away: true)
        desk.paused = false
        desk.run(minutes: 5, away: false)

        #expect(desk.minutes(of: .idleBegin).count == 1, "\(desk.log.kinds)")
        #expect(desk.minutes(of: .idleEnd).count == 1, "\(desk.log.kinds)")
    }
}
