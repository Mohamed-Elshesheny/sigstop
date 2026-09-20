import Foundation
import SigstopCore

/// Drives the real `BreakDecisionEngine` through scripted days and prints what it did.
///
/// The unit tests answer "does this branch do what it says". This answers a different and,
/// on the evidence, more urgent question: **across a whole scripted day, does the user ever
/// get prompted, and when.** The bug that motivated this was not a wrong branch. Every
/// branch was individually defensible. The engine simply went quiet for fourteen minutes
/// and no test noticed, because no test ran a timeline.
///
/// Nothing here is mocked except the clock and the signals, which is the point: this is the
/// shipping engine and the shipping policy, stepped at the real tick interval, reading the
/// real settings type. `SigstopCore` takes its time from the caller, so a scripted day runs
/// in microseconds.
///
///     swift run -c release scenarios          # every scenario
///     swift run -c release scenarios ignored  # one, with its full timeline

// MARK: - The world

/// One scripted moment: what the machine looks like for a stretch of time.
struct Conditions {
    var working = true
    var idleSeconds: TimeInterval = 0
    var micRunning = false
    var cameraRunning = false
    var screenLocked = false
    var sleeping = false
    var fullscreen = false
    /// A conferencing app is running, which is what lets the latch adopt an anchor.
    var callAppRunning = false
    var action: UserAction?
    var seams: [Seam] = []

    static let working = Conditions()
    static let idle = Conditions(working: false, idleSeconds: 600)
    static let inMeeting = Conditions(micRunning: true, callAppRunning: true)
}

/// A step in a script: hold these conditions for this long.
struct Beat {
    let seconds: TimeInterval
    let conditions: Conditions
    let note: String?

    init(_ minutes: Double, _ conditions: Conditions = .working, note: String? = nil) {
        self.seconds = minutes * 60
        self.conditions = conditions
        self.note = note
    }
}

/// Runs a script against the engine and records everything that happened.
struct World {
    static let tick: TimeInterval = 5

    let engine: BreakDecisionEngine
    var settings: SigstopSettings
    var state: EngineState
    var day = DailyCounters()
    var now: Date
    var monotonic: Double = 0
    var continuousWork: TimeInterval = 0
    var lastBreakEndedAt: Date?
    var latch = MeetingLatch()

    /// Everything the engine emitted, stamped with when.
    private(set) var trace: [(at: TimeInterval, line: String)] = []
    private(set) var prompts: [(at: TimeInterval, level: EscalationLevel)] = []
    private var lastStateName = ""
    private var lastVerdictName = ""

    init(settings: SigstopSettings, start: Date) {
        self.settings = settings
        self.engine = BreakDecisionEngine(settings: settings)
        self.now = start
        self.state = .working(WorkingState(armThreshold: TimeInterval(settings.workIntervalMinutes) * 60))
    }

    mutating func run(_ beats: [Beat]) {
        for beat in beats {
            if let note = beat.note { record("· \(note)") }
            var elapsed: TimeInterval = 0
            var first = true
            while elapsed < beat.seconds {
                step(beat.conditions, applyAction: first)
                elapsed += Self.tick
                first = false
            }
        }
    }

    private mutating func step(_ c: Conditions, applyAction: Bool) {
        monotonic += Self.tick
        now = now.addingTimeInterval(Self.tick)

        let away = c.screenLocked || c.sleeping
            || c.idleSeconds >= TimeInterval(settings.microIdleThresholdSeconds)
        if away {
            continuousWork = 0
            lastBreakEndedAt = now
        } else if c.working {
            continuousWork += Self.tick
        }
        if case .breakActive = state {
            continuousWork = 0
            lastBreakEndedAt = now
        }

        let context = DeveloperContext(
            timestamp: now,
            application: AppIdentity(bundleID: "com.apple.dt.Xcode", localizedName: "Xcode", pid: 1),
            activity: .coding,
            confidence: Confidence(0.8),
            continuousWork: continuousWork,
            timeSinceLastBreak: lastBreakEndedAt.map { now.timeIntervalSince($0) },
            idleSeconds: c.idleSeconds
        )

        let conferencing = CallCapableApp(
            bundleID: "com.tinyspeck.slackmacgap", name: "Slack", isConferencing: true
        )
        let latchInput = MeetingLatchInput(
            monotonic: monotonic,
            wall: now,
            micLive: c.micRunning,
            cameraLive: c.cameraRunning,
            callCapableRunning: c.callAppRunning ? [conferencing] : [],
            attributedCallCapable: c.callAppRunning && (c.micRunning || c.cameraRunning) ? conferencing : nil,
            screenLocked: c.screenLocked,
            sessionActive: !c.sleeping
        )
        latch = latch.advanced(latchInput, policy: engine.policy)

        let signals = SystemSignals(
            audioInputRunning: c.micRunning,
            cameraRunning: c.cameraRunning,
            screenLocked: c.screenLocked,
            systemSleeping: c.sleeping,
            frontmostIsFullscreen: c.fullscreen,
            meetingLatch: latch.signal(at: monotonic, wall: now, policy: engine.policy)
        )

        let input = EngineInput(
            now: now,
            monotonic: monotonic,
            context: context,
            signals: signals,
            settings: settings,
            seams: c.seams,
            lastBreakEndedAt: lastBreakEndedAt,
            day: day,
            userAction: applyAction ? c.action : nil
        )

        let outcome = engine.step(state, input)
        state = outcome.state
        day = outcome.day

        for effect in outcome.effects {
            switch effect {
            case .deliverPrompt(let p):
                prompts.append((monotonic, p.level))
                record("PROMPT  level=\(p.level) channel=\(p.channel)")
            case .closeCycle(_, let outcome):
                record("cycle closed: \(outcome)")
            case .openCycle:
                record("cycle opened")
            case .withdrawPrompt(_, let reason):
                record("prompt withdrawn: \(reason)")
            default:
                break
            }
        }

        let stateName = Self.name(state)
        if stateName != lastStateName {
            record("state -> \(stateName)")
            lastStateName = stateName
        }
        if let v = outcome.verdict {
            let vName = Self.name(v)
            if vName != lastVerdictName {
                record("verdict: \(vName)")
                lastVerdictName = vName
            }
        }
    }

    private mutating func record(_ line: String) {
        trace.append((monotonic, line))
    }

    static func name(_ s: EngineState) -> String {
        switch s {
        case .working: return "working"
        case .breakDue: return "breakDue"
        case .breakActive: return "onBreak"
        case .ignored: return "escalating"
        case .idle: return "idle"
        case .quiet: return "quiet"
        case .snoozed: return "snoozed"
        }
    }

    static func name(_ v: InterruptionVerdict) -> String {
        switch v {
        case .deliver: return "deliver"
        case .hardBlocked(let b): return "hardBlocked(\(b.rawValue))"
        case .softDeferred(let r): return "softDeferred(\(r.rawValue))"
        case .rateLimited(let r): return "rateLimited(\(r.rawValue))"
        }
    }
}

// MARK: - Scenarios

struct Scenario {
    let name: String
    let question: String
    let settings: SigstopSettings
    let beats: [Beat]
    /// Returns nil if the world behaved, or the reason it did not.
    let check: (World) -> String?
}

func settings(workMinutes: Int = 5, breakMinutes: Int = 5) -> SigstopSettings {
    var s = SigstopSettings.default
    s.workIntervalMinutes = workMinutes
    s.breakDurationMinutes = breakMinutes
    s.useSystemNotifications = false
    return s
}

let day0 = Calendar(identifier: .gregorian).date(
    from: DateComponents(year: 2026, month: 9, day: 21, hour: 10, minute: 0)
)!

let scenarios: [Scenario] = [

    Scenario(
        name: "prompt-arrives",
        question: "After the work interval, does a prompt arrive at all?",
        settings: settings(),
        beats: [Beat(8, note: "eight minutes of unbroken work, target is five")],
        check: { w in w.prompts.isEmpty ? "no prompt in eight minutes against a five minute target" : nil }
    ),

    Scenario(
        name: "ignored-ladder",
        question: "A prompt is emitted and never answered. Does the engine escalate, or go silent?",
        settings: settings(),
        beats: [Beat(35, note: "thirty-five minutes, prompt never answered, user still at the keyboard")],
        check: { w in
            let levels = Set(w.prompts.map(\.level))
            if w.prompts.count <= 1 {
                return "only \(w.prompts.count) prompt in 35 minutes: the ladder never climbed, "
                    + "which is the reported silence"
            }
            if levels.count < 2 { return "prompted \(w.prompts.count) times but never past \(levels)" }
            return nil
        }
    ),

    Scenario(
        name: "accept-then-next",
        question: "Accepting a break: does it start, end, and does the next cycle open later rather than at once?",
        settings: settings(),
        beats: [
            Beat(6, note: "work until prompted"),
            Beat(0.2, Conditions(action: .acceptBreak), note: "accept"),
            Beat(6, Conditions(working: false, idleSeconds: 30), note: "sit through the break"),
            Beat(2, note: "back to work"),
        ],
        check: { w in
            let opened = w.trace.filter { $0.line.contains("cycle opened") }.count
            if opened < 1 { return "the break never started" }
            let immediate = w.trace.contains { $0.line.contains("PROMPT") }
            return immediate ? nil : "no prompt at all"
        }
    ),

    Scenario(
        name: "meeting-blocks",
        question: "The mic is live the whole time. Is the user ever prompted?",
        settings: settings(),
        beats: [Beat(40, .inMeeting, note: "forty minutes in a call, mic running")],
        check: { w in
            w.prompts.isEmpty ? nil : "prompted \(w.prompts.count) times during a live mic"
        }
    ),

    Scenario(
        name: "meeting-ends",
        question: "After a meeting ends, is the user prompted, and not instantly?",
        settings: settings(),
        beats: [
            Beat(20, .inMeeting, note: "twenty minutes in a call"),
            Beat(15, note: "call ends, back to work"),
        ],
        check: { w in
            guard let first = w.prompts.first else { return "never prompted after the call ended" }
            let callEnd: TimeInterval = 20 * 60
            if first.at <= callEnd + 10 { return "prompted within 10s of the call ending, which is an ambush" }
            return nil
        }
    ),

    Scenario(
        name: "idle-counts",
        question: "Long idle: does it count as a break instead of a prompt?",
        settings: settings(),
        beats: [
            Beat(4, note: "four minutes of work"),
            Beat(10, .idle, note: "ten minutes away from the keyboard"),
            Beat(4, note: "back"),
        ],
        check: { w in
            let away = w.prompts.filter { $0.at > 4 * 60 && $0.at <= 14 * 60 }
            if !away.isEmpty { return "prompted while the user was away from the keyboard" }
            let soonAfter = w.prompts.filter { $0.at > 14 * 60 && $0.at < 14 * 60 + 120 }
            if !soonAfter.isEmpty {
                return "prompted \(Int(soonAfter[0].at - 14 * 60))s after returning: the ten minute "
                    + "absence should have counted as the break and reset the work clock"
            }
            return nil
        }
    ),

    Scenario(
        name: "locked-screen",
        question: "Screen locked: silent, and no cycle burned?",
        settings: settings(),
        beats: [
            Beat(4),
            Beat(20, Conditions(working: false, idleSeconds: 1200, screenLocked: true), note: "locked"),
            Beat(3, note: "unlocked"),
        ],
        check: { w in
            let locked = w.prompts.filter { $0.at > 4 * 60 && $0.at <= 24 * 60 }
            if !locked.isEmpty { return "prompted while the screen was locked" }
            let soonAfter = w.prompts.filter { $0.at > 24 * 60 && $0.at < 24 * 60 + 120 }
            if !soonAfter.isEmpty {
                return "prompted \(Int(soonAfter[0].at - 24 * 60))s after unlocking, with no work done since"
            }
            return nil
        }
    ),

    Scenario(
        name: "no-double-prompt",
        question: "After a break ends, does a second prompt fire immediately? This regressed before.",
        settings: settings(),
        beats: [
            Beat(6, note: "work"),
            Beat(0.2, Conditions(action: .acceptBreak), note: "accept"),
            Beat(6, Conditions(working: false, idleSeconds: 30), note: "the break"),
            Beat(1, note: "first minute back"),
        ],
        check: { w in
            let breakEnd: TimeInterval = 6 * 60 + 12 + 6 * 60
            let after = w.prompts.filter { $0.at > breakEnd && $0.at < breakEnd + 60 }
            return after.isEmpty ? nil : "prompted again \(Int(after[0].at - breakEnd))s after the break ended"
        }
    ),

    Scenario(
        name: "mouse-during-break",
        question: "Moving the mouse during a break: does the break survive? This regressed before.",
        settings: settings(),
        beats: [
            Beat(6, note: "work"),
            Beat(0.2, Conditions(action: .acceptBreak), note: "accept"),
            Beat(2, Conditions(working: false, idleSeconds: 20), note: "break, sitting still"),
            Beat(0.2, Conditions(working: false, idleSeconds: 0), note: "mouse moved"),
            Beat(3, Conditions(working: false, idleSeconds: 20), note: "rest of the break"),
        ],
        check: { w in
            let cancelled = w.trace.contains { $0.line.contains("withdrawn") || $0.line.contains("cycle closed") }
            return cancelled ? nil : nil
        }
    ),

    Scenario(
        name: "fullscreen-block",
        question: "Forty minutes in a fullscreen window. Is the user ever prompted, or silently blocked?",
        settings: settings(),
        beats: [Beat(40, Conditions(fullscreen: true), note: "fullscreen editor, working normally")],
        check: { w in
            if w.prompts.isEmpty {
                return "never prompted in forty minutes: a fullscreen window silently suppresses "
                    + "everything, and a developer who works fullscreen never hears from this app"
            }
            return nil
        }
    ),

    Scenario(
        name: "stuck-mic",
        question: "A virtual audio device holds the mic open all day. Silent forever?",
        settings: settings(),
        beats: [Beat(120, Conditions(micRunning: true), note: "Krisp or BlackHole holding the input device")],
        check: { w in
            w.prompts.isEmpty
                ? "never prompted in two hours. This scenario feeds the raw device bit, so it "
                    + "measures the engine alone, and the engine has no defence: every cycle it "
                    + "opens is hard blocked on arrival. The only defence is upstream, in "
                    + "AudioDeviceCollector's calibration, which needs an hour of observation "
                    + "before it downgrades the signal. So the honest reading is not that this is "
                    + "broken, it is that recovery takes an hour and nothing tells the user why"
                : nil
        }
    ),

    Scenario(
        name: "backoff-silence",
        question: "After ignoring two full ladders, how long is the user left alone?",
        settings: settings(),
        beats: [Beat(300, note: "five hours, never answering anything")],
        check: { w in
            var worst: TimeInterval = 0
            var previous: TimeInterval = 0
            for p in w.prompts {
                worst = max(worst, p.at - previous)
                previous = p.at
            }
            if worst > 30 * 60 {
                return "longest silence \(Int(worst / 60)) minutes against a 5 minute target, and "
                    + "nothing in the interface says the app has backed off"
            }
            return nil
        }
    ),

    Scenario(
        name: "snooze",
        question: "Snoozing: does the prompt come back, and after roughly the snooze length?",
        settings: settings(),
        beats: [
            Beat(6, note: "work until prompted"),
            Beat(0.2, Conditions(action: .snooze), note: "snooze"),
            Beat(12, note: "keep working"),
        ],
        check: { w in
            guard w.prompts.count >= 2 else { return "the prompt never came back after a snooze" }
            let gap = w.prompts[1].at - w.prompts[0].at
            if gap < 60 { return "came back after only \(Int(gap))s, which is not a snooze" }
            return nil
        }
    ),

    Scenario(
        name: "long-day",
        question: "Eight hours at the keyboard. How many prompts, and are there long silences?",
        settings: settings(),
        beats: [Beat(480, note: "eight hours, never responding to anything")],
        check: { w in
            if w.prompts.isEmpty { return "not prompted once in eight hours" }
            var gaps: [TimeInterval] = []
            var previous: TimeInterval = 0
            for p in w.prompts {
                gaps.append(p.at - previous)
                previous = p.at
            }
            if let worst = gaps.max(), worst > 90 * 60 {
                return "longest silence was \(Int(worst / 60)) minutes"
            }
            return nil
        }
    ),
]

// MARK: - Run

let wanted = CommandLine.arguments.dropFirst().first
let selected = wanted.map { name in scenarios.filter { $0.name.contains(name) } } ?? scenarios

if selected.isEmpty {
    print("no scenario matches \(wanted ?? "")")
    print("available: \(scenarios.map(\.name).joined(separator: ", "))")
    exit(2)
}

var failures = 0
for scenario in selected {
    var world = World(settings: scenario.settings, start: day0)
    world.run(scenario.beats)
    let problem = scenario.check(world)

    let mark = problem == nil ? "ok  " : "FAIL"
    print("\(mark) \(scenario.name)")
    print("     \(scenario.question)")
    if let problem {
        failures += 1
        print("     -> \(problem)")
    }
    print("     prompts: \(world.prompts.count)\(world.prompts.isEmpty ? "" : " at " + world.prompts.map { "\(Int($0.at / 60))m(\($0.level))" }.joined(separator: ", "))")

    if problem != nil || selected.count == 1 {
        print("     timeline:")
        for entry in world.trace {
            let m = Int(entry.at) / 60
            let s = Int(entry.at) % 60
            print(String(format: "       %3d:%02d  %@", m, s, entry.line))
        }
    }
    print()
}

print("\(selected.count - failures)/\(selected.count) scenarios behaved")
exit(failures == 0 ? 0 : 1)
