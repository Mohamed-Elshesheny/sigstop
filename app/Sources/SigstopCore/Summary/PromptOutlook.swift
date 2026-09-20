import Foundation

/// The answer to "why has it not prompted me", read off the event log.
///
/// This exists because the owner could not get that answer any other way. The panel said
/// RUNNING, the log had two lines and then nothing, and the real reason, that a dismissed
/// prompt had re-armed the engine twenty minutes late, was recoverable only by noticing
/// that 1205 seconds is exactly `rearmAfterSkip` minus the work interval.
///
/// Pure, so it runs in `--doctor` without a window server and can be unit tested against
/// a literal array of events.
public struct PromptOutlook: Sendable, Hashable {
    /// One sentence a person can read out loud.
    public let headline: String
    /// The supporting facts, each one traceable to a line in the file.
    public let detail: [String]

    public init(headline: String, detail: [String] = []) {
        self.headline = headline
        self.detail = detail
    }

    /// Reads the outlook from a day's events.
    ///
    /// The events are sorted first rather than trusted in file order: `idle_begin` is
    /// backdated to when the idle period actually started, so a log can and does contain
    /// lines out of order, and a reader that assumes otherwise reports the wrong last
    /// event.
    public static func read(
        events: [LoggedEvent],
        now: Date,
        policy: BreakPolicy = .default,
        calendar: Calendar = .current
    ) -> PromptOutlook {
        let sorted = events.sorted { $0.at < $1.at }
        guard !sorted.isEmpty else {
            return PromptOutlook(headline: "Nothing has been recorded today, so there is nothing to explain.")
        }

        func clock(_ date: Date) -> String {
            let c = calendar.dateComponents([.hour, .minute, .second], from: date)
            return "\(Pad.two(c.hour ?? 0)):\(Pad.two(c.minute ?? 0)):\(Pad.two(c.second ?? 0))"
        }
        func last(_ kinds: Set<EventKind>) -> LoggedEvent? {
            sorted.last { kinds.contains($0.kind) }
        }

        if let lifecycle = last([.start, .stop]), lifecycle.kind == .stop {
            return PromptOutlook(
                headline: "The app is not running. It stopped at \(clock(lifecycle.at)).",
                detail: ["Nothing is measured and nothing is prompted while it is stopped."]
            )
        }

        let opened = last([.breakOpen])
        let closed = last([.cycleClose])
        let cycleIsOpen = opened != nil && (closed == nil || closed!.at < opened!.at)

        if let opened, cycleIsOpen {
            var detail = ["A break opportunity opened at \(clock(opened.at)) and has not closed."]
            if let prompt = sorted.last(where: { $0.kind == .breakPrompt }), prompt.at >= opened.at {
                detail.append("The prompt reached the screen at \(clock(prompt.at)).")
            } else {
                detail.append("No prompt has reached the screen for it yet.")
            }
            if let gate = sorted.last(where: { $0.kind == .gate }), let reason = gate.gate {
                detail.append(
                    reason == .delivered
                        ? "As of \(clock(gate.at)) nothing was holding a prompt."
                        : "As of \(clock(gate.at)) it was holding off: \(reason.summary)."
                )
            }
            return PromptOutlook(headline: "A break is due right now.", detail: detail)
        }

        guard let closed, let outcome = closed.outcome else {
            if opened != nil {
                return PromptOutlook(
                    headline: "The last break opportunity left no record of how it ended.",
                    detail: [
                        "That is this log predating the cycle_close event, not a live problem.",
                        "The next opportunity to open will say how it closes.",
                    ]
                )
            }
            return PromptOutlook(
                headline: "No break opportunity has opened yet today.",
                detail: ["A cycle opens after \(DurationText.long(policy.targetContinuousWork)) of continuous active work."]
            )
        }

        let at = clock(closed.at)
        switch outcome {
        case .skipped:
            let target = policy.targetContinuousWork + policy.rearmAfterSkip
            return PromptOutlook(
                headline: "You waved the last one off at \(at), and a skip re-arms late on purpose.",
                detail: [
                    "The engine is waiting for about \(DurationText.long(target)) of continuous"
                        + " work instead of the usual \(DurationText.long(policy.targetContinuousWork)).",
                    "That is \(DurationText.long(policy.rearmAfterSkip)) of extra work, measured"
                        + " from where the clock stood when you skipped, not from the clock.",
                    "Walking away long enough to count as a break resets it immediately.",
                ]
            )
        case .ignoredExhausted:
            return PromptOutlook(
                headline: "The last ladder ran out of rungs at \(at).",
                detail: [
                    "Nothing new opens for \(DurationText.long(policy.cooldownAfterExhausted)) after that.",
                    "The app stops asking when four escalations go unanswered. It is not stuck.",
                ]
            )
        case .expired:
            let target = policy.targetContinuousWork + policy.rearmAfterStale
            return PromptOutlook(
                headline: "The last opportunity went stale at \(at) and was abandoned.",
                detail: [
                    "A break that is an hour overdue is noise, so it is dropped rather than fired late.",
                    "The next one needs about \(DurationText.long(target)) of continuous work.",
                ]
            )
        case .quietSuppressed:
            return PromptOutlook(
                headline: "The last opportunity was suppressed at \(at), inside quiet hours or a pause.",
                detail: ["It is excluded from compliance: you cannot miss a prompt that was never delivered."]
            )
        case .dailyCapReached:
            return PromptOutlook(
                headline: "Today's notification budget was spent at \(at).",
                detail: ["Passive only from here. The budget is Settings, notifications per day."]
            )
        case .honored:
            return PromptOutlook(
                headline: "You took the last one at \(at), so the clock started again there.",
                detail: [
                    "The next opportunity needs \(DurationText.long(policy.targetContinuousWork))"
                        + " of continuous active work.",
                    "There is also a \(DurationText.long(policy.settleInAfterBreak)) settle-in"
                        + " window after a break in which nothing is delivered.",
                ]
            )
        }
    }
}
