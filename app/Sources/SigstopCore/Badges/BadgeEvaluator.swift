import Foundation

// MARK: - One day, as the evaluator sees it

/// A logical day's summary, plus the events behind it when the log still has them.
///
/// Six of the ten conditions are arithmetic over `DailySummary` alone, so a day that
/// survives only as a stored summary still counts towards them. The four that need the
/// raw log, the fifteen-second accepts, the prompt that reached `SIGSTOP`, and the two
/// clock badges, can only be seen inside the retention window, which is exactly why
/// `BadgeLedger` is the durable record and this type is not.
public struct BadgeDay: Sendable, Hashable {
    public let summary: DailySummary
    /// The logical day's events. May carry the one event from *before* the interval that
    /// `EventStore.events(forLogicalDay:)` deliberately includes; the evaluator clips,
    /// so a caller never has to.
    public let events: [LoggedEvent]

    public init(summary: DailySummary, events: [LoggedEvent] = []) {
        self.summary = summary
        self.events = events
    }

    public var day: CalendarDay { summary.day }

    /// Reduce a day out of its events, then keep the events for the four conditions the
    /// summary cannot answer.
    public static func from(
        day: CalendarDay,
        events: [LoggedEvent],
        policy: RollupPolicy = .default,
        calendar: Calendar = .current
    ) -> BadgeDay {
        BadgeDay(
            summary: DailyRollup.compute(
                day: day, events: events, policy: policy, calendar: calendar
            ),
            events: events
        )
    }
}

// MARK: - The evaluator

/// Days in, unlocked badges out. A pure function, and nothing else.
///
/// **There is no clock here and no `TimeSource` parameter, because there is nothing to
/// ask one.** A badge unlocks on the day whose evidence completed it, which the fold
/// below reads off the day it is currently accumulating, so the same days in the same
/// order always produce the same ledger with the same dates, whatever time it is when
/// the app happens to run this. The rest of `SigstopCore` injects a clock; this is the
/// stronger position of not needing one (CLAUDE.md §3.2).
///
/// The fold is also what makes the dates honest. Evidence accumulates day by day in
/// ascending order, and after each day every still-locked badge is asked its question
/// once. The first day on which a badge says yes is the day recorded, not "today",
/// which is what a naive recompute would stamp on a badge that was actually earned last
/// Tuesday.
public enum BadgeEvaluator {

    /// The union of `knownUnlocked` and everything `days` proves. Never smaller than
    /// what it was handed (`BadgeLedger.merging`).
    public static func evaluate(
        days: [BadgeDay],
        calendar: Calendar = .current,
        policy: RollupPolicy = .default,
        knownUnlocked: BadgeLedger = .empty
    ) -> BadgeLedger {
        var ledger = knownUnlocked
        var evidence = BadgeEvidence()
        for day in days.sorted(by: { $0.day < $1.day }) {
            accumulate(day, into: &evidence, calendar: calendar, policy: policy)
            for badge in Badge.all where !ledger.contains(badge.id) {
                if badge.isEarned(evidence) { ledger.record(badge.id, on: day.day) }
            }
        }
        return ledger
    }

    /// The tally `days` adds up to. Exposed because the same arithmetic answers "how far
    /// along am I" and a test should be able to check the count without going through
    /// ten predicates.
    public static func evidence(
        for days: [BadgeDay],
        calendar: Calendar = .current,
        policy: RollupPolicy = .default
    ) -> BadgeEvidence {
        var evidence = BadgeEvidence()
        for day in days.sorted(by: { $0.day < $1.day }) {
            accumulate(day, into: &evidence, calendar: calendar, policy: policy)
        }
        return evidence
    }

    // MARK: One day's contribution

    private static func accumulate(
        _ day: BadgeDay,
        into evidence: inout BadgeEvidence,
        calendar: Calendar,
        policy: RollupPolicy
    ) {
        let summary = day.summary
        evidence.breaksTaken += summary.breakCount

        let asked = summary.breakOpportunities - summary.excludedOpportunities
        if asked > 0, summary.honoredOpportunities == asked {
            evidence.cleanDays += 1
        }

        if summary.totalActiveWork >= BadgeThreshold.yieldMinimumWork,
           summary.longestContinuousSession > 0,
           summary.longestContinuousSession <= BadgeThreshold.yieldStretchCeiling {
            evidence.yieldDays += 1
        }

        let events = clip(day, calendar: calendar, policy: policy)
        evidence.reflexAccepts += reflexAccepts(in: events)

        if events.contains(where: {
            $0.wasDelivered && $0.reason == EscalationLevel.incident.signal
        }) {
            evidence.reachedSigstop = true
        }

        let hours = events
            .filter { $0.kind == .breakBegin }
            .map { calendar.component(.hour, from: $0.at) }
        if hours.contains(where: {
            $0 >= policy.dayBoundaryHour && $0 < BadgeThreshold.earlyHour
        }) {
            evidence.earlyDays += 1
        }
        if hours.contains(where: {
            $0 >= BadgeThreshold.lateHour && $0 < policy.dayBoundaryHour
        }) {
            evidence.lateDays += 1
        }
    }

    /// The events that belong to this logical day, ascending.
    private static func clip(
        _ day: BadgeDay,
        calendar: Calendar,
        policy: RollupPolicy
    ) -> [LoggedEvent] {
        let ordered = day.events.sorted { $0.at < $1.at }
        guard let interval = day.day.interval(
            boundaryHour: policy.dayBoundaryHour, calendar: calendar
        ) else { return ordered }
        return ordered.filter { $0.at >= interval.start && $0.at < interval.end }
    }

    /// Breaks that began within `reflexWindow` of the prompt that asked for them.
    ///
    /// Matched by cycle, against the most recent prompt in that cycle that was actually
    /// *delivered*: a prompt withheld for a meeting never reached anyone, so accepting
    /// "quickly" after one would be measuring the app's silence rather than a reflex.
    /// Only `.accepted` breaks count, walking away and hitting "take a break now" are
    /// both breaks, but neither is a default disposition.
    private static func reflexAccepts(in events: [LoggedEvent]) -> Int {
        var promptedAt: [Int: Date] = [:]
        var count = 0
        for event in events {
            guard let cycle = event.cycle else { continue }
            switch event.kind {
            case .breakPrompt where event.wasDelivered:
                promptedAt[cycle] = event.at
            case .breakBegin where event.origin == .accepted:
                guard let asked = promptedAt[cycle] else { break }
                if event.at.timeIntervalSince(asked) <= BadgeThreshold.reflexWindow,
                   event.at >= asked {
                    count += 1
                }
                promptedAt[cycle] = nil
            default:
                break
            }
        }
        return count
    }
}
