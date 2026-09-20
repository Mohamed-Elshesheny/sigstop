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
            return openCycle(opened, in: sorted, now: now, policy: policy, clock: clock)
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

    /// How long an open cycle may go without a line before the file is evidence that the
    /// app stopped rather than evidence about now.
    ///
    /// `VerdictLedger` writes at least once per `heartbeat` for as long as a cycle is
    /// open, whatever state holds it, so a longer gap than that cannot happen while the
    /// app is running. One tick of slack for a heartbeat that landed late.
    static let silenceCeiling: TimeInterval = VerdictLedger.defaultHeartbeat + 60

    /// A cycle that is open in the file, which is a claim about *now* and therefore has to
    /// be bounded by what the file can actually support.
    ///
    /// This said "A break is due right now" for any unclosed `break_open`, no matter how
    /// old, and no matter what the user had already done about it. On the log it was
    /// designed from it was wrong three ways at once: a `start` had orphaned the cycle, a
    /// `break_response` had answered it, and the newest line was a day old.
    /// Consecutive opportunities closed `ignoredExhausted` since the last one that was
    /// honored. The engine's own `consecutiveIgnoredCycles`, recovered from the file,
    /// because a separate process cannot read the running counter.
    private static func ignoredRun(in sorted: [LoggedEvent]) -> Int {
        sorted.reduce(into: 0) { run, event in
            guard event.kind == .cycleClose, let outcome = event.outcome else { return }
            switch outcome {
            case .ignoredExhausted: run += 1
            case .honored:          run = 0
            case .skipped, .expired, .quietSuppressed, .dailyCapReached: break
            }
        }
    }

    private static func openCycle(
        _ opened: LoggedEvent,
        in sorted: [LoggedEvent],
        now: Date,
        policy: BreakPolicy,
        clock: (Date) -> String
    ) -> PromptOutlook {
        // Engine state is deliberately not persisted, so a relaunch forgets an open cycle.
        // A `start` after the open is therefore the end of it, and the only record there
        // will ever be of the end of it.
        if let restart = sorted.last(where: { $0.kind == .start }), restart.at > opened.at {
            return PromptOutlook(
                headline: "The break opportunity from \(clock(opened.at)) was dropped by a restart"
                    + " at \(clock(restart.at)).",
                detail: [
                    "Engine state is not kept across launches on purpose, so a restart forgets"
                        + " an open cycle rather than resuming a stale one.",
                    "The work clock starts again from there. Nothing was recorded against you.",
                ]
            )
        }

        // Everything below this line except the two past-tense answers is a claim about
        // now, and a claim about now needs a live file under it. An open cycle writes at
        // least one line per heartbeat for as long as it is open, whatever state holds it,
        // so a longer gap than that is the process being gone: a rebuild, a crash, a quit
        // that never reached its `stop`.
        let stopped: Bool = sorted.last.map {
            now.timeIntervalSince($0.at) > silenceCeiling
        } ?? false

        // What the user already did about it. The answer is in the file; not reading it is
        // what let the reader tell somebody who had just pressed SIGALRM that a break was
        // due right now and nothing was holding it.
        let response = sorted.last { $0.kind == .breakResponse && $0.at >= opened.at }
        if let response, let action = response.action {
            switch action {
            case .snoozed:
                let seconds = TimeInterval(response.snoozeSeconds ?? 0)
                let returns = response.at.addingTimeInterval(seconds)
                if seconds > 0, returns > now, !stopped {
                    return PromptOutlook(
                        headline: "You snoozed it at \(clock(response.at)). It comes back at"
                            + " \(clock(returns)).",
                        detail: [
                            "SIGALRM defers the question. The work clock keeps running, so a"
                                + " snooze buys quiet, never credit.",
                            "The opportunity from \(clock(opened.at)) is still open underneath it.",
                        ]
                    )
                }
            case .ignored where !stopped:
                let rung = sorted.last {
                    $0.kind == .breakPrompt && $0.at >= opened.at && $0.reason != nil
                }?.reason
                let named = rung.map { " The last rung delivered was \($0.rawValue)." } ?? ""
                /// Both of the sentences below are false once the backoff has capped the
                /// ladder: nothing further can be delivered in this cycle, so it is not
                /// climbing and four escalations are not coming. Saying so anyway is
                /// exactly the confident wrong claim CLAUDE.md §4.1 forbids, in the one
                /// file written to answer "why has it not prompted me".
                if ignoredRun(in: sorted) >= policy.ignoreBackoffThreshold {
                    return PromptOutlook(
                        headline: "The prompt from \(clock(opened.at)) went unanswered.\(named)",
                        detail: [
                            "Enough opportunities have gone unanswered in a row that each one"
                                + " now gets a single prompt, so nothing further is coming for"
                                + " this one and it closes on its own.",
                            "Taking a break clears that and the full ladder comes back.",
                        ]
                    )
                }
                return PromptOutlook(
                    headline: "The prompt from \(clock(opened.at)) went unanswered, so the ladder"
                        + " is climbing.\(named)",
                    detail: [
                        "Each rung is louder than the last and the ladder ends by itself; four"
                            + " unanswered escalations close the opportunity.",
                        "Answering any of them, including waving it off, stops it now.",
                    ]
                )
            case .taken:
                if let ended = sorted.last(where: { $0.kind == .breakEnd && $0.at >= response.at }) {
                    return PromptOutlook(
                        headline: "You took the last one at \(clock(response.at)) and it ended at"
                            + " \(clock(ended.at)).",
                        detail: [
                            "The opportunity itself was never marked closed, which is this log"
                                + " predating the cycle_close event rather than a live problem.",
                        ]
                    )
                }
                if !stopped {
                    return PromptOutlook(
                        headline: "You are on a break. It started at \(clock(response.at)).",
                        detail: ["Nothing is prompted during one, and the clock resumes when it ends."]
                    )
                }
            case .ignored:
                // Stale, so the log-stopped answer below is the honest one: a ladder that
                // was climbing when the process died is not a ladder that is climbing.
                break
            case .skipped:
                return PromptOutlook(
                    headline: "You waved it off at \(clock(response.at)).",
                    detail: [
                        "The opportunity was never marked closed, which is this log predating the"
                            + " cycle_close event rather than a live problem.",
                    ]
                )
            }
        }

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

        if stopped, let newest = sorted.last {
            return PromptOutlook(
                headline: "The log stops at \(clock(newest.at)) and nothing has been recorded since.",
                detail: detail + [
                    "An open cycle writes at least one line every"
                        + " \(DurationText.long(VerdictLedger.defaultHeartbeat)), so this is the app"
                        + " no longer running rather than the app being quiet.",
                    "It says nothing about what is happening now. Start it and it will.",
                ]
            )
        }

        return PromptOutlook(headline: "A break is due right now.", detail: detail)
    }
}
