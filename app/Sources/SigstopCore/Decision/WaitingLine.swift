import Foundation

/// The one line the panel always shows: what the app is waiting for, and roughly when.
///
/// Silence by design and silence by defect look identical from the outside. A user who is
/// not prompted for an hour cannot tell whether the app decided to back off, is blocked,
/// crashed, or never worked, and they will not file a bug about it. Being quiet is a claim
/// like any other, and until this file it was the one claim the app made without evidence
/// (CLAUDE.md §4.1).
///
/// So the rule is total: `read` has an answer for every state the engine can be in, and
/// its last branch names itself as a bug rather than rendering nothing.
///
/// The words live in `Core` for the reason `QuietCause.title` already gives: `SigstopApp`
/// has no test target, so a vocabulary kept there is unchecked. `PromptOutlook` is
/// deliberately *not* what feeds this. That reads the event log because `--doctor` is a
/// separate process that cannot see the running engine; in-process `continuousWork`,
/// `armThreshold` and `cooldownUntilMono` are free, and no `LoggedEvent` carries them.
public struct WaitingLine: Sendable, Hashable {

    /// Three different claims, kept apart on purpose.
    ///
    /// "holding off" means something is blocking or rate-limiting a prompt right now.
    /// "not asking yet" means nothing is, and the engine is waiting on its own clock.
    /// "waiting on you" means the ask is already out, or a break is running, so the
    /// silence is the user's rather than the app's. Collapsing any two of them would put
    /// the app back where it started, saying RUNNING while it had no intention of
    /// speaking for an hour.
    public enum Claim: String, Sendable, Codable, CaseIterable, Hashable {
        case holdingOff
        case notAskingYet
        case waitingOnYou

        public var prefix: String {
            switch self {
            case .holdingOff:   return "holding off"
            case .notAskingYet: return "not asking yet"
            case .waitingOnYou: return "waiting on you"
            }
        }
    }

    public let claim: Claim
    /// The middle of the sentence, lower case, no trailing full stop.
    public let body: String

    public init(_ claim: Claim, _ body: String) {
        self.claim = claim
        self.body = body
    }

    public var text: String { "\(claim.prefix), \(body)." }

    /// The fallback, which has to exist. A state with no words is the failure this whole
    /// file is about, so it says so rather than rendering an empty line.
    public static let unexplained = WaitingLine(
        .notAskingYet, "and it cannot say why, which is a bug. Run make doctor"
    )
}

// MARK: - Reading it off the live engine

public extension WaitingLine {

    /// Everything the line is allowed to know. All of it is already in hand on the tick
    /// the model publishes, so the line costs no wake-up and schedules nothing.
    struct Reading: Sendable {
        public var state: EngineState
        /// The gate's answer this tick, from the engine's verdict when a cycle is open and
        /// from the sensor gate when none is. Nil when nothing is holding a prompt.
        public var gate: GateReason?
        public var continuousWork: TimeInterval
        /// True while the device bit itself is live, which is what makes the manual
        /// "ignore this input device" answer worth confirming.
        public var audioInputRunning: Bool
        /// When the user's "ignore this input device" runs out, while it is still live.
        public var micIgnoredUntil: Date?
        public var now: Date
        public var monotonic: Double
        public var policy: BreakPolicy
        public var settings: SigstopSettings
        public var calendar: Calendar

        public init(
            state: EngineState,
            gate: GateReason? = nil,
            continuousWork: TimeInterval = 0,
            audioInputRunning: Bool = false,
            micIgnoredUntil: Date? = nil,
            now: Date,
            monotonic: Double = 0,
            policy: BreakPolicy = .default,
            settings: SigstopSettings = .default,
            calendar: Calendar = .current
        ) {
            self.state = state
            self.gate = gate
            self.continuousWork = continuousWork
            self.audioInputRunning = audioInputRunning
            self.micIgnoredUntil = micIgnoredUntil
            self.now = now
            self.monotonic = monotonic
            self.policy = policy
            self.settings = settings
            self.calendar = calendar
        }
    }

    /// Total over the engine's state space. Every branch returns a line.
    static func read(_ r: Reading) -> WaitingLine {
        if let until = r.micIgnoredUntil, until > r.now, r.audioInputRunning {
            return WaitingLine(
                .notAskingYet,
                "taking your word for it, the mic will not hold your break until \(clock(until, r))"
            )
        }

        switch r.state {
        case .breakActive(let b):
            return WaitingLine(.waitingOnYou, "the break runs to \(clock(b.plannedEnd, r))")

        case .snoozed(let s):
            return WaitingLine(.waitingOnYou, "you snoozed it, asking again at \(clock(s.until, r))")

        case .idle:
            return WaitingLine(.notAskingYet, "the clock is stopped while you are away")

        case .quiet(let q):
            return quiet(q, r)

        case .working(let w):
            return working(w, r)

        case .breakDue, .ignored:
            return pending(r)
        }
    }

    // MARK: Branches

    private static func quiet(_ q: QuietState, _ r: Reading) -> WaitingLine {
        switch q.cause {
        case .userPaused:
            guard let until = q.until else { return WaitingLine(.notAskingYet, "you paused it") }
            return WaitingLine(.notAskingYet, "you paused it until \(clock(until, r))")
        case .scheduledQuietHours:
            let ends = minuteOfDay(r.settings.quietHours.endMinute)
            return WaitingLine(.notAskingYet, "you are inside your quiet hours until \(ends)")
        case .dailyCapReached, .sustainedFocusMode:
            return WaitingLine(.notAskingYet, q.cause.summary)
        }
    }

    private static func working(_ w: WorkingState, _ r: Reading) -> WaitingLine {
        if let cooldown = w.cooldownUntilMono, r.monotonic < cooldown {
            let until = r.now.addingTimeInterval(cooldown - r.monotonic)
            let why = (w.standDown ?? .ladderExhausted).summary
            return WaitingLine(.notAskingYet, "\(why), so nothing new until \(clock(until, r))")
        }
        if w.armThreshold > r.policy.targetContinuousWork {
            let extra = DurationText.short(w.armThreshold - r.policy.targetContinuousWork)
            let why = (w.standDown ?? .skipped).summary
            return WaitingLine(.notAskingYet, "\(why), so the next is \(extra) later than usual")
        }
        /// Deliberately no block reason here. Nothing is being held while the engine is
        /// working, because no break is due yet, and the panel used to borrow the sensor
        /// gate's answer anyway: on a Mac with a stuck input device it therefore asserted
        /// "you may be on a call" for an hour, with the app's own process table in the
        /// same process saying nobody had the microphone.
        let remaining = max(0, w.armThreshold - r.continuousWork)
        guard remaining >= 60 else { return WaitingLine(.notAskingYet, "the next one is due any moment") }
        return WaitingLine(.notAskingYet, "the next one is \(DurationText.short(remaining)) of work away")
    }

    private static func pending(_ r: Reading) -> WaitingLine {
        if let gate = r.gate, gate != .delivered {
            if gate.isHardBlock { return blocked(gate, r) }
            if gate == .ignoreBackoff {
                return WaitingLine(.holdingOff, "this one gets a single prompt and has had it")
            }
            return WaitingLine(.holdingOff, gate.summary)
        }
        if case .ignored(let e) = r.state {
            let overdue = DurationText.short(r.now.timeIntervalSince(e.dueSince))
            return WaitingLine(.waitingOnYou, "this one has been due \(overdue)")
        }
        if case .breakDue = r.state {
            return WaitingLine(.waitingOnYou, "a break is due and nothing is holding it")
        }
        return .unexplained
    }

    /// A block, with its deadline where the app has one.
    ///
    /// The microphone is the case worth spelling out: it is the only hard block that can
    /// last for hours on a perfectly healthy machine, because a virtual audio device holds
    /// the input open and the app used to read that as "you may be on a call" forever.
    private static func blocked(_ gate: GateReason, _ r: Reading) -> WaitingLine {
        guard gate == .audioInputInUse, let held = r.state.uncorroboratedAudioElapsed, held >= 60 else {
            return WaitingLine(.holdingOff, gate.summary)
        }
        let remaining = max(0, r.policy.uncorroboratedAudioCeiling - held)
        let stops = clock(r.now.addingTimeInterval(remaining), r)
        return WaitingLine(
            .holdingOff,
            "the mic has been open \(DurationText.short(held)) with nothing call-shaped"
                + " running. It stops holding at \(stops)"
        )
    }

    // MARK: Formatting

    /// `HH:mm`, 24-hour. A wall-clock time rather than a countdown, deliberately: a
    /// duration is something the reader has to re-check, and a string that changes every
    /// second would turn the menu bar's observation loop into a per-second redraw.
    private static func clock(_ date: Date, _ r: Reading) -> String {
        let c = r.calendar.dateComponents([.hour, .minute], from: date)
        return "\(Pad.two(c.hour ?? 0)):\(Pad.two(c.minute ?? 0))"
    }

    private static func minuteOfDay(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return "\(Pad.two(m / 60)):\(Pad.two(m % 60))"
    }
}
