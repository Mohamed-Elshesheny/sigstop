# Session Model & Break Decision Engine

Design spec for the local-first macOS app. Two subsystems:

1. **Session model** — what "continuous active work" means, measured honestly.
2. **Break decision engine** — when, whether, and how the app is allowed to say something.

**Framing constraint.** Everything here is about *workflow and behavior*: rhythm, context switching,
momentum, attention to the clock. The app makes no health claims and none of its copy may imply any.
It is a timekeeper for a work pattern the user chose, not an advisor. See
[Copy rules](#16-copy-rules-non-negotiable).

**Privacy constraint.** All state is local. Nothing in this subsystem makes a network call, and
nothing it computes is ever transmitted: the app's one request is the update check described in
`docs/PRIVACY.md` §5, which carries no data and is triggered by a button, not by the engine.
Window titles are used transiently
for classification and are never persisted. Raw input samples are never persisted — only classified
gaps and per-minute attribution buckets.

---

## 1. The core claim: continuous active work ≠ elapsed time

The naive implementation is `now - sessionStartedAt`. It is wrong in every direction that matters:

- it counts the 20 minutes you spent in the kitchen,
- it counts the meeting where you did not touch the keyboard,
- it does not survive the machine sleeping,
- and if you fix it with a naive idle timeout, it resets the clock every time you read a paragraph.

**Definition.** `continuousActiveWork` is the sum of one-second ticks during which the user was at the
machine, since the last event that reset the clock. "At the machine" is not "typing" — a gap in input
shorter than `microIdleGrace` (90 s) is *credited as work*, because reading a diff, thinking about a
design, and watching a test run are all work. A gap that grows past 90 s stops crediting, and the
90 s already credited for that gap is **revoked** (provisional credit, see §3.3).

So the clock has three distinct effects available, and they are independent:

| Effect | Meaning |
|---|---|
| **credit** | `continuousActiveWork += Δ` |
| **pause** | stop crediting; keep the accumulated value |
| **reset** | `continuousActiveWork = 0` |

and separately:

| Effect | Meaning |
|---|---|
| **record break** | `breakCount += 1`, `lastBreakAt = gap.start`, `lastBreakEndedAt = gap.end` |
| **end session** | finalize the `DeveloperSession`, start a new one on return |

A reset is not a break. A break always implies a reset. A pause implies neither. Conflating these
three is the single most common bug in this class of app, so the model keeps them orthogonal.

---

## 2. Part A — the session model

### 2.1 Types

```swift
import Foundation

enum ActivityType: String, Codable, CaseIterable {
    case coding          // editor / IDE frontmost
    case terminal        // shell, REPL, build output
    case debugging       // debugger UI frontmost, or editor in a debug session
    case review          // diff/PR/docs reading
    case browsing        // browser, unclassified
    case communication   // chat, mail
    case design          // figma, sketch, image tools
    case meeting         // conferencing app + live mic/camera
    case media           // video/music foreground with no input
    case unknown
}

enum ClassificationSource: String, Codable {
    case bundleIdentifier   // high confidence, cheap, always available
    case windowTitle        // needs Accessibility; transient, never persisted
    case systemSignal       // mic/camera/display-capture state; not a guess
    case userOverride       // user pinned this app to a type
}

struct ActivityClassification: Codable, Equatable {
    var type: ActivityType
    var confidence: Double          // 0.0 ... 1.0
    var source: ClassificationSource
    var observedAt: Date
}

struct AppIdentity: Codable, Equatable, Hashable {
    var bundleIdentifier: String    // "com.microsoft.VSCode"
    var localizedName: String       // for display only
}
```

`confidence` is calibrated, not decorative:

| Signal | Type | Confidence |
|---|---|---|
| Known IDE / editor bundle id | `.coding` | 0.90 |
| Known terminal bundle id | `.terminal` | 0.85 |
| Debugger attached (AX) or debug-console window focused | `.debugging` | 0.80 |
| Conferencing bundle **and** input device running | `.meeting` | 0.95 |
| Browser, no window-title access | `.browsing` | 0.40 |
| Browser, title matches a code-host / docs pattern | `.review` | 0.65 |
| Unknown bundle id | `.unknown` | 0.00 |
| User override | as pinned | 1.00 |

**Rule: confidence gates deferral, never blocking.** A classification may only cause a *soft* deferral
if `confidence >= 0.60`. Nothing derived from a guess about what an app is may hard-block a prompt.
Only `.systemSignal` observations (the audio input device is actually running, the display is actually
being captured) are allowed to hard-block. This is the difference between "I think you might be in a
meeting" and "the microphone is on".

### 2.2 `DeveloperSession`

```swift
enum PauseCause: String, Codable {
    case microIdleExceeded      // input gap grew past the grace window
    case screenLocked
    case systemSleep
    case displaySleep
    case fastUserSwitch
    case meetingNoInput         // live call, hands off keyboard
    case breakActive
    case userPaused             // "pause the app for 1 hour"
}

enum WorkClockState: Equatable {
    case running
    case paused(cause: PauseCause, since: Date)
    case stopped                // session finalized
}

enum ResetReason: String, Codable {
    case qualifyingBreak        // >= 5 min away: a real break
    case longPause              // >= 20 min paused for any reason: context is gone
    case sessionStart
    case dayBoundary
    case userReset
}

struct DeveloperSession: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    private(set) var endedAt: Date?

    // ---- the work clock ----
    private(set) var continuousActiveWork: TimeInterval = 0   // resets; the number the engine acts on
    private(set) var totalActiveWork: TimeInterval = 0        // never resets within the session
    private(set) var peakContinuousActiveWork: TimeInterval = 0
    private(set) var clock: WorkClockState = .running
    private(set) var provisionalGraceCredit: TimeInterval = 0 // see §3.3

    // ---- breaks ----
    private(set) var lastBreakAt: Date?          // start of the most recent qualifying break
    private(set) var lastBreakEndedAt: Date?     // drives the post-break settle-in hard block
    private(set) var breakCount: Int = 0
    private(set) var skippedBreakCount: Int = 0
    private(set) var snoozeCount: Int = 0
    private(set) var ignoredPromptCount: Int = 0

    // ---- idle ----
    private(set) var lastInputAt: Date
    private(set) var idleDuration: TimeInterval = 0     // current uninterrupted gap; 0 while active
    private(set) var accumulatedIdle: TimeInterval = 0  // all uncredited time this session

    // ---- application context ----
    private(set) var activeApplication: AppIdentity?
    private(set) var activity: ActivityClassification
    private(set) var applicationSwitches: Int = 0
    private(set) var recentSwitches: [Date] = []                 // ring buffer, trimmed to 10 min
    private(set) var appActiveSeconds: [String: TimeInterval] = [:]  // bundleID -> credited seconds

    // ---- derived ----
    var activityType: ActivityType { activity.type }
    var activityConfidence: Double { activity.confidence }
    var timeSinceLastBreak: TimeInterval? {
        lastBreakEndedAt.map { Date().timeIntervalSince($0) }
    }
}
```

### 2.3 Focus estimate

Not a mood reading — two observable quantities.

```swift
extension DeveloperSession {
    /// 0...1. Low switch rate + one dominant app = deep focus.
    func focusScore(now: Date, window: TimeInterval = 600) -> Double {
        let switches = recentSwitches.filter { now.timeIntervalSince($0) <= window }.count
        let switchTerm = max(0, min(1, 1 - Double(switches) / 6.0))
        let total = appActiveSeconds.values.reduce(0, +)
        let dominance = total > 0 ? (appActiveSeconds.values.max() ?? 0) / total : 0
        return 0.6 * switchTerm + 0.4 * dominance
    }

    func isInDeepFocus(now: Date, policy: BreakPolicy) -> Bool {
        focusScore(now: now) >= 0.70
            && continuousActiveWork >= 20 * 60
            && activityConfidence >= 0.60
            && [.coding, .debugging, .terminal].contains(activityType)
    }
}
```

Deep focus buys **exactly one** deferral extension per break cycle (§9). It is never a veto: deep
focus is precisely the state in which people lose track of the clock, so an app that treats it as a
permanent shield is an app that never fires.

---

## 3. The tick loop

### 3.1 Sampling

- Tick every **1 s** (5 s when on battery below 20 % or in Low Power Mode).
- Idle is read from `CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)`
  (`~0` is `kCGAnyInputEventType`). This counts keyboard, mouse, trackpad and tablet input across all
  apps and requires no permission.
- Frontmost app from `NSWorkspace.shared.frontmostApplication` + `didActivateApplicationNotification`.
- Lock / unlock from `DistributedNotificationCenter` names `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`.
- Sleep / wake from `NSWorkspace.shared.notificationCenter`: `willSleepNotification`, `didWakeNotification`,
  `screensDidSleepNotification`, `screensDidWakeNotification`.
- Fast user switching from `sessionDidResignActiveNotification` / `sessionDidBecomeActiveNotification`.

### 3.2 The tick must never trust its own interval

Notifications get dropped. App Nap throttles timers. The process is suspended under a debugger. Sleep
stops `mach_absolute_time` but not the wall clock. So every tick reconstructs reality from two
independent clocks and never credits more than one interval:

```swift
func tick(now: Date, uptime: TimeInterval /* ProcessInfo.systemUptime */) {
    let wallDelta = now.timeIntervalSince(lastTickAt)
    let uptimeDelta = uptime - lastTickUptime
    defer { lastTickAt = now; lastTickUptime = uptime }

    // wall advanced but uptime did not -> the machine slept.
    // both advanced too far      -> we were throttled/suspended/the timer was starved.
    let discontinuity = wallDelta > policy.tickInterval + policy.tickTolerance   // 2 s
    if discontinuity {
        let cause: PauseCause = (wallDelta - uptimeDelta > 5) ? .systemSleep : .microIdleExceeded
        ingestGap(duration: wallDelta, endedAt: now, cause: cause)   // classified by §4, never credited
        return
    }

    let idle = readSystemIdle()
    session.idleDuration = idle
    creditOrPause(idle: idle, delta: min(wallDelta, policy.tickInterval))
}
```

The invariant this protects: **credited active work can never exceed elapsed wall-clock time.** It is
the first property test (§15).

### 3.3 Micro-idle: why 30 s of reading does not reset the clock

Provisional credit, confirmed by resumption, revoked by absence:

```swift
private func creditOrPause(idle: TimeInterval, delta: TimeInterval) {
    guard case .running = session.clock else { return }   // paused clocks credit nothing

    if idle < policy.activityEpsilon {            // 2 s: real input just happened
        session.credit(delta)
        session.provisionalGraceCredit = 0        // everything so far is confirmed work
    } else if idle < policy.microIdleGrace {      // 90 s: reading, thinking, watching a build
        session.credit(delta)
        session.provisionalGraceCredit += delta   // credited, but provisionally
    } else {
        // the gap turned out to be real absence: take the grace back and stop the clock
        session.revoke(session.provisionalGraceCredit)
        session.provisionalGraceCredit = 0
        session.pauseClock(cause: .microIdleExceeded, since: session.lastInputAt)
    }
}
```

Consequences, exactly as intended:

- **30 s spent reading a function** → credited, clock never pauses, no state change. The user does not
  experience the app "forgetting" that they were working.
- **3 min bathroom trip** → at 90 s the clock pauses and the 90 s of grace is revoked, so the recorded
  work matches the work actually done. On return the clock **resumes from where it was** — the trip
  did not earn a break and did not cost the user their accumulated progress toward one.
- **40 min lunch** → crosses the qualifying-break threshold: reset, break recorded, cycle over.

The grace window is the whole design. Too short and the app forgets you between keystrokes; too long
and a coffee run counts as coding. 90 s is the default and is configurable in
`[60 s ... 180 s]`; outside that range the behavior degenerates in one of those two directions.

---

## 4. Gap classification — the state transition table

Every non-credited stretch of time is a **gap**. A gap is classified once, when it ends (or when it
crosses a threshold, whichever comes first), by duration and context. This is the authoritative table.

```swift
enum GapClassification: String, Codable {
    case microIdle, shortPause, qualifyingBreak, longPause, sessionGap, meetingIdle
}

struct GapOutcome: Equatable {
    var creditsWork = false
    var pausesClock = false
    var resetsClock = false
    var recordsBreak = false
    var endsSession = false
}
```

### 4.1 Work-clock transitions

| # | Trigger / gap | Duration | Context | Classification | Clock | Break recorded | Session |
|---|---|---|---|---|---|---|---|
| 1 | Input gap | `0 – 90 s` | any | `microIdle` | **credit** (provisional) | no | continues |
| 2 | Input gap | `90 s – 5 min` | any | `shortPause` | **pause**, revoke grace | no | continues |
| 3 | Input gap | `5 min – 20 min` | not in meeting | `qualifyingBreak` | **reset** | **yes** (`.idleInferred`) | continues |
| 4 | Input gap | `20 min – 30 min` | not in meeting | `qualifyingBreak` | **reset** | **yes** | continues |
| 5 | Input gap | `≥ 30 min` | any | `sessionGap` | **reset** | no | **ends**; new session on return |
| 6 | Input gap | any | live meeting (mic/camera running) | `meetingIdle` | **pause** | no | continues |
| 7 | Any pause reaching | `20 min` | any cause incl. meeting | `longPause` | **reset** | no | continues |
| 8 | Screen lock | `< 5 min` | — | `shortPause` | **pause immediately** (no grace) | no | continues |
| 9 | Screen lock | `5 – 30 min` | — | `qualifyingBreak` | **reset** | **yes** | continues |
| 10 | Screen lock | `≥ 30 min` | — | `sessionGap` | **reset** | no | **ends** |
| 11 | System sleep | `< 5 min` | — | `shortPause` | **pause at `willSleep`** | no | continues |
| 12 | System sleep | `5 – 30 min` | — | `qualifyingBreak` | **reset** | **yes** | continues |
| 13 | System sleep | `≥ 30 min` | — | `sessionGap` | **reset** | no | **ends** |
| 14 | Display sleep | any | — | same bands as input gap | as bands | as bands | as bands |
| 15 | Fast user switch | any | — | same bands as screen lock | as bands | as bands | as bands |
| 16 | App cold start | gap since last persisted tick | — | same bands as input gap | as bands | as bands | as bands |
| 17 | Local day boundary (04:00) | — | — | — | **reset** | no | **ends** |
| 18 | Accepted break ends | `≥ 5 min` | — | `qualifyingBreak` | **reset** | **yes** (`.accepted`) | continues |
| 19 | Accepted break ends | `< 5 min` | — | `shortPause` | **pause only** | **no** | continues |

Rows worth defending:

- **Row 6 (meeting idle).** A 40-minute call where you never touch the keyboard is not coding and it is
  not a break. Crediting it would overstate the work; recording it as a break would tell the user they
  rested when they did not. So it pauses, and nothing else — until row 7 fires.
- **Row 7 (long pause resets without recording a break).** After 20 minutes away for *any* reason, the
  work context is gone; prompting "you've been at this 45 minutes" the second the meeting ends would be
  stale and wrong. The clock resets, but `breakCount` does not move and compliance is unaffected — the
  app does not get to credit the user with a break they did not take.
- **Row 19.** A break the user ends after 90 seconds is not a break. It resets nothing and is recorded
  as `.abandoned`. The alternative — counting it — makes the compliance number a lie the user can farm.
- **Rows 5 / 10 / 13 (session boundary).** Ending the session keeps "longest continuous session" honest
  and keeps a laptop reopened at 9 pm from being appended to the morning.

### 4.2 Reference thresholds

```swift
struct BreakPolicy: Codable, Equatable {
    // --- session model ---
    var tickInterval: TimeInterval        = 1
    var tickTolerance: TimeInterval       = 2
    var activityEpsilon: TimeInterval     = 2
    var microIdleGrace: TimeInterval      = 90         // 60...180
    var qualifyingBreak: TimeInterval     = 5 * 60     // 3...15 min
    var longPauseReset: TimeInterval      = 20 * 60
    var sessionGap: TimeInterval          = 30 * 60
    var dayBoundaryHour: Int              = 4          // local

    // --- break cycle ---
    var targetContinuousWork: TimeInterval = 45 * 60   // 20...120 min
    var absoluteMaxWork: TimeInterval      = 90 * 60   // fire-regardless floor
    var breakDurationTarget: TimeInterval  = 5 * 60
    var settleInAfterBreak: TimeInterval   = 5 * 60    // hard block on re-prompting

    // --- deferral ---
    var softDeferralWindow: TimeInterval   = 8 * 60
    var deepFocusExtension: TimeInterval   = 7 * 60    // once per cycle
    var seamIdleBlip: TimeInterval         = 20
    var staleBreakCeiling: TimeInterval    = 60 * 60   // abandon the cycle
    var rearmAfterStale: TimeInterval      = 10 * 60
    var rearmAfterSkip: TimeInterval       = 20 * 60
    var cooldownAfterExhausted: TimeInterval = 25 * 60

    // --- prompts ---
    var promptTimeout: TimeInterval        = 90        // no interaction -> ignored
    var snoozeDurations: [TimeInterval]    = [5*60, 10*60, 15*60]
    var maxSnoozesPerCycle: Int            = 3
    var maxSnoozeTotalPerCycle: TimeInterval = 30 * 60
    var minNotificationSpacing: TimeInterval = 5 * 60
    var maxNotificationsPerCycle: Int      = 4
    var dailyNotificationCap: Int          = 12

    var quietHours: QuietHours = .default
}
```

---

## 5. Part B — engine states

```swift
enum EngineState: Equatable {
    case working
    case breakDue(BreakDue)
    case breakActive(BreakActive)
    case snoozed(until: Date, index: Int, cycle: CycleID)
    case ignored(Escalation)
    case idle(since: Date, cause: PauseCause)
    case quiet(until: Date?, cause: QuietCause)
}

struct BreakDue: Equatable {
    var cycle: CycleID
    var dueSince: Date
    var seamWaitElapsed: TimeInterval = 0     // accrues ONLY while not hard-blocked
    var totalElapsed: TimeInterval = 0        // wall clock since dueSince
    var deepFocusExtensionUsed = false
    var promptedAt: Date?
    var snoozesUsed: Int = 0
    var snoozeTotal: TimeInterval = 0
    var notificationsThisCycle: Int = 0
    var lastVerdict: InterruptionVerdict?
}

struct BreakActive: Equatable {
    var startedAt: Date
    var plannedEnd: Date
    var origin: BreakOrigin     // .accepted, .idleInferred, .userInitiated
}

enum QuietCause: String, Codable {
    case scheduledQuietHours, userPaused, sustainedFocusMode, dailyCapReached
}

enum EscalationLevel: Int, Codable { case passive = 1, quietRepeat, seamArmed, final }

struct Escalation: Equatable {
    var cycle: CycleID
    var dueSince: Date
    var ignoredAt: Date              // t0 for the ladder
    var level: EscalationLevel
    var enteredLevelAt: Date
    var notificationsThisCycle: Int
}
```

`.idle` and `.quiet` are engine states, not session states: the session model keeps measuring
throughout (the rollup is still accurate during quiet hours). These two states only describe what the
engine is allowed to *say*.

### 5.1 Engine state transition table

`W` = continuous active work, `T` = `policy.targetContinuousWork`.

| From | Event | Guard | To | Side effects |
|---|---|---|---|---|
| `working` | tick | `W >= T` and not quiet | `breakDue` | open cycle, passive indicator → "due" |
| `working` | tick | `W >= T` and quiet-hours active | `quiet` | log `.quietSuppressed`, passive indicator only |
| `working` | gap ≥ grace | — | `idle` | clock pauses (§4) |
| `working` | quiet window starts | — | `quiet` | cancel nothing (nothing pending) |
| `working` | user picks "break now" | — | `breakActive` | begin break, `origin: .userInitiated` |
| `breakDue` | tick | verdict `.deliver` | `breakDue` (prompted) | deliver notification, `promptedAt = now` |
| `breakDue` | tick | verdict `.hardBlocked` | `breakDue` | **both deferral clocks pause**; passive indicator only |
| `breakDue` | tick | verdict `.softDeferred` | `breakDue` | `seamWaitElapsed += Δ` |
| `breakDue` | seam observed | not hard-blocked, not rate-limited | `breakDue` (prompted) | deliver immediately |
| `breakDue` | tick | `seamWaitElapsed >= softDeferralWindow (+ extension)` | `breakDue` (prompted) | **deliver anyway** |
| `breakDue` | tick | `totalElapsed >= staleBreakCeiling` | `working` | abandon cycle `.expired`; re-arm at `W + rearmAfterStale` |
| `breakDue` | user accepts | — | `breakActive` | begin break |
| `breakDue` | user snoozes | `snoozesUsed < 3` and `snoozeTotal + d <= 30 min` | `snoozed` | **work clock keeps running** |
| `breakDue` | user skips | — | `working` | `skippedBreakCount += 1`; re-arm at `W + rearmAfterSkip`; no reset; `consecutiveIgnoredCycles` **unchanged** |
| `breakDue` | no interaction for `promptTimeout` | user was present (input seen) | `ignored` | ladder level 1 (passive) |
| `breakDue` | no interaction for `promptTimeout` | user was absent (idle ≥ grace) | `idle` | not an ignore; retract prompt |
| `breakDue` | gap ≥ `qualifyingBreak` | — | `working` | break recorded (`.idleInferred`), cycle closed **honored** |
| `breakDue` | quiet window starts | — | `quiet` | withdraw the pending prompt; never queue it |
| `snoozed` | deadline reached | not hard-blocked | `breakDue` | `seamWaitElapsed = 0`; `totalElapsed` continues |
| `snoozed` | gap ≥ `qualifyingBreak` | — | `working` | break recorded; cycle closed honored |
| `snoozed` | user picks "break now" | — | `breakActive` | begin break |
| `ignored` | tick | ladder timing (§11) | `ignored` | next level; at most one notification per level |
| `ignored` | any user interaction | — | per action | ladder stops |
| `ignored` | gap ≥ `qualifyingBreak` | — | `working` | break recorded; cycle closed honored |
| `ignored` | tick | `totalElapsed >= staleBreakCeiling` | `working` | abandon cycle `.expired`; re-arm at `W + rearmAfterStale` |
| `ignored` | level 4 delivered + no response | — | `working` | cycle `.ignoredExhausted`; cooldown 25 min; consecutive-ignore counter += 1 |
| `breakActive` | tick | `now >= plannedEnd` | `working` | reset clock, record break, `lastBreakEndedAt = now` |
| `breakActive` | user ends early | elapsed `>= qualifyingBreak` | `working` | as above |
| `breakActive` | user ends early | elapsed `< qualifyingBreak` | `working` | **no reset, no break recorded**, log `.abandoned` |
| `breakActive` | input resumes | elapsed `< qualifyingBreak` | `breakActive` | keep the timer; do not nag; a break is not a jail |
| `idle` | input resumes | gap `< qualifyingBreak` | `working` or `breakDue` | resume clock; re-evaluate `W >= T` |
| `idle` | input resumes | gap `>= qualifyingBreak` | `working` | reset, record break, close any open cycle honored |
| `idle` | gap `>= sessionGap` | — | `working` (new session) | finalize session |
| `quiet` | window ends | `W >= T` | `breakDue` | fresh cycle, fresh deferral clocks — **never a backlog** |
| `quiet` | window ends | `W < T` | `working` | — |
| any | user pauses the app | — | `quiet(.userPaused)` | duration chosen by user; measurement continues |

Two structural rules the table encodes:

1. **A break taken without being asked always closes the open cycle as honored.** The user walking away
   on their own is the success case, not a missed prompt.
2. **Quiet hours withdraw, never queue.** Nothing the engine wanted to say at 18:55 is allowed to
   arrive at 09:00.

---

## 6. Engine inputs

```swift
struct EnvironmentSnapshot: Equatable {
    var now: Date
    var idleSeconds: TimeInterval
    var keystrokeRate: Double              // events/sec over the last 5 s

    var frontmost: AppIdentity?
    var activity: ActivityClassification
    var seamsSinceLastTick: [Seam]

    // system signals (facts, not guesses)
    var audioInputRunning: Bool            // kAudioDevicePropertyDeviceIsRunningSomewhere
    var cameraRunning: Bool                // kCMIODevicePropertyDeviceIsRunningSomewhere
    var displayCaptured: Bool              // always false: no permission-free signal exists
    var screenLocked: Bool
    var focusModeActive: Bool?             // nil == undetectable, see §7.1
    var frontmostIsFullscreen: Bool        // AX kAXFullscreenAttribute on the focused window
    var frontmostIsPresentationApp: Bool

    // power
    var batteryFraction: Double?           // nil on desktops
    var isCharging: Bool
    var lowPowerMode: Bool

    // calendar-adjacent (optional, read-only EventKit; absent if not granted)
    var calendar: CalendarSignals?
}

struct CalendarSignals: Equatable {
    var eventInProgress: Bool
    var inProgressIsBusy: Bool
    var inProgressHasVideoLink: Bool
    var minutesUntilNextBusyEvent: Int?
}

enum Seam: String, Codable {
    case applicationSwitch          // the canonical seam
    case idleBlip                   // >= 20 s of no input, then input resumes
    case terminalCommandFinished    // opt-in shell integration only (§7.3)
    case meetingEnded               // declared, never produced. See 7.3
    case fullscreenExited
    case spaceSwitch
}
```

The engine also reads from the session: `continuousActiveWork`, `timeSinceLastBreak`, `idleDuration`,
`activityType` + `activityConfidence`, `applicationSwitches`, `focusScore`, `snoozeCount`,
`ignoredPromptCount`, `skippedBreakCount`, plus today's `notificationsDelivered` and
`consecutiveIgnoredCycles`.

---

## 7. Interruption appropriateness

The requirement: **the app must never be the thing that ruined a moment.** One badly timed banner
during a demo costs more trust than fifty well-timed ones earn. The policy is therefore asymmetric —
generous with waiting, strict about never firing into a hard block — but bounded, so that politeness
cannot become silence.

```swift
enum InterruptionVerdict: Equatable {
    case deliver
    case hardBlocked(HardBlock)
    case softDeferred(SoftDeferReason)
    case rateLimited(RateLimit)
}

enum HardBlock: String, Codable {
    case audioInputInUse          // mic is live: call, recording, dictation
    case cameraInUse
    case screenBeingShared
    case presentationFullscreen
    case focusModeActive
    case screenLocked
    case systemSleeping
    case fastUserSwitched
    case settleInAfterBreak
    case videoEventInProgress     // calendar event with a video link AND mic live
    case imminentMeeting          // < 2 min before a busy event starts
}

enum SoftDeferReason: String, Codable {
    case deepFocus
    case typingBurst              // > 2 keystrokes/sec in the last 5 s
    case terminalCommandRunning
    case preMeetingWindow         // 2...6 min before a busy event
    case recentAppLaunch          // < 20 s since the frontmost app changed
}

enum RateLimit: String, Codable {
    case quietHours, dailyCapReached, cycleNotificationCap, minimumSpacing, ignoreBackoff
}
```

### 7.1 Hard blocks — never deliver, and the deferral clocks stop

| Block | Detection | Notes |
|---|---|---|
| `audioInputInUse` | CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` on every input device, attributed through `kAudioProcessPropertyIsRunningInput`, and **bounded**: see §7.1.1 | Public API, no permission. Covers Zoom/Meet/Teams/huddles/recording uniformly, which is why the engine keys on *the microphone*, not on a list of app bundle ids it will always be behind on. |
| `cameraInUse` | CMIO `kCMIODevicePropertyDeviceIsRunningSomewhere` over `kCMIOHardwarePropertyDevices` | Same idea for video, and **shipped**. Public API, no Camera permission, no prompt, verified against `tccd`. A read failure is `nil`, never `false`. Four states with the same calibration guard as audio, because a virtual camera can hold a device open forever. This closes the camera-on / microphone-muted posture, which is the normal one on Teams and Meet, with no inference at all. |
| `recentCallContinuing` | The call latch: a capture device ran continuously for >= 45 s and stopped less than the hold budget ago | See §7.7. Named after what it asserts, not after what you might conclude from it. |
| `screenBeingShared` | **Nothing. This block cannot fire.** | `CGDisplayIsCaptured`, which this row used to name, is annotated `API_DEPRECATED("No longer supported", macos(10.0,10.9))` and does not compile from Swift. CoreMediaIO enumerates no display-capture device. ScreenCaptureKit needs the Screen Recording grant CLAUDE.md 4.2 forbids hard-requiring. The weaker and honest claim: someone looked for a permission-free signal and did not find one. The mitigation this row promised was a manual toggle, and it never shipped; it does now, as "I am in a meeting" in the menu, time-boxed to two hours. `--doctor` prints this block as UNOBSERVABLE with the reason and says out loud that it never fires. |
| `presentationFullscreen` | AX `kAXFullscreenAttribute` on the focused window **AND** (presentation-capable app **OR** camera/mic live) | Fullscreen **alone is not a block** — developers work fullscreen all day, and blocking on it would mean never firing for half the user base. |
| `focusModeActive` | Parse `~/Library/DoNotDisturb/DB/ModeConfigurations.json` when readable; otherwise unknown | **Honest limitation:** no public API. Mitigation that always works: the app posts at `UNNotificationInterruptionLevel.active` and *never* `.timeSensitive` or `.critical`, so macOS itself suppresses the banner during any Focus mode. When Focus is undetectable the engine still "delivers" and the OS may swallow it — the passive indicator is the safety net, and the cycle is recorded as `.deliveryUnconfirmed` rather than counted as ignored. |
| `screenLocked` / `systemSleeping` / `fastUserSwitched` | Workspace + distributed notifications | Nobody is there. |
| `settleInAfterBreak` | `now - lastBreakEndedAt < 5 min` | You do not tell someone who just sat back down to get up. |
| `imminentMeeting` | `minutesUntilNextBusyEvent <= 2` | The two minutes before a call are not free time. |

While hard-blocked: **`seamWaitElapsed` pauses and no notification is emitted on any channel.** A
two-hour meeting therefore costs the break cycle its deferral budget nothing — the cycle is
preserved, not consumed and not fired stale. The work clock's own behavior during that time is
governed by §4 rows 6 and 7, independently.

This paragraph used to say `totalElapsed` pauses too. It does not: `handleBreakDue` adds `dt` to it
unconditionally, before the verdict is even computed, and the comment on `BreakDue.totalElapsed`
calls this document out by name. §7.4 depends on the code's behaviour, not on the old sentence, so
the doc was the bug and this is the fix. It matters more now that the call latch makes long hard
blocks ordinary: a cycle that spends an hour blocked hits the stale ceiling and is abandoned as an
*excluded* opportunity, which is what stops a call quietly turning into a prompt nobody asked for
an hour later.

Also true, and worth stating because nothing else in this document does: while hard-blocked, **a
prompt already on screen is withdrawn** (`WithdrawReason.blocked`) and the prompt stamp is cleared
with it. Without the first half, a panel delivered one second before a call sat on a screen share
for its duration. Without the second, the 90-second prompt timeout had already elapsed the instant
the block lifted, so the user was charged an ignored prompt for a meeting they were never allowed to
answer during, and two of those truncate the ladder to L1 and L2.

#### 7.1.1 The microphone is a fact, but "you are on a call" is an inference

Every other row above is an OS fact *about the user*: the screen really is locked, another
account really is on the console. `audioInputInUse` is the odd one. The fact is **a device is
running**. "Therefore you are on a call" is a guess, and a guess in the uncatchable list is how
a Mac with Krisp, BlackHole, an aggregate device or a headset daemon goes silent forever: those
hold an input device open permanently, the engine read it as a call, and every cycle it opened
was hard-blocked on arrival. Recovery depended on `AudioDeviceCollector`'s calibration, an hour
of awake observation away, and nothing on screen said any of it.

Two changes, and neither of them lowers the bar for a real call.

**Attribution.** `SensorStack.audioDeviceHold` asks the question `micLiveForLatch` already asked
one method above and the hard block never did. Three answers: the device bit is false, so false;
the process table could not be read, so the bare bit, exactly as before; the table was read and
**nothing at all** has input open, named or not, which is evidence of absence and drops the
block. A running process with no bundle id counts as a holder, because a command-line recorder
has no bundle id and interrupting a recording would turn a silence bug into an interruption bug.
The empty reading has to hold still for 30 s before it is acted on: the per-object listener's
latency against the device property is unmeasured, and a transient disagreement at the start of
every real call would be worse than the bug.

**A ceiling in Core.** Attribution does nothing for Krisp, which is an app and holds the
microphone through its own process. So `CycleBudget.uncorroboratedAudioElapsed` measures how long
the current opportunity has been held by a device with nothing else agreeing, and past
`uncorroboratedAudioCeiling` the block downgrades to `SoftDeferReason.liveCaptureUnattributed`,
which §7.2's seam budget then bounds. The ceiling is `latchFactHold + latchAnchorExtension`
(8 + 12 = 20 min), this repo's own written answer to how long a capture fact alone may mean call,
rather than a new number.

Corroboration is anything independent of that microphone bit: a camera running, a call app the
latch actually adopted, a manual "I'm in a meeting", or a busy calendar event in progress. Any
one of them and the block is unbounded exactly as it was. The latch arming on the same microphone
is *not* corroboration; that is the same evidence counted twice. The counter resets the instant
the device releases, so a run of real short calls never accumulates.

**The cost, stated rather than discovered.** A long uncorroborated capture, a podcast take or a
DAW session with no camera and no calendar entry, can now be interrupted where before it never
would be. It is a seam wait rather than an immediate prompt, the sound channel is suppressed for
the whole time capture is live (§7.5), and "Ignore this input device" buys 30 minutes. That is
the trade: one interrupted take against an app that is invisible forever on a Krisp Mac.

### 7.2 Soft deferrals — wait for a seam, but on a budget

While soft-deferred, `seamWaitElapsed` accrues. Budget:

```
budget = softDeferralWindow (8 min)
       + (deepFocus && !deepFocusExtensionUsed ? deepFocusExtension (7 min) : 0)
maximum 15 minutes of seam-waiting per cycle
```

Deliver on the **first** of:

1. any `Seam` arriving while not hard-blocked and not rate-limited → deliver within one tick;
2. `seamWaitElapsed >= budget` → **deliver anyway**, seam or no seam;
3. `continuousActiveWork >= absoluteMaxWork` (90 min) → deliver at the next seam or within 60 s,
   whichever is first, ignoring deep focus entirely.

Rule 3 is the floor that makes the whole policy safe to be generous elsewhere.

### 7.3 Seams

A seam is a moment the user has already broken their own concentration:

| Seam | How | Strength |
|---|---|---|
| `applicationSwitch` | `NSWorkspace.didActivateApplicationNotification` | strongest — they chose to context-switch |
| `idleBlip` | ≥ 20 s without input, then input resumes | strong |
| `meetingEnded` | **declared and never produced** | See below. |
| `fullscreenExited` | AX attribute flipped | medium |
| `spaceSwitch` | active space changed | medium |
| `terminalCommandFinished` | **opt-in only** | strong when available |

**`meetingEnded` has no producer, and deliberately gains none.** A seam *delivers*: `verdict` returns
`.deliver` for any non-empty seam before the soft reasons are consulted at all. So emitting one the
instant the microphone stops would fire the prompt on "thanks everyone, bye", which is the complaint
this whole area exists to fix rather than a fix for it. The call latch's hold (§7.7) is what serves
the purpose the seam was invented for, and it serves it as a *block* rather than as a trigger. The
row stays in the table so the next person does not re-invent it.

`terminalCommandFinished` requires shell integration the user installs deliberately: a `precmd`/`preexec`
hook writing one byte to a Unix domain socket in the app's container. Without it, the app **cannot** see
that a build finished, and the spec does not pretend otherwise — the `idleBlip` seam covers most of the
same moments, because people stop typing while a command runs.

### 7.4 Expiry, and the two failure modes

**When the soft window expires, the app fires.** That is the entire answer to "so polite it never
fires". The deferral policy can change *when* within a bounded window, never *whether*.

**When `totalElapsed` reaches `staleBreakCeiling` (60 min)** — which can only happen under sustained
hard blocks — the cycle is **abandoned**, not fired. This applies in `ignored` as well as in
`breakDue`, and it has to: `ladderElapsed` only accrues while *not* hard-blocked, so a sustained
block freezes the ladder and `.ignoredExhausted` can never be reached. Without the ceiling in both
states an escalating cycle under a long meeting is unbounded. A "time for a break" arriving 70 minutes late is
noise, and worse, it is evidence to the user that the app is not paying attention. The cycle is logged
`.expired`, counted as an *excluded* opportunity in the rollup (§14), and the engine returns to
`working` with the work clock **intact**, re-arming only after another `rearmAfterStale` (10 min) of
continuous active work so the user is not prompted the instant they leave the meeting.

Summary of the two extremes and the specific mechanisms against each:

| Failure mode | Mechanisms |
|---|---|
| **Nagging** | max 4 notifications per cycle; ≥ 5 min between any two; daily cap of 12; snooze always offered (3×); explicit skip that costs nothing; escalation ladder that ends permanently; backoff to 1 notification per cycle after 2 consecutive ignored cycles; ladder timing that stretches, never compresses. A skip neither trips that backoff nor clears it: it is an answer, so it is not an ignore, and it is not a break, so it does not earn a clean slate. |
| **Never firing** | soft deferrals are bounded at 15 min total; deep focus buys one extension, once; hard blocks pause rather than cancel; `absoluteMaxWork` floor at 90 min; the passive indicator is always live even during quiet hours, DND and cap exhaustion, so the information is never lost — only the interruption is. |

### 7.5 Channels

| Channel | Interrupts? | Allowed under |
|---|---|---|
| Passive menu-bar indicator (icon state + title) | no | **always**, including quiet hours, DND, daily cap, hard blocks |
| Standard notification (`.active`, silent by default) | yes | not hard-blocked, not rate-limited |
| Notification with sound | yes | escalation level 3+ only, never twice in a cycle, and never while a microphone or camera is live |
| Panel / HUD overlay (dismissible, non-modal, never key-window-stealing, never fullscreen) | yes | escalation level 4 only; downgraded to a notification on battery < 20 % or Low Power Mode |

Nothing in the app is ever modal, ever blocks input, or ever takes keyboard focus. There is no
configuration in which the app can prevent the user from working.

Live capture suppresses the sound channel for the same reason low battery does, and it matters more
now that §7.1.1 lets a prompt reach a Mac with a microphone open: the rung still arrives, it just
does not chime into somebody's recording.

**One correction to the row above, which the implementation got wrong for a while.** When system
notifications are off, which is the default, every rung is drawn by the app itself, because there is
no other channel. That is fine; what was not fine is that the panel was built at `screen.frame` on
every display and filled at 78 % black, so an L1 `SIGTSTP` blacked out the machine. Below level 4
the app's own prompt is a card in the corner of one screen. Level 4 takes every display, and that is
the only rung that does, because `SIGSTOP` is the one the product says cannot be ignored and the
bluff has to cost something.

### 7.6 Low battery

Battery is an input about *cost and context*, never a reason to skip a break:

- battery < 20 % and discharging, or Low Power Mode: tick interval 1 s → 5 s; device-running polls
  throttled to every 15 s; overlay channel disabled (notification instead); animations disabled.
- battery < 10 %: additionally suppress the level-4 overlay entirely.
- Battery never changes *whether* a break is due, and never suppresses the passive indicator.

### 7.7 Calendar-adjacent signals

Read-only EventKit, optional, degrades to nothing if not granted:

- Busy event in progress **with** a video link **and** mic live → hard block (`videoEventInProgress`).
- Busy event in progress alone → **soft** deferral only. People leave events on their calendars they
  are not attending; a calendar entry is a guess, and guesses do not hard-block (§2.1).
- `minutesUntilNextBusyEvent <= 2` → hard block.
- `minutesUntilNextBusyEvent` in `3...6` → soft defer (`preMeetingWindow`).
- **Opportunistic early prompt:** if `W >= 0.8 * T` and the next busy event starts in 6–15 minutes, the
  engine may prompt *now*, framed as "good moment before your next event". This is the one case where
  the app fires early, and it is the most natural seam a calendar can offer.

### 7.8 The call latch — a bounded trailing edge on two facts

`audioInputInUse` and `cameraInUse` are facts, and until now they ended the instant the bit dropped,
which is exactly what pressing mute does. That is the gap: in a call where the microphone is muted
and the camera is off, nothing at Tier 0 is live, the deferral runs out, and the prompt lands in the
meeting.

The latch asserts something narrower than "you are in a meeting":

> a capture device on this machine ran continuously for at least `latchArmDwell` and stopped less
> than `holdBudget` seconds ago.

Every clause is an OS property read plus arithmetic on the injected clock. There is no `Confidence`
anywhere in it, no `Activity`, no `ConcurrentStates`, and no window title: the guess is not
*representable* in `MeetingLatchInput`, which is cheaper than promising not to use it. That is why
the block is called `recentCallContinuing` rather than `inMeeting`, and why the user-facing string
says what was observed and when rather than what to conclude from it.

**Phases.** `closed → arming → live → held → (live | closed)`.

| Transition | Rule |
|---|---|
| `closed → arming` | capture live |
| `arming → live` | capture continuously live for `latchArmDwell` (45 s) |
| `arming → closed` | capture stops before the dwell, or an unobserved gap |
| `live → held` | capture stops, or an unobserved gap ended while it was not running |
| `held → live` | capture returns. No second dwell inside one episode |
| `held → closed` | `now - lastLive >= holdBudget`, or a ceiling, or a gap |

`isHolding` is normally **false** while capture is live, because the two live blocks already cover
that. `heldSeconds` therefore measures the latch's *own* footprint and nothing else, which is what
makes the ceilings below mean anything at all: a developer idling in a Discord voice channel with
the microphone open cannot accumulate a single second of hold.

**The one exception, and why it is not a hole in that reasoning.** `audioInputRunning` and
`cameraRunning` are `.running`-only, so on a Mac with Krisp, Loopback or BlackHole installed they
are both false for the whole of a genuinely live call (§2.3a of ACTIVITY-DETECTION). There the two
live blocks are not covering anything, the latch is the only thing left, and staying silent in
`.live` inverted the protection: absent during the meeting, present for twenty minutes after it. So
the latch is handed `liveCaptureAlreadyBlocks` — precisely `audioInputRunning || cameraRunning`, not
inferred from its own `micLive`, which on that Mac is true from attribution alone — and when it is
false the latch holds during the call and **charges itself for the time**. The accounting property
above survives: the latch is charged exactly when the latch is the thing blocking.

**The hold budget**, recomputed every tick:

```
if an adopted anchor has quit           -> latchAnchorQuitHold   (90 s)
else latchFactHold (8 min) + (anchor still running ? latchAnchorExtension (12 min) : 0)
```

The base is unconditional on the capture fact. The anchor can only ever *add* the extension or
collapse the hold; delete every line of anchor logic and an eight-minute fact hold remains. The
anchor is adopted once, at arming, preferring attribution ("CoreAudio says this bundle has the
microphone") over frontmost over "a conferencing app is running". A browser can anchor only through
the first two, because a browser is open on every developer's Mac all day.

**Constants.** `latchArmDwell` 45 s; `latchFactHold` 8 min; `latchAnchorExtension` 12 min;
`latchAnchorQuitHold` 90 s; `latchEpisodeCeiling` 90 min of hold; `latchDailyCeiling` 3 h of hold;
`latchRearmQuiet` 10 min; `latchManualInhibit` 30 min; `latchManualHold` 2 h; `latchGapTolerance`
10 s; `latchColdStartGrace` 90 s. Maximum single hold: 20 minutes, of which the last 12 need an
adopted app still running.

**Unobserved gaps.** A step larger than `latchGapTolerance` on either clock is time nobody watched,
and it is credited in neither direction: if it exceeds what was left of the hold the latch closes,
because a call can end while the lid is shut; if it is shorter, the hold is not *spent* on it, so a
two-minute lid-close on the way to a meeting room does not end the call. Note that the monotonic
clock does not advance across a system sleep while the wall clock does, so the gap is the larger of
the two deltas. `MutableTimeSource.sleepAndWake` advances both and therefore models a throttle, not
a sleep; the test for this uses two separately-advanced values.

Three clauses of that rule are load-bearing and were each missing once:

- **It applies in `live`, not only in `held`.** A lid closed mid-call used to fall straight through
  to `live → held` on wake and start a fresh twenty-minute hold, however long the machine had been
  asleep, under a sentence claiming the microphone was live "until just now". A gap in `live` with
  capture no longer running is charged as though capture stopped at the *start* of it, and a gap
  longer than the whole hold closes the latch, because a call cannot still be running after one.
- **The forgiveness accumulates, and is bounded.** Refunding each short gap into `lastLive` without
  a total meant a process throttled to 12-second samples — App Nap, or heavy load, CLAUDE.md §3.4 —
  held a break back indefinitely, while `heldSeconds` stayed at zero so no ceiling could catch it
  either. The per-episode total of forgiven time is capped at the hold budget; past that the latch
  closes as a discontinuity.
- **Forgiven time still costs the ceilings.** It is time the latch spent holding, so it is charged
  to `heldSeconds` even though it is not charged to the hold. The bound above is what stops one long
  sleep from spending the whole day's ceiling on a call that ended before it.

**Why it is not persisted.** A latch restored from disk is a suppression that can outlive the bug
that created it, across launches, invisibly, and quitting the app is a user's crude escape hatch
that has to keep working. `EngineState` is rebuilt `.initial` at every launch for the same reason.
Only the day's accumulated hold survives, because a counter can only ever make the app noisier, and
without it the daily ceiling is defeated by quitting and reopening.

**The circuit breakers**, in order of how visible they are:

1. `.unreliable` inheritance. Attribution (§2.3a of ACTIVITY-DETECTION) is what keeps a downgraded
   Mac protected at all, at both edges of the call — but it is per-process evidence, so it can only
   name apps the bundle-id list already knows, and it degrades visibly to the device bit when the
   process table cannot be read.
2. Episode ceiling, 90 minutes of hold, then 10 minutes of quiet capture before it may re-arm.
3. Daily ceiling, 3 hours of hold, until the next local day.
4. `IndicatorState.held`, a distinct menu bar state, and a dropdown line naming the fact and the
   closing time, with "Not in a meeting" one click away. `--doctor` is not a safety valve, because
   nobody runs it; this is.
5. `holdBreaksDuringCalls` in Settings, which disables the latch and **nothing else**: a live
   microphone or camera still blocks, because that is a fact and it predates the switch. The switch
   ends every hold this file produces, the manual "I'm in a meeting" one included — a row that says
   it controls holding and leaves a two-hour assertion running would be lying. And it is a switch,
   not a fuse: the disabled state clears the moment it comes back on, which it did not do at first,
   so turning the feature off and on again used to kill it until the app was relaunched.

**The weak states defer rather than block.** `arming`, and a 90-second cold-start window when a
call-capable app is running, both produce `SoftDeferReason.inferredMeeting`. That is also the only
meeting deferral a zero-permission user can receive at all: `meetingConfidence` is clamped to the
Tier 0 ceiling (0.55), which sits below the specific-claim threshold (0.60), so
`ConcurrentStates.inMeeting` is structurally false without Accessibility and the older branch is
unreachable. Raising the ceiling would mean fixing an honesty mechanism by breaking it. This gets
the deferral from a fact instead.

**What it still misses**, stated rather than buried: a call joined muted with the camera off and
never unmuted (no capture fact ever happens); Google Meet in Safari, whose audio attributes to
`com.apple.WebKit.GPU` and so names no app; and a screen share with the microphone muted, which is
unobservable at Tier 0. The manual "I'm in a meeting" hold is the answer to all three, and it is the
mitigation §7.1 promised years ago and never shipped.

---

## 8. Verdict evaluation, in order

```swift
func verdict(_ s: EnvironmentSnapshot, _ session: DeveloperSession,
             _ cycle: BreakDue, _ day: DailyCounters) -> InterruptionVerdict {
    // 1. hard blocks — evaluated first, pause the deferral clocks
    if s.screenLocked            { return .hardBlocked(.screenLocked) }
    if s.audioInputRunning       { return .hardBlocked(.audioInputInUse) }
    if s.cameraRunning           { return .hardBlocked(.cameraInUse) }
    if s.meetingLatch.isHolding  { return .hardBlocked(.recentCallContinuing) }   // 7.8
    if s.displayCaptured         { return .hardBlocked(.screenBeingShared) }      // cannot fire
    if s.frontmostIsFullscreen && (s.frontmostIsPresentationApp || s.cameraRunning) {
        return .hardBlocked(.presentationFullscreen)
    }
    if s.focusModeActive == true { return .hardBlocked(.focusModeActive) }
    if let e = session.lastBreakEndedAt,
       s.now.timeIntervalSince(e) < policy.settleInAfterBreak { return .hardBlocked(.settleInAfterBreak) }
    if let c = s.calendar, (c.minutesUntilNextBusyEvent ?? .max) <= 2 { return .hardBlocked(.imminentMeeting) }

    // 2. rate limits — do not pause the clocks; they close the cycle instead
    if policy.quietHours.contains(s.now)                  { return .rateLimited(.quietHours) }
    if day.notificationsDelivered >= policy.dailyNotificationCap { return .rateLimited(.dailyCapReached) }
    if cycle.notificationsThisCycle >= policy.maxNotificationsPerCycle { return .rateLimited(.cycleNotificationCap) }
    if let last = day.lastNotificationAt,
       s.now.timeIntervalSince(last) < policy.minNotificationSpacing { return .rateLimited(.minimumSpacing) }
    if day.consecutiveIgnoredCycles >= 2 && cycle.notificationsThisCycle >= 1 {
        return .rateLimited(.ignoreBackoff)
    }

    // 3. the floor beats every soft consideration
    if session.continuousActiveWork >= policy.absoluteMaxWork { return .deliver }

    // 4. soft deferrals, only while the budget lasts
    let budget = policy.softDeferralWindow
        + (session.isInDeepFocus(now: s.now, policy: policy) && !cycle.deepFocusExtensionUsed
           ? policy.deepFocusExtension : 0)
    if cycle.seamWaitElapsed < budget {
        if !s.seamsSinceLastTick.isEmpty            { return .deliver }        // a seam beats any soft reason
        if s.keystrokeRate > 2.0                    { return .softDeferred(.typingBurst) }
        if s.terminalCommandRunning                 { return .softDeferred(.terminalCommandRunning) }
        if let c = s.calendar, (3...6).contains(c.minutesUntilNextBusyEvent ?? .max) {
            return .softDeferred(.preMeetingWindow)
        }
        if session.isInDeepFocus(now: s.now, policy: policy) { return .softDeferred(.deepFocus) }
    }
    return .deliver     // budget spent: fire.
}
```

Order matters and is part of the spec: hard blocks precede rate limits (a blocked prompt should not
burn a cycle's notification budget), rate limits precede the floor, and a seam beats every soft reason.

---

## 9. Snooze semantics

- **Offered durations:** 5 / 10 / 15 minutes. 5 is the primary button; the others live behind a
  disclosure so the common case is one click.
- **Maximum 3 snoozes per cycle**, and `snoozeTotal` capped at 30 minutes. Durations offered shrink to
  fit the remaining cap (a third snooze after 5 + 15 may only be 10).
- **After the cap:** the prompt no longer offers snooze. It offers exactly two actions — *Take it now*
  and *Skip this one*. Removing the option is honest; offering a fourth snooze that silently behaves
  like the third is not.
- **What a snooze does to the work clock: nothing.** The clock keeps running. Snoozing defers the
  question, it does not buy credit. If you snooze 15 minutes at 45 minutes of work, you are at 60
  minutes of work when it returns, and the copy says so.
- **On snooze expiry:** re-enter `breakDue` with `seamWaitElapsed = 0` (a fresh seam window — the
  deferral machinery gets to do its job again) but `totalElapsed` continuing from the original
  `dueSince`, so snoozing cannot be used to outrun the stale ceiling.
- **Snooze while hard-blocked** cannot happen — there is no prompt to snooze.
- **Skip** (`skipThisOne`): closes the cycle, `skippedBreakCount += 1`, no reset, no break recorded,
  counted as a *missed* opportunity in compliance (it was a real, answered opportunity). The engine
  re-arms after another `rearmAfterSkip` (20 min) of continuous active work. This is the mid-deploy
  escape hatch and it is deliberately cheap to use.
- **Skip is not the cheap gesture, and the UI must not let it look like one.** Twenty minutes of
  silence is the longest suppression in the engine, so the control that buys it says so, and Escape
  does not call it. Escape and *Not now* leave the prompt standing in the engine: it times out after
  `promptTimeout` and the ladder climbs, which is what §10 means by ignored and what the product
  means by a rung you are allowed to catch.
- **Skip leaves `consecutiveIgnoredCycles` alone.** It used to reset it, which made waving a prompt
  off worth as much to the ladder backoff as taking the break, while the same act still counted
  against compliance. It is an answer, so it is not an ignore; it is not a break, so it does not earn
  a clean slate.

---

## 10. Ignored: definition

A prompt is **ignored** when all of the following hold:

1. it was delivered (`promptedAt != nil`) **and it reached the screen** (see below),
2. `promptTimeout` (90 s) has elapsed with no interaction,
3. **and the user was present** — at least one input event occurred during that window.

"Reached the screen" is decided in the app layer, not the engine, because only the app can
see its own window. When the app draws the prompt itself (the default), it asks the window
server whether the panel is composited — `kCGWindowIsOnscreen` for the panel's window number,
the same bit a screenshot sees — re-orders the panel on every tick until it is, and writes the
`break_prompt` line only at that moment. A prompt the window server never confirmed therefore
has no `break_prompt` line, is never recorded as ignored (`recordIgnoredPrompt` is dropped in
`AppModel.execute`), and its cycle is excluded by the rollup (§14) rather than counted as a
miss. A system notification, when the user opts into one, cannot be seen by the app and is
taken on trust. The engine still starts its 90 s clock from emission, so a delivery that takes
several ticks to confirm shortens the window the user gets; that is the accepted cost of
keeping the confirmation out of `Core`.

Condition 3 is what keeps the ladder honest. If they walked away, that is not an ignore; it is
`idle`, and if it lasts 5 minutes it is a break and the cycle closes as honored. Escalating at someone
who is not there is the purest form of the failure this design is trying to avoid.

If `focusModeActive` is unknown and the OS may have swallowed the banner, the cycle is recorded
`.deliveryUnconfirmed` and **cannot** advance past ladder level 2.

---

## 11. Escalation ladder

`t0` = the moment the prompt was classified ignored.

| Level | Fires at | Channel | Counts toward caps | Behavior |
|---|---|---|---|---|
| **1 — Passive** | `t0` | menu-bar indicator turns amber, count visible on hover | **no** | Silent. No banner. The information is available; the interruption is not. |
| **2 — Quiet repeat** | `t0 + 5 min` | notification, no sound | yes | Different copy, acknowledging the elapsed time rather than repeating verbatim. |
| **3 — Seam-armed** | armed at `t0 + 12 min`, fires at the **first seam**, forced at `t0 + 20 min` | notification, sound (the only sound in the cycle) | yes | The engine stops guessing and waits for the user to break their own concentration. This is the level most likely to land. |
| **4 — Final** | `t0 + 35 min` | dismissible panel/HUD (downgraded to a notification on low battery, or if hard-blocked when due) | yes | One assertive, still non-blocking presentation. Then the ladder **ends permanently for this cycle**. |

After level 4 with no response: cycle → `.ignoredExhausted`, `consecutiveIgnoredCycles += 1`, engine
returns to `working` with a **25-minute cooldown** before a new cycle may open. No further
notification about this cycle is ever emitted.

**A ladder ends when it has nothing left to deliver, not when its timer runs out.** The engine used
to decide exhaustion by waiting for `ladderLevel4 + promptTimeout` whenever level 4 had not been
delivered. Under rule 5 below the ceiling is capped to level 2, and level 2 is then refused by
`ignoreBackoff` for the rest of the cycle, so nothing could ever arrive and the engine sat running a
four-rung clock over rungs it had already switched off. That was **36 of the 63 minutes** a user was
left alone after two ignored opportunities, and nobody chose it: the cooldown is 25 and the timeout
is 1.5. `InterruptionPolicy.ladderIsSpent` states the same fact `rateLimit` states, from counters
that only grow, so exhaustion now fires when it becomes true. The gap falls to **26 min 30 s**, which
is not a new cadence: it is already the gap between a normally exhausted ladder and the next cycle.
`cooldownAfterExhausted` is untouched at 25 minutes, and so is every other number here.

The indicator through all of this is `IndicatorState.backedOff`, which is dim and full: a break is
owed and the app has decided not to ask. It used to be `.escalating` during the capped ladder, which
was a positive claim that the opposite of the truth was happening, and `.working` during the
cooldown, with the work clock still climbing against a threshold nothing was waiting for.

**Anti-spam invariants** (all enforced in `verdict`, all independently sufficient):

1. At most **one** notification per ladder level.
2. At most **4** notifications per break cycle (initial prompt + levels 2, 3, 4).
3. Minimum **5 minutes** between any two notifications from any source. Realized gaps in the ladder are
   5 / 7+ / 15 minutes — the spacing **stretches** as the ladder climbs; it never compresses.
4. A hard block at a level's scheduled time **postpones** that level (the ladder clock pauses); it never
   stacks two levels together on release.
5. **Backoff:** after 2 consecutive fully-ignored cycles, for the rest of the local day the ladder is
   truncated to levels 1–2 — one notification per cycle, maximum. Reset by any **qualifying break**
   (`qualifyingBreak`, 5 min), and deliberately not by the cycle it was attached to. A truncated cycle
   is closed `promptTimeout` after its single prompt — that is what truncating it means — so a user who
   answers even a minute late starts their break with no open cycle. While the reset was conditional on
   one, the backoff was unescapable for the rest of the day for everyone who did not answer inside 90
   seconds, which is the window the backoff exists to shorten. `honoredOpportunities` stays conditional
   on an open cycle, because the compliance denominator only grows when an opportunity was opened.
6. **Daily cap** (12) overrides everything above. On reaching it, the app goes passive-only until the
   next day boundary and records `quiet(.dailyCapReached)`. That state is terminal until the boundary
   and computes no verdict, so it writes no `gate` line either: the menu is the only place a user can
   find out, and it says so in words (`QuietCause.summary`). It drew as the literal title "quiet hours"
   for every cause until the counters started surviving a relaunch made it reachable in practice — a
   false label on an app that has gone quiet for the rest of the day is the failure this whole section
   exists to prevent.

Cap arithmetic: a well-matched day is ~9 cycles in 8 hours × 1 notification each = 9, under the cap. A
day where everything is ignored hits the cap after ~3 cycles — and the backoff rule engages after 2.
The caps bind in exactly the situation they are meant for.

The knock-on from ending a capped ladder promptly, said here rather than left to be found: backed-off
cycles close sooner, so a user who ignores everything reaches the daily cap earlier in the afternoon.
That trades an unnamed hour of drift for `quiet(.dailyCapReached)`, which is named in words, dim on
the menu bar mark, bounded by the day boundary, and a number the user set. The rate goes up and the
*weight* goes down: each backed-off cycle still spends exactly one level-1 notification, never four
rungs with a sound and a panel. If that trade is ever judged wrong, the answer is a quieter channel
for the surviving rung, not a longer cooldown, because a longer cooldown re-creates the invisible
hole this section exists to close.

---

## 11.1 The waiting line: the app is never quiet without saying so

Silence by design and silence by defect look identical from outside the process. A user who is not
prompted for an hour cannot tell whether the app decided to back off, is blocked, crashed, or never
worked, and they do not file a bug about it, they delete it. §4.1 says the app must always be able to
answer "why do you think that"; being quiet is a claim like any other, and it was the one claim the
app made without evidence.

`WaitingLine.read` is therefore **total over the engine's state space**: every state, every quiet
cause, every stand-down cause and every gate reason produces exactly one short line, and its last
branch names itself as a bug rather than rendering nothing. It carries one of three claims, and they
are three different claims:

| Claim | Means |
|---|---|
| `holding off, X.` | something is blocking or rate-limiting a prompt right now |
| `not asking yet, X.` | nothing is, and the engine is waiting on its own clock |
| `waiting on you, X.` | the ask is already out, or a break is running; the silence is yours |

Deadlines in it are wall-clock times and never countdowns, and every one of them comes from a value
the engine already holds (`cooldownUntilMono`, `snoozeUntil`, `plannedEnd`, `pausedUntil`, the quiet
window, the audio ceiling). Nothing is scheduled to make them true and nothing polls.

It lives in `SigstopCore` for the reason `QuietCause.title` already gives: `SigstopApp` has no test
target, so a vocabulary kept there is unchecked. It is deliberately **not** fed by `PromptOutlook`,
which reads the event log because `--doctor` is a separate process that cannot see the running
engine; in-process `continuousWork`, `armThreshold` and `cooldownUntilMono` are free and no
`LoggedEvent` carries them.

`WorkingState.standDown` exists for the same honesty reason. A raised `armThreshold` has two causes,
and the panel used to infer a skip from the number, so a user whose opportunity expired unseen was
told they had waved it off. `StandDownCause` names which it was, and the four causes have four
sentences.

The menu bar mark carries one bit of this, because the user who never opens the panel is exactly the
user who concludes the app is broken. Opacity now means **is the app going to ask**: dim for `.idle`,
`.quiet` and `.backedOff`, full brightness otherwise. No new hue and no new glyph, which keeps the
decision in `MenuBarIcon` intact. The tooltip carries the sentence, so hovering is enough.

---

## 12. Quiet hours

```swift
struct QuietHours: Codable, Equatable {
    struct Window: Codable, Equatable {
        var weekday: Int          // 1 = Sunday (Calendar convention)
        var startMinuteOfDay: Int // e.g. 19*60
        var endMinuteOfDay: Int   // may be < start: wraps past midnight
    }
    var windows: [Window]
    var allowPassiveIndicator: Bool = true
    var respectSystemFocusModes: Bool = true

    static let `default` = QuietHours(windows: (1...7).map {
        Window(weekday: $0, startMinuteOfDay: 19 * 60, endMinuteOfDay: 9 * 60)   // 19:00 -> 09:00
    })
}
```

- Boundaries are computed with `Calendar.current.nextDate(after:matching:matchingPolicy:)` in the
  user's current time zone and **recomputed on every `NSSystemTimeZoneDidChange` and
  `NSCalendarDayChanged`** — never by adding 86 400 to a `Date`. DST transitions therefore behave: a
  window whose start falls in a skipped hour begins at the next valid minute.
- Quiet hours suppress **delivery only**. Measurement, the session model, and the rollup continue
  unchanged, so the daily summary of an evening session is complete and correct.
- **Entering** quiet hours withdraws any pending prompt and closes the cycle as `.quietSuppressed`
  (an *excluded* opportunity, §14).
- **Leaving** quiet hours never flushes a backlog. If work is currently owed a break, a fresh cycle
  opens with fresh deferral clocks.
- A system Focus mode that has been continuously on for more than 10 minutes promotes the engine to
  `quiet(.sustainedFocusMode)` rather than leaving it stuck hard-blocked in `breakDue`, which keeps the
  state machine truthful about what it is doing.

---

## 13. Persistence & recovery

- Local store (SQLite via GRDB or Core Data) in the app container. Nothing here is ever uploaded,
  and the app's own binary references no networking symbol at all (`docs/PRIVACY.md` §2.7).
- Persisted: session records, classified gaps, break records, cycle outcomes, per-minute app
  attribution buckets (bundle id + credited seconds), daily counters.
- Not persisted: raw idle samples, keystroke timings, window titles, URLs.
- The last tick timestamp is written every 15 s. On launch, the gap since it is classified by §4 row 16,
  so a crash, a force-quit, or a reboot resolves as an ordinary gap rather than as fabricated work.
- Retention default 90 days, user-configurable, with a one-click erase.

---

## 14. Daily rollup

```swift
struct DailySummary: Codable, Equatable {
    let day: DateComponents               // local y/m/d, day boundary at 04:00

    let codingTime: TimeInterval          // credited active work across all sessions
    let activeWorkByActivity: [ActivityType: TimeInterval]
    let applicationDistribution: [String: TimeInterval]   // bundleID -> credited seconds
    let longestContinuousSession: TimeInterval            // max peakContinuousActiveWork

    let breakCount: Int                   // qualifying breaks: accepted + idle-inferred
    let breaksAccepted: Int
    let breaksIdleInferred: Int
    let breaksAbandoned: Int              // ended under qualifyingBreak; not in breakCount
    let skippedBreakCount: Int
    let snoozeCount: Int
    let ignoredPromptCount: Int

    let breakOpportunities: Int
    let honoredOpportunities: Int
    let excludedOpportunities: Int
    let notificationsDelivered: Int
    let sessionCount: Int

    var breakCompliance: Double? {        // nil, never 0 or 1, when there is nothing to measure
        let denominator = breakOpportunities - excludedOpportunities
        guard denominator > 0 else { return nil }
        return Double(honoredOpportunities) / Double(denominator)
    }
}
```

### 14.1 Definitions, exactly

- **`codingTime`** — the sum of credited ticks (§3.3) across every session whose credit fell inside the
  day. Not wall clock, not app-foreground time. `applicationDistribution` partitions exactly this
  quantity: `applicationDistribution.values.sum() == codingTime` is an invariant (§15).
- **`longestContinuousSession`** — `max` over the day of `peakContinuousActiveWork`, sampled at every
  clock reset and again at day end so an in-flight stretch is included. Note this is a *continuous work
  stretch*, not a `DeveloperSession`; the field name follows the everyday meaning.
- **A break opportunity** opens each time `continuousActiveWork` reaches `targetContinuousWork`,
  i.e. each entry into `breakDue` — *including* entries suppressed by quiet hours.
- **Honored.** An opportunity is honored iff a qualifying break (duration ≥ `qualifyingBreak`) **began**
  within `complianceWindow = 10 minutes` of the opportunity opening — **regardless of how it started.**
  An accepted prompt, a snooze then a break, and simply walking away without ever seeing a notification
  all count identically. The metric measures the behavior, not obedience to the app.
- **Excluded.** An opportunity is excluded from both numerator and denominator iff no qualifying break
  began in its window **and** the app never successfully asked: the whole window was covered by quiet
  hours, an unbroken hard block, a daily-cap or backoff rate limit, or the cycle expired at the stale
  ceiling. You cannot hold a user to a prompt that was never delivered. Excluded opportunities are
  reported alongside the percentage so the number is auditable rather than flattering.
- **Missed** = `breakOpportunities - excludedOpportunities - honoredOpportunities`. Skipped and ignored
  prompts are missed, not excluded — those were real, delivered questions.

### 14.2 Worked example

A day with 9 opportunities: 6 followed by a qualifying break within 10 minutes (4 accepted from a
prompt, 2 spontaneous), 1 covered entirely by a 70-minute meeting (hard-blocked throughout, cycle
expired), 1 skipped, 1 ignored through level 4.

```
breakOpportunities   = 9
excludedOpportunities= 1        (the meeting cycle)
honoredOpportunities = 6
breakCompliance      = 6 / (9 - 1) = 0.75  -> "75% (6 of 8; 1 not asked)"
```

The UI always renders the parenthetical. A bare percentage invites the user to optimize a number; the
long form keeps it a description of a day.

---

## 15. Property tests (the invariants worth enforcing in CI)

1. `credited work ≤ wall-clock elapsed`, for every session, under every replayed event stream.
2. `sum(applicationDistribution) == codingTime` (± one tick per app, from bucket rounding).
3. A synthetic stream of `[work 44 min, idle 30 s, work 2 min]` reaches `breakDue` — micro-idle never resets.
4. A stream of `[work 44 min, idle 3 min, work 2 min]` reaches `breakDue` at 46 min of *credited* work,
   with the grace revoked — a short pause neither resets nor secretly credits.
5. A stream of `[work 40 min, idle 40 min, work 5 min]` never reaches `breakDue` from the pre-gap work.
6. Replay with sleep injected (wall advances, uptime does not) credits zero for the sleep.
7. No two notifications in any replay are less than `minNotificationSpacing` apart.
8. No replay emits more than 4 notifications per cycle, or more than `dailyNotificationCap` per day.
9. No notification is ever emitted while any `HardBlock` predicate holds.
10. For any input stream with ≥ 90 minutes of continuous credited work and no hard block, **at least
    one** notification is emitted — the anti-silence test.
11. `breakCompliance` is `nil`, never `0.0` or `1.0`, when `breakOpportunities == excludedOpportunities`.
12. Every state transition in §5.1 has a test; the engine is a pure function of
    `(state, snapshot, session, policy)` precisely so this is cheap.

---

## 16. Copy rules (non-negotiable)

- Describe **time and workflow**: "45 minutes since your last break", "you've been in the same file
  for an hour", "good moment before your 3:00".
- Never describe **outcomes, bodies, or benefits**. No claims about eyes, wrists, posture, strain,
  energy, alertness, mood, or productivity gains. The app knows what the clock says and nothing else.
- Never imply the user is doing something wrong by working. "Skip this one" is a first-class button,
  not a hidden one, and skipping produces no scolding copy on the next prompt.
- The daily summary reports; it does not grade. No streaks, no red numbers, and nothing in
  the summary that could be read as a score.
- **There are badges, and this is where the line between them and a streak is drawn.** Ten
  of them, defined in `SigstopCore/Badges/Badge.swift` and shown only in Settings, never in
  the summary and never in the prompt. Three properties make them compatible with the rule
  above rather than an exception to it: **nothing expires** — a badge records something that
  happened and cannot be taken back, so there is no number to protect and missing a day
  costs nothing; **nothing is new** — every condition is arithmetic over the `DailySummary`
  fields in §14 and the event vocabulary that already existed, so the privacy inventory grew
  by one derived file and not one observation; and **none of them rewards working longer** —
  every one is for taking the break or for not needing it, and `yielded` is explicitly
  for a full working day in which no single stretch passed an hour. A badge for a long
  session would have the product arguing with itself, and is the one shape of badge this
  file forbids.
