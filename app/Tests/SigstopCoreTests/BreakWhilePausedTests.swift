import Foundation
import Testing

@testable import SigstopCore

@Suite("a break taken while quiet goes back to being quiet")
struct BreakWhilePausedTests {

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        return c
    }()

    private static func ended(_ effects: [Effect]) -> Bool {
        effects.contains { if case .endBreak = $0 { return true } else { return false } }
    }

    private static func indicators(_ effects: [Effect]) -> [IndicatorState] {
        effects.compactMap { if case .setIndicator(let s) = $0 { return s } else { return nil } }
    }

    private static func quiet(_ state: EngineState) -> QuietState? {
        if case .quiet(let q) = state { return q } else { return nil }
    }

    private static func runBreakOut(_ driver: inout EngineHarness.Driver) -> [Effect] {
        driver.step(untilLimit: 200) { ended($0) }
    }

    @Test("pause for an hour, take a break, and the pause is still there with its own end")
    func pauseSurvivesABreak() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        driver.step()
        driver.step(action: .pauseApp(3600))
        guard let paused = Self.quiet(driver.state) else {
            Issue.record("the pause did not take: \(driver.state)")
            return
        }
        driver.step()

        driver.step(action: .startBreakNow)
        guard case .breakActive = driver.state else {
            Issue.record("the break did not start: \(driver.state)")
            return
        }

        let ending = Self.runBreakOut(&driver)
        #expect(Self.ended(ending))
        #expect(Self.quiet(driver.state) == paused, "after the break the engine is \(driver.state)")
        #expect(Self.indicators(ending).last == .quiet)
        #expect(!ending.contains { if case .openCycle = $0 { return true } else { return false } })

        for _ in 0..<60 { driver.step() }
        #expect(Self.quiet(driver.state) == paused, "prompts came back before the hour: \(driver.state)")
    }

    @Test("SIGCONT early from a paused break goes back to the pause too")
    func endingEarlyKeepsThePause() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        driver.step(action: .pauseApp(3600))
        let paused = Self.quiet(driver.state)
        driver.step(action: .startBreakNow)
        driver.step()
        let ending = driver.step(action: .endBreak)
        #expect(Self.ended(ending))
        #expect(Self.quiet(driver.state) == paused)
    }

    @Test("a pause that runs out during the break ends with it")
    func expiredPauseReturnsToWork() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        driver.step(action: .pauseApp(120))
        driver.step(action: .startBreakNow)
        let ending = Self.runBreakOut(&driver)
        #expect(Self.ended(ending))
        #expect(driver.state.isWorking, "a pause that already ended came back: \(driver.state)")
        #expect(Self.indicators(ending).last == .working)
    }

    @Test("pausing during a paused break replaces the pause, as it always did")
    func pausingAgainReplacesIt() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        driver.step(action: .pauseApp(3600))
        driver.step(action: .startBreakNow)
        driver.step()
        let produced = driver.step(action: .pauseApp(600))
        #expect(Self.ended(produced))
        #expect(Self.quiet(driver.state)?.until == driver.now.addingTimeInterval(600))
    }

    @Test("a break inside quiet hours goes back to quiet hours while the window is open")
    func quietHoursSurviveABreak() {
        var settings = EngineHarness.ownerSettings
        settings.quietHours = QuietHours(startMinute: 22 * 60, endMinute: 23 * 60, enabled: true)
        var driver = EngineHarness.Driver(settings: settings)
        driver.calendarSystem = Self.utc
        for _ in 0..<200 where Self.quiet(driver.state) == nil { driver.step() }
        #expect(Self.quiet(driver.state)?.cause == .scheduledQuietHours)

        driver.step(action: .startBreakNow)
        let ending = Self.runBreakOut(&driver)
        #expect(Self.ended(ending))
        #expect(Self.quiet(driver.state)?.cause == .scheduledQuietHours, "\(driver.state)")
        #expect(Self.indicators(ending).last == .quiet)
    }

    @Test("a break that outlasts the quiet window comes back to work")
    func quietHoursThatEndDuringTheBreak() {
        var settings = EngineHarness.ownerSettings
        settings.quietHours = QuietHours(startMinute: 22 * 60, endMinute: 22 * 60 + 20, enabled: true)
        var driver = EngineHarness.Driver(settings: settings)
        driver.calendarSystem = Self.utc
        for _ in 0..<200 where Self.quiet(driver.state) == nil { driver.step() }
        #expect(Self.quiet(driver.state)?.cause == .scheduledQuietHours)

        driver.step(action: .startBreakNow)
        let ending = Self.runBreakOut(&driver)
        #expect(Self.ended(ending))
        #expect(driver.state.isWorking, "\(driver.state)")
    }

    @Test("a break after the daily cap goes back to the cap, and a new day ends it")
    func dailyCapSurvivesABreakUntilTheBoundary() {
        for (start, expectQuiet) in [(1_700_000_000.0, true), (1_700_020_200.0, false)] {
            var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings, start: Date(timeIntervalSince1970: start))
            driver.calendarSystem = Self.utc
            let policy = driver.engine.policy
            driver.day.dayIndex = LocalDay.index(of: driver.now, calendar: Self.utc, boundaryHour: policy.dayBoundaryHour)
            driver.day.notificationsDelivered = policy.dailyNotificationCap
            for _ in 0..<200 where Self.quiet(driver.state) == nil { driver.step() }
            #expect(Self.quiet(driver.state)?.cause == .dailyCapReached)

            driver.step(action: .startBreakNow)
            let ending = Self.runBreakOut(&driver)
            #expect(Self.ended(ending))
            if expectQuiet {
                #expect(Self.quiet(driver.state)?.cause == .dailyCapReached, "\(driver.state)")
            } else {
                #expect(driver.state.isWorking, "the cap outlived the day boundary: \(driver.state)")
            }
        }
    }

    @Test("a break the tracker infers while paused, a locked screen say, leaves the pause alone")
    func inferredBreakKeepsThePause() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        driver.day.consecutiveIgnoredCycles = 2
        driver.step(action: .pauseApp(3600))
        let paused = Self.quiet(driver.state)
        for _ in 0..<70 { driver.step() }

        driver.sessionEvents = [.breakRecorded(
            origin: .idleInferred,
            start: driver.now.addingTimeInterval(-330),
            end: driver.now,
            duration: 330
        )]
        let produced = driver.step()
        #expect(Self.quiet(driver.state) == paused, "the locked screen ended the pause: \(driver.state)")
        #expect(Self.indicators(produced) == [.quiet])
        #expect(driver.day.consecutiveIgnoredCycles == 0, "a qualifying break still resets the backoff")
    }

    @Test("an inferred break after the pause has run out goes back to work, as before")
    func inferredBreakAfterThePause() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        driver.step(action: .pauseApp(60))
        for _ in 0..<11 { driver.step() }
        driver.sessionEvents = [.breakRecorded(
            origin: .idleInferred, start: driver.now.addingTimeInterval(-330), end: driver.now, duration: 330
        )]
        driver.step()
        #expect(driver.state.isWorking, "\(driver.state)")
    }

    @Test("a break encoded before quietBefore existed still decodes")
    func olderEncodingDecodes() throws {
        let active = BreakActive(
            cycle: nil, startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            plannedEnd: Date(timeIntervalSince1970: 1_700_000_300), startedMono: 12,
            plannedDuration: 300, origin: .userInitiated,
            quietBefore: QuietState(until: Date(timeIntervalSince1970: 1_700_003_600), untilMono: 3612, cause: .userPaused)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(EngineState.breakActive(active))
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(text.contains("quietBefore"))

        let older = try #require(
            text.replacingOccurrences(
                of: #""quietBefore":\{[^}]*\},"#, with: "", options: .regularExpression
            ).data(using: .utf8)
        )
        let decoded = try JSONDecoder().decode(EngineState.self, from: older)
        var expected = active
        expected.quietBefore = nil
        #expect(decoded == .breakActive(expected), "\(String(decoding: older, as: UTF8.self))")
    }

    @Test("a break from working still ends in working")
    func breakFromWorkIsUnchanged() {
        var driver = EngineHarness.Driver(settings: EngineHarness.ownerSettings)
        driver.step()
        driver.step(action: .startBreakNow)
        let ending = Self.runBreakOut(&driver)
        #expect(Self.ended(ending))
        #expect(driver.state.isWorking)
    }
}
