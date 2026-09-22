import Foundation
import Testing

@testable import SigstopCore

@Suite("the panel always says what it is waiting for")
struct WaitingLineTests {

    private let noon = Date(timeIntervalSince1970: 1_700_000_000)
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        c.locale = Locale(identifier: "en_GB")
        return c
    }

    private func calendar(_ identifier: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        c.locale = Locale(identifier: identifier)
        return c
    }

    private func read(
        _ state: EngineState,
        gate: GateReason? = nil,
        continuousWork: TimeInterval = 0,
        audioInputRunning: Bool = false,
        micIgnoredUntil: Date? = nil,
        monotonic: Double = 0,
        policy: BreakPolicy = .default,
        settings: SigstopSettings = .default,
        calendar: Calendar? = nil
    ) -> WaitingLine {
        WaitingLine.read(
            WaitingLine.Reading(
                state: state,
                gate: gate,
                continuousWork: continuousWork,
                audioInputRunning: audioInputRunning,
                micIgnoredUntil: micIgnoredUntil,
                now: noon,
                monotonic: monotonic,
                policy: policy,
                settings: settings,
                calendar: calendar ?? self.calendar
            )
        )
    }

    @Test("no state the engine can reach leaves the panel with nothing to say")
    func totalOverTheStateSpace() {
        let cycle = CycleID.initial
        var due = BreakDue(cycle: cycle, dueSince: noon, lastStepMono: 0)
        due.uncorroboratedAudioElapsed = 5 * 60
        let escalation = Escalation(
            cycle: cycle, dueSince: noon, ignoredAt: noon,
            notificationsThisCycle: 1, totalElapsed: 600, lastStepMono: 0
        )

        var states: [EngineState] = [
            .working(WorkingState(armThreshold: 45 * 60)),
            .working(WorkingState(armThreshold: 65 * 60, standDown: .skipped)),
            .working(WorkingState(armThreshold: 55 * 60, standDown: .cycleExpired)),
            .working(WorkingState(armThreshold: 45 * 60, cooldownUntilMono: 600, standDown: .backedOff)),
            .working(WorkingState(armThreshold: 45 * 60, cooldownUntilMono: 600, standDown: .ladderExhausted)),
            .breakDue(due),
            .ignored(escalation),
            .snoozed(SnoozedState(cycle: cycle, until: noon, untilMono: 0, index: 0, due: due)),
            .idle(IdleState(since: noon, cause: .microIdleExceeded)),
            .breakActive(BreakActive(
                cycle: cycle, startedAt: noon, plannedEnd: noon, startedMono: 0,
                plannedDuration: 300, origin: .accepted
            )),
        ]
        states += QuietCause.allCases.map { .quiet(QuietState(until: noon, cause: $0)) }

        var gates: [GateReason?] = [nil]
        gates += GateReason.allCases.map { $0 }

        for state in states {
            for gate in gates {
                let line = read(state, gate: gate)
                #expect(line != .unexplained, "\(state.name) with \(gate?.rawValue ?? "no gate") has no words")
                #expect(!line.body.isEmpty)
                #expect(!line.text.contains("—"), "no em dashes in a user-facing string")
                #expect(line.text.hasSuffix("."))
            }
        }
    }

    @Test("the backed-off cooldown names the backoff and says when it ends")
    func backedOffCooldownCarriesItsDeadline() {
        let line = read(
            .working(WorkingState(armThreshold: 45 * 60, cooldownUntilMono: 1500, standDown: .backedOff)),
            continuousWork: 169 * 60,
            monotonic: 0
        )
        #expect(line.claim == .notAskingYet)
        #expect(line.body.contains("the last few went unanswered"))
        #expect(line.text.contains("nothing new until 22:38"), "\(line.text)")
    }

    @Test("a cycle that expired unseen is not reported as a skip")
    func staleRearmIsNotASkip() {
        let skipped = read(.working(WorkingState(armThreshold: 65 * 60, standDown: .skipped)))
        let expired = read(.working(WorkingState(armThreshold: 55 * 60, standDown: .cycleExpired)))
        #expect(skipped.body != expired.body)
        #expect(skipped.body.contains("you waved the last one off"))
        #expect(expired.body.contains("timed out unseen"))
        #expect(!expired.body.contains("waved"))
    }

    @Test("a microphone the app is starting to doubt says so, with a deadline")
    func uncorroboratedMicrophoneSaysHowLongAndUntilWhen() {
        var due = BreakDue(cycle: .initial, dueSince: noon, lastStepMono: 0)
        due.uncorroboratedAudioElapsed = 12 * 60
        let line = read(.breakDue(due), gate: .audioInputInUse)

        #expect(line.claim == .holdingOff)
        #expect(line.body.contains("12m"))
        #expect(line.body.contains("nothing call-shaped"))
        #expect(line.text.contains("It stops holding at 22:21"), "\(line.text)")
    }

    @Test("a microphone that just started reads as an ordinary call block")
    func freshMicrophoneReadsPlainly() {
        var due = BreakDue(cycle: .initial, dueSince: noon, lastStepMono: 0)
        due.uncorroboratedAudioElapsed = 30
        let line = read(.breakDue(due), gate: .audioInputInUse)
        #expect(line.body == GateReason.audioInputInUse.summary)
    }

    @Test("ignoring an input device is confirmed in words while the device is still open")
    func theManualOverrideAnswersBack() {
        let line = read(
            .working(WorkingState(armThreshold: 45 * 60)),
            audioInputRunning: true,
            micIgnoredUntil: noon.addingTimeInterval(1800)
        )
        #expect(line.body.contains("taking your word for it"))
        #expect(line.text.contains("22:43"), "\(line.text)")
    }

    @Test("a working engine reports the work clock, never a block")
    func workingNeverBorrowsABlockReason() {
        let line = read(
            .working(WorkingState(armThreshold: 45 * 60)),
            gate: .audioInputInUse,
            continuousWork: 33 * 60
        )
        #expect(line.claim == .notAskingYet)
        #expect(line.body == "the next one is 12m of work away")
    }

    @Test("every stand-down cause has its own words")
    func everyStandDownCauseHasItsOwnWords() {
        let causes = StandDownCause.allCases
        #expect(causes.count == 4, "a new stand-down cause needs words of its own")
        #expect(Set(causes.map(\.summary)).count == causes.count, "two causes share a sentence")
        for cause in causes {
            #expect(!cause.summary.isEmpty)
            #expect(!cause.summary.contains("—"))
        }
    }

    @Test("a break, a pause, a snooze and a quiet cause all outrank the mic confirmation")
    func theMicConfirmationNeverSpeaksForAnotherState() {
        let ignored = noon.addingTimeInterval(1800)
        let states: [EngineState] = [
            .breakActive(BreakActive(
                cycle: .initial, startedAt: noon, plannedEnd: noon.addingTimeInterval(300),
                startedMono: 0, plannedDuration: 300, origin: .accepted
            )),
            .snoozed(SnoozedState(
                cycle: .initial, until: noon.addingTimeInterval(600), untilMono: 600, index: 0,
                due: BreakDue(cycle: .initial, dueSince: noon, lastStepMono: 0)
            )),
            .idle(IdleState(since: noon, cause: .microIdleExceeded)),
        ] + QuietCause.allCases.map { .quiet(QuietState(until: noon, cause: $0)) }

        for state in states {
            let line = read(state, audioInputRunning: true, micIgnoredUntil: ignored)
            #expect(
                !line.body.contains("taking your word for it"),
                "\(state.name) had its own reason and the mic answered for it: \(line.text)"
            )
        }
    }

    @Test("a stand-down outranks the mic confirmation")
    func theMicConfirmationNeverSpeaksOverAStandDown() {
        let line = read(
            .working(WorkingState(armThreshold: 45 * 60, cooldownUntilMono: 1500, standDown: .backedOff)),
            audioInputRunning: true,
            micIgnoredUntil: noon.addingTimeInterval(1800)
        )
        #expect(line.body.contains("the last few went unanswered"), "\(line.text)")
    }

    @Test("the clock follows the reader's locale, like the row above it")
    func theClockFollowsTheLocale() {
        let due = SnoozedState(
            cycle: .initial, until: noon.addingTimeInterval(1800), untilMono: 1800, index: 0,
            due: BreakDue(cycle: .initial, dueSince: noon, lastStepMono: 0)
        )
        let british = read(.snoozed(due), calendar: calendar("en_GB"))
        #expect(british.text.contains("22:43"), "\(british.text)")

        let american = read(.snoozed(due), calendar: calendar("en_US"))
        #expect(american.text.contains("10:43"), "\(american.text)")
        #expect(american.text.contains("PM"), "\(american.text)")
        #expect(!american.text.contains("22:43"), "\(american.text)")
    }

    @Test("the three claims stay three claims")
    func claimsAreDistinct() {
        #expect(Set(WaitingLine.Claim.allCases.map(\.prefix)).count == 3)
    }
}
