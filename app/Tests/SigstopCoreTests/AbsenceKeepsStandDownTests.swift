import Foundation
import Testing

@testable import SigstopCore

@Suite("two minutes away does not cancel a stand-down")
struct AbsenceKeepsStandDownTests {

    typealias Bench = TrackerEngineBench

    @Test("a skip stays quiet for its twenty minutes of work across a short absence")
    func skipSurvivesAnAbsence() throws {
        var bench = Bench()
        let prompt = bench.workUntilPrompt()
        _ = try #require(prompt)
        bench.tick(action: .skip)
        let skippedAt = bench.continuousWork
        bench.work(minutes: 1)
        bench.away(minutes: 2)
        bench.tick()

        let working = try #require(bench.working)
        #expect(working.standDown == .skipped)
        #expect(working.armThreshold == skippedAt + bench.policy.rearmAfterSkip)

        let reached = bench.workUntilOpen()
        let opened = try #require(reached)
        #expect(opened >= skippedAt + bench.policy.rearmAfterSkip,
                "asked again \((opened - skippedAt) / 60) min of work after the skip")
    }

    @Test("an exhausted ladder keeps its cooldown across a short absence")
    func cooldownSurvivesAnAbsence() throws {
        var bench = Bench()
        let prompt = bench.workUntilPrompt()
        _ = try #require(prompt)
        let exhausted = bench.workUntil(limitMinutes: 60) { Bench.closes($0).contains(.ignoredExhausted) }
        _ = try #require(exhausted)
        let cooldownFrom = bench.time.continuousSeconds

        bench.away(minutes: 2)
        bench.tick()
        let working = try #require(bench.working)
        #expect(working.standDown == .ladderExhausted)
        #expect(working.cooldownUntilMono == cooldownFrom + bench.policy.cooldownAfterExhausted)

        let reached = bench.workUntilOpen()
        _ = try #require(reached)
        let waited = bench.time.continuousSeconds - cooldownFrom
        #expect(waited >= bench.policy.cooldownAfterExhausted, "asked again after \(waited / 60) min")
    }

    @Test("a cycle that went stale keeps its re-arm across a short absence")
    func staleRearmSurvivesAnAbsence() throws {
        var bench = Bench()
        bench.mic = true
        bench.camera = true
        let expired = bench.workUntil(limitMinutes: 150) { Bench.closes($0).contains(.expired) }
        _ = try #require(expired)
        let expiredAt = bench.continuousWork
        bench.mic = false
        bench.camera = false

        bench.away(minutes: 2)
        bench.tick()
        let working = try #require(bench.working)
        #expect(working.standDown == .cycleExpired)

        let reached = bench.workUntilOpen()
        let opened = try #require(reached)
        #expect(opened >= expiredAt + bench.policy.rearmAfterStale,
                "asked again \((opened - expiredAt) / 60) min of work after it went stale")
    }

    @Test("a real break still clears the stand-down")
    func aBreakClearsIt() throws {
        var bench = Bench()
        let prompt = bench.workUntilPrompt()
        _ = try #require(prompt)
        bench.tick(action: .skip)
        bench.work(minutes: 1)
        bench.away(minutes: 6)
        bench.tick()

        let working = try #require(bench.working)
        #expect(working.standDown == nil)
        #expect(working.armThreshold == bench.policy.targetContinuousWork)
    }

    @Test("a silent call long enough to reset the clock clears it, as it resets the work")
    func longPauseClearsIt() throws {
        var bench = Bench()
        let prompt = bench.workUntilPrompt()
        _ = try #require(prompt)
        bench.tick(action: .skip)
        bench.mic = true
        bench.away(minutes: 21)
        bench.mic = false
        bench.tick()

        let working = try #require(bench.working)
        #expect(bench.events.contains(.clockReset(reason: .longPause)))
        #expect(working.standDown == nil)
        #expect(working.armThreshold == bench.policy.targetContinuousWork)
    }

    @Test("changing the work interval while away moves the parked threshold too")
    func retargetWhileAway() throws {
        let parked = WorkingState(armThreshold: 45 * 60 + 20 * 60, lastWorkSeen: 45 * 60, standDown: .skipped)
        let idle = EngineState.idle(
            IdleState(since: Date(timeIntervalSince1970: 0), cause: .microIdleExceeded, resume: parked)
        )
        guard case .idle(let after) = idle.retargeted(from: 45 * 60, to: 30 * 60) else {
            Issue.record("expected .idle"); return
        }
        let moved = try #require(after.resume)
        #expect(moved.armThreshold == TimeInterval(50 * 60))
        #expect(moved.standDown == .skipped)
    }
}
