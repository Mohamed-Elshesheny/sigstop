import Foundation
import Testing

@testable import SigstopCore

/// "Why has it not prompted me", which is the question the owner could not get answered.
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

    /// The incident itself, as the file would look today: open, prompt, close skipped.
    @Test("a skip is named as the reason, with the re-arm spelled out")
    func skipIsExplained() {
        let events: [LoggedEvent] = [
            .start(at: Self.at(0)),
            .breakOpen(at: Self.at(303), cycle: .initial),
            .breakPrompt(at: Self.at(303), cycle: .initial, reason: "SIGTSTP"),
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
            .breakPrompt(at: Self.at(300), cycle: .initial, reason: "SIGTSTP"),
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

    /// `idle_begin` is backdated, so the file is genuinely not in timestamp order. A
    /// reader that trusts file order reports the wrong last event.
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

    /// The whole loop: run the engine, write the log the way the app writes it, and ask
    /// the reader why it is quiet. The answer must be the skip, not a shrug.
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
