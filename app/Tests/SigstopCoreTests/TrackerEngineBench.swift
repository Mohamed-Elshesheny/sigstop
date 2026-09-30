import Foundation
import Testing

@testable import SigstopCore

struct TrackerEngineBench {
    static let app = AppIdentity(bundleID: "com.apple.dt.Xcode", localizedName: "Xcode", pid: 1)
    static let tick: TimeInterval = 5

    let time: MutableTimeSource
    let settings: SigstopSettings
    let policy: BreakPolicy
    let engine: BreakDecisionEngine
    let calendar: Calendar
    var tracker: SessionTracker
    var state: EngineState
    var day: DailyCounters
    var mic = false
    var camera = false
    private(set) var effects: [Effect] = []
    private(set) var events: [SessionEvent] = []

    static var settings: SigstopSettings {
        var s = SigstopSettings()
        s.workIntervalMinutes = 45
        s.breakDurationMinutes = 5
        s.quietHours = QuietHours(enabled: false)
        s.useSystemNotifications = false
        return s
    }

    init(settings: SigstopSettings = Self.settings, start: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        self.settings = settings
        var policy = BreakPolicy(settings: settings)
        policy.tickInterval = Self.tick
        policy.tickTolerance = Self.tick
        self.policy = policy
        engine = BreakDecisionEngine(policy: policy)
        calendar = CalendarDay.utcCalendar
        time = MutableTimeSource(now: start, monotonic: 1_000)
        tracker = SessionTracker(time: time, policy: policy, calendar: calendar)
        state = .initial(policy: policy)
        day = DailyCounters(
            dayIndex: LocalDay.index(of: start, calendar: calendar, boundaryHour: policy.dayBoundaryHour)
        )
    }

    var continuousWork: TimeInterval { tracker.session.continuousActiveWork }

    private var isPaused: Bool {
        if case .quiet(let q) = state, q.cause == .userPaused { return true }
        return false
    }

    @discardableResult
    mutating func tick(
        idle: TimeInterval = 0, locked: Bool = false, action: UserAction? = nil, advance: TimeInterval = tick
    ) -> [Effect] {
        time.advance(by: advance)
        let sessionEvents = tracker.tick(
            TickSample(
                idleSeconds: idle, screenLocked: locked, micRunning: mic, userPaused: isPaused,
                application: Self.app, activity: .coding, confidence: Confidence(0.9)
            )
        )
        events.append(contentsOf: sessionEvents)
        let now = time.now
        let input = EngineInput(
            now: now,
            monotonic: time.continuousSeconds,
            context: tracker.makeContext(now: now),
            signals: SystemSignals(audioInputRunning: mic, cameraRunning: camera, screenLocked: locked),
            settings: settings,
            calendarSystem: calendar,
            focusScore: tracker.focusScore,
            lastBreakEndedAt: tracker.session.lastBreakEndedAt,
            day: day,
            userAction: action,
            sessionEvents: sessionEvents
        )
        let outcome = engine.step(state, input)
        state = outcome.state
        day = outcome.day
        for effect in outcome.effects {
            switch effect {
            case .beginBreak(_, let origin, _): tracker.beginBreak(origin: origin)
            case .endBreak(_, let origin, _, _, let threshold): tracker.endBreak(origin: origin, threshold: threshold)
            case .recordSkip: tracker.recordSkip()
            case .recordSnooze: tracker.recordSnooze()
            case .recordIgnoredPrompt: tracker.recordIgnoredPrompt()
            default: break
            }
        }
        effects.append(contentsOf: outcome.effects)
        return outcome.effects
    }

    @discardableResult
    mutating func sleep(for seconds: TimeInterval, wakeIdle: TimeInterval = 0, locked: Bool = false) -> [Effect] {
        tracker.noteSystemWake()
        return tick(idle: wakeIdle, locked: locked, advance: seconds)
    }

    @discardableResult
    mutating func work(minutes: Double) -> [Effect] {
        var produced: [Effect] = []
        for _ in 0..<Int(minutes * 60 / Self.tick) { produced += tick() }
        return produced
    }

    @discardableResult
    mutating func away(minutes: Double, locked: Bool = false) -> [Effect] {
        var produced: [Effect] = []
        var idle: TimeInterval = 0
        for _ in 0..<Int(minutes * 60 / Self.tick) {
            idle += Self.tick
            produced += tick(idle: idle, locked: locked)
        }
        return produced
    }

    @discardableResult
    mutating func workUntil(limitMinutes: Double = 120, _ predicate: ([Effect]) -> Bool) -> [Effect]? {
        for _ in 0..<Int(limitMinutes * 60 / Self.tick) {
            let produced = tick()
            if predicate(produced) { return produced }
        }
        return nil
    }

    @discardableResult
    mutating func workUntilPrompt(limitMinutes: Double = 120) -> PromptRequest? {
        workUntil(limitMinutes: limitMinutes) { !Self.prompts($0).isEmpty }.map(Self.prompts)?.first
    }

    mutating func workUntilOpen(limitMinutes: Double = 120) -> TimeInterval? {
        guard workUntil(limitMinutes: limitMinutes, Self.opensCycle) != nil else { return nil }
        return continuousWork
    }

    var working: WorkingState? {
        if case .working(let w) = state { return w }
        return nil
    }
}

extension TrackerEngineBench {
    static func prompts(_ effects: [Effect]) -> [PromptRequest] {
        effects.compactMap { if case .deliverPrompt(let p) = $0 { return p } else { return nil } }
    }

    static func closes(_ effects: [Effect]) -> [CycleOutcome] {
        effects.compactMap { if case .closeCycle(_, let outcome) = $0 { return outcome } else { return nil } }
    }

    static func ignoredPrompts(_ effects: [Effect]) -> Int {
        effects.filter { if case .recordIgnoredPrompt = $0 { return true } else { return false } }.count
    }

    static func opensCycle(_ effects: [Effect]) -> Bool {
        effects.contains { if case .openCycle = $0 { return true } else { return false } }
    }
}
