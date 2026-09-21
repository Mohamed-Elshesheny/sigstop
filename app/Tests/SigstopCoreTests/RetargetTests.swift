import Foundation
import Testing

@testable import SigstopCore

/// Changing the work interval has to reach the state that is already running.
///
/// Reported: the owner set the interval to 45 in Settings and the panel went on counting
/// to `/ 5:00`. `armThreshold` is copied into `WorkingState` when it is built, and
/// `update(settings:)` rebuilt the policy and the engine while leaving the live state
/// alone — the same shape as the daily cap, where the cap was re-read and the state was
/// not.
struct RetargetTests {

    @Test("a plain working state moves onto the new interval")
    func plainThresholdMoves() {
        let before = EngineState.working(WorkingState(armThreshold: 5 * 60))
        guard case .working(let after) = before.retargeted(from: 5 * 60, to: 45 * 60) else {
            Issue.record("expected .working"); return
        }
        #expect(after.armThreshold == 45 * 60)
    }

    @Test("a stand-down keeps the silence it was promised")
    func standDownSurvives() {
        // A skip adds twenty minutes on top of the target.
        let deferred = EngineState.working(
            WorkingState(armThreshold: 5 * 60 + 20 * 60, standDown: .skipped)
        )
        guard case .working(let after) = deferred.retargeted(from: 5 * 60, to: 45 * 60) else {
            Issue.record("expected .working"); return
        }
        #expect(after.armThreshold == 45 * 60 + 20 * 60,
                "the extra twenty minutes must survive, got \(after.armThreshold / 60)m")
        #expect(after.standDown == .skipped)
    }

    @Test("lowering the interval lowers the threshold with it")
    func loweringWorks() {
        let before = EngineState.working(WorkingState(armThreshold: 45 * 60))
        guard case .working(let after) = before.retargeted(from: 45 * 60, to: 5 * 60) else {
            Issue.record("expected .working"); return
        }
        #expect(after.armThreshold == 5 * 60)
    }

    @Test("it never goes negative, and it leaves every other state alone")
    func edgesAreSafe() {
        let tiny = EngineState.working(WorkingState(armThreshold: 60))
        guard case .working(let after) = tiny.retargeted(from: 45 * 60, to: 5 * 60) else {
            Issue.record("expected .working"); return
        }
        #expect(after.armThreshold == 0, "clamped, not negative")

        // Nothing else carries a threshold: each rebuilds one from the current policy.
        let others: [EngineState] = [
            .quiet(QuietState(cause: .dailyCapReached)),
            .idle(IdleState(since: Date(timeIntervalSince1970: 0), cause: .microIdleExceeded)),
            .breakDue(BreakDue(cycle: CycleID.initial, dueSince: Date(timeIntervalSince1970: 0), lastStepMono: 0)),
        ]
        for state in others {
            #expect(state.retargeted(from: 5 * 60, to: 45 * 60) == state, "\(state.name) must be untouched")
        }
    }

    @Test("no change is a no-op")
    func noChangeIsNoOp() {
        let s = EngineState.working(WorkingState(armThreshold: 5 * 60, standDown: .skipped))
        #expect(s.retargeted(from: 5 * 60, to: 5 * 60) == s)
    }
}
