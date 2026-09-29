import Foundation

public enum BreakEnding {
    public static func ranOut(
        _ effects: [Effect],
        userAction: UserAction?,
        from state: EngineState,
        monotonic: Double,
        policy: BreakPolicy
    ) -> Bool {
        guard userAction == nil else { return false }
        guard case .breakActive(let active) = state else { return false }
        guard effects.contains(where: { if case .endBreak = $0 { return true } else { return false } })
        else { return false }
        let late = monotonic - active.startedMono - active.plannedDuration
        return late <= policy.tickInterval + policy.tickTolerance
    }
}
