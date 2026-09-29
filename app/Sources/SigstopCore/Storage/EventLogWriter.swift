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

public struct SessionLogLedger: Sendable, Hashable {
    public private(set) var inferredBreakBeganAt: Date?

    public init() {}

    public mutating func lines(
        for event: SessionEvent, at now: Date, qualifyingBreak: TimeInterval
    ) -> [LoggedEvent] {
        switch event {
        case .clockResumed:
            guard let began = inferredBreakBeganAt else { return [] }
            inferredBreakBeganAt = nil
            return [Self.inferredBreakEnd(from: began, at: now, threshold: qualifyingBreak)]

        case .breakRecorded(let origin, let start, _, _):
            guard origin == .idleInferred, inferredBreakBeganAt == nil else { return [] }
            inferredBreakBeganAt = start
            return [.breakBegin(at: start, origin: .idleInferred)]

        case .sessionStarted(_, let at):
            return [.start(at: at)]

        case .sessionEnded(_, let at):
            idleBeganAt = nil
            var out: [LoggedEvent] = [.stop(at: at)]
            if let began = inferredBreakBeganAt {
                inferredBreakBeganAt = nil
                out.append(Self.inferredBreakEnd(from: began, at: now, threshold: qualifyingBreak))
            }
            return out

        case .clockPaused, .gapClassified, .clockReset, .graceRevoked, .wallClockSkewIgnored:
            return []
        }
    }

    private static func inferredBreakEnd(
        from start: Date, at end: Date, threshold: TimeInterval
    ) -> LoggedEvent {
        .breakEnd(
            at: end, origin: .idleInferred,
            durationSeconds: Int(max(0, end.timeIntervalSince(start)).rounded()),
            thresholdSeconds: Int(max(0, threshold).rounded())
        )
    }
}
