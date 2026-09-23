import Foundation
import Testing

@testable import SigstopCore

enum EngineHarness {

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
        var cameraRunning = false
        var idleSeconds: TimeInterval = 0
        var sessionEvents: [SessionEvent] = []
        var lastBreakEndedAt: Date?
        var calendarSystem: Calendar = .current

        private(set) var effects: [Effect] = []
        private(set) var lastVerdict: InterruptionVerdict?

        init(settings: SigstopSettings, start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
            self.settings = settings
            self.engine = BreakDecisionEngine(settings: settings)
            self.now = start
            self.state = .working(
                WorkingState(armThreshold: TimeInterval(settings.workIntervalMinutes) * 60)
            )
        }

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
                signals: SystemSignals(audioInputRunning: micRunning, cameraRunning: cameraRunning),
                settings: settings,
                calendarSystem: calendarSystem,
                lastBreakEndedAt: lastBreakEndedAt,
                day: day,
                userAction: action,
                sessionEvents: sessionEvents
            )
            sessionEvents = []

            let outcome = engine.step(state, input)
            state = outcome.state
            day = outcome.day
            lastVerdict = outcome.verdict
            effects.append(contentsOf: outcome.effects)
            return outcome.effects
        }

        @discardableResult
        mutating func step(untilLimit limit: Int = 600, _ predicate: ([Effect]) -> Bool) -> [Effect] {
            for _ in 0..<limit {
                let produced = step()
                if predicate(produced) { return produced }
            }
            return []
        }
    }

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

        var cameraRunning: Bool {
            get { driver.cameraRunning }
            set { driver.cameraRunning = newValue }
        }

        mutating func startCorroboratedCall() {
            driver.micRunning = true
            driver.cameraRunning = true
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

        @discardableResult
        mutating func stepToPrompt(limit: Int = 200) -> [Effect] {
            step(untilLimit: limit) { effects in
                effects.contains { if case .deliverPrompt = $0 { return true } else { return false } }
            }
        }
    }
}
