import Foundation
import Testing

@testable import SigstopCore

@Suite("one line for a status bar, and only when it changes")
struct StatusLineTests {

    private let noon = Date(timeIntervalSince1970: 1_700_000_000)
    private let cycle = CycleID.initial

    private var due: BreakDue { BreakDue(cycle: cycle, dueSince: noon, lastStepMono: 0) }

    @Test("every engine state has the word the menu bar header shows")
    func wordsMatchTheHeader() {
        let working = EngineState.working(WorkingState(armThreshold: 2700))
        #expect(StatusWord.read(state: working, indicator: .working) == "running")
        #expect(StatusWord.read(state: .breakDue(due), indicator: .breakDue) == "break due")
        #expect(StatusWord.read(state: .breakDue(due), indicator: .held) == "break due")

        let escalation = Escalation(
            cycle: cycle, dueSince: noon, ignoredAt: noon,
            notificationsThisCycle: 1, totalElapsed: 600, lastStepMono: 0
        )
        #expect(StatusWord.read(state: .ignored(escalation), indicator: .escalating) == "escalating")

        let snoozed = SnoozedState(cycle: cycle, until: noon, untilMono: 300, index: 1, due: due)
        #expect(StatusWord.read(state: .snoozed(snoozed), indicator: .working) == "snoozed")

        let onBreak = BreakActive(
            cycle: cycle, startedAt: noon, plannedEnd: noon.addingTimeInterval(300),
            startedMono: 0, plannedDuration: 300, origin: .accepted
        )
        #expect(StatusWord.read(state: .breakActive(onBreak), indicator: .onBreak) == "stopped")

        let idle = IdleState(since: noon, cause: .microIdleExceeded)
        #expect(StatusWord.read(state: .idle(idle), indicator: .idle) == "idle")
    }

    @Test("a quiet state is named by its cause, and a pause is a pause whatever the indicator says")
    func quietStatesAreNamedByCause() {
        for cause in QuietCause.allCases {
            let quiet = EngineState.quiet(QuietState(until: noon, cause: cause))
            let expected = cause == .userPaused ? "paused" : cause.title
            #expect(StatusWord.read(state: quiet, indicator: .quiet) == expected)
        }
        let paused = EngineState.quiet(QuietState(until: nil, cause: .userPaused))
        #expect(StatusWord.read(state: paused, indicator: .backedOff) == "paused")
    }

    @Test("stood down is the indicator's word, not the engine's")
    func stoodDown() {
        let working = EngineState.working(WorkingState(armThreshold: 2700, standDown: .backedOff))
        #expect(StatusWord.read(state: working, indicator: .backedOff) == "stood down")
        #expect(StatusWord.read(state: .breakDue(due), indicator: .backedOff) == "stood down")
    }

    @Test("the line is the word, the waiting sentence, and one newline")
    func renderedLine() {
        let line = StatusLine.render(
            word: "running",
            waiting: WaitingLine(.notAskingYet, "the next one is 12m of work away")
        )
        #expect(line == "running \u{00B7} not asking yet, the next one is 12m of work away.\n")
        #expect(line.filter { $0 == "\n" }.count == 1)
        #expect(!line.contains("\u{2014}"))
        #expect(StatusLine.fileName == "status.txt")
    }

    @Test("the ledger writes on a change, never on a repeat, and removes once when switched off")
    func ledgerWritesOnlyOnChange() {
        var ledger = StatusLineLedger()
        let first = "running \u{00B7} not asking yet, the next one is 12m of work away.\n"
        let second = "running \u{00B7} not asking yet, the next one is 11m of work away.\n"

        #expect(ledger.update(enabled: false, line: first) == nil)
        #expect(ledger.update(enabled: true, line: first) == .write(first))
        #expect(ledger.update(enabled: true, line: first) == nil)
        #expect(ledger.update(enabled: true, line: first) == nil)
        #expect(ledger.update(enabled: true, line: second) == .write(second))
        #expect(ledger.update(enabled: false, line: second) == .remove)
        #expect(ledger.update(enabled: false, line: second) == nil)
        #expect(ledger.update(enabled: true, line: second) == .write(second))
    }

    @Test("a failed write is tried again at the next update, even with the same line")
    func failedWriteIsRetried() {
        var ledger = StatusLineLedger()
        let line = "idle \u{00B7} not asking yet, the clock is stopped while you are away.\n"
        #expect(ledger.update(enabled: true, line: line) == .write(line))
        ledger.noteWriteFailed()
        #expect(ledger.update(enabled: true, line: line) == .write(line))
    }

    @Test("switching off after a failed write still removes the file the last good write left")
    func switchOffAfterAFailedWriteStillRemoves() {
        var ledger = StatusLineLedger()
        let line = "idle \u{00B7} not asking yet, the clock is stopped while you are away.\n"
        #expect(ledger.update(enabled: true, line: line) == .write(line))
        ledger.noteWriteFailed()
        #expect(ledger.update(enabled: false, line: line) == .remove)
        #expect(ledger.update(enabled: false, line: line) == nil)

        var neverWritten = StatusLineLedger()
        #expect(neverWritten.update(enabled: true, line: line) == .write(line))
        neverWritten.noteWriteFailed()
        #expect(neverWritten.update(enabled: false, line: line) == .remove)
    }

    @Test("the switch is off by default and survives a settings file that does not know it")
    func settingIsOffByDefault() throws {
        #expect(SigstopSettings.default.statusLineEnabled == false)
        let decoded = try JSONDecoder().decode(SigstopSettings.self, from: Data("{}".utf8))
        #expect(decoded.statusLineEnabled == false)
        let on = try JSONDecoder().decode(
            SigstopSettings.self, from: Data(#"{"statusLineEnabled":true}"#.utf8)
        )
        #expect(on.statusLineEnabled == true)
    }
}
