import Foundation
import Testing
@testable import SigstopCore

// Every test here runs headlessly: no window server, no Xcode, no GUI session, no real
// clock. Dates are literals and the store is in-memory, which is the entire point of
// keeping `DailyRollup` a pure function behind the `EventStore` protocol.

// MARK: - Fixtures

private enum Fix {
    /// A UTC calendar, so a test scenario reads the same on any machine.
    static let calendar = CalendarDay.utcCalendar
    static let policy = RollupPolicy(
        microIdleGrace: 90,
        qualifyingBreak: 5 * 60,
        longPauseReset: 20 * 60,
        complianceWindow: 10 * 60,
        dayBoundaryHour: 4
    )

    static let day = CalendarDay(year: 2026, month: 9, day: 20)

    /// 2026-09-20 09:00:00 UTC, comfortably inside the logical day [04:00, 04:00).
    static let nineAM: Date = {
        var c = DateComponents()
        c.year = 2026
        c.month = 9
        c.day = 20
        c.hour = 9
        return calendar.date(from: c) ?? Date(timeIntervalSince1970: 1_790_000_000)
    }()

    static func t(_ minutes: Double) -> Date { nineAM.addingTimeInterval(minutes * 60) }

    static func roll(_ events: [LoggedEvent]) -> DailySummary {
        DailyRollup.compute(day: day, events: events, policy: policy, calendar: calendar)
    }
}

private let xcode = "com.apple.dt.Xcode"
private let chrome = "com.google.Chrome"
private let term = "com.apple.Terminal"

// MARK: - Compliance formula

@Suite("break compliance")
struct ComplianceTests {

    /// The worked example from docs/BREAK-DECISION.md §14.2, reproduced as events:
    /// 9 opportunities, 6 honoured, 1 never asked, 1 skipped, 1 ignored.
    @Test func worked_example_from_the_doc() {
        var events: [LoggedEvent] = [.start(at: Fix.t(0)), .focus(at: Fix.t(0), app: xcode, activity: .coding)]
        var minute = 10.0

        // 6 honoured: opportunity, delivered prompt, qualifying break inside the window.
        for i in 0..<6 {
            let cycle = CycleID(rawValue: i)
            events.append(.breakOpen(at: Fix.t(minute), cycle: cycle))
            events.append(.breakPrompt(at: Fix.t(minute), cycle: cycle))
            events.append(.breakBegin(at: Fix.t(minute + 2), origin: i < 4 ? .accepted : .idleInferred))
            events.append(
                .breakEnd(at: Fix.t(minute + 8), origin: i < 4 ? .accepted : .idleInferred,
                          durationSeconds: 6 * 60)
            )
            minute += 60
        }
        // 1 excluded: the opportunity opened, every prompt was withheld.
        events.append(.breakOpen(at: Fix.t(minute), cycle: CycleID(rawValue: 6)))
        events.append(
            .breakPrompt(at: Fix.t(minute), cycle: CycleID(rawValue: 6), deferred: "meeting")
        )
        minute += 60
        // 1 skipped: delivered, answered "skip".
        events.append(.breakOpen(at: Fix.t(minute), cycle: CycleID(rawValue: 7)))
        events.append(.breakPrompt(at: Fix.t(minute), cycle: CycleID(rawValue: 7)))
        events.append(
            .breakResponse(at: Fix.t(minute + 1), cycle: CycleID(rawValue: 7), action: .skipped)
        )
        minute += 60
        // 1 ignored through level 4: delivered, no response.
        events.append(.breakOpen(at: Fix.t(minute), cycle: CycleID(rawValue: 8)))
        events.append(.breakPrompt(at: Fix.t(minute), cycle: CycleID(rawValue: 8)))
        events.append(
            .breakResponse(at: Fix.t(minute + 2), cycle: CycleID(rawValue: 8), action: .ignored)
        )
        events.append(.stop(at: Fix.t(minute + 10)))

        let s = Fix.roll(events)
        #expect(s.breakOpportunities == 9)
        #expect(s.excludedOpportunities == 1)
        #expect(s.honoredOpportunities == 6)
        #expect(s.missedOpportunities == 2)
        #expect(s.breakCompliance == 0.75)
        #expect(s.complianceDescription == "75% (6 of 8; 1 not asked)")
        #expect(s.breakCount == 6)
        #expect(s.breaksAccepted == 4)
        #expect(s.breaksIdleInferred == 2)
        #expect(s.skippedBreakCount == 1)
        #expect(s.ignoredPromptCount == 1)
    }

    /// Edge case: zero breaks. Prompts were delivered and nothing happened — that is
    /// 0%, not "unmeasurable". The metric must be willing to say zero.
    @Test func zero_breaks_with_delivered_prompts_is_zero_not_nil() {
        let events: [LoggedEvent] = [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(0), app: xcode, activity: .coding),
            .breakOpen(at: Fix.t(45), cycle: .initial),
            .breakPrompt(at: Fix.t(45), cycle: .initial),
            .breakResponse(at: Fix.t(46), cycle: .initial, action: .skipped),
            .stop(at: Fix.t(90)),
        ]
        let s = Fix.roll(events)
        #expect(s.breakOpportunities == 1)
        #expect(s.excludedOpportunities == 0)
        #expect(s.breakCompliance == 0.0)
        #expect(s.complianceDescription == "0% (0 of 1)")
    }

    /// docs/BREAK-DECISION.md §15 property 11: `nil`, never 0.0 or 1.0, when every
    /// opportunity was excluded. You cannot hold someone to a question never asked.
    @Test func compliance_is_nil_when_every_opportunity_was_excluded() {
        let events: [LoggedEvent] = [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(0), app: chrome, activity: .meeting),
            .breakOpen(at: Fix.t(45), cycle: .initial),
            .breakPrompt(at: Fix.t(45), cycle: .initial, deferred: "meeting"),
            .breakOpen(at: Fix.t(100), cycle: CycleID(rawValue: 1)),
            .breakPrompt(at: Fix.t(100), cycle: CycleID(rawValue: 1), deferred: "quiet_hours"),
            .stop(at: Fix.t(140)),
        ]
        let s = Fix.roll(events)
        #expect(s.breakOpportunities == 2)
        #expect(s.excludedOpportunities == 2)
        #expect(s.breakCompliance == nil)
        #expect(s.notificationsDelivered == 0)
        #expect(s.complianceDescription == "Not measured (2 opportunities, none asked).")
    }

    /// Zero work, zero everything. No opportunities means no denominator means nil.
    @Test func a_day_with_no_events_at_all() {
        let s = Fix.roll([])
        #expect(s.totalActiveWork == 0)
        #expect(s.longestContinuousSession == 0)
        #expect(s.breakCount == 0)
        #expect(s.breakOpportunities == 0)
        #expect(s.breakCompliance == nil)
        #expect(s.complianceDescription == "No breaks were due.")
        #expect(s.applicationDistribution.isEmpty)
        #expect(s.isEmptyDay)
    }

    /// A day with only idle: the app ran, nobody touched it. Long idle is never
    /// credited, no matter how long the app was open.
    @Test func a_day_with_only_idle_credits_nothing() {
        let events: [LoggedEvent] = [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(0), app: xcode, activity: .coding),
            .idleBegin(at: Fix.t(0)),
            .idleEnd(at: Fix.t(300), idleSeconds: 300 * 60),
            .stop(at: Fix.t(300)),
        ]
        let s = Fix.roll(events)
        #expect(s.totalActiveWork == 0)
        #expect(s.longestContinuousSession == 0)
        #expect(s.breakOpportunities == 0)
        #expect(s.breakCompliance == nil)
        #expect(s.applicationDistribution.isEmpty)
    }

    /// A break that begins after the 10-minute compliance window does not honour the
    /// opportunity, even though it is a perfectly real break.
    @Test func a_break_outside_the_window_does_not_honor() {
        let events: [LoggedEvent] = [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(0), app: xcode, activity: .coding),
            .breakOpen(at: Fix.t(45), cycle: .initial),
            .breakPrompt(at: Fix.t(45), cycle: .initial),
            .breakBegin(at: Fix.t(45 + 11), origin: .userInitiated),
            .breakEnd(at: Fix.t(45 + 20), origin: .userInitiated, durationSeconds: 9 * 60),
            .stop(at: Fix.t(120)),
        ]
        let s = Fix.roll(events)
        #expect(s.honoredOpportunities == 0)
        #expect(s.missedOpportunities == 1)
        #expect(s.breakCount == 1) // the break still happened and is still reported
        #expect(s.breaksUserInitiated == 1)
    }

    /// A break too short to qualify is "abandoned": counted separately, never in
    /// `breakCount`, and it does not honour an opportunity.
    @Test func a_short_break_is_abandoned_not_counted() {
        let events: [LoggedEvent] = [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(0), app: xcode, activity: .coding),
            .breakOpen(at: Fix.t(45), cycle: .initial),
            .breakPrompt(at: Fix.t(45), cycle: .initial),
            .breakBegin(at: Fix.t(46), origin: .accepted),
            .breakEnd(at: Fix.t(48), origin: .accepted, durationSeconds: 2 * 60),
            .stop(at: Fix.t(90)),
        ]
        let s = Fix.roll(events)
        #expect(s.breakCount == 0)
        #expect(s.breaksAbandoned == 1)
        #expect(s.honoredOpportunities == 0)
        #expect(s.missedOpportunities == 1)
    }

    /// Walking away without ever seeing a prompt counts identically to accepting one.
    /// The metric measures behaviour, not obedience (§14.1).
    @Test func a_spontaneous_break_honors_just_like_an_accepted_one() {
        let events: [LoggedEvent] = [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(0), app: xcode, activity: .coding),
            .breakOpen(at: Fix.t(45), cycle: .initial),
            .breakPrompt(at: Fix.t(45), cycle: .initial),
            .breakBegin(at: Fix.t(46), origin: .idleInferred),
            .breakEnd(at: Fix.t(53), origin: .idleInferred, durationSeconds: 7 * 60),
            .stop(at: Fix.t(90)),
        ]
        let s = Fix.roll(events)
        #expect(s.honoredOpportunities == 1)
        #expect(s.breakCompliance == 1.0)
        #expect(s.breaksIdleInferred == 1)
    }
}

// MARK: - The work clock

@Suite("credited work and the longest stretch")
struct WorkClockTests {

    /// Micro-idle never resets and is credited: 30 s of reading is not a break
    /// (docs/BREAK-DECISION.md §15 property 3).
    @Test func micro_idle_is_credited_and_does_not_split_the_stretch() {
        let events: [LoggedEvent] = [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(0), app: xcode, activity: .coding),
            .idleBegin(at: Fix.t(44)),
            .idleEnd(at: Fix.t(44.5), idleSeconds: 30),
            .focus(at: Fix.t(44.5), app: xcode, activity: .coding),
            .stop(at: Fix.t(46)),
        ]
        let s = Fix.roll(events)
        #expect(s.totalActiveWork == 46 * 60)
        #expect(s.longestContinuousSession == 46 * 60)
    }

    /// A 3-minute pause neither resets the stretch nor secretly credits itself
    /// (§15 property 4).
    @Test func a_short_pause_neither_credits_nor_resets() {
        let events: [LoggedEvent] = [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(0), app: xcode, activity: .coding),
            .idleBegin(at: Fix.t(44)),
            .idleEnd(at: Fix.t(47), idleSeconds: 180),
            .focus(at: Fix.t(47), app: xcode, activity: .coding),
            .stop(at: Fix.t(49)),
        ]
        let s = Fix.roll(events)
        #expect(s.totalActiveWork == 46 * 60)        // 44 + 2, the 3-minute gap uncredited
        #expect(s.longestContinuousSession == 46 * 60) // one stretch, not two
    }

    /// A gap long enough to qualify as a break splits the stretch. The longest is the
    /// max of the pieces, not the sum.
    @Test func longest_session_across_pauses() {
        let events: [LoggedEvent] = [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(0), app: xcode, activity: .coding),
            // stretch 1: 30 min
            .idleBegin(at: Fix.t(30)),
            .idleEnd(at: Fix.t(40), idleSeconds: 600),   // 10 min: qualifying, resets
            .focus(at: Fix.t(40), app: xcode, activity: .coding),
            // stretch 2: 55 min, with a 2-minute pause inside that must NOT split it
            .idleBegin(at: Fix.t(70)),
            .idleEnd(at: Fix.t(72), idleSeconds: 120),
            .focus(at: Fix.t(72), app: xcode, activity: .coding),
            .system(at: Fix.t(97), .lock),               // 25 min locked: resets
            .system(at: Fix.t(122), .unlock),
            .focus(at: Fix.t(122), app: xcode, activity: .coding),
            // stretch 3: 20 min
            .stop(at: Fix.t(142)),
        ]
        let s = Fix.roll(events)
        // stretch 2 = (70-40) + (97-72) = 30 + 25 = 55 minutes
        #expect(s.longestContinuousSession == 55 * 60)
        // total = 30 + 55 + 20 = 105 minutes credited; the 10-min idle, the 2-min pause
        // and the 25-min lock are all uncredited.
        #expect(s.totalActiveWork == 105 * 60)
    }

    /// A lock, a sleep, or a fast user switch is never credited, at any duration — not
    /// even under the micro-idle grace. "Nobody is at the machine" is a system fact,
    /// not a guess about reading.
    @Test func a_brief_lock_is_still_not_work() {
        let events: [LoggedEvent] = [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(0), app: xcode, activity: .coding),
            .system(at: Fix.t(10), .lock),
            .system(at: Fix.t(10.5), .unlock),   // 30 seconds — under the grace
            .focus(at: Fix.t(10.5), app: xcode, activity: .coding),
            .stop(at: Fix.t(20)),
        ]
        let s = Fix.roll(events)
        #expect(s.totalActiveWork == 19.5 * 60)
        #expect(s.longestContinuousSession == 19.5 * 60) // brief: pauses but does not reset
    }

    /// Time inside a break is never credited as work.
    @Test func break_time_is_not_work_time() {
        let events: [LoggedEvent] = [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(0), app: xcode, activity: .coding),
            .breakBegin(at: Fix.t(45), origin: .accepted),
            .breakEnd(at: Fix.t(53), origin: .accepted, durationSeconds: 8 * 60),
            .focus(at: Fix.t(53), app: xcode, activity: .coding),
            .stop(at: Fix.t(60)),
        ]
        let s = Fix.roll(events)
        #expect(s.totalActiveWork == 52 * 60)
        #expect(s.longestContinuousSession == 45 * 60) // the 8-min break reset the stretch
    }

    /// The timeline closes at the last observed event, never at the day boundary.
    /// Without a `stop`, work is credited only up to what the log can prove
    /// (§15 property 1: credited work ≤ wall-clock elapsed).
    @Test func an_unterminated_log_does_not_fabricate_work() {
        let events: [LoggedEvent] = [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(0), app: xcode, activity: .coding),
            .focus(at: Fix.t(30), app: term, activity: .terminalWork),
        ]
        let s = Fix.roll(events)
        #expect(s.totalActiveWork == 30 * 60)
    }
}

// MARK: - Application distribution

@Suite("application distribution")
struct DistributionTests {

    /// docs/BREAK-DECISION.md §15 property 2: the distribution exactly partitions
    /// credited work. This is the invariant that makes the pie chart honest.
    @Test func distribution_sums_to_total_active_work() {
        let events: [LoggedEvent] = [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(0), app: xcode, activity: .coding),
            .focus(at: Fix.t(25), app: chrome, activity: .browsing),
            .focus(at: Fix.t(40), app: term, activity: .terminalWork),
            .idleBegin(at: Fix.t(55)),
            .idleEnd(at: Fix.t(65), idleSeconds: 600),   // uncredited
            .focus(at: Fix.t(65), app: xcode, activity: .coding),
            .stop(at: Fix.t(95)),
        ]
        let s = Fix.roll(events)
        let sum = s.applicationDistribution.values.reduce(0, +)
        #expect(sum == s.totalActiveWork)
        #expect(s.applicationDistribution[xcode] == TimeInterval(55 * 60))  // 25 + 30
        #expect(s.applicationDistribution[chrome] == TimeInterval(15 * 60))
        #expect(s.applicationDistribution[term] == TimeInterval(15 * 60))
        #expect(s.totalActiveWork == 85 * 60)
    }

    /// Activity buckets partition the same quantity.
    @Test func activity_distribution_sums_to_total_active_work() {
        let events: [LoggedEvent] = [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(0), app: xcode, activity: .coding),
            .focus(at: Fix.t(20), app: xcode, activity: .debugging),
            .focus(at: Fix.t(50), app: chrome, activity: .codeReview),
            .stop(at: Fix.t(70)),
        ]
        let s = Fix.roll(events)
        let sum = s.activeWorkByActivity.values.reduce(0, +)
        #expect(sum == s.totalActiveWork)
        #expect(s.workByActivity[.coding] == TimeInterval(20 * 60))
        #expect(s.workByActivity[.debugging] == TimeInterval(30 * 60))
        #expect(s.workByActivity[.codeReview] == TimeInterval(20 * 60))
    }

    /// Time with no bundle identifier — app tracking off, or a bundle-less process —
    /// goes to an explicit bucket. Dropping it would quietly break the partition.
    @Test func unattributed_time_keeps_the_partition_exact() {
        let events: [LoggedEvent] = [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(0), app: nil, activity: .unknown),
            .focus(at: Fix.t(20), app: xcode, activity: .coding),
            .stop(at: Fix.t(50)),
        ]
        let s = Fix.roll(events)
        #expect(s.applicationDistribution[DailyRollup.unattributedApplication] == TimeInterval(20 * 60))
        #expect(s.applicationDistribution.values.reduce(0, +) == s.totalActiveWork)
        #expect(s.topApplication?.bundleID == xcode)
    }
}

// MARK: - Event log round-trip

@Suite("event log encode/decode")
struct EventLogTests {

    private static func everyFieldEvent() -> LoggedEvent {
        LoggedEvent(
            at: Fix.t(3),
            kind: .breakResponse,
            app: xcode,
            category: "code",
            activity: .debugging,
            titleSignal: "editor",
            idleSeconds: 378,
            reason: "streak_45m",
            action: .snoozed,
            snoozeSeconds: 600,
            deferred: "meeting",
            origin: .accepted,
            durationSeconds: 420,
            cycle: 7
        )
    }

    @Test func a_fully_populated_event_round_trips_without_loss() throws {
        let original = Self.everyFieldEvent()
        let line = try EventLogCodec.encode(original)
        let decoded = try #require(EventLogCodec.decode(line))
        #expect(decoded == original)
    }

    @Test func a_whole_log_round_trips_and_stays_ordered() throws {
        let events: [LoggedEvent] = [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(0), app: xcode, category: "code", activity: .coding, titleSignal: "editor"),
            .idleBegin(at: Fix.t(31)),
            .idleEnd(at: Fix.t(37), idleSeconds: 360),
            .breakOpen(at: Fix.t(45), cycle: .initial, reason: "streak_45m"),
            .breakPrompt(at: Fix.t(45), cycle: .initial, reason: "streak_45m"),
            .breakResponse(at: Fix.t(46), cycle: .initial, action: .snoozed, snoozeSeconds: 600),
            .breakBegin(at: Fix.t(56), origin: .accepted, cycle: .initial),
            .breakEnd(at: Fix.t(62), origin: .accepted, durationSeconds: 360, cycle: .initial),
            .system(at: Fix.t(120), .lock),
            .system(at: Fix.t(160), .unlock),
            .stop(at: Fix.t(300)),
        ]
        let text = try EventLogCodec.encodeLines(events)
        let result = EventLogCodec.decodeLines(text)
        #expect(result.malformedLines == 0)
        #expect(result.events == events)
    }

    /// Optional fields are omitted, not written as `null`. The whole argument for JSONL
    /// is that a line is readable at a glance.
    @Test func a_line_is_short_and_plainly_named() throws {
        let line = try EventLogCodec.encode(.focus(at: Fix.t(0), app: xcode, category: "code"))
        // Keys are sorted, which is what makes the line byte-stable across runs.
        #expect(line == #"{"app":"com.apple.dt.Xcode","cat":"code","e":"focus","t":"2026-09-20T09:00:00Z","v":1}"#)
        #expect(!line.contains("null"))
    }

    /// Sub-second precision is deliberately discarded (docs/PRIVACY.md §4.3).
    @Test func timestamps_are_truncated_to_the_second() throws {
        let event = LoggedEvent(at: Fix.t(0).addingTimeInterval(0.987), kind: .start)
        let decoded = try #require(EventLogCodec.decode(try EventLogCodec.encode(event)))
        #expect(decoded.at == Fix.t(0))
    }

    /// A crash mid-append leaves a torn final line. It is skipped and counted; every
    /// other line of the day survives.
    @Test func a_torn_final_line_costs_exactly_one_line() throws {
        let good: [LoggedEvent] = [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(1), app: xcode, activity: .coding),
        ]
        var text = try EventLogCodec.encodeLines(good)
        text += #"{"v":1,"t":"2026-09-20T09:05:00Z","e":"fo"#   // killed mid-write
        let result = EventLogCodec.decodeLines(text)
        #expect(result.events == good)
        #expect(result.malformedLines == 1)
    }

    /// An unknown schema major is rejected rather than half-understood.
    @Test func an_unknown_schema_version_is_rejected() {
        let line = #"{"v":99,"t":"2026-09-20T09:00:00Z","e":"start"}"#
        #expect(EventLogCodec.decode(line) == nil)
    }

    @Test func a_malformed_timestamp_is_rejected() {
        #expect(EventLogCodec.decode(#"{"v":1,"t":"yesterday","e":"start"}"#) == nil)
        #expect(EventLogCodec.decode(#"{"v":1,"t":"2026-09-20 09:00:00","e":"start"}"#) == nil)
        #expect(ISO8601Second.date(from: "2026-09-20T09:00:00Z") != nil)
    }

    @Test func day_keys_sort_lexicographically_as_well_as_chronologically() {
        let a = CalendarDay(year: 2026, month: 9, day: 9)
        let b = CalendarDay(year: 2026, month: 9, day: 20)
        #expect(a < b)
        #expect(a.description < b.description)     // the assumption retention relies on
        #expect(a.fileName == "2026-09-09.jsonl")
        #expect(CalendarDay.parse("2026-09-20") == Fix.day)
        #expect(CalendarDay.parse("2026-9-20") == nil)
    }
}

// MARK: - Store behaviour

@Suite("store, export, retention, delete")
struct StoreTests {

    @Test func the_in_memory_store_round_trips_a_day() throws {
        let store = InMemoryEventStore()
        try store.append(contentsOf: [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(0), app: xcode, activity: .coding),
            .stop(at: Fix.t(60)),
        ])
        let load = try store.load(day: Fix.day)
        #expect(load.events.count == 3)
        #expect(try store.availableDays() == [Fix.day])
    }

    /// An export is a copy, not a report: it re-parses into exactly the events it came
    /// from, so what you audit is what the app has.
    @Test func an_export_is_readable_and_re_readable() throws {
        let events: [LoggedEvent] = [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(0), app: xcode, category: "code", activity: .coding),
            .stop(at: Fix.t(120)),
        ]
        let store = InMemoryEventStore(events: events)
        let text = try store.exportText()
        #expect(text.contains("# sigstop event log export"))
        #expect(text.contains("# events: 3"))
        #expect(text.contains("never the title"))
        let reread = EventLogCodec.decodeLines(text)
        #expect(reread.events == events)
        #expect(reread.malformedLines == 0)
    }

    @Test func retention_prunes_beyond_the_window_and_keeps_the_rest() throws {
        let store = InMemoryEventStore()
        for back in 0..<12 {
            let day = Fix.day.adding(days: -back)
            guard let noon = CalendarDay.utcCalendar.date(
                from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)
            ) else { continue }
            try store.append(.start(at: noon))
        }
        #expect(try store.availableDays().count == 12)

        let report = try store.prune(retentionDays: 7, asOf: Fix.t(600))
        #expect(report.removedDays.count == 5)
        #expect(report.removedEvents == 5)
        let left = try store.availableDays()
        #expect(left.count == 7)
        #expect(left.first == Fix.day.adding(days: -6))
        #expect(left.last == Fix.day)
    }

    /// Retention 0 is "memory-only mode": a real setting, not a degenerate one.
    @Test func retention_zero_keeps_nothing() throws {
        let store = InMemoryEventStore(events: [.start(at: Fix.t(0))])
        let report = try store.prune(retentionDays: 0, asOf: Fix.t(0))
        #expect(report.removedDays == [Fix.day])
        #expect(try store.availableDays().isEmpty)
    }

    @Test func delete_removes_everything_and_says_what_it_removed() throws {
        let store = InMemoryEventStore(events: [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(0), app: xcode, activity: .coding),
        ])
        let report = try store.deleteEverything()
        #expect(report.removedEvents == 2)
        #expect(report.removedDays == [Fix.day])
        #expect(report.userFacingSummary.contains("Deleted:"))
        #expect(report.userFacingSummary.contains("tccutil reset Accessibility"))
        #expect(try store.availableDays().isEmpty)
        #expect(try store.load(day: Fix.day).events.isEmpty)
    }

    /// Unreadable lines reach the summary rather than silently shrinking the day.
    @Test func malformed_lines_are_reported_through_to_the_summary() throws {
        let store = InMemoryEventStore(events: [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(0), app: xcode, activity: .coding),
            .stop(at: Fix.t(30)),
        ])
        store.injectMalformedLines(2, on: Fix.day)
        let summary = try DailyRollup.compute(
            day: Fix.day, from: store, policy: Fix.policy, calendar: Fix.calendar
        )
        #expect(summary.malformedLines == 2)
        #expect(summary.totalActiveWork == 30 * 60)
    }

    // MARK: On-disk store

    private static func tempRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sigstop-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func the_file_store_appends_loads_and_prunes() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileEventStore(root: root)

        try store.append(contentsOf: [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(0), app: xcode, category: "code", activity: .coding),
            .stop(at: Fix.t(120)),
        ])
        #expect(try store.availableDays() == [Fix.day])
        let load = try store.load(day: Fix.day)
        #expect(load.events.count == 3)
        #expect(load.malformedLines == 0)

        // The file really is one JSON object per line and nothing else.
        let raw = try String(contentsOf: store.url(for: Fix.day), encoding: .utf8)
        #expect(raw.split(separator: "\n").count == 3)
        #expect(raw.hasSuffix("\n"))

        let report = try store.prune(retentionDays: 0, asOf: Fix.t(0))
        #expect(report.removedDays == [Fix.day])
        #expect(try store.availableDays().isEmpty)
    }

    /// The crash case, for real: a torn tail on disk. The next append heals it, so one
    /// interrupted write costs one line and fuses nothing.
    @Test func a_torn_tail_on_disk_is_healed_by_the_next_append() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileEventStore(root: root)

        try store.append(.start(at: Fix.t(0)))
        // Simulate a process killed mid-write: a partial line, no newline.
        let handle = try FileHandle(forWritingTo: store.url(for: Fix.day))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"v":1,"t":"2026-09-20T09:05:00Z","e":"fo"#.utf8))
        try handle.close()

        try store.append(.stop(at: Fix.t(10)))

        let load = try store.load(day: Fix.day)
        #expect(load.events.map(\.kind) == [.start, .stop])
        #expect(load.malformedLines == 1)   // exactly one, not two
    }

    @Test func the_file_store_exports_atomically_and_deletes_everything() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileEventStore(root: root)
        try store.append(contentsOf: [
            .start(at: Fix.t(0)),
            .focus(at: Fix.t(0), app: xcode, activity: .coding),
        ])

        let destination = root.appendingPathComponent("export.txt")
        let exported = try store.export(to: destination)
        #expect(exported.events == 2)
        let text = try String(contentsOf: destination, encoding: .utf8)
        #expect(EventLogCodec.decodeLines(text).events.count == 2)

        // Overwriting an existing export must also work (replaceItemAt path).
        try store.append(.stop(at: Fix.t(5)))
        #expect(try store.export(to: destination).events == 3)

        let deletion = try store.deleteEverything()
        #expect(deletion.removedEvents == 3)
        #expect(deletion.removedFiles >= 1)
        #expect(try store.availableDays().isEmpty)
        #expect(FileManager.default.fileExists(atPath: store.eventsDirectory.path))
    }

    @Test func summaries_round_trip_through_the_file_store() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileEventStore(root: root)

        let summary = DailySummary(
            day: Fix.day,
            totalActiveWork: 3600,
            activeWorkByActivity: [Activity.coding.rawValue: 3600],
            applicationDistribution: [xcode: 3600],
            longestContinuousSession: 3600,
            breakCount: 2,
            breakOpportunities: 3,
            honoredOpportunities: 2,
            excludedOpportunities: 1
        )
        try store.writeSummary(summary)
        let back = try store.readSummaries(year: 2026, month: 9)
        #expect(back[Fix.day] == summary)
        #expect(back[Fix.day]?.breakCompliance == 1.0)
    }
}

// MARK: - Narrator

@Suite("summary narrator")
struct SummaryNarratorTests {

    private static let busyDay = DailySummary(
        day: Fix.day,
        totalActiveWork: 8 * 3600,
        activeWorkByActivity: [Activity.coding.rawValue: 8 * 3600 as TimeInterval],
        applicationDistribution: [xcode: 5 * 3600 as TimeInterval, chrome: 3 * 3600 as TimeInterval],
        longestContinuousSession: 97 * 60,
        breakCount: 5,
        breaksAccepted: 4,
        breaksIdleInferred: 1,
        skippedBreakCount: 2,
        breakOpportunities: 9,
        honoredOpportunities: 6,
        excludedOpportunities: 1,
        notificationsDelivered: 8,
        sessionCount: 2
    )

    @Test func selection_is_deterministic_in_the_seed() {
        let narrator = SummaryNarrator(tone: .sarcastic)
        let a = narrator.line(for: Self.busyDay, seed: 42)
        let b = narrator.line(for: Self.busyDay, seed: 42)
        #expect(a == b)
    }

    @Test func different_seeds_produce_different_lines() {
        let narrator = SummaryNarrator(tone: .sarcastic)
        let lines = Set((0..<200).map { narrator.line(for: Self.busyDay, seed: UInt64($0)) })
        #expect(lines.count > 8)
        #expect(lines.count <= narrator.variantCount())
    }

    @Test func every_tone_has_several_variants_and_renders_every_slot() {
        for tone in Tone.allCases {
            let narrator = SummaryNarrator(tone: tone)
            #expect(narrator.variantCount() >= 36)
            for seed in UInt64(0)..<200 {
                let line = narrator.line(for: Self.busyDay, seed: seed)
                #expect(!line.isEmpty)
                #expect(!line.contains("{"))
                #expect(!line.contains("}"))
            }
        }
    }

    /// A template that needs a slot the day cannot fill is simply not selected.
    /// Absence is modelled as absence — no `{top}` ever leaks into a rendered line.
    @Test func a_day_with_no_attributed_app_never_renders_an_app_slot() {
        let bare = DailySummary(day: Fix.day, totalActiveWork: 1800)
        for tone in Tone.allCases {
            let narrator = SummaryNarrator(tone: tone)
            for seed in UInt64(0)..<120 {
                let line = narrator.line(for: bare, seed: seed)
                #expect(!line.contains("{"))
            }
        }
    }

    @Test func an_empty_day_gets_its_own_line_and_never_scolds() {
        let empty = DailySummary(day: Fix.day)
        for tone in Tone.allCases {
            let line = SummaryNarrator(tone: tone).line(for: empty, seed: 7)
            #expect(!line.isEmpty)
            #expect(!line.contains("{"))
        }
    }

    @Test func the_detail_line_always_carries_the_parenthetical() {
        let detail = SummaryNarrator(tone: .friendly).detail(for: Self.busyDay)
        #expect(detail.contains("75% (6 of 8; 1 not asked)"))
        #expect(detail.contains("Active work 8h"))
        #expect(detail.contains("longest stretch 1h 37m"))
        #expect(detail.contains("Xcode 5h"))
    }

    @Test func durations_read_like_a_developer_wrote_them() {
        #expect(DurationText.short(0) == "0m")
        #expect(DurationText.short(59) == "1m")
        #expect(DurationText.short(47 * 60) == "47m")
        #expect(DurationText.short(3600) == "1h")
        #expect(DurationText.short(8 * 3600 + 12 * 60) == "8h 12m")
        #expect(DurationText.long(3600) == "1 hour")
        #expect(DurationText.long(2 * 3600 + 60) == "2 hours 1 minute")
        #expect(DurationText.long(0) == "0 minutes")
    }

    /// The content rails, mechanically (CLAUDE.md §4.5, docs/MESSAGE-ENGINE.md §4.2 and
    /// the L7 banned lexicon). No medical claims, no bodies, no competence, no job
    /// security. This is the same check the corpus lint runs, pointed at this file.
    @Test func every_template_clears_the_content_rails() throws {
        let banned = [
            "fat", "ugly", "weight", "calorie", "skinny",
            "eye strain", "eyestrain", "carpal", "posture", "spine", "wrist", "back pain",
            "health", "healthy", "medical", "doctor", "injury", "strain",
            "burnout", "burned out", "burnt out", "depress", "anxi", "addict", "mental",
            "incompetent", "stupid", "idiot", "lazy", "sloppy",
            "fired", "performance review", "your manager", "promotion",
        ]
        // The trait detector from lint W1: this grammar attaches a label to the person.
        let traitDetector = try Regex(#"(?i)\byou(?:'re| are)\s+(?:a|an|so|such|just)\b"#)

        for text in SummaryNarrator.allTemplateTexts {
            let lower = text.lowercased()
            for stem in banned {
                #expect(!lower.contains(stem), "rail violation: \"\(stem)\" in \(text)")
            }
            #expect(
                text.firstMatch(of: traitDetector) == nil,
                "trait detector (lint W1) hit: \(text)"
            )
            #expect(text.count <= 240, "too long for a notification: \(text)")
        }
    }

    /// SIGKILL is unrecoverable and destroys exactly what the name promises to keep.
    /// SIGHUP is never an escalation rung. Neither may appear anywhere in the copy.
    @Test func the_signal_vocabulary_is_respected() {
        for text in SummaryNarrator.allTemplateTexts {
            #expect(!text.contains("SIGKILL"))
            #expect(!text.uppercased().contains("SIGHUP"))
        }
    }

    @Test func bundle_identifiers_are_spoken_without_asking_the_os() {
        #expect(SummaryNarrator.defaultAppName("com.apple.dt.Xcode") == "Xcode")
        #expect(SummaryNarrator.defaultAppName("com.google.Chrome") == "Chrome")
        #expect(SummaryNarrator.defaultAppName("sigstop") == "sigstop")
        #expect(
            SummaryNarrator.defaultAppName(DailyRollup.unattributedApplication)
                == "an unidentified app"
        )
    }
}
