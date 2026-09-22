import Foundation

public struct EffectLogContext: Sendable, Hashable {
    public var confirmedPromptCycle: CycleID?

    public init(confirmedPromptCycle: CycleID? = nil) {
        self.confirmedPromptCycle = confirmedPromptCycle
    }
}

public enum EventLogWriter {

    public static func lines(
        for effect: Effect,
        at now: Date,
        context: EffectLogContext = EffectLogContext()
    ) -> [LoggedEvent] {
        switch effect {
        case .openCycle(let cycle):
            return [.breakOpen(at: now, cycle: cycle)]

        case .closeCycle(let cycle, let outcome):
            return [.cycleClose(at: now, cycle: cycle, outcome: outcome)]

        case .deliverPrompt:
            return []

        case .withdrawPrompt:
            return []

        case .setIndicator:
            return []

        case .beginBreak(let cycle, let origin, _):
            var out: [LoggedEvent] = [.breakBegin(at: now, origin: origin, cycle: cycle)]
            if let cycle { out.append(.breakResponse(at: now, cycle: cycle, action: .taken)) }
            return out

        case .endBreak(let cycle, let origin, _, let elapsed, let threshold):
            return [
                .breakEnd(
                    at: now, origin: origin,
                    durationSeconds: Int(max(0, elapsed).rounded()),
                    thresholdSeconds: Int(max(0, threshold).rounded()),
                    cycle: cycle
                )
            ]

        case .scheduleWake, .cancelScheduledWake:
            return []

        case .recordVerdict:
            return []

        case .recordSkip(let cycle):
            return [.breakResponse(at: now, cycle: cycle, action: .skipped)]

        case .recordIgnoredPrompt(let cycle):
            guard context.confirmedPromptCycle == cycle else { return [] }
            return [.breakResponse(at: now, cycle: cycle, action: .ignored)]

        case .recordSnooze(let cycle, let duration):
            return [
                .breakResponse(
                    at: now, cycle: cycle, action: .snoozed,
                    snoozeSeconds: Int(max(0, duration).rounded())
                )
            ]
        }
    }
}
