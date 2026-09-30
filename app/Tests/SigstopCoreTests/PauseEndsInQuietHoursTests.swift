import Foundation
import Testing

@testable import SigstopCore

@Suite("a pause that runs out inside quiet hours ends there")
struct PauseEndsInQuietHoursTests {

    @Test("an hour's pause from 21:31 is quiet hours at 23:01, not a pause that ended at 22:31")
    func pauseHandsOverToQuietHours() throws {
        let calendar = CalendarDay.utcCalendar
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 21, minute: 30)))
        var settings = TrackerEngineBench.settings
        settings.quietHours = QuietHours(startMinute: 22 * 60, endMinute: 8 * 60, enabled: true)
        var bench = TrackerEngineBench(settings: settings, start: start)

        bench.work(minutes: 1)
        bench.tick(action: .pauseApp(3600))
        guard case .quiet(let paused) = bench.state, paused.cause == .userPaused else {
            Issue.record("expected a pause, got \(bench.state.name)"); return
        }

        bench.work(minutes: 90)
        guard case .quiet(let quiet) = bench.state else {
            Issue.record("expected quiet hours, got \(bench.state.name)"); return
        }
        #expect(quiet.cause == .scheduledQuietHours, "still reads as a pause that ended at 22:31")
        #expect(quiet.until == nil)
        #expect(quiet.untilMono == nil)
    }

    @Test("a pause that outlasts the start of quiet hours is still a pause until its own end")
    func longerPauseHolds() throws {
        let calendar = CalendarDay.utcCalendar
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 21, minute: 30)))
        var settings = TrackerEngineBench.settings
        settings.quietHours = QuietHours(startMinute: 22 * 60, endMinute: 8 * 60, enabled: true)
        var bench = TrackerEngineBench(settings: settings, start: start)

        bench.work(minutes: 1)
        bench.tick(action: .pauseApp(3 * 3600))
        bench.work(minutes: 90)
        guard case .quiet(let quiet) = bench.state else {
            Issue.record("expected the pause, got \(bench.state.name)"); return
        }
        #expect(quiet.cause == .userPaused)
    }
}
