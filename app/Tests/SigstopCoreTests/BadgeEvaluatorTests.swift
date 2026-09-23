import Foundation
import Testing
@testable import SigstopCore

private enum Fix {
    static let calendar = CalendarDay.utcCalendar
    static let policy = RollupPolicy(
        microIdleGrace: 90,
        qualifyingBreak: 5 * 60,
        longPauseReset: 20 * 60,
        complianceWindow: 10 * 60,
        dayBoundaryHour: 4
    )

    static func day(_ n: Int) -> CalendarDay { CalendarDay(year: 2026, month: 9, day: n) }

    static func at(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026
        c.month = 9
        c.day = day
        c.hour = hour
        c.minute = minute
        c.second = second
        return calendar.date(from: c) ?? Date(timeIntervalSince1970: 1_790_000_000)
    }

    static func summary(
        _ n: Int,
        breaks: Int = 0,
        opportunities: Int = 0,
        honored: Int = 0,
        excluded: Int = 0,
        work: TimeInterval = 0,
        longest: TimeInterval = 0
    ) -> BadgeDay {
        BadgeDay(
            summary: DailySummary(
                day: day(n),
                totalActiveWork: work,
                longestContinuousSession: longest,
                breakCount: breaks,
                breakOpportunities: opportunities,
                honoredOpportunities: honored,
                excludedOpportunities: excluded
            )
        )
    }

    static func events(_ n: Int, _ events: [LoggedEvent]) -> BadgeDay {
        BadgeDay(summary: DailySummary(day: day(n)), events: events)
    }

    static func evaluate(_ days: [BadgeDay], known: BadgeLedger = .empty) -> BadgeLedger {
        BadgeEvaluator.evaluate(
            days: days, calendar: calendar, policy: policy, knownUnlocked: known
        )
    }

    static func acceptedPrompt(
        cycle: Int, promptedAt: Date, afterSeconds: TimeInterval
    ) -> [LoggedEvent] {
        let id = CycleID(rawValue: cycle)
        return [
            .breakPrompt(at: promptedAt, cycle: id, reason: .sigtstp),
            .breakBegin(at: promptedAt.addingTimeInterval(afterSeconds), origin: .accepted, cycle: id),
        ]
    }
}

@Suite("badges · breaks taken")
struct BreakCountBadgeTests {

    @Test("[1]+ Stopped needs one break, and nothing else unlocks with it")
    func first_break() {
        let ledger = Fix.evaluate([Fix.summary(1, breaks: 1)])
        #expect(ledger.contains(.stoppedOnce))
        #expect(ledger.date(for: .stoppedOnce) == Fix.day(1))
        #expect(!ledger.contains(.niceN10))
        #expect(!ledger.contains(.stoppedHundred))
    }

    @Test("A day with no breaks unlocks nothing at all")
    func nothing_from_nothing() {
        let ledger = Fix.evaluate([Fix.summary(1, work: 3 * 3600, longest: 40 * 60)])
        #expect(ledger.isEmpty)
    }

    @Test("ten down does not unlock on nine breaks, and does on the tenth")
    func ten_breaks_not_nine() {
        let nine = (1...9).map { Fix.summary($0, breaks: 1) }
        #expect(!Fix.evaluate(nine).contains(.niceN10))

        let ten = nine + [Fix.summary(10, breaks: 1)]
        let ledger = Fix.evaluate(ten)
        #expect(ledger.contains(.niceN10))
        #expect(ledger.date(for: .niceN10) == Fix.day(10))
    }

    @Test("[100]+ Stopped does not unlock on ninety nine")
    func hundred_breaks_not_ninety_nine() {
        #expect(!Fix.evaluate([Fix.summary(1, breaks: 99)]).contains(.stoppedHundred))

        let ledger = Fix.evaluate([Fix.summary(1, breaks: 99), Fix.summary(2, breaks: 1)])
        #expect(ledger.contains(.stoppedHundred))
        #expect(ledger.date(for: .stoppedHundred) == Fix.day(2))
    }
}

@Suite("badges · every break offered was taken")
struct CleanDayBadgeTests {

    private func cleanDay(_ n: Int) -> BadgeDay {
        Fix.summary(n, breaks: 3, opportunities: 3, honored: 3)
    }

    @Test("nothing blocked wants one day where nothing was deferred and nothing left pending")
    func one_clean_day() {
        let ledger = Fix.evaluate([cleanDay(1)])
        #expect(ledger.contains(.unmasked))
        #expect(!ledger.contains(.provablyHalts))
    }

    @Test("A day that missed one opportunity is not clean")
    func one_missed_is_not_clean() {
        let ledger = Fix.evaluate([Fix.summary(1, breaks: 2, opportunities: 3, honored: 2)])
        #expect(!ledger.contains(.unmasked))
    }

    @Test("Excluded opportunities come out of the denominator, not the numerator")
    func quiet_hours_do_not_break_the_day() {
        let ledger = Fix.evaluate([
            Fix.summary(1, breaks: 2, opportunities: 3, honored: 2, excluded: 1)
        ])
        #expect(ledger.contains(.unmasked))
    }

    @Test("A day the app never asked about is not a clean day")
    func no_opportunities_is_not_a_clean_day() {
        let ledger = Fix.evaluate([Fix.summary(1, breaks: 2, opportunities: 0, honored: 0)])
        #expect(!ledger.contains(.unmasked))
        #expect(ledger.contains(.stoppedOnce))
    }

    @Test("always halts wants ten of them, and nine is nine")
    func ten_clean_days_not_nine() {
        let nine = (1...9).map(cleanDay)
        #expect(!Fix.evaluate(nine).contains(.provablyHalts))

        let ledger = Fix.evaluate(nine + [cleanDay(10)])
        #expect(ledger.contains(.provablyHalts))
        #expect(ledger.date(for: .provablyHalts) == Fix.day(10))
    }
}

@Suite("badges · no handler")
struct ReflexBadgeTests {

    private func fastDays(_ count: Int, seconds: TimeInterval) -> [BadgeDay] {
        (1...count).map { n in
            Fix.events(n, Fix.acceptedPrompt(
                cycle: n, promptedAt: Fix.at(n, 10), afterSeconds: seconds
            ))
        }
    }

    @Test("Five accepts inside fifteen seconds")
    func five_fast_accepts() {
        let ledger = Fix.evaluate(fastDays(5, seconds: 4))
        #expect(ledger.contains(.sigDFL))
        #expect(ledger.date(for: .sigDFL) == Fix.day(5))
    }

    @Test("Four is not five")
    func four_is_not_five() {
        #expect(!Fix.evaluate(fastDays(4, seconds: 4)).contains(.sigDFL))
    }

    @Test("Sixteen seconds is deliberation, not a default disposition")
    func just_outside_the_window() {
        #expect(!Fix.evaluate(fastDays(5, seconds: 16)).contains(.sigDFL))
        #expect(Fix.evaluate(fastDays(5, seconds: 15)).contains(.sigDFL))
    }

    @Test("A prompt that was withheld never asked anything, so nothing was answered fast")
    func a_deferred_prompt_does_not_count() {
        let days = (1...5).map { n -> BadgeDay in
            let cycle = CycleID(rawValue: n)
            return Fix.events(n, [
                .breakPrompt(at: Fix.at(n, 10), cycle: cycle, reason: .sigtstp, deferred: .inferredMeeting),
                .breakBegin(at: Fix.at(n, 10, 0, 3), origin: .accepted, cycle: cycle),
            ])
        }
        #expect(!Fix.evaluate(days).contains(.sigDFL))
    }

    @Test("Walking away is a break, but it is not a default disposition")
    func idle_inferred_breaks_do_not_count() {
        let days = (1...5).map { n -> BadgeDay in
            let cycle = CycleID(rawValue: n)
            return Fix.events(n, [
                .breakPrompt(at: Fix.at(n, 10), cycle: cycle, reason: .sigtstp),
                .breakBegin(at: Fix.at(n, 10, 0, 3), origin: .idleInferred, cycle: cycle),
            ])
        }
        #expect(!Fix.evaluate(days).contains(.sigDFL))
    }
}

@Suite("badges · uncatchable")
struct SigstopBadgeTests {

    @Test("One prompt that reached the fourth rung is enough")
    func reaching_sigstop() {
        let ledger = Fix.evaluate([
            Fix.events(1, [
                .breakPrompt(at: Fix.at(1, 11), cycle: .initial, reason: .sigtstp),
                .breakPrompt(at: Fix.at(1, 11, 20), cycle: .initial, reason: .sigstop),
            ])
        ])
        #expect(ledger.contains(.einval))
    }

    @Test("Three rungs is not four")
    func stopping_at_sigterm() {
        let ledger = Fix.evaluate([
            Fix.events(1, [
                .breakPrompt(at: Fix.at(1, 11), cycle: .initial, reason: .sigtstp),
                .breakPrompt(at: Fix.at(1, 11, 10), cycle: .initial, reason: .sigint),
                .breakPrompt(at: Fix.at(1, 11, 20), cycle: .initial, reason: .sigterm),
            ])
        ])
        #expect(!ledger.contains(.einval))
    }

    @Test("A SIGSTOP rung that was never delivered never reached anyone")
    func a_withheld_sigstop_does_not_count() {
        let ledger = Fix.evaluate([
            Fix.events(1, [
                .breakPrompt(
                    at: Fix.at(1, 11), cycle: .initial, reason: .sigstop, deferred: .quietHours
                )
            ])
        ])
        #expect(!ledger.contains(.einval))
    }

    @Test("The rung is named by the ladder, not by a literal in the evaluator")
    func the_name_comes_from_the_ladder() {
        #expect(EscalationLevel.incident.signalName == "SIGSTOP")
    }
}

@Suite("badges · yielded")
struct YieldBadgeTests {

    @Test("Four hours of work with nothing past the hour")
    func a_yielded_day() {
        let ledger = Fix.evaluate([
            Fix.summary(1, work: 5 * 3600, longest: 52 * 60)
        ])
        #expect(ledger.contains(.schedYield))
    }

    @Test("One stretch past the hour loses the day")
    func one_long_stretch_loses_it() {
        let ledger = Fix.evaluate([
            Fix.summary(1, work: 8 * 3600, longest: 61 * 60)
        ])
        #expect(!ledger.contains(.schedYield))
    }

    @Test("Exactly an hour still counts, the badge is for not passing it")
    func exactly_an_hour() {
        #expect(Fix.evaluate([Fix.summary(1, work: 4 * 3600, longest: 3600)]).contains(.schedYield))
    }

    @Test("A short day is not a yielded day, it is a short day")
    func short_days_do_not_count() {
        let ledger = Fix.evaluate([Fix.summary(1, work: 3 * 3600, longest: 20 * 60)])
        #expect(!ledger.contains(.schedYield))
    }

    @Test("A day with no work at all cannot win it by having no long stretch")
    func an_empty_day_does_not_count() {
        #expect(!Fix.evaluate([Fix.summary(1)]).contains(.schedYield))
    }
}

@Suite("badges · the two clock badges")
struct ClockBadgeTests {

    private func breakAt(_ day: Int, hour: Int) -> [LoggedEvent] {
        [
            .breakBegin(at: Fix.at(day, hour), origin: .accepted, cycle: .initial),
            .breakEnd(
                at: Fix.at(day, hour, 6), origin: .accepted,
                durationSeconds: 6 * 60, cycle: .initial
            ),
        ]
    }

    @Test("early return wants five separate days with a break before 10:00")
    func five_early_days() {
        let four = (1...4).map { Fix.events($0, breakAt($0, hour: 8)) }
        #expect(!Fix.evaluate(four).contains(.earlyReturn))

        let ledger = Fix.evaluate(four + [Fix.events(5, breakAt(5, hour: 9))])
        #expect(ledger.contains(.earlyReturn))
        #expect(ledger.date(for: .earlyReturn) == Fix.day(5))
    }

    @Test("Five breaks on one day is one day")
    func five_breaks_one_day_is_not_five_days() {
        let many = (0..<5).flatMap { i -> [LoggedEvent] in
            [.breakBegin(at: Fix.at(1, 6, i * 5), origin: .accepted, cycle: .initial)]
        }
        #expect(!Fix.evaluate([Fix.events(1, many)]).contains(.earlyReturn))
    }

    @Test("A break at 10:00 is not an early return")
    func ten_is_not_early() {
        let days = (1...5).map { Fix.events($0, breakAt($0, hour: 10)) }
        #expect(!Fix.evaluate(days).contains(.earlyReturn))
    }

    @Test("still running wants five breaks after 01:00, which belong to the previous logical day")
    func five_late_nights() {
        let days = (1...5).map { n in
            BadgeDay(
                summary: DailySummary(day: Fix.day(n)),
                events: breakAt(n + 1, hour: 2)
            )
        }
        let ledger = Fix.evaluate(days)
        #expect(ledger.contains(.nohup))
        #expect(!ledger.contains(.earlyReturn))
    }

    @Test("Midnight is not yet a late break; 01:00 is")
    func the_window_opens_at_one() {
        let midnight = (1...5).map { n in
            BadgeDay(summary: DailySummary(day: Fix.day(n)), events: breakAt(n + 1, hour: 0))
        }
        #expect(!Fix.evaluate(midnight).contains(.nohup))

        let one = (1...5).map { n in
            BadgeDay(summary: DailySummary(day: Fix.day(n)), events: breakAt(n + 1, hour: 1))
        }
        #expect(Fix.evaluate(one).contains(.nohup))
    }

    @Test("Events outside the logical day are clipped, not counted")
    func events_are_clipped_to_the_day() {
        let day = BadgeDay(
            summary: DailySummary(day: Fix.day(1)),
            events: breakAt(1, hour: 3)
        )
        #expect(!Fix.evaluate([day]).contains(.nohup))
    }
}

@Suite("badges · the ledger")
struct BadgeLedgerTests {

    @Test("A badge keeps the day it was actually earned, not the day it was noticed")
    func the_date_is_the_day_the_evidence_completed() {
        let days = (1...9).map { Fix.summary($0, breaks: 1) }
            + [Fix.summary(10, breaks: 1)]
            + (11...20).map { Fix.summary($0, breaks: 1) }
        let ledger = Fix.evaluate(days)
        #expect(ledger.date(for: .niceN10) == Fix.day(10))
        #expect(ledger.date(for: .stoppedOnce) == Fix.day(1))
    }

    @Test("Evaluating is a union: it never removes what it was handed")
    func evaluation_only_adds() {
        var known = BadgeLedger()
        known.record(.provablyHalts, on: Fix.day(1))
        let ledger = Fix.evaluate([Fix.summary(9, breaks: 1)], known: known)
        #expect(ledger.contains(.provablyHalts))
        #expect(ledger.date(for: .provablyHalts) == Fix.day(1))
        #expect(ledger.contains(.stoppedOnce))
    }

    @Test("Recording again never moves a date later")
    func a_date_never_moves_forward() {
        var ledger = BadgeLedger()
        ledger.record(.unmasked, on: Fix.day(5))
        ledger.record(.unmasked, on: Fix.day(9))
        #expect(ledger.date(for: .unmasked) == Fix.day(5))
        ledger.record(.unmasked, on: Fix.day(2))
        #expect(ledger.date(for: .unmasked) == Fix.day(2))
    }

    @Test("The file is a flat, readable map of badge id to day")
    func the_file_is_readable() throws {
        var ledger = BadgeLedger()
        ledger.record(.stoppedOnce, on: Fix.day(20))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let text = String(decoding: try encoder.encode(ledger), as: UTF8.self)
        #expect(text.contains("\"stopped-1\" : \"2026-09-20\""))

        let back = try JSONDecoder().decode(BadgeLedger.self, from: Data(text.utf8))
        #expect(back == ledger)
    }

    @Test("A badge this build has never heard of is kept, not dropped")
    func unknown_ids_survive_a_round_trip() throws {
        let text = #"{"v":1,"unlocked":{"stopped-1":"2026-09-20","from-the-future":"2027-01-01"}}"#
        let ledger = try JSONDecoder().decode(BadgeLedger.self, from: Data(text.utf8))
        #expect(ledger.count == 1)
        let written = String(decoding: try JSONEncoder().encode(ledger), as: UTF8.self)
        #expect(written.contains("from-the-future"))
    }

    @Test("newlyUnlocked reports the difference in catalogue order")
    func newly_unlocked_is_ordered() {
        var before = BadgeLedger()
        before.record(.stoppedOnce, on: Fix.day(1))
        var after = before
        after.record(.unmasked, on: Fix.day(2))
        after.record(.niceN10, on: Fix.day(2))
        #expect(after.newlyUnlocked(since: before) == [.niceN10, .unmasked])
    }
}

@Suite("badges · earned is earned")
struct BadgeRetentionTests {

    @Test("An unlocked badge survives the log it was computed from being pruned")
    func a_badge_outlives_its_evidence() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sigstop-badges-\(UUID().uuidString)", isDirectory: true)
        let store = try FileEventStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let clock = MutableTimeSource(now: Fix.at(1, 12))
        let events = Fix.acceptedPrompt(cycle: 1, promptedAt: Fix.at(1, 10), afterSeconds: 3)
            + [
                .breakEnd(
                    at: Fix.at(1, 10, 8), origin: .accepted,
                    durationSeconds: 8 * 60, cycle: .initial
                )
            ]
        try store.append(contentsOf: events)

        let day = BadgeDay.from(
            day: Fix.day(1), events: events, policy: Fix.policy, calendar: Fix.calendar
        )
        let earned = Fix.evaluate([day])
        #expect(earned.contains(.stoppedOnce))
        try store.writeBadges(earned)

        clock.advance(by: 30 * 86_400)
        let report = try store.prune(retentionDays: 7, asOf: clock.now)
        #expect(!report.isEmpty)
        #expect(try store.availableDays().isEmpty)

        let reloaded = try store.readBadges()
        #expect(reloaded.contains(.stoppedOnce))
        #expect(reloaded.date(for: .stoppedOnce) == Fix.day(1))

        let afterPrune = BadgeEvaluator.evaluate(
            days: [], calendar: Fix.calendar, policy: Fix.policy, knownUnlocked: reloaded
        )
        #expect(afterPrune.contains(.stoppedOnce))
        #expect(afterPrune.date(for: .stoppedOnce) == Fix.day(1))
    }

    @Test("Deleting everything really does delete the badges too")
    func delete_means_delete() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sigstop-badges-\(UUID().uuidString)", isDirectory: true)
        let store = try FileEventStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        var ledger = BadgeLedger()
        ledger.record(.stoppedOnce, on: Fix.day(1))
        try store.writeBadges(ledger)
        #expect(try store.readBadges().contains(.stoppedOnce))

        _ = try store.deleteEverything()
        #expect(try store.readBadges().isEmpty)
    }
}

@Suite("badges · the rule")
struct BadgeDesignRuleTests {

    @Test("A ten hour day with no breaks unlocks nothing")
    func nothing_rewards_working_longer() {
        let grind = Fix.summary(
            1,
            breaks: 0,
            opportunities: 6,
            honored: 0,
            work: 10 * 3600,
            longest: 10 * 3600
        )
        #expect(Fix.evaluate([grind]).isEmpty)
    }

    @Test("Every badge has copy and a distinct id")
    func the_catalogue_is_complete() {
        #expect(Badge.all.count == BadgeID.allCases.count)
        #expect(Set(Badge.all.map(\.id)).count == Badge.all.count)
        for badge in Badge.all {
            #expect(!badge.title.isEmpty)
            #expect(!badge.blurb.isEmpty)
            #expect(!badge.lockedHint.isEmpty)
            #expect(!badge.isEarned(BadgeEvidence()))
        }
    }

    @Test("Every badge keeps the motif it was given")
    func the_motifs_are_fixed() {
        let expected: [BadgeID: BadgeMotif] = [
            .stoppedOnce: .jobLine,
            .niceN10: .descent,
            .unmasked: .liftedGate,
            .provablyHalts: .tombstone,
            .sigDFL: .straightThrough,
            .einval: .escalation,
            .schedYield: .handoff,
            .earlyReturn: .earlyExit,
            .nohup: .detached,
            .stoppedHundred: .jobLineFull,
        ]
        for badge in Badge.all {
            #expect(badge.motif == expected[badge.id])
        }
    }

    @Test("No two badges share a motif")
    func the_motifs_are_distinct() {
        #expect(Set(Badge.all.map(\.motif)).count == Badge.all.count)
    }
}
