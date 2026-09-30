import Foundation
import Testing

@testable import SigstopCore

@Suite("a session that ends takes its open cycle with it")
struct SessionEndClosesCycleTests {

    typealias Bench = TrackerEngineBench

    @Test("forty minutes asleep with a prompt up is not an ignored prompt, and the new session starts clean")
    func sleepWithAPromptUp() throws {
        var bench = Bench()
        let step1 = bench.workUntilPrompt()
        _ = try #require(step1)

        let wake = bench.sleep(for: 40 * 60)
        #expect(Bench.ignoredPrompts(wake) == 0, "the lid was shut, nobody ignored anything")
        #expect(Bench.closes(wake) == [.expired])

        let after = bench.work(minutes: 40)
        #expect(Bench.prompts(after).isEmpty, "the new session asked before it had done any work")
        #expect(Bench.ignoredPrompts(after) == 0)
        #expect(bench.tracker.sessionCount == 2)

        let reached = bench.workUntilOpen()

        let opened = try #require(reached)
        #expect(opened >= bench.policy.targetContinuousWork, "opened at \(opened / 60) min of work")
    }

    @Test("waking locked after forty minutes, then unlocking, delivers nothing at zero work")
    func lockedWake() throws {
        var bench = Bench()
        let step2 = bench.workUntilPrompt()
        _ = try #require(step2)

        var produced = bench.sleep(for: 40 * 60, wakeIdle: 0, locked: true)
        for _ in 0..<12 { produced += bench.tick(locked: true) }
        #expect(Bench.closes(produced) == [.expired])

        produced = bench.work(minutes: 40)
        #expect(Bench.prompts(produced).isEmpty, "got \(Bench.prompts(produced).map(\.signal))")
        #expect(bench.state.openCycle == nil)
    }

    @Test("two hours asleep leaves a fresh working state, not a stale re-arm")
    func twoHourSleep() throws {
        var bench = Bench()
        let step3 = bench.workUntilPrompt()
        _ = try #require(step3)

        bench.sleep(for: 2 * 3600)
        bench.work(minutes: 1)
        let working = try #require(bench.working)
        #expect(working.standDown == nil)
        #expect(working.cooldownUntilMono == nil)
        #expect(working.armThreshold == bench.policy.targetContinuousWork)

        let reached = bench.workUntilOpen()

        let opened = try #require(reached)
        #expect(opened >= bench.policy.targetContinuousWork, "opened at \(opened / 60) min of work")
    }

    @Test("a ladder left at SIGTSTP does not wake up at SIGSTOP")
    func ignoredLadderSleeps() throws {
        var bench = Bench()
        let step4 = bench.workUntilPrompt()
        _ = try #require(step4)
        let step5 = bench.workUntil(limitMinutes: 5) { Bench.ignoredPrompts($0) > 0 }
        _ = try #require(step5)
        guard case .ignored = bench.state else {
            Issue.record("expected the ladder to be running, got \(bench.state.name)"); return
        }

        var produced = bench.sleep(for: 35 * 60)
        produced += bench.work(minutes: 30)
        #expect(Bench.prompts(produced).isEmpty, "got \(Bench.prompts(produced).map(\.signal))")
        #expect(Bench.closes(produced) == [.expired])
    }

    @Test("the 04:00 boundary closes a cycle that is still open and asks nothing at zero work")
    func dayBoundaryWithABreakDue() throws {
        let calendar = CalendarDay.utcCalendar
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 2, minute: 50)))
        let four = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 4)))
        var bench = Bench(start: start)
        let step6 = bench.workUntilPrompt()
        _ = try #require(step6)

        while bench.time.now.addingTimeInterval(Bench.tick) < four { bench.tick() }
        #expect(bench.state.openCycle != nil, "the test needs a cycle open at the boundary, got \(bench.state.name)")

        var produced = bench.tick()
        #expect(Bench.closes(produced) == [.expired])
        produced += bench.work(minutes: 40)
        #expect(Bench.prompts(produced).isEmpty, "got \(Bench.prompts(produced).map(\.signal))")
        #expect(bench.state.openCycle == nil)
    }

    @Test("a pause that is still running when the session ends is left alone")
    func pauseSurvivesTheSessionEnd() throws {
        var bench = Bench()
        bench.work(minutes: 5)
        bench.tick(action: .pauseApp(3 * 3600))
        bench.sleep(for: 40 * 60)
        bench.work(minutes: 1)
        guard case .quiet(let quiet) = bench.state else {
            Issue.record("expected the pause to hold, got \(bench.state.name)"); return
        }
        #expect(quiet.cause == .userPaused)
    }
}
