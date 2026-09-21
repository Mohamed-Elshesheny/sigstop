import Foundation

// MARK: - Policy

/// The thresholds the rollup reads a day against. Defaults are the reference values in
/// docs/BREAK-DECISION.md §4.2 and §14.1; they are parameters so a test can state a
/// scenario in round numbers instead of in the production constants.
public struct RollupPolicy: Sendable, Codable, Hashable {
    /// An input gap no longer than this is reading or thinking. The clock keeps running
    /// and the time is credited (docs/BREAK-DECISION.md §3.3).
    public var microIdleGrace: TimeInterval
    /// Away at least this long is a real break: uncredited, and it resets the
    /// continuous-work run.
    public var qualifyingBreak: TimeInterval
    /// Away at least this long and the context is gone regardless of cause.
    public var longPauseReset: TimeInterval
    /// A break must *begin* within this long of an opportunity opening to honour it.
    public var complianceWindow: TimeInterval
    /// Local hour at which the logical day rolls over.
    public var dayBoundaryHour: Int

    public init(
        microIdleGrace: TimeInterval = 90,
        qualifyingBreak: TimeInterval = 5 * 60,
        longPauseReset: TimeInterval = 20 * 60,
        complianceWindow: TimeInterval = 10 * 60,
        dayBoundaryHour: Int = 4
    ) {
        self.microIdleGrace = microIdleGrace
        self.qualifyingBreak = qualifyingBreak
        self.longPauseReset = longPauseReset
        self.complianceWindow = complianceWindow
        self.dayBoundaryHour = dayBoundaryHour
    }

    public static let `default` = RollupPolicy()

    /// The same three numbers the engine runs on, derived the same way.
    ///
    /// This type had no settings init and every caller took `.default`, so the panel that
    /// reports your day judged a break against a hard-coded 5 minutes and 90 seconds while
    /// the engine that offered it used whatever `idleCountsAsBreakMinutes` and
    /// `microIdleThresholdSeconds` were set to. Turn the qualifying break down to 2 minutes
    /// and the engine honours a 2 minute break while the summary files it as abandoned.
    /// Mirrors `BreakPolicy.init(settings:)`, floor and all, so the two cannot drift.
    public init(settings: SigstopSettings) {
        self.init()
        microIdleGrace = TimeInterval(settings.microIdleThresholdSeconds)
        qualifyingBreak = max(
            TimeInterval(settings.idleCountsAsBreakMinutes * 60),
            microIdleGrace + 30
        )
        longPauseReset = min(max(longPauseReset, qualifyingBreak), max(longPauseReset, qualifyingBreak * 2))
    }
}

// MARK: - The summary

/// One day, reported.
///
/// Field names follow docs/BREAK-DECISION.md §14 except that the doc's `codingTime` is
/// spelled `totalActiveWork` here, because the quantity includes browsing, review and
/// meetings and calling all of it "coding" would be the kind of flattering imprecision
/// this project exists to avoid. `codingTime` remains as an alias so the doc's name
/// still resolves.
public struct DailySummary: Sendable, Codable, Hashable {
    /// Local y/m/d, with the day boundary at `RollupPolicy.dayBoundaryHour`.
    public let day: CalendarDay

    /// Credited active work across the day. Not wall clock, not app-foreground time.
    public let totalActiveWork: TimeInterval
    /// Partitions `totalActiveWork` by inferred activity. Keyed by `Activity.rawValue`
    /// so the summary file stays a plain JSON object a human can read.
    public let activeWorkByActivity: [String: TimeInterval]
    /// Partitions `totalActiveWork` by bundle identifier. Exactly partitions it:
    /// `applicationDistribution.values.sum() == totalActiveWork` is an invariant
    /// (docs/BREAK-DECISION.md §15 property 2), which is why unattributed time gets an
    /// explicit bucket rather than being dropped.
    public let applicationDistribution: [String: TimeInterval]
    /// Longest *continuous* credited stretch, i.e. the peak between resets. This is a
    /// work stretch, not a `DeveloperSession`; the field name follows everyday usage.
    public let longestContinuousSession: TimeInterval

    /// Qualifying breaks: accepted + idle-inferred + user-initiated.
    public let breakCount: Int
    public let breaksAccepted: Int
    public let breaksIdleInferred: Int
    public let breaksUserInitiated: Int
    /// Started but ended before `qualifyingBreak`. Not counted in `breakCount`.
    public let breaksAbandoned: Int
    public let skippedBreakCount: Int
    public let snoozeCount: Int
    public let ignoredPromptCount: Int

    public let breakOpportunities: Int
    public let honoredOpportunities: Int
    public let excludedOpportunities: Int
    public let notificationsDelivered: Int
    public let sessionCount: Int

    /// Lines of the event log that could not be parsed while building this summary.
    /// Reported rather than swallowed, so a truncated log is visible instead of
    /// silently shrinking the day.
    public let malformedLines: Int

    public init(
        day: CalendarDay,
        totalActiveWork: TimeInterval = 0,
        activeWorkByActivity: [String: TimeInterval] = [:],
        applicationDistribution: [String: TimeInterval] = [:],
        longestContinuousSession: TimeInterval = 0,
        breakCount: Int = 0,
        breaksAccepted: Int = 0,
        breaksIdleInferred: Int = 0,
        breaksUserInitiated: Int = 0,
        breaksAbandoned: Int = 0,
        skippedBreakCount: Int = 0,
        snoozeCount: Int = 0,
        ignoredPromptCount: Int = 0,
        breakOpportunities: Int = 0,
        honoredOpportunities: Int = 0,
        excludedOpportunities: Int = 0,
        notificationsDelivered: Int = 0,
        sessionCount: Int = 0,
        malformedLines: Int = 0
    ) {
        self.day = day
        self.totalActiveWork = totalActiveWork
        self.activeWorkByActivity = activeWorkByActivity
        self.applicationDistribution = applicationDistribution
        self.longestContinuousSession = longestContinuousSession
        self.breakCount = breakCount
        self.breaksAccepted = breaksAccepted
        self.breaksIdleInferred = breaksIdleInferred
        self.breaksUserInitiated = breaksUserInitiated
        self.breaksAbandoned = breaksAbandoned
        self.skippedBreakCount = skippedBreakCount
        self.snoozeCount = snoozeCount
        self.ignoredPromptCount = ignoredPromptCount
        self.breakOpportunities = breakOpportunities
        self.honoredOpportunities = honoredOpportunities
        self.excludedOpportunities = excludedOpportunities
        self.notificationsDelivered = notificationsDelivered
        self.sessionCount = sessionCount
        self.malformedLines = malformedLines
    }

    /// The doc's name for `totalActiveWork` (docs/BREAK-DECISION.md §14).
    public var codingTime: TimeInterval { totalActiveWork }

    /// Typed view of `activeWorkByActivity`.
    public var workByActivity: [Activity: TimeInterval] {
        var out: [Activity: TimeInterval] = [:]
        for (key, value) in activeWorkByActivity {
            if let activity = Activity(rawValue: key) { out[activity] = value }
        }
        return out
    }

    /// Opportunities that were real, delivered questions and went unanswered by a break.
    /// Skipped and ignored prompts are *missed*, not excluded.
    public var missedOpportunities: Int {
        max(0, breakOpportunities - excludedOpportunities - honoredOpportunities)
    }

    /// **`nil`, never 0 or 1, when there is nothing to measure.**
    ///
    /// The formula is docs/BREAK-DECISION.md §14 verbatim:
    ///
    /// ```
    /// denominator = breakOpportunities - excludedOpportunities
    /// compliance  = honoredOpportunities / denominator     (nil when denominator <= 0)
    /// ```
    ///
    /// The only thing the doc leaves open is the *operational* test for "the app never
    /// successfully asked". See `DailyRollup` for the reading implemented here.
    public var breakCompliance: Double? {
        let denominator = breakOpportunities - excludedOpportunities
        guard denominator > 0 else { return nil }
        return Double(honoredOpportunities) / Double(denominator)
    }

    /// The UI always renders the long form. A bare percentage invites the user to
    /// optimise a number; the parenthetical keeps it a description of a day
    /// (docs/BREAK-DECISION.md §14.2).
    public var complianceDescription: String {
        guard let compliance = breakCompliance else {
            return breakOpportunities == 0
                ? "No breaks were due."
                : "Not measured (\(excludedOpportunities) opportunities, none asked)."
        }
        let denominator = breakOpportunities - excludedOpportunities
        let percent = Int((compliance * 100).rounded())
        var text = "\(percent)% (\(honoredOpportunities) of \(denominator)"
        if excludedOpportunities > 0 { text += "; \(excludedOpportunities) not asked" }
        text += ")"
        return text
    }

    /// Bundle id with the most credited time, if any.
    public var topApplication: (bundleID: String, seconds: TimeInterval)? {
        applicationDistribution
            .max { ($0.value, $1.key) < ($1.value, $0.key) }
            .map { ($0.key, $0.value) }
    }

    public var isEmptyDay: Bool { totalActiveWork <= 0 && breakOpportunities == 0 }
}

// MARK: - The rollup

/// Reduces an event log into one `DailySummary`.
///
/// Deliberately a pure function over `[LoggedEvent]`: no I/O, no clock, no store. The
/// `EventStore` protocol exists so that this stays true, `FileEventStore` does the
/// reading, this does the arithmetic, and a test states a day as a literal array.
public enum DailyRollup {

    /// Bucket for credited time that has no bundle identifier, app tracking off, or a
    /// bundle-less process. It gets a named bucket rather than being dropped, because
    /// dropping it would quietly break the partition invariant and make the
    /// distribution add up to less than the day.
    public static let unattributedApplication = "unattributed"

    // MARK: Interpretation notes

    public static func compute(
        day: CalendarDay,
        events: [LoggedEvent],
        policy: RollupPolicy = .default,
        calendar: Calendar = .current,
        malformedLines: Int = 0
    ) -> DailySummary {
        guard let interval = day.interval(
            boundaryHour: policy.dayBoundaryHour, calendar: calendar
        ) else {
            return DailySummary(day: day, malformedLines: malformedLines)
        }

        let ordered = events.sorted { $0.at < $1.at }
        let timeline = buildTimeline(ordered, in: interval)
        let work = creditWork(timeline, policy: policy)
        let inDay = ordered.filter { $0.at >= interval.start && $0.at < interval.end }
        let breaks = countBreaks(inDay, dayEnd: interval.end, policy: policy)
        let counters = countPromptOutcomes(inDay)
        let opportunities = scoreOpportunities(inDay, dayEnd: interval.end, policy: policy)

        return DailySummary(
            day: day,
            totalActiveWork: work.total,
            activeWorkByActivity: work.byActivity,
            applicationDistribution: work.byApplication,
            longestContinuousSession: work.longestRun,
            breakCount: breaks.qualifying,
            breaksAccepted: breaks.accepted,
            breaksIdleInferred: breaks.idleInferred,
            breaksUserInitiated: breaks.userInitiated,
            breaksAbandoned: breaks.abandoned,
            skippedBreakCount: counters.skipped,
            snoozeCount: counters.snoozed,
            ignoredPromptCount: counters.ignored,
            breakOpportunities: opportunities.total,
            honoredOpportunities: opportunities.honored,
            excludedOpportunities: opportunities.excluded,
            notificationsDelivered: counters.delivered,
            sessionCount: inDay.filter { $0.kind == .start }.count,
            malformedLines: malformedLines
        )
    }

    /// Convenience: read the day out of a store, then reduce it.
    public static func compute(
        day: CalendarDay,
        from store: some EventStore,
        policy: RollupPolicy = .default,
        calendar: Calendar = .current
    ) throws -> DailySummary {
        let loaded = try store.events(forLogicalDay: day, calendar: calendar, policy: policy)
        return compute(
            day: day,
            events: loaded.events,
            policy: policy,
            calendar: calendar,
            malformedLines: loaded.malformedLines
        )
    }

    // MARK: - Timeline

    enum SegmentKind: Sendable, Hashable {
        /// Frontmost, hands on the machine.
        case working
        /// No input. May still be credited if the whole idle run is under the grace.
        case idle
        /// Locked, asleep, switched out, on a break, or the app was not running. Never
        /// credited, under any duration.
        case suspended
    }

    struct Segment: Sendable, Hashable {
        var start: Date
        var end: Date
        var kind: SegmentKind
        var app: String?
        var activity: Activity
        var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    }

    /// Walks the log into non-overlapping segments clipped to `interval`.
    ///
    /// Durations come from diffing real timestamps, never from a tick count times an
    /// interval (CLAUDE.md §3.4). `idle_s` is carried in the log for auditing and is
    /// deliberately not trusted here.
    static func buildTimeline(_ events: [LoggedEvent], in interval: DateInterval) -> [Segment] {
        var segments: [Segment] = []

        var app: String?
        var activity: Activity = .unknown
        var isIdle = false
        var suspensions: Set<EventKind> = []
        /// No `start` seen yet means the app was not observing; time is not credited.
        var running = false
        var cursor: Date?

        func currentKind() -> SegmentKind {
            if !running || !suspensions.isEmpty { return .suspended }
            return isIdle ? .idle : .working
        }

        func closeSegment(at end: Date) {
            guard let start = cursor, end > start else { cursor = end; return }
            let clippedStart = max(start, interval.start)
            let clippedEnd = min(end, interval.end)
            if clippedEnd > clippedStart {
                segments.append(
                    Segment(
                        start: clippedStart, end: clippedEnd,
                        kind: currentKind(), app: app, activity: activity
                    )
                )
            }
            cursor = end
        }

        for event in events {
            if event.at > interval.end { break }
            closeSegment(at: event.at)

            switch event.kind {
            case .start:
                running = true
                suspensions.removeAll()
            case .stop:
                running = false
            case .focus:
                app = event.app
                activity = event.activity ?? activity
                running = true
            case .idleBegin:
                isIdle = true
            case .idleEnd:
                isIdle = false
            case .lock, .sleep, .displaySleep, .sessionOut:
                suspensions.insert(event.kind)
                running = true
            case .unlock:
                suspensions.remove(.lock)
            case .wake:
                suspensions.remove(.sleep)
            case .displayWake:
                suspensions.remove(.displaySleep)
            case .sessionIn:
                suspensions.remove(.sessionOut)
            case .breakBegin:
                suspensions.insert(.breakBegin)
                isIdle = false
            case .breakEnd:
                suspensions.remove(.breakBegin)
                isIdle = false
            case .breakOpen, .breakPrompt, .breakResponse, .cycleClose, .gate:
                break // bookkeeping only; does not move the clock
            }

            if cursor == nil { cursor = event.at }
        }

        if let cursor, let last = events.last?.at, last > cursor {
            closeSegment(at: last)
        }
        return segments
    }

    // MARK: - Credit

    struct WorkTotals: Sendable {
        var total: TimeInterval = 0
        var byActivity: [String: TimeInterval] = [:]
        var byApplication: [String: TimeInterval] = [:]
        var longestRun: TimeInterval = 0
    }

    /// Credits the timeline and finds the longest continuous run.
    ///
    /// The rule, in one place:
    ///
    /// * a `working` segment is credited and extends the current run;
    /// * a maximal run of consecutive `idle` segments totalling `<= microIdleGrace` is
    ///   credited too, 30 seconds of reading is not a break (§3.3);
    /// * any other uncredited stretch is *not* credited, and resets the run only once it
    ///   reaches `qualifyingBreak`. A three-minute pause therefore neither resets the
    ///   clock nor secretly credits itself (§15 property 4).
    static func creditWork(_ segments: [Segment], policy: RollupPolicy) -> WorkTotals {
        var totals = WorkTotals()
        var run: TimeInterval = 0

        func credit(_ segment: Segment) {
            let d = segment.duration
            guard d > 0 else { return }
            totals.total += d
            totals.byActivity[segment.activity.rawValue, default: 0] += d
            totals.byApplication[segment.app ?? unattributedApplication, default: 0] += d
            run += d
        }

        var i = 0
        while i < segments.count {
            if segments[i].kind == .working {
                credit(segments[i])
                i += 1
                continue
            }
            var j = i
            var stretch: TimeInterval = 0
            var idleOnly = true
            while j < segments.count, segments[j].kind != .working {
                stretch += segments[j].duration
                if segments[j].kind != .idle { idleOnly = false }
                j += 1
            }
            if idleOnly && stretch <= policy.microIdleGrace {
                for k in i..<j { credit(segments[k]) }
            } else if stretch >= policy.qualifyingBreak {
                totals.longestRun = max(totals.longestRun, run)
                run = 0
            }
            i = j
        }
        totals.longestRun = max(totals.longestRun, run)
        return totals
    }

    // MARK: - Breaks

    struct BreakTotals: Sendable {
        var qualifying = 0
        var accepted = 0
        var idleInferred = 0
        var userInitiated = 0
        var abandoned = 0
    }

    struct BreakSpan: Sendable {
        var start: Date
        var measured: TimeInterval
        var origin: BreakOrigin
        var qualifies: Bool
    }

    /// Pairs `break_begin` with the next `break_end`.
    ///
    /// Duration comes from diffing the two timestamps; `dur_s` is used only when the
    /// end carries one and the timestamps agree less well than it does (a long sleep
    /// between the two, for instance, is exactly the case where the writer's own
    /// measurement is the better number).
    static func breakSpans(
        _ events: [LoggedEvent], dayEnd: Date, policy: RollupPolicy
    ) -> [BreakSpan] {
        var spans: [BreakSpan] = []
        var open: LoggedEvent?
        for event in events {
            switch event.kind {
            case .breakBegin:
                if let pending = open {
                    spans.append(span(from: pending, to: event.at, measured: nil, terminated: false, policy: policy))
                }
                open = event
            case .breakEnd:
                guard let pending = open else {
                    continue
                }
                let measured = event.durationSeconds.map(TimeInterval.init)
                spans.append(span(from: pending, to: event.at, measured: measured, terminated: true, policy: policy))
                open = nil
            default:
                continue
            }
        }
        if let pending = open {
            spans.append(span(from: pending, to: dayEnd, measured: nil, terminated: false, policy: policy))
        }
        return spans
    }

    /// A break with no `break_end` is of unknown length, and unknown is not long.
    ///
    /// `terminated` is the discriminator, and it has to be passed rather than inferred from
    /// `measured == nil`: `measured` is the end line's own `dur_s`, which is absent on plenty
    /// of perfectly complete breaks. Reading nil as "never ended" broke two existing tests
    /// that pair a begin with an end and no `dur_s`, which is exactly the trap.
    ///
    /// Unterminated means the process died mid-break, which happens routinely because engine
    /// state is not kept across launches. The span was closed at the next `break_begin` or at
    /// the end of the day and took that whole gap as its length, so quitting during a break
    /// minted a qualifying break out of nothing.
    ///
    /// It still appears, with the time that actually elapsed, because something did happen
    /// and hiding it would be its own lie. It just cannot qualify: `countBreaks` files it
    /// under abandoned, which is what an interrupted break is.
    private static func span(
        from begin: LoggedEvent, to end: Date, measured: TimeInterval?,
        terminated: Bool, policy: RollupPolicy
    ) -> BreakSpan {
        let elapsed = max(0, end.timeIntervalSince(begin.at))
        let duration = max(elapsed, measured ?? 0)
        return BreakSpan(
            start: begin.at,
            measured: duration,
            origin: begin.origin ?? .idleInferred,
            qualifies: terminated && duration >= policy.qualifyingBreak
        )
    }

    static func countBreaks(
        _ events: [LoggedEvent], dayEnd: Date, policy: RollupPolicy
    ) -> BreakTotals {
        var totals = BreakTotals()
        for span in breakSpans(events, dayEnd: dayEnd, policy: policy) {
            guard span.qualifies else {
                totals.abandoned += 1
                continue
            }
            totals.qualifying += 1
            switch span.origin {
            case .accepted: totals.accepted += 1
            case .idleInferred: totals.idleInferred += 1
            case .userInitiated: totals.userInitiated += 1
            }
        }
        return totals
    }

    // MARK: - Prompt outcomes

    struct PromptCounters: Sendable {
        var delivered = 0
        var skipped = 0
        var snoozed = 0
        var ignored = 0
    }

    static func countPromptOutcomes(_ events: [LoggedEvent]) -> PromptCounters {
        var counters = PromptCounters()
        for event in events {
            if event.wasDelivered { counters.delivered += 1 }
            guard event.kind == .breakResponse, let action = event.action else { continue }
            switch action {
            case .skipped: counters.skipped += 1
            case .snoozed: counters.snoozed += 1
            case .ignored: counters.ignored += 1
            case .taken: break // the break itself is counted from break_begin/break_end
            }
        }
        return counters
    }

    // MARK: - Opportunities

    struct OpportunityTotals: Sendable {
        var total = 0
        var honored = 0
        var excluded = 0
    }

    static func scoreOpportunities(
        _ events: [LoggedEvent], dayEnd: Date, policy: RollupPolicy
    ) -> OpportunityTotals {
        let opens = events.filter { $0.kind == .breakOpen }
        guard !opens.isEmpty else { return OpportunityTotals() }

        let spans = breakSpans(events, dayEnd: dayEnd, policy: policy).filter(\.qualifies)
        let delivered = events.filter(\.wasDelivered).map(\.at)

        /// One break answers one opportunity.
        ///
        /// This used to ask each opportunity whether *any* qualifying break started inside
        /// its window, so two opportunities opened close together were both answered by
        /// the same single break. The day then read more opportunities honoured than
        /// breaks taken, which is what the owner saw: one break and two honoured, six and
        /// seven. It also unlocked the badge for a day where every break offered was
        /// taken, on a day where they were not, because the badge asks whether honoured
        /// equals asked and the left side was inflated.
        ///
        /// Each span is now spent on the first opportunity whose window it falls in.
        let ordered = spans.sorted { $0.start < $1.start }
        var spent = Set<Int>()

        var totals = OpportunityTotals()
        totals.total = opens.count
        for open in opens {
            let windowEnd = open.at.addingTimeInterval(policy.complianceWindow)
            let match = ordered.indices.first {
                !spent.contains($0) && ordered[$0].start >= open.at && ordered[$0].start <= windowEnd
            }
            if let match {
                spent.insert(match)
                totals.honored += 1
            } else if !delivered.contains(where: { $0 >= open.at && $0 <= windowEnd }) {
                totals.excluded += 1
            }
        }
        return totals
    }
}
