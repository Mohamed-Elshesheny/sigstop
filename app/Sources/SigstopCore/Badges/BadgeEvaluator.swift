import Foundation

public struct BadgeDay: Sendable, Hashable {
    public let summary: DailySummary
    public let events: [LoggedEvent]

    public init(summary: DailySummary, events: [LoggedEvent] = []) {
        self.summary = summary
        self.events = events
    }

    public var day: CalendarDay { summary.day }

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

public enum BadgeEvaluator {

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

    private static func accumulate(
        _ day: BadgeDay,
        into evidence: inout BadgeEvidence,
        calendar: Calendar,
        policy: RollupPolicy
    ) {
        let summary = day.summary
        let taken = evidence.breaksTaken.addingReportingOverflow(summary.breakCount)
        evidence.breaksTaken = taken.overflow ? .max : taken.partialValue

        let asked = summary.breakOpportunities.subtractingReportingOverflow(summary.excludedOpportunities)
            .partialValue
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
