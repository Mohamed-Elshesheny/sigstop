import Foundation
import Testing

@testable import SigstopCore

/// The scripted world every engine test in this target runs in.
///
/// One driver, one set of settings, one log replay, so two suites cannot quietly disagree
/// about what the shipping engine does. Nothing is mocked but the clock and the machine's
/// signals: `SigstopCore` takes its time from the caller (CLAUDE.md §3.2), which is what
/// makes a scripted hour run in microseconds.
enum EngineHarness {

    // MARK: - The world

    /// The owner's settings, read from
    /// `~/Library/Application Support/dev.sigstop.app/settings.json` on the machine that
    /// produced the log. Five minute interval, quiet hours off, panel delivery.
    static var ownerSettings: SigstopSettings {
        var s = SigstopSettings()
        s.workIntervalMinutes = 5
        s.breakDurationMinutes = 5
        s.microIdleThresholdSeconds = 90
        s.maxNotificationsPerDay = 14
        s.maxSnoozesPerBreak = 2
        s.snoozeMinutes = 5
        s.idleCountsAsBreakMinutes = 5
        s.useSystemNotifications = false
        s.tone = .nuclear
        s.quietHours = QuietHours(enabled: false)
        return s
    }

    /// The shipping engine, stepped at the shipping five second cadence with the clock
    /// injected. Nothing is mocked but time and the machine's signals.
    struct Driver {
        static let tick: TimeInterval = 5

        let engine: BreakDecisionEngine
        let settings: SigstopSettings
        var state: EngineState
        var day = DailyCounters()
        var now: Date
        var monotonic: Double = 0
        var continuousWork: TimeInterval = 0
        var micRunning = false
        /// Seconds since the last input event. Above `microIdleThresholdSeconds` the
        /// engine suspends the cycle and goes `.idle`, which is a second state that holds
        /// a cycle open while computing no verdict.
        var idleSeconds: TimeInterval = 0

        private(set) var effects: [Effect] = []
        /// The verdict the engine computed on the last step. Nil on every tick with no
        /// cycle open, which is what the ledger reads as "there was no question to answer".
        private(set) var lastVerdict: InterruptionVerdict?

        init(settings: SigstopSettings, start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
            self.settings = settings
            self.engine = BreakDecisionEngine(settings: settings)
            self.now = start
            self.state = .working(
                WorkingState(armThreshold: TimeInterval(settings.workIntervalMinutes) * 60)
            )
        }

        /// One tick. Returns the effects this step produced, and also appends them to the
        /// running stream so a whole scenario can be asserted on at the end.
        @discardableResult
        mutating func step(action: UserAction? = nil) -> [Effect] {
            monotonic += Self.tick
            now = now.addingTimeInterval(Self.tick)
            if case .breakActive = state {} else { continuousWork += Self.tick }

            let context = DeveloperContext(
                timestamp: now,
                application: AppIdentity(bundleID: "com.apple.dt.Xcode", localizedName: "Xcode", pid: 1),
                activity: .coding,
                confidence: Confidence(0.8),
                continuousWork: continuousWork,
                idleSeconds: idleSeconds
            )
            let input = EngineInput(
                now: now,
                monotonic: monotonic,
                context: context,
                signals: SystemSignals(audioInputRunning: micRunning),
                settings: settings,
                day: day,
                userAction: action
            )

            let outcome = engine.step(state, input)
            state = outcome.state
            day = outcome.day
            lastVerdict = outcome.verdict
            effects.append(contentsOf: outcome.effects)
            return outcome.effects
        }

        /// Steps until `predicate` holds, up to `limit` ticks. Returns the tick's effects.
        @discardableResult
        mutating func step(untilLimit limit: Int = 600, _ predicate: ([Effect]) -> Bool) -> [Effect] {
            for _ in 0..<limit {
                let produced = step()
                if predicate(produced) { return produced }
            }
            return []
        }
    }

    // MARK: - The log, replayed through the real writer

    /// Replays an effect stream through `EventLogWriter`, the shipping mapping.
    ///
    /// This started life as a transcription of `AppModel.execute`, because that switch
    /// lived in `SigstopApp` and `SigstopApp` has no test target. It does not any more:
    /// the mapping is pure Core and this drives it directly, so the test and the app can
    /// no longer disagree.
    ///
    /// The one line the writer does not produce is `break_prompt`, and that is deliberate.
    /// It means "this reached the screen", which only the app can know, so it is appended
    /// here exactly where `verifyPromptPresentation()` appends it: after delivery, once
    /// the window server has confirmed the panel's own window number.
    struct LogReplay {
        private(set) var lines: [LoggedEvent] = []
        private var confirmed: CycleID?

        var kinds: [String] { lines.map(\.kind.rawValue) }

        mutating func append(_ line: LoggedEvent) { lines.append(line) }

        mutating func execute(_ effects: [Effect], at now: Date) {
            for effect in effects {
                lines.append(
                    contentsOf: EventLogWriter.lines(
                        for: effect, at: now,
                        context: EffectLogContext(confirmedPromptCycle: confirmed)
                    )
                )
                switch effect {
                case .deliverPrompt(let request):
                    confirmed = request.cycle
                    lines.append(
                        .breakPrompt(at: now, cycle: request.cycle, reason: request.level.signal)
                    )
                case .closeCycle, .withdrawPrompt:
                    confirmed = nil
                default:
                    break
                }
            }
        }
    }

    // MARK: - A whole session, logged the way the app logs it

    /// The driver, the log writer and the verdict ledger wired together exactly as
    /// `AppModel.tick` wires them.
    ///
    /// This is what makes "an open cycle never goes ten minutes without writing anything"
    /// an assertion rather than a hope: the file a scenario produces here is the file the
    /// app would have produced.
    struct Session {
        var driver: Driver
        private(set) var log = LogReplay()
        private var verdicts = VerdictLedger()

        init(settings: SigstopSettings = EngineHarness.ownerSettings) {
            self.driver = Driver(settings: settings)
        }

        var micRunning: Bool {
            get { driver.micRunning }
            set { driver.micRunning = newValue }
        }

        @discardableResult
        mutating func step(action: UserAction? = nil) -> [Effect] {
            let openBefore = driver.state.openCycle
            let effects = driver.step(action: action)
            if let line = verdicts.observe(
                driver.lastVerdict.map(GateReason.init),
                holding: driver.state.silence,
                cycle: openBefore,
                at: driver.now,
                monotonic: driver.monotonic
            ) {
                log.append(line)
            }
            log.execute(effects, at: driver.now)
            if effects.contains(where: { if case .closeCycle = $0 { return true } else { return false } }) {
                verdicts.reset()
            }
            return effects
        }

        mutating func step(times: Int) {
            for _ in 0..<times { step() }
        }

        @discardableResult
        mutating func step(untilLimit limit: Int = 600, _ predicate: ([Effect]) -> Bool) -> [Effect] {
            for _ in 0..<limit {
                let produced = step()
                if predicate(produced) { return produced }
            }
            return []
        }

        /// Steps until the engine delivers a prompt, which is where most scenarios start.
        @discardableResult
        mutating func stepToPrompt(limit: Int = 200) -> [Effect] {
            step(untilLimit: limit) { effects in
                effects.contains { if case .deliverPrompt = $0 { return true } else { return false } }
            }
        }
    }
}
