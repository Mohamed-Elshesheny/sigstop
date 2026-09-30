import Foundation
import Testing

@testable import SigstopCore

@Suite("a pause does not cancel a stand-down")
struct PauseKeepsStandDownTests {

    typealias Bench = TrackerEngineBench

    enum Ending: String, Sendable, CaseIterable, CustomStringConvertible {
        case resume
        case runsOut

        var description: String { rawValue }
    }

    @discardableResult
    private static func pauseAndComeBack(_ bench: inout Bench, _ ending: Ending) -> [Effect] {
        var resumed: [Effect] = []
        switch ending {
        case .resume:
            bench.tick(action: .pauseApp(3600))
            bench.tick(idle: Bench.tick)
            bench.work(minutes: 10)
            resumed = bench.tick(action: .resumeApp)
        case .runsOut:
            bench.tick(action: .pauseApp(10 * 60))
            bench.tick(idle: Bench.tick)
            bench.work(minutes: 10)
        }
        bench.tick()
        bench.tick()
        return resumed
    }

    private static func isPaused(_ state: EngineState) -> Bool {
        if case .quiet(let q) = state, q.cause == .userPaused { return true }
        return false
    }

    @Test("a skip keeps its twenty minutes of work across a pause", arguments: Ending.allCases)
    func skipSurvivesAPause(_ ending: Ending) throws {
        var bench = Bench()
        let prompt = bench.workUntilPrompt()
        _ = try #require(prompt)
        bench.tick(action: .skip)
        let skippedAt = bench.continuousWork
        bench.work(minutes: 1)

        Self.pauseAndComeBack(&bench, ending)
        #expect(!Self.isPaused(bench.state), "the pause never ended: \(bench.state)")

        let working = try #require(bench.working, "expected working, got \(bench.state)")
        #expect(working.standDown == .skipped)
        #expect(working.armThreshold == skippedAt + bench.policy.rearmAfterSkip)

        let reached = bench.workUntilOpen()
        let opened = try #require(reached)
        #expect(opened >= skippedAt + bench.policy.rearmAfterSkip,
                "asked again \((opened - skippedAt) / 60) min of work after the skip")
    }

    @Test("an exhausted ladder keeps its cooldown across a pause", arguments: Ending.allCases)
    func cooldownSurvivesAPause(_ ending: Ending) throws {
        var bench = Bench()
        let prompt = bench.workUntilPrompt()
        _ = try #require(prompt)
        let exhausted = bench.workUntil(limitMinutes: 60) { Bench.closes($0).contains(.ignoredExhausted) }
        _ = try #require(exhausted)
        let cooldownFrom = bench.time.continuousSeconds

        let resumed = Self.pauseAndComeBack(&bench, ending)
        if ending == .resume {
            #expect(resumed.contains(.setIndicator(.backedOff)), "\(resumed)")
            #expect(!resumed.contains(.setIndicator(.working)), "\(resumed)")
        }

        let working = try #require(bench.working, "expected working, got \(bench.state)")
        #expect(working.standDown == .ladderExhausted)
        #expect(working.cooldownUntilMono == cooldownFrom + bench.policy.cooldownAfterExhausted)

        let reached = bench.workUntilOpen()
        _ = try #require(reached)
        let waited = bench.time.continuousSeconds - cooldownFrom
        #expect(waited >= bench.policy.cooldownAfterExhausted, "asked again after \(waited / 60) min")
    }

    @Test("a cycle that went stale keeps its re-arm across a pause", arguments: Ending.allCases)
    func staleRearmSurvivesAPause(_ ending: Ending) throws {
        var bench = Bench()
        bench.mic = true
        bench.camera = true
        let expired = bench.workUntil(limitMinutes: 150) { Bench.closes($0).contains(.expired) }
        _ = try #require(expired)
        let expiredAt = bench.continuousWork
        bench.mic = false
        bench.camera = false

        Self.pauseAndComeBack(&bench, ending)

        let working = try #require(bench.working, "expected working, got \(bench.state)")
        #expect(working.standDown == .cycleExpired)
        #expect(working.armThreshold == expiredAt + bench.policy.rearmAfterStale)

        let reached = bench.workUntilOpen()
        let opened = try #require(reached)
        #expect(opened >= expiredAt + bench.policy.rearmAfterStale,
                "asked again \((opened - expiredAt) / 60) min of work after it went stale")
    }

    @Test("an hour's pause that runs out resets the work clock, and the stand-down goes with it")
    func anHourOutlastsTheStandDown() throws {
        var bench = Bench()
        let prompt = bench.workUntilPrompt()
        _ = try #require(prompt)
        bench.tick(action: .skip)
        bench.tick(action: .pauseApp(3600))
        let ending = bench.work(minutes: 61)

        #expect(bench.events.contains(.clockReset(reason: .longPause)))
        #expect(!Bench.opensCycle(ending), "the pause ended into a prompt")
        let working = try #require(bench.working, "expected working, got \(bench.state)")
        #expect(working.standDown == nil)
        #expect(working.armThreshold == bench.policy.targetContinuousWork)
    }

    @Test("a stand-down parked while away is kept when the pause starts from idle")
    func pauseFromIdleKeepsIt() throws {
        let parked = WorkingState(
            armThreshold: 65 * 60, lastWorkSeen: 50 * 60, standDown: .skipped
        )
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        driver.state = .idle(IdleState(resume: parked))
        driver.continuousWork = parked.lastWorkSeen
        driver.step(action: .pauseApp(3600))
        driver.continuousWork = parked.lastWorkSeen
        driver.step(action: .resumeApp)

        guard case .working(let working) = driver.state else {
            Issue.record("expected working, got \(driver.state)"); return
        }
        #expect(working.standDown == .skipped)
        #expect(working.armThreshold == parked.armThreshold)
        #expect(working.armThreshold > driver.engine.policy.targetContinuousWork)
    }

    @Test("credit taken back as the pause starts is not mistaken for a reset")
    func graceRevokedKeepsIt() throws {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        let parked = WorkingState(
            armThreshold: 70 * 60, lastWorkSeen: 50 * 60, standDown: .skipped
        )
        driver.state = .working(parked)
        driver.continuousWork = parked.lastWorkSeen - EngineHarness.Driver.tick
        driver.step(action: .pauseApp(3600))
        driver.continuousWork = parked.lastWorkSeen - 4 - EngineHarness.Driver.tick
        driver.sessionEvents = [.graceRevoked(seconds: 4)]
        driver.step()
        driver.continuousWork = parked.lastWorkSeen - 4 - EngineHarness.Driver.tick
        driver.step(action: .resumeApp)
        driver.continuousWork = parked.lastWorkSeen - 4 - EngineHarness.Driver.tick
        driver.step()

        guard case .working(let working) = driver.state else {
            Issue.record("expected working, got \(driver.state)"); return
        }
        #expect(working.standDown == .skipped)
        #expect(working.armThreshold == parked.armThreshold)
    }

    @Test("a break, a reset or a new session inside the pause ends the parked stand-down",
          arguments: [
            SessionEvent.clockReset(reason: .longPause),
            SessionEvent.breakRecorded(
                origin: .idleInferred,
                start: Date(timeIntervalSince1970: 1_700_000_000),
                end: Date(timeIntervalSince1970: 1_700_000_600),
                duration: 600
            ),
            SessionEvent.sessionEnded(id: UUID(), at: Date(timeIntervalSince1970: 1_700_000_000)),
          ])
    func somethingRealEndsIt(_ event: SessionEvent) throws {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        let parked = WorkingState(
            armThreshold: 70 * 60, lastWorkSeen: 50 * 60, standDown: .skipped
        )
        driver.state = .working(parked)
        driver.continuousWork = parked.lastWorkSeen - EngineHarness.Driver.tick
        driver.step(action: .pauseApp(3600))
        driver.sessionEvents = [event]
        driver.step()
        driver.step(action: .resumeApp)

        guard case .working(let working) = driver.state else {
            Issue.record("expected working, got \(driver.state)"); return
        }
        #expect(working.standDown == nil)
        #expect(working.armThreshold == driver.engine.policy.targetContinuousWork)
    }

    @Test("a break taken inside the pause ends the parked stand-down and keeps the pause")
    func aBreakInsideThePauseEndsIt() throws {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        let parked = WorkingState(
            armThreshold: 70 * 60, lastWorkSeen: 50 * 60, standDown: .skipped
        )
        driver.state = .working(parked)
        driver.continuousWork = parked.lastWorkSeen - EngineHarness.Driver.tick
        driver.step(action: .pauseApp(3600))
        driver.step(action: .startBreakNow)
        driver.step(untilLimit: 200) { effects in
            effects.contains { if case .endBreak = $0 { return true } else { return false } }
        }
        guard case .quiet(let quiet) = driver.state else {
            Issue.record("expected the pause back, got \(driver.state)"); return
        }
        #expect(quiet.cause == .userPaused)
        #expect(quiet.resume == nil)
    }

    @Test("a pause that runs out inside quiet hours hands the stand-down on to them")
    func quietHoursCarryIt() throws {
        let calendar = CalendarDay.utcCalendar
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 21, minute: 55)))
        var settings = EngineHarness.ownerSettings
        settings.quietHours = QuietHours(startMinute: 22 * 60, endMinute: 22 * 60 + 30, enabled: true)
        var driver = EngineHarness.Driver(settings: settings, start: start)
        driver.calendarSystem = calendar
        let parked = WorkingState(
            armThreshold: 70 * 60, lastWorkSeen: 50 * 60, standDown: .skipped
        )
        driver.state = .working(parked)
        driver.continuousWork = parked.lastWorkSeen - EngineHarness.Driver.tick
        driver.step(action: .pauseApp(10 * 60))

        var handedOver: QuietState?
        for _ in 0..<(40 * 60 / Int(EngineHarness.Driver.tick)) {
            driver.continuousWork = parked.lastWorkSeen - EngineHarness.Driver.tick
            driver.step()
            if case .quiet(let q) = driver.state, q.cause == .scheduledQuietHours, handedOver == nil {
                handedOver = q
            }
            if driver.state.isWorking { break }
        }
        let quietHours = try #require(handedOver, "the pause never became quiet hours")
        #expect(quietHours.resume == parked)
        guard case .working(let working) = driver.state else {
            Issue.record("expected working after quiet hours, got \(driver.state)"); return
        }
        #expect(working.standDown == .skipped)
        #expect(working.armThreshold == parked.armThreshold)
    }

    @Test("changing the work interval while paused moves the parked threshold too")
    func retargetWhilePaused() throws {
        let parked = WorkingState(armThreshold: 45 * 60 + 20 * 60, lastWorkSeen: 45 * 60, standDown: .skipped)
        let paused = EngineState.quiet(QuietState(cause: .userPaused, resume: parked))
        guard case .quiet(let after) = paused.retargeted(from: 45 * 60, to: 30 * 60) else {
            Issue.record("expected .quiet"); return
        }
        let moved = try #require(after.resume)
        #expect(moved.armThreshold == TimeInterval(50 * 60))
        #expect(moved.standDown == .skipped)
    }

    @Test("a pause saved without a parked state still decodes")
    func olderEncodingDecodes() throws {
        let json = Data(#"{"cause":"userPaused","untilMono":3600}"#.utf8)
        let decoded = try JSONDecoder().decode(QuietState.self, from: json)
        #expect(decoded.resume == nil)
        #expect(decoded.cause == .userPaused)
    }
}
