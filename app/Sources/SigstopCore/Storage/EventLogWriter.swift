import Foundation

/// What the app layer knows about a prompt and the engine does not.
///
/// Exactly one fact, and it exists for exactly one reason: a prompt the window server
/// never confirmed is not something a user can have ignored, so `.recordIgnoredPrompt`
/// must not be written as if they had. Passing it in keeps that judgement out of the
/// mapping and still lets the mapping stay a pure function.
public struct EffectLogContext: Sendable, Hashable {
    /// The cycle whose prompt the window server confirmed was on screen, if any.
    public var confirmedPromptCycle: CycleID?

    public init(confirmedPromptCycle: CycleID? = nil) {
        self.confirmedPromptCycle = confirmedPromptCycle
    }
}

/// The one place that decides what each `Effect` leaves behind in the event log.
///
/// This switch used to live in `AppModel.execute`, inside `SigstopApp`. That target has
/// no tests and cannot have any: there is no Xcode here, so there is no window server in
/// CI, and a test that needs one never runs. The defect that produced the 20:06:51Z
/// incident was therefore untestable in principle, in the one file where an unlogged
/// transition means a user decision vanishes.
///
/// It is pure, and the switch is exhaustive with no `default`. A fifteenth `Effect` stops
/// this file compiling until somebody states, in one place, what it writes.
///
/// Two effects deliberately write nothing, and say so rather than falling through:
///
///   * `.deliverPrompt` — `break_prompt` means "this reached the screen", and only the
///     app can know that. It is appended by `verifyPromptPresentation()` once the window
///     server confirms the panel's own window number.
///   * `.recordVerdict` — the verdict is computed on every tick and is the same value for
///     minutes at a time. Writing it here would add thousands of identical lines a day.
///     `VerdictLedger` writes it on transition instead.
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

        case .endBreak(let cycle, let origin, _, let elapsed):
            return [
                .breakEnd(
                    at: now, origin: origin,
                    durationSeconds: Int(max(0, elapsed).rounded()), cycle: cycle
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

        case .resumeWorkClock:
            return []
        }
    }
}
