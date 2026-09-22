import Foundation

public struct RollupPolicy: Sendable, Codable, Hashable {
    public var microIdleGrace: TimeInterval
    public var qualifyingBreak: TimeInterval
    public var longPauseReset: TimeInterval
    public var complianceWindow: TimeInterval
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

public struct DailySummary: Sendable, Codable, Hashable {
    public let day: CalendarDay

    public let totalActiveWork: TimeInterval
    public let activeWorkByActivity: [String: TimeInterval]
    public let applicationDistribution: [String: TimeInterval]
    public let longestContinuousSession: TimeInterval

    public let breakCount: Int
    public let breaksAccepted: Int
    public let breaksIdleInferred: Int
    public let breaksUserInitiated: Int
    public let breaksAbandoned: Int
    public let skippedBreakCount: Int
    public let snoozeCount: Int
    public let ignoredPromptCount: Int

    public let breakOpportunities: Int
    public let honoredOpportunities: Int
    public let excludedOpportunities: Int
    public let notificationsDelivered: Int
    public let sessionCount: Int

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

    public var workByActivity: [Activity: TimeInterval] {
        var out: [Activity: TimeInterval] = [:]
        for (key, value) in activeWorkByActivity {
            if let activity = Activity(rawValue: key) { out[activity] = value }
        }
        return out
    }

    public var missedOpportunities: Int {
        max(0, breakOpportunities - excludedOpportunities - honoredOpportunities)
    }

    public var breakCompliance: Double? {
        let denominator = breakOpportunities - excludedOpportunities
        guard denominator > 0 else { return nil }
        return Double(honoredOpportunities) / Double(denominator)
    }

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

    public var topApplication: (bundleID: String, seconds: TimeInterval)? {
        applicationDistribution
            .max { ($0.value, $1.key) < ($1.value, $0.key) }
            .map { ($0.key, $0.value) }
    }

    public var isEmptyDay: Bool { totalActiveWork <= 0 && breakOpportunities == 0 }
}

public enum DailyRollup {

    public static let unattributedApplication = "unattributed"

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

    enum SegmentKind: Sendable, Hashable {
        case working
        case idle
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

    static func buildTimeline(_ events: [LoggedEvent], in interval: DateInterval) -> [Segment] {
        var segments: [Segment] = []

        var app: String?
        var activity: Activity = .unknown
        var isIdle = false
        var suspensions: Set<EventKind> = []
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
                break
            }

            if cursor == nil { cursor = event.at }
        }

        if let cursor, let last = events.last?.at, last > cursor {
            closeSegment(at: last)
        }
        return segments
    }

    struct WorkTotals: Sendable {
        var total: TimeInterval = 0
        var byActivity: [String: TimeInterval] = [:]
        var byApplication: [String: TimeInterval] = [:]
        var longestRun: TimeInterval = 0
    }

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
            case .taken: break
            }
        }
        return counters
    }

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
