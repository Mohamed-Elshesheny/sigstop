import Foundation
import Testing

@testable import SigstopCore

@Suite("the log can answer why it is quiet")
struct PromptOutlookTests {

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return c
    }

    private static var policy: BreakPolicy {
        var settings = SigstopSettings()
        settings.workIntervalMinutes = 5
        settings.breakDurationMinutes = 5
        return BreakPolicy(settings: settings)
    }

    private static func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

    @Test("a skip is named as the reason, with the re-arm spelled out")
    func skipIsExplained() {
        let events: [LoggedEvent] = [
            .start(at: Self.at(0)),
            .breakOpen(at: Self.at(303), cycle: .initial),
            .breakPrompt(at: Self.at(303), cycle: .initial, reason: .sigtstp),
            .cycleClose(at: Self.at(308), cycle: .initial, outcome: .skipped),
        ]
        let outlook = PromptOutlook.read(
            events: events, now: Self.at(1200), policy: Self.policy, calendar: Self.utc
        )
        #expect(outlook.headline.contains("waved the last one off"))
        #expect(outlook.detail.contains { $0.contains("25 minutes") }, "5 target plus 20 re-arm")
        #expect(outlook.detail.contains { $0.contains("20 minutes") })
    }

    @Test("an open cycle reports the gate that is holding it")
    func openCycleReportsTheGate() {
        let events: [LoggedEvent] = [
            .start(at: Self.at(0)),
            .breakOpen(at: Self.at(300), cycle: .initial),
            .breakPrompt(at: Self.at(300), cycle: .initial, reason: .sigtstp),
            .gate(at: Self.at(310), reason: .audioInputInUse, cycle: .initial),
        ]
        let outlook = PromptOutlook.read(
            events: events, now: Self.at(900), policy: Self.policy, calendar: Self.utc
        )
        #expect(outlook.headline.contains("due right now"))
        #expect(outlook.detail.contains { $0.contains("audio input device is running") })
    }

    @Test("an exhausted ladder names the cooldown rather than looking stuck")
    func exhaustedLadderIsExplained() {
        let events: [LoggedEvent] = [
            .start(at: Self.at(0)),
            .breakOpen(at: Self.at(300), cycle: .initial),
            .cycleClose(at: Self.at(2600), cycle: .initial, outcome: .ignoredExhausted),
        ]
        let outlook = PromptOutlook.read(
            events: events, now: Self.at(2700), policy: Self.policy, calendar: Self.utc
        )
        #expect(outlook.headline.contains("ran out of rungs"))
        #expect(outlook.detail.contains { $0.contains("25 minutes") })
    }

    @Test("a stopped app says so before anything else")
    func stoppedAppIsNamedFirst() {
        let events: [LoggedEvent] = [
            .start(at: Self.at(0)),
            .breakOpen(at: Self.at(300), cycle: .initial),
            .stop(at: Self.at(400)),
        ]
        let outlook = PromptOutlook.read(
            events: events, now: Self.at(900), policy: Self.policy, calendar: Self.utc
        )
        #expect(outlook.headline.contains("not running"))
    }

    @Test("an out of order file is still read in time order")
    func unsortedFileIsSorted() {
        let events: [LoggedEvent] = [
            .start(at: Self.at(0)),
            .breakOpen(at: Self.at(300), cycle: .initial),
            .cycleClose(at: Self.at(305), cycle: .initial, outcome: .skipped),
            .idleBegin(at: Self.at(250)),
        ]
        let outlook = PromptOutlook.read(
            events: events, now: Self.at(900), policy: Self.policy, calendar: Self.utc
        )
        #expect(outlook.headline.contains("waved the last one off"))
    }

    @Test("a relaunch ends an open cycle, and the reader says so")
    func aRelaunchOrphansAnOpenCycle() {
        let events: [LoggedEvent] = [
            .start(at: Self.at(0)),
            .breakOpen(at: Self.at(300), cycle: .initial),
            .breakPrompt(at: Self.at(300), cycle: .initial, reason: .sigtstp),
            .start(at: Self.at(3900)),
        ]
        let outlook = PromptOutlook.read(
            events: events, now: Self.at(3960), policy: Self.policy, calendar: Self.utc
        )
        #expect(!outlook.headline.contains("due right now"), "\(outlook.headline)")
        #expect(
            (outlook.detail + [outlook.headline]).contains { $0.contains("restart") },
            "the relaunch that dropped the cycle has to be named"
        )
    }

    @Test("a stale open cycle is reported as a log that stopped, not as a break due now")
    func aStaleOpenCycleIsNotPresentTense() {
        let events: [LoggedEvent] = [
            .start(at: Self.at(0)),
            .breakOpen(at: Self.at(300), cycle: .initial),
            .breakPrompt(at: Self.at(300), cycle: .initial, reason: .sigtstp),
        ]
        let outlook = PromptOutlook.read(
            events: events, now: Self.at(300 + 25 * 3600), policy: Self.policy, calendar: Self.utc
        )
        #expect(!outlook.headline.contains("due right now"), "\(outlook.headline)")
        #expect(outlook.headline.contains("22:18:20"), "the last line’s time is the honest anchor")
    }

    @Test("a snoozed prompt is named, with the time it comes back")
    func aSnoozeIsExplained() {
        var settings = EngineHarness.ownerSettings
        settings.snoozeMinutes = 15
        var session = EngineHarness.Session(settings: settings)
        session.stepToPrompt()
        session.step(action: .snooze)
        session.step(times: 120)

        let outlook = PromptOutlook.read(
            events: session.log.lines,
            now: session.driver.now,
            policy: BreakPolicy(settings: settings),
            calendar: Self.utc
        )
        #expect(!outlook.headline.contains("due right now"), "\(outlook.headline)")
        #expect(outlook.headline.contains("snooze"), "\(outlook.headline)")
        #expect(
            outlook.detail.contains { $0.contains("SIGALRM") },
            "the vocabulary is the product's own"
        )
    }

    @Test("a snooze left behind by a dead process reads as a stopped log")
    func aStaleSnoozeIsNotPending() {
        let events: [LoggedEvent] = [
            .start(at: Self.at(0)),
            .breakOpen(at: Self.at(300), cycle: .initial),
            .breakPrompt(at: Self.at(300), cycle: .initial, reason: .sigtstp),
            .breakResponse(at: Self.at(310), cycle: .initial, action: .snoozed, snoozeSeconds: 900),
            .gate(at: Self.at(910), reason: .userSnoozed, cycle: .initial),
        ]
        let outlook = PromptOutlook.read(
            events: events, now: Self.at(310 + 800), policy: Self.policy, calendar: Self.utc
        )
        #expect(outlook.headline.contains("snoozed"), "\(outlook.headline)")

        let dead = PromptOutlook.read(
            events: events, now: Self.at(310 + 25 * 3600), policy: Self.policy, calendar: Self.utc
        )
        #expect(dead.headline.contains("log stops"), "\(dead.headline)")
    }

    @Test("an ignored prompt says the ladder is climbing and which rung it reached")
    func anIgnoredPromptIsExplained() {
        var session = EngineHarness.Session()
        session.stepToPrompt()
        session.step(untilLimit: 60) { effects in
            effects.contains { if case .recordIgnoredPrompt = $0 { return true } else { return false } }
        }
        let outlook = PromptOutlook.read(
            events: session.log.lines,
            now: session.driver.now,
            policy: BreakPolicy(settings: EngineHarness.ownerSettings),
            calendar: Self.utc
        )
        #expect(!outlook.headline.contains("due right now"), "\(outlook.headline)")
        #expect(outlook.headline.contains("SIGTSTP"), "\(outlook.headline)")
    }

    @Test("a break in progress is not a break that is due")
    func aRunningBreakIsNotDue() {
        let events: [LoggedEvent] = [
            .start(at: Self.at(0)),
            .breakOpen(at: Self.at(300), cycle: .initial),
            .breakPrompt(at: Self.at(300), cycle: .initial, reason: .sigtstp),
            .breakBegin(at: Self.at(303), origin: .accepted, cycle: .initial),
            .breakResponse(at: Self.at(303), cycle: .initial, action: .taken),
        ]
        let outlook = PromptOutlook.read(
            events: events, now: Self.at(400), policy: Self.policy, calendar: Self.utc
        )
        #expect(!outlook.headline.contains("due right now"), "\(outlook.headline)")
        #expect(outlook.headline.contains("break"), "\(outlook.headline)")
    }

    @Test("driving the real engine produces a log that explains itself")
    func endToEnd() {
        var session = EngineHarness.Session()
        session.stepToPrompt()
        session.step(action: .skip)
        session.step(times: 10)

        let outlook = PromptOutlook.read(
            events: session.log.lines,
            now: session.driver.now,
            policy: BreakPolicy(settings: EngineHarness.ownerSettings),
            calendar: Self.utc
        )
        #expect(outlook.headline.contains("waved the last one off"))
    }
}
