import Foundation
import Testing

@testable import SigstopCore

@Suite("the last prompt a ladder allows gets its full time to be answered")
struct LastPromptTests {

    static func delivered(_ effects: [Effect]) -> [PromptRequest] {
        effects.compactMap { if case .deliverPrompt(let r) = $0 { return r } else { return nil } }
    }

    static func closes(_ effects: [Effect]) -> [(CycleID, CycleOutcome)] {
        effects.compactMap { if case .closeCycle(let c, let o) = $0 { return (c, o) } else { return nil } }
    }

    static func withdrawn(_ effects: [Effect]) -> [CycleID] {
        effects.compactMap { if case .withdrawPrompt(let c, _) = $0 { return c } else { return nil } }
    }

    private static func expectAnswerable(
        _ session: inout EngineHarness.Session,
        final: [Effect],
        level: EscalationLevel,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let prompts = delivered(final)
        #expect(prompts.map(\.level) == [level], "the last rung was not the one expected: \(prompts)",
                sourceLocation: sourceLocation)
        guard let prompt = prompts.first else { return }
        #expect(withdrawn(final).isEmpty, "the last prompt was withdrawn in the step that posted it: \(final)",
                sourceLocation: sourceLocation)
        #expect(closes(final).isEmpty, "the cycle closed in the step that posted its last prompt: \(final)",
                sourceLocation: sourceLocation)
        #expect(session.driver.state.openCycle == prompt.cycle, "the cycle is not open to be answered",
                sourceLocation: sourceLocation)

        let postedAt = session.driver.monotonic
        let timeout = session.driver.engine.policy.promptTimeout
        let closing = session.step(untilLimit: 400) { !closes($0).isEmpty }
        let gap = session.driver.monotonic - postedAt
        #expect(closes(closing).map(\.1) == [.ignoredExhausted], "\(closing)", sourceLocation: sourceLocation)
        #expect(gap >= timeout, "the last prompt had \(gap)s to be answered, not \(timeout)s",
                sourceLocation: sourceLocation)
        #expect(delivered(closing).isEmpty, sourceLocation: sourceLocation)
    }

    @Test("L1, L2, snooze, L1, ignore, L2: the fourth prompt stays up for promptTimeout")
    func snoozedFromTheLadder() {
        var session = EngineHarness.Session()
        #expect(Self.delivered(session.stepToPrompt()).map(\.level) == [.first])
        #expect(Self.delivered(session.stepToPrompt()).map(\.level) == [.second])
        session.step(action: .snooze)
        #expect(session.driver.state.name == "snoozed")
        #expect(Self.delivered(session.stepToPrompt()).map(\.level) == [.first])
        let final = session.stepToPrompt()
        Self.expectAnswerable(&session, final: final, level: .second)
    }

    @Test("L1, snooze, L1, L2, L3: the SIGTERM rung is not posted into a closed cycle")
    func snoozedAtTheFirstRung() {
        var session = EngineHarness.Session()
        #expect(Self.delivered(session.stepToPrompt()).map(\.level) == [.first])
        session.step()
        session.step(action: .snooze)
        #expect(session.driver.state.name == "snoozed")
        #expect(Self.delivered(session.stepToPrompt()).map(\.level) == [.first])
        #expect(Self.delivered(session.stepToPrompt()).map(\.level) == [.second])
        let final = session.stepToPrompt(limit: 600)
        Self.expectAnswerable(&session, final: final, level: .third)
    }

    @Test("an unsnoozed ladder still ends promptTimeout after L4, as before")
    func unsnoozedLadderIsUnchanged() {
        var session = EngineHarness.Session()
        #expect(Self.delivered(session.stepToPrompt()).map(\.level) == [.first])
        #expect(Self.delivered(session.stepToPrompt()).map(\.level) == [.second])
        #expect(Self.delivered(session.stepToPrompt(limit: 600)).map(\.level) == [.third])
        let final = session.stepToPrompt(limit: 600)
        Self.expectAnswerable(&session, final: final, level: .incident)
    }

    @Test("a backed-off cycle still closes promptTimeout after its single prompt")
    func backedOffCycleIsUnchanged() {
        var session = EngineHarness.Session()
        session.driver.day.consecutiveIgnoredCycles = 2
        let first = session.stepToPrompt()
        #expect(Self.delivered(first).map(\.level) == [.first])
        let postedAt = session.driver.monotonic
        let closing = session.step(untilLimit: 400) { !Self.closes($0).isEmpty }
        #expect(Self.closes(closing).map(\.1) == [.ignoredExhausted])
        #expect(session.driver.monotonic - postedAt >= session.driver.engine.policy.promptTimeout)
    }
}

@Suite("no step posts a prompt and takes its cycle down")
struct DeliverAndWithdrawPropertyTests {

    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }
        mutating func pick<T>(_ items: [T]) -> T { items[Int.random(in: 0..<items.count, using: &self)] }
    }

    struct Tally {
        var failures: [String] = []
        var cappedBeforeL4 = 0
        var exhausted = 0
        var snoozes = 0
        var breaks = 0
        var pauses = 0
        var blocks = 0
    }

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        return c
    }()

    private static func run(seed: UInt64, steps: Int, tally: inout Tally) {
        var rng = SplitMix(state: seed)
        var settings = EngineHarness.ownerSettings
        settings.maxSnoozesPerBreak = rng.pick([0, 1, 2, 3, 5])
        if rng.chance(0.25) {
            settings.quietHours = QuietHours(startMinute: 23 * 60, endMinute: 23 * 60 + 40, enabled: true)
        }
        var driver = EngineHarness.Driver(settings: settings)
        driver.calendarSystem = utc
        let policy = driver.engine.policy
        driver.day.dayIndex = LocalDay.index(of: driver.now, calendar: utc, boundaryHour: policy.dayBoundaryHour)
        if rng.chance(0.3) { driver.day.consecutiveIgnoredCycles = policy.ignoreBackoffThreshold }
        if rng.chance(0.2) { driver.day.notificationsDelivered = policy.dailyNotificationCap - Int.random(in: 1...8, using: &rng) }

        var lastDelivery: [CycleID: (mono: Double, level: EscalationLevel)] = [:]
        var closed: Set<CycleID> = []
        var idleStepsLeft = 0
        var planned: (action: UserAction, after: Int)?

        for index in 0..<steps {
            var action: UserAction?
            if let p = planned {
                if p.after <= 0 { action = p.action; planned = nil } else { planned = (p.action, p.after - 1) }
            } else if case .breakActive = driver.state, rng.chance(0.01) {
                action = .endBreak
            } else if rng.chance(0.004) {
                let pause = TimeInterval(Int.random(in: 1...60, using: &rng) * 60)
                action = rng.pick([
                    .snooze, .skip, .acceptBreak, .startBreakNow, .endBreak, .resumeApp, .pauseApp(pause),
                ])
            }

            if idleStepsLeft > 0 {
                idleStepsLeft -= 1
                driver.idleSeconds += EngineHarness.Driver.tick
            } else if driver.idleSeconds > 0 {
                if driver.idleSeconds >= policy.qualifyingBreak {
                    driver.sessionEvents = [.breakRecorded(
                        origin: .idleInferred,
                        start: driver.now.addingTimeInterval(-driver.idleSeconds),
                        end: driver.now,
                        duration: driver.idleSeconds
                    )]
                    driver.continuousWork = 0
                }
                driver.idleSeconds = 0
            } else if rng.chance(0.003) {
                idleStepsLeft = Int.random(in: 1...150, using: &rng)
            }
            if rng.chance(0.002) {
                driver.micRunning.toggle()
                tally.blocks += 1
            }

            let workBefore = driver.continuousWork
            let effects = driver.step(action: action)
            if driver.idleSeconds >= policy.microIdleGrace { driver.continuousWork = workBefore }
            if case .snooze = action, case .snoozed = driver.state { tally.snoozes += 1 }
            if case .pauseApp = action { tally.pauses += 1 }

            let posted = LastPromptTests.delivered(effects)
            let takenDown = Set(LastPromptTests.closes(effects).map(\.0))
                .union(LastPromptTests.withdrawn(effects))
            for prompt in posted {
                if takenDown.contains(prompt.cycle) {
                    tally.failures.append("seed \(seed) step \(index): posted \(prompt.signal) and took cycle \(prompt.cycle) down in the same step: \(effects)")
                }
                if closed.contains(prompt.cycle) {
                    tally.failures.append("seed \(seed) step \(index): posted \(prompt.signal) into closed cycle \(prompt.cycle)")
                }
                lastDelivery[prompt.cycle] = (driver.monotonic, prompt.level)
            }
            for (cycle, outcome) in LastPromptTests.closes(effects) {
                closed.insert(cycle)
                guard outcome == .ignoredExhausted else { continue }
                tally.exhausted += 1
                guard let last = lastDelivery[cycle] else {
                    tally.failures.append("seed \(seed) step \(index): cycle \(cycle) exhausted with no prompt")
                    continue
                }
                if last.level != .incident { tally.cappedBeforeL4 += 1 }
                let gap = driver.monotonic - last.mono
                if gap < policy.promptTimeout {
                    tally.failures.append("seed \(seed) step \(index): cycle \(cycle) closed \(gap)s after its last prompt (\(last.level.signalName))")
                }
            }

            if effects.contains(where: { if case .endBreak(_, _, true, _, _) = $0 { return true } else { return false } }) {
                driver.continuousWork = 0
                driver.lastBreakEndedAt = driver.now
                tally.breaks += 1
            }

            guard !posted.isEmpty, planned == nil else { continue }
            let roll = Double.random(in: 0..<1, using: &rng)
            let delay = Int.random(in: 0...30, using: &rng)
            switch roll {
            case ..<0.45: break
            case ..<0.70: planned = (.snooze, delay)
            case ..<0.77: planned = (.skip, delay)
            case ..<0.84: planned = (.acceptBreak, delay)
            case ..<0.88: planned = (.startBreakNow, delay)
            case ..<0.92: planned = (.pauseApp(TimeInterval(delay + 1) * 60), delay)
            case ..<0.97: idleStepsLeft = Int.random(in: 1...150, using: &rng)
            default: planned = (.resumeApp, delay)
            }
        }
    }

    @Test("random ticks and answers never deliver and withdraw or close the same cycle in one step")
    func noStepDeliversAndTakesDown() {
        var tally = Tally()
        for seed in UInt64(1)...64 {
            Self.run(seed: seed &* 0x2545_F491_4F6C_DD1D, steps: 3000, tally: &tally)
        }
        for failure in tally.failures.prefix(5) { Issue.record("\(failure)") }
        #expect(tally.failures.count == 0, "violations, the first five are recorded above")
        #expect(tally.cappedBeforeL4 > 0, "no ladder was capped before L4, so the case this guards was never driven")
        #expect(tally.exhausted > 0 && tally.snoozes > 0 && tally.breaks > 0 && tally.pauses > 0 && tally.blocks > 0,
                "the sequences did not cover the ground: \(tally)")
    }
}
