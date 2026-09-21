import Foundation
import Testing

@testable import SigstopCore

/// Stepping away mid-escalation must not put the ladder back at the bottom.
///
/// Reconstructed from a real session on the owner's machine, 2026-09-21. Cycle 14 was
/// prompted at SIGTSTP, ignored at 14:35:20, and re-prompted at 14:38:54 — at SIGTSTP
/// again, 214 seconds later, instead of escalating to SIGINT. Cycle 10 earlier the same
/// day had climbed SIGTSTP → SIGINT → SIGTERM correctly.
///
/// The difference was a gap in the band between `microIdleGrace` (90s) and
/// `qualifyingBreak` (300s): too long to ignore, too short to be a break. It suspended
/// the cycle into `.idle`, and `IdleState` carried only the cycle id, so the resume built
/// a virgin `BreakDue` and every prompt after it started again at rung one — spending
/// another unit of a 14-a-day budget each time round.
struct IdleResumeLadderTests {

    /// Walk the driver away for `seconds`, then bring it back.
    private static func stepAway(_ session: inout EngineHarness.Session, seconds: TimeInterval) {
        session.driver.idleSeconds = 120
        session.step(times: Int(seconds / EngineHarness.Driver.tick))
        session.driver.idleSeconds = 0
    }

    private static func isIgnored(_ state: EngineState) -> Bool {
        if case .ignored = state { return true }
        return false
    }

    /// Step until the engine has classified the standing prompt as ignored.
    ///
    /// Written as a plain loop rather than `step(untilLimit:)`: that takes `session`
    /// inout, so a predicate that reads `session.driver.state` is an overlapping access.
    private static func stepUntilIgnored(_ session: inout EngineHarness.Session, limit: Int = 200) {
        for _ in 0..<limit {
            session.step()
            if isIgnored(session.driver.state) { return }
        }
    }

    private static func prompts(_ session: EngineHarness.Session) -> [String] {
        session.log.lines.filter { $0.kind == .breakPrompt }.compactMap(\.reason).map(\.rawValue)
    }

    @Test("a gap too short to be a break does not reset the escalation ladder")
    func shortGapKeepsTheLadder() {
        var session = EngineHarness.Session()
        session.stepToPrompt()
        #expect(Self.prompts(session) == ["SIGTSTP"], "the ladder starts at rung one")

        // Ignore it: say nothing until the engine classifies the prompt as ignored.
        Self.stepUntilIgnored(&session)
        #expect(Self.isIgnored(session.driver.state), "the prompt must have been classified ignored")

        // 214 seconds away, the exact gap from the logged session.
        Self.stepAway(&session, seconds: 214)

        // The next prompt must be the NEXT rung.
        session.step(untilLimit: 400) { effects in
            effects.contains { if case .deliverPrompt = $0 { return true } else { return false } }
        }

        let seen = Self.prompts(session)
        #expect(seen.count >= 2, "a second prompt must arrive after the gap, got \(seen)")
        #expect(seen.last == "SIGINT", "after a sub-qualifying gap the ladder must continue, got \(seen)")
        #expect(!seen.dropFirst().contains("SIGTSTP"), "rung one must never be re-sent inside one cycle, got \(seen)")
    }

    @Test("the gap ages the opportunity but is not credited to the ladder")
    func gapAgesTheOpportunityOnly() {
        var session = EngineHarness.Session()
        session.stepToPrompt()
        Self.stepUntilIgnored(&session)

        guard case .ignored(let before) = session.driver.state else {
            Issue.record("expected .ignored, got \(session.driver.state)")
            return
        }
        Self.stepAway(&session, seconds: 214)
        session.step()

        guard case .ignored(let after) = session.driver.state else {
            Issue.record("the cycle must resume as .ignored, got \(session.driver.state)")
            return
        }
        #expect(after.cycle == before.cycle, "it must be the same opportunity, not a new one")
        #expect(after.level == before.level, "the rung must survive the gap")
        #expect(after.deliveredLevels == before.deliveredLevels, "what was already sent must survive")
        #expect(after.totalElapsed >= before.totalElapsed + 200,
                "time away still ages the opportunity toward the stale ceiling")
        #expect(after.ladderElapsed < before.ladderElapsed + 30,
                "time away must not count as time spent ignoring a prompt")
    }
}
