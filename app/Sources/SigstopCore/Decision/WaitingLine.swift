import Foundation

public struct WaitingLine: Sendable, Hashable {

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
    public let body: String

    public init(_ claim: Claim, _ body: String) {
        self.claim = claim
        self.body = body
    }

    public var text: String { "\(claim.prefix), \(body)." }

    public static let unexplained = WaitingLine(
        .notAskingYet, "and it cannot say why, which is a bug. Run make doctor"
    )
}

public extension WaitingLine {

    struct Reading: Sendable {
        public var state: EngineState
        public var gate: GateReason?
        public var continuousWork: TimeInterval
        public var audioInputRunning: Bool
        public var micIgnoredUntil: Date?
        public var now: Date
        public var monotonic: Double
        public var policy: BreakPolicy
        public var settings: SigstopSettings
        public var calendar: Calendar
        public var notificationsDelivered: Int

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
            calendar: Calendar = .current,
            notificationsDelivered: Int = 0
        ) {
            self.notificationsDelivered = notificationsDelivered
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

    static func read(_ r: Reading) -> WaitingLine {
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

    private static func quiet(_ q: QuietState, _ r: Reading) -> WaitingLine {
        switch q.cause {
        case .userPaused:
            guard let until = q.until else { return WaitingLine(.notAskingYet, "you paused it") }
            return WaitingLine(.notAskingYet, "you paused it until \(clock(until, r))")
        case .scheduledQuietHours:
            let ends = minuteOfDay(r.settings.quietHours.endMinute)
            return WaitingLine(.notAskingYet, "you are inside your quiet hours until \(ends)")
        case .dailyCapReached, .sustainedFocusMode:
            return WaitingLine(.holdingOff, q.cause.summary)
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
        if let until = r.micIgnoredUntil, until > r.now, r.audioInputRunning {
            return WaitingLine(
                .notAskingYet,
                "taking your word for it, the mic will not hold your break until \(clock(until, r))"
            )
        }
        if r.notificationsDelivered >= r.policy.dailyNotificationCap {
            return WaitingLine(.holdingOff, QuietCause.dailyCapReached.summary)
        }
        let remaining = max(0, w.armThreshold - r.continuousWork)
        guard remaining >= 60 else { return WaitingLine(.notAskingYet, "the next one is due any moment") }
        return WaitingLine(.notAskingYet, "the next one is \(DurationText.short(remaining)) of work away")
    }

    private static func pending(_ r: Reading) -> WaitingLine {
        if let gate = r.gate, gate.isHardBlock { return blocked(gate, r) }

        if case .ignored(let e) = r.state {
            let overdue = DurationText.short(r.now.timeIntervalSince(e.dueSince))
            return WaitingLine(.waitingOnYou, "you waved the last one off, and it has been due \(overdue)")
        }
        if case .breakDue(let d) = r.state, d.promptedAt != nil {
            return WaitingLine(.waitingOnYou, "you have been asked and it is still waiting")
        }

        if let gate = r.gate, gate != .delivered {
            if gate == .ignoreBackoff {
                return WaitingLine(.holdingOff, "this one gets a single prompt and has had it")
            }
            return WaitingLine(.holdingOff, gate.summary)
        }
        if case .breakDue = r.state {
            return WaitingLine(.waitingOnYou, "a break is due and nothing is holding it")
        }
        return .unexplained
    }

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

    private static func clock(_ date: Date, _ r: Reading) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = r.calendar.timeZone
        if let locale = r.calendar.locale { style.locale = locale }
        return date.formatted(style)
    }

    private static func minuteOfDay(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return "\(Pad.two(m / 60)):\(Pad.two(m % 60))"
    }
}
