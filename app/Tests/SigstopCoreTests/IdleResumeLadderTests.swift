import Foundation
import Testing

@testable import SigstopCore

struct IdleResumeLadderTests {

    private static func stepAway(_ session: inout EngineHarness.Session, seconds: TimeInterval) {
        session.driver.idleSeconds = 120
        session.step(times: Int(seconds / EngineHarness.Driver.tick))
        session.driver.idleSeconds = 0
    }

    private static func isIgnored(_ state: EngineState) -> Bool {
        if case .ignored = state { return true }
        return false
    }

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

        Self.stepUntilIgnored(&session)
        #expect(Self.isIgnored(session.driver.state), "the prompt must have been classified ignored")

        Self.stepAway(&session, seconds: 214)

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
