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
for classification and are never persisted. Raw input samples are never persisted. What is kept is
classified gaps and, for every day, the seconds of active work per bundle identifier and per
activity, which the daily summaries hold until *Delete everything* and which never leave the Mac
(`docs/PRIVACY.md` §4.3).

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

This section used to sketch `ActivityType`, `ClassificationSource` and `ActivityClassification`, and
none of them was built. The session carries `Activity`, the detector's enum in
`app/Sources/SigstopCore/Model/Activity.swift` (quoted in `docs/ACTIVITY-DETECTION.md` §3), with a
`Confidence` beside it, and the app as an `AppIdentity` (`bundleID`, `localizedName`, `pid`) from
`Model/Identity.swift`.

The table below was the design for that confidence. The number the app uses is computed by
`ConfidenceEngine` from evidence and tier ceilings (`docs/ACTIVITY-DETECTION.md` §6), not read from
this table:

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

The pause, clock and reset vocabulary, from `app/Sources/SigstopCore/Session/SessionTypes.swift`:

```swift
public enum PauseCause: String, Sendable, Codable, Hashable {
    case microIdleExceeded
    case screenLocked
    case systemSleep
    case displaySleep
    case fastUserSwitch
    case meetingNoInput
    case breakActive
    case userPaused
}

public enum WorkClockState: Sendable, Codable, Hashable {
    case running
    case paused(cause: PauseCause, since: Date)
    case stopped
}

public enum ResetReason: String, Sendable, Codable, Hashable {
    case qualifyingBreak
    case longPause
    case sessionStart
    case dayBoundary
    case userReset
}
```

The session's stored properties, from `app/Sources/SigstopCore/Session/DeveloperSession.swift`:

```swift
public struct DeveloperSession: Sendable, Codable, Hashable, Identifiable {

    public let id: UUID
    public let startedAt: Date
    public private(set) var endedAt: Date?

    public private(set) var continuousActiveWork: TimeInterval = 0
    public private(set) var totalActiveWork: TimeInterval = 0
    public private(set) var peakContinuousActiveWork: TimeInterval = 0
    public private(set) var clock: WorkClockState = .running
    public private(set) var provisionalGraceCredit: TimeInterval = 0

    public private(set) var observedElapsed: TimeInterval = 0

    public private(set) var lastBreakAt: Date?
    public private(set) var lastBreakEndedAt: Date?
    public private(set) var breakCount: Int = 0
    public private(set) var abandonedBreakCount: Int = 0
    public private(set) var skippedBreakCount: Int = 0
    public private(set) var snoozeCount: Int = 0
    public private(set) var ignoredPromptCount: Int = 0
    public private(set) var resetCount: Int = 0

    public private(set) var lastInputAt: Date
    public private(set) var idleDuration: TimeInterval = 0
    public private(set) var accumulatedIdle: TimeInterval = 0

    public private(set) var activeApplication: AppIdentity?
    public private(set) var activity: Activity = .unknown
    public private(set) var activityConfidence: Confidence = .none
    public private(set) var applicationSwitches: Int = 0
    public private(set) var recentSwitches: [Date] = []
    public private(set) var appActiveSeconds: [String: TimeInterval] = [:]

    private var provisionalByApp: [String: TimeInterval] = [:]
```

### 2.3 Focus estimate

Not a mood reading — two observable quantities.

```swift
public func focusScore(now: Date, window: TimeInterval = 600) -> Double {
    let switches = recentSwitches.filter { now.timeIntervalSince($0) <= window }.count
    let switchTerm = max(0, min(1, 1 - Double(switches) / 6.0))
    let total = appActiveSeconds.values.reduce(0, +)
    let dominance = total > 0 ? (appActiveSeconds.values.max() ?? 0) / total : 0
    return 0.6 * switchTerm + 0.4 * dominance
}
```

That is `DeveloperSession.focusScore(now:window:)`, in
`app/Sources/SigstopCore/Session/DeveloperSession.swift`, which `SessionTracker.focusScore` hands to
the engine. The test the engine applies is `InterruptionPolicy.isDeepFocus(_:)`, in
`app/Sources/SigstopCore/Decision/InterruptionPolicy.swift`:

```swift
public func isDeepFocus(_ input: EngineInput) -> Bool {
    input.focusScore >= 0.70
        && input.context.continuousWork >= policy.deepFocusMinimumWork
        && input.context.confidence.isConfidentEnoughForSpecificClaim
        && BreakPolicy.deepFocusActivities.contains(input.context.activity)
}
```

`deepFocusMinimumWork` is 20 minutes, and `deepFocusActivities` is coding, debugging, testing,
terminal work and AI coding.

Deep focus buys **exactly one** deferral extension per break cycle (§9). It is never a veto: deep
focus is precisely the state in which people lose track of the clock, so an app that treats it as a
permanent shield is an app that never fires.

---

## 3. The tick loop

### 3.1 Sampling

- Tick every **5 s**, sooner when the end of a break, a snooze, a pause or the work target falls
  inside that. `AppModel.tickInterval` overrides the 1 s in `BreakPolicy`, and `tickTolerance` is 5 s.
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
let delta = max(0, mono - lastTickMono)
let wallDelta = now.timeIntervalSince(lastTickWall)
let skew = wallDelta - delta
let skewed = abs(skew) > policy.wallClockSkewTolerance
if skewed {
    dayIndex = LocalDay.index(of: now, calendar: calendar, boundaryHour: policy.dayBoundaryHour)
    events.append(.wallClockSkewIgnored(seconds: skew))
}
lastTickMono = mono
lastTickWall = now

session.observe(elapsed: delta)
session.note(application: sample.application, activity: sample.activity, confidence: sample.confidence, at: now)

let discontinuity = delta > policy.tickInterval + policy.tickTolerance
```

That is the top of `SessionTracker.tick(_:)` in `app/Sources/SigstopCore/Session/SessionTracker.swift`.
Credit is measured on the monotonic clock only. The wall clock is compared against it, and a
disagreement larger than `wallClockSkewTolerance` (5 s) is logged as `wallClockSkewIgnored` rather
than credited. A monotonic step longer than `tickInterval + tickTolerance` (10 s in the app, §3.1) is
a discontinuity: it opens a gap, whose cause is `.systemSleep` when `AppModel` has reported a wake
through `noteSystemWake()` and otherwise an idle pause, or a meeting pause if the microphone is
running, and the tick credits nothing for it: `creditIfPossible(delta: discontinuity ? 0 : delta, ...)`.

The invariant this protects: **credited active work can never exceed elapsed wall-clock time.** It is
the first property test (§15).

### 3.3 Micro-idle: why 30 s of reading does not reset the clock

Provisional credit, confirmed by resumption, revoked by absence:

```swift
private mutating func creditIfPossible(delta: TimeInterval, mono: Double, bundleID: String?) {
    guard delta > 0, session.isRunning else { return }
    let start = mono - delta
    var creditEnd = min(mono, lastInputMono + policy.microIdleGrace)
    if let gap { creditEnd = min(creditEnd, gap.startMono) }
    let credited = max(0, creditEnd - start)
    guard credited > 0 else { return }
    let provisional = max(0, creditEnd - max(start, lastInputMono))
    session.credit(credited, provisional: provisional, bundleID: bundleID)
}
```

That is `SessionTracker.creditIfPossible`, in `SessionTracker.swift`. Credit runs to
`microIdleGrace` past the last input and no further, and the part of it after the last input is
recorded as provisional. New input confirms it: `tick` calls `confirmProvisionalCredit()` when the
last-input time moves forward. Absence takes it back: once the gap is classified as a pause or
longer, `applyGapThresholds` calls `revokeProvisionalCredit()` and pauses the clock.

Consequences, exactly as intended:

- **30 s spent reading a function** → credited, clock never pauses, no state change. The user does not
  experience the app "forgetting" that they were working.
- **3 min bathroom trip** → at 90 s the clock pauses and the 90 s of grace is revoked, so the recorded
  work matches the work actually done. On return the clock **resumes from where it was** — the trip
  did not earn a break and did not cost the user their accumulated progress toward one.
- **40 min lunch** → crosses the qualifying-break threshold: reset, break recorded, cycle over.

The grace window is the whole design. Too short and the app forgets you between keystrokes; too long
and a coffee run counts as coding. 90 s is the default. It is
`microIdleThresholdSeconds` in `settings.json`, which accepts 15 s to 600 s and has no control in
Settings; the intended range is 60 s to 180 s, and outside it the behavior degenerates in one of those
two directions.

---

## 4. Gap classification — the state transition table

Every non-credited stretch of time is a **gap**. A gap is classified once, when it ends (or when it
crosses a threshold, whichever comes first), by duration and context. This is the authoritative table.

`GapClassification`, in `app/Sources/SigstopCore/Session/SessionTypes.swift`:

```swift
public enum GapClassification: Sendable, Hashable {
    case microIdle
    case pause(PauseCause)
    case qualifyingBreak
    case sessionEnd
}
```

and the function that assigns it, `classify(duration:cause:)` in
`app/Sources/SigstopCore/Session/SessionTracker.swift`:

```swift
public func classify(duration: TimeInterval, cause: PauseCause) -> GapClassification {
    switch cause {
    case .meetingNoInput, .userPaused, .breakActive:
        return .pause(cause)
    case .screenLocked, .systemSleep, .displaySleep, .fastUserSwitch:
        if duration < policy.qualifyingBreak { return .pause(cause) }
        if duration < policy.sessionGap { return .qualifyingBreak }
        return .sessionEnd
    case .microIdleExceeded:
        if duration < policy.microIdleGrace { return .microIdle }
        if duration < policy.qualifyingBreak { return .pause(.microIdleExceeded) }
        if duration < policy.sessionGap { return .qualifyingBreak }
        return .sessionEnd
    }
}
```

The table below keeps the design's names. In the code `shortPause`, `meetingIdle` and `longPause` are
all `.pause(cause)`, the 20-minute reset is applied to a pause by `applyGapThresholds` when it reaches
`longPauseReset`, and `sessionGap` is `.sessionEnd`. The `GapOutcome` struct this section used to
sketch was not built.

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

`BreakPolicy`, in `app/Sources/SigstopCore/Decision/InterruptionPolicy.swift`, down to the ladder.
The audio ceiling and the call-latch constants follow in the same struct and are listed in §7.1.1 and
§7.8.

```swift
public struct BreakPolicy: Sendable, Codable, Hashable {

    public var tickInterval: TimeInterval = 1
    public var tickTolerance: TimeInterval = 2
    public var microIdleGrace: TimeInterval = 90
    public var qualifyingBreak: TimeInterval = 5 * 60
    public var longPauseReset: TimeInterval = 20 * 60
    public var sessionGap: TimeInterval = 30 * 60
    public var dayBoundaryHour: Int = 4
    public var wallClockSkewTolerance: TimeInterval = 5

    public var targetContinuousWork: TimeInterval = 45 * 60
    public var absoluteMaxWork: TimeInterval = 90 * 60
    public var breakDurationTarget: TimeInterval = 5 * 60
    public var settleInAfterBreak: TimeInterval = 5 * 60
    public var deepFocusMinimumWork: TimeInterval = 20 * 60

    public var softDeferralWindow: TimeInterval = 8 * 60
    public var deepFocusExtension: TimeInterval = 7 * 60
    public var maxSeamWaitPerCycle: TimeInterval = 15 * 60
    public var seamIdleBlip: TimeInterval = 20
    public var staleBreakCeiling: TimeInterval = 60 * 60
    public var rearmAfterStale: TimeInterval = 10 * 60
    public var rearmAfterSkip: TimeInterval = 20 * 60
    public var cooldownAfterExhausted: TimeInterval = 25 * 60

    public var promptTimeout: TimeInterval = 90
    public var snoozeDurations: [TimeInterval] = [5 * 60, 10 * 60, 15 * 60]
    public var maxSnoozesPerCycle: Int = 2
    public var maxSnoozeTotalPerCycle: TimeInterval = 30 * 60
    public var minNotificationSpacing: TimeInterval = 5 * 60
    public var maxNotificationsPerCycle: Int = 4
    public var dailyNotificationCap: Int = 14

    public var ladderLevel2: TimeInterval = 5 * 60
    public var ladderLevel3Armed: TimeInterval = 12 * 60
    public var ladderLevel3Forced: TimeInterval = 20 * 60
    public var ladderLevel4: TimeInterval = 35 * 60
    public var ignoreBackoffThreshold: Int = 2
```

These are the defaults of `BreakPolicy()`. The app builds its policy with `init(settings:)`, in the
same `InterruptionPolicy.swift`, which takes several of them from `settings.json`:

```swift
public init(settings: SigstopSettings) {
    self.init()
    targetContinuousWork = settings.workInterval
    breakDurationTarget = settings.breakDuration
    microIdleGrace = TimeInterval(settings.microIdleThresholdSeconds)
    qualifyingBreak = TimeInterval(settings.idleCountsAsBreakMinutes * 60)
    dailyNotificationCap = settings.maxNotificationsPerDay
    maxSnoozesPerCycle = settings.maxSnoozesPerBreak
    let unit = TimeInterval(settings.snoozeMinutes * 60)
    snoozeDurations = [unit, unit * 2, unit * 3]
    let cyclesInAWakingDay = Int((16 * 3600) / max(60, targetContinuousWork + breakDurationTarget))
    dailyNotificationCap = max(settings.maxNotificationsPerDay, cyclesInAWakingDay)
    absoluteMaxWork = max(absoluteMaxWork, targetContinuousWork * 2)
    qualifyingBreak = max(qualifyingBreak, microIdleGrace + 30)
    sessionGap = max(sessionGap, qualifyingBreak * 2)
    longPauseReset = min(max(longPauseReset, qualifyingBreak), sessionGap)
}
```

With the default settings that is a 45-minute interval, a 5-minute break, 90 s of micro-idle grace, a
5-minute qualifying break, `snoozeDurations` of 5, 10 and 15 minutes (only the first is used, §9)
with at most 2 snoozes per cycle, and a daily cap of 19: the *Most prompts in a day* setting is 14,
but 16 hours hold 19 cycles of 45 + 5 minutes and the larger number wins. `AppModel` then sets
`tickInterval` and `tickTolerance` to 5 s each (§3.1).

---

## 5. Part B — engine states

```swift
public enum EngineState: Sendable, Codable, Hashable {
    case working(WorkingState)
    case breakDue(BreakDue)
    case breakActive(BreakActive)
    case snoozed(SnoozedState)
    case ignored(Escalation)
    case idle(IdleState)
    case quiet(QuietState)
```

`EngineState`, in `app/Sources/SigstopCore/Decision/EngineState.swift`, where the payload types sit
too. The one the transition table leans on most is `BreakDue`:

```swift
public struct BreakDue: Sendable, Codable, Hashable {
    public var cycle: CycleID
    public var dueSince: Date
    public var seamWaitElapsed: TimeInterval = 0
    public var seamWaitTotal: TimeInterval = 0
    public var totalElapsed: TimeInterval = 0
    public var deepFocusExtensionUsed: Bool = false
    public var promptedAt: Date?
    public var promptedAtMono: Double?
    public var snoozesUsed: Int = 0
    public var snoozeTotal: TimeInterval = 0
    public var notificationsThisCycle: Int = 0
    public var uncorroboratedAudioElapsed: TimeInterval = 0
    public var lastVerdict: InterruptionVerdict?
    public var lastStepMono: Double
```

`QuietCause` is `scheduledQuietHours`, `userPaused`, `sustainedFocusMode` or `dailyCapReached`. The
ladder's levels are `EscalationLevel` in `Model/Settings.swift`: `.first`, `.second`, `.third` and
`.incident`, named after `SIGTSTP`, `SIGINT`, `SIGTERM` and `SIGSTOP`.

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
| `breakDue` | user snoozes | `snoozesUsed < maxSnoozesPerCycle` (2) and `snoozeTotal + d <= 30 min` | `snoozed` | **work clock keeps running** |
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
| `ignored` | no input for `microIdleGrace` | gap `< qualifyingBreak` | `idle` | not an ignore; retract prompt and **park the ladder** |
| `ignored` | gap ≥ `qualifyingBreak` | — | `working` | break recorded; cycle closed honored |
| `ignored` | tick | `totalElapsed >= staleBreakCeiling` | `working` | abandon cycle `.expired`; re-arm at `W + rearmAfterStale` |
| `ignored` | the last prompt the cycle allows + no response for `promptTimeout` | — | `working` | cycle `.ignoredExhausted`; cooldown 25 min; consecutive-ignore counter += 1 |
| `breakActive` | tick | `now >= plannedEnd` | `working` | reset clock, record break, `lastBreakEndedAt = now` |
| `breakActive` | user ends early | elapsed `>= qualifyingBreak` | `working` | as above |
| `breakActive` | user ends early | elapsed `< qualifyingBreak` | `working` | **no reset, no break recorded**, log `.abandoned` |
| `breakActive` | the break ends, any of the three ways above | it started from `quiet` and that quiet still holds | that `quiet`, unchanged | as above, but the pause keeps its own end (rule 3) |
| `breakActive` | input resumes | elapsed `< qualifyingBreak` | `breakActive` | keep the timer; do not nag; a break is not a jail |
| `idle` | input resumes | gap `< qualifyingBreak`, ladder parked | `ignored` | **resume the ladder at its rung**; gap ages `totalElapsed`, not `ladderElapsed` |
| `idle` | input resumes | gap `< qualifyingBreak` | `working` or `breakDue` | resume clock; re-evaluate `W >= T` |
| `idle` | input resumes | gap `>= qualifyingBreak` | `working` | reset, record break, close any open cycle honored |
| `idle` | gap `>= sessionGap` | — | `working` (new session) | finalize session |
| `quiet` | window ends | `W >= T` | `breakDue` | fresh cycle, fresh deferral clocks — **never a backlog** |
| `quiet` | window ends | `W < T` | `working` | — |
| `quiet` | user picks "break now" | — | `breakActive` | begin break, `origin: .userInitiated`; the break keeps the quiet state (`BreakActive.quietBefore`) |
| `quiet` | gap ≥ `qualifyingBreak` | the quiet still holds | `quiet` | break recorded, backoff reset, the quiet state is left alone (rule 3) |
| any | user pauses the app | — | `quiet(.userPaused)` | duration chosen by user; measurement continues |

Three structural rules the table encodes:

1. **A break taken without being asked always closes the open cycle as honored.** The user walking away
   on their own is the success case, not a missed prompt.
2. **Quiet hours withdraw, never queue.** Nothing the engine wanted to say at 18:55 is allowed to
   arrive at 09:00.
3. **A break never ends the quiet it was taken in.** The menu offers *Take a break now* while the
   app is paused, and the break used to end in `working` whatever it started from, so an hour's pause
   lasted until the first break and prompts came back before the hour was up. Locking the screen
   inside a pause did the same once the pause was five minutes old, because the session model
   records that gap as a break.
   A break that starts from `quiet` now carries that state in `BreakActive.quietBefore` (optional, so
   an older encoding still decodes) and goes back to it when the break ends, however it ends, if it
   still holds: a pause until its own `until`, quiet hours while the window is open, the daily cap
   until the day boundary, and focus-mode quiet while Focus is on (nothing enters that state today).
   A pause that ran out during the break ends in `working`, as before. A break the session model
   infers inside a quiet state leaves it in place the same way, and still resets the backoff, as
   every qualifying break does. Quiet hours and the daily cap used to come back on their own at the
   next due point, by opening a cycle and closing it in the same step; going straight back means the
   indicator says quiet in between rather than working, and no cycle is opened only to be excluded.

---

## 6. Engine inputs

```swift
public struct EngineInput: Sendable {
    public var now: Date
    public var monotonic: Double
    public var context: DeveloperContext
    public var signals: SystemSignals
    public var settings: SigstopSettings
    public var calendarSystem: Calendar
    public var calendar: CalendarSignals?
    public var seams: [Seam]
    public var keystrokeRate: Double
    public var terminalCommandRunning: Bool
    public var secondsSinceFrontmostChange: TimeInterval
    public var focusScore: Double
    public var lastBreakEndedAt: Date?
    public var day: DailyCounters
    public var userAction: UserAction?
    public var sessionEvents: [SessionEvent]
```

That is `EngineInput`, in `app/Sources/SigstopCore/Decision/BreakDecisionEngine.swift`. Its `signals`
are:

```swift
public struct SystemSignals: Sendable, Codable, Hashable {
    public var audioInputRunning: Bool
    public var cameraRunning: Bool
    public var displayCaptured: Bool
    public var screenLocked: Bool
    public var systemSleeping: Bool
    public var fastUserSwitched: Bool
    public var focusModeActive: Bool?
    public var frontmostIsFullscreen: Bool
    public var frontmostIsPresentationApp: Bool
    public var batteryFraction: Double?
    public var isCharging: Bool
    public var lowPowerMode: Bool
    public var meetingLatch: MeetingLatchSignal
```

and its seams, both in `InterruptionPolicy.swift`:

```swift
public enum Seam: String, Sendable, Codable, Hashable, CaseIterable {
    case applicationSwitch
    case idleBlip
    case terminalCommandFinished
    case meetingEnded
    case fullscreenExited
    case spaceSwitch
}
```

`CalendarSignals` has the four fields §7.7 uses. Several inputs have no producer in the shipping app:
`AppModel` passes `calendar: nil`, `keystrokeRate: 0` and `terminalCommandRunning: false` on every
tick, and `SensorStack` sets `displayCaptured` to `false`, `frontmostIsPresentationApp` to `false`
and `focusModeActive` to `nil`. The rules that depend only on them cannot fire. `SensorStack` also
passes `frontmostIsFullscreen: false`, but that one is produced: `AppModel` overwrites it on every
tick from window geometry (§7.1).

The engine also reads from the session: `continuousActiveWork`, `timeSinceLastBreak`, `idleDuration`,
`activity` + `activityConfidence`, `applicationSwitches`, `focusScore`, `snoozeCount`,
`ignoredPromptCount`, `skippedBreakCount`, plus today's `notificationsDelivered` and
`consecutiveIgnoredCycles`.

---

## 7. Interruption appropriateness

The requirement: **the app must never be the thing that ruined a moment.** One badly timed banner
during a demo costs more trust than fifty well-timed ones earn. The policy is therefore asymmetric —
generous with waiting, strict about never firing into a hard block — but bounded, so that politeness
cannot become silence.

```swift
public enum HardBlock: String, Sendable, Codable, Hashable {
    case audioInputInUse
    case cameraInUse
    case recentCallContinuing
    case screenBeingShared
    case presentationFullscreen
    case focusModeActive
    case screenLocked
    case systemSleeping
    case fastUserSwitched
    case settleInAfterBreak
    case videoEventInProgress
    case imminentMeeting
}

public enum SoftDeferReason: String, Sendable, Codable, Hashable {
    case deepFocus
    case typingBurst
    case terminalCommandRunning
    case preMeetingWindow
    case recentAppLaunch
    case inferredMeeting
    case liveCaptureUnattributed
    case calendarEventInProgress
}

public enum RateLimit: String, Sendable, Codable, Hashable {
    case quietHours
    case dailyCapReached
    case cycleNotificationCap
    case minimumSpacing
    case ignoreBackoff

    public var isTerminalForCycle: Bool {
        switch self {
        case .ignoreBackoff, .cycleNotificationCap: return true
        case .minimumSpacing, .quietHours, .dailyCapReached: return false
        }
    }
}
```

These are in `app/Sources/SigstopCore/Decision/InterruptionPolicy.swift`, just below
`InterruptionVerdict`, whose four cases are `.deliver`, `.hardBlocked(HardBlock)`,
`.softDeferred(SoftDeferReason)` and `.rateLimited(RateLimit)`.

### 7.1 Hard blocks — never deliver, and the deferral clocks stop

| Block | Detection | Notes |
|---|---|---|
| `audioInputInUse` | CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` on every input device, attributed through `kAudioProcessPropertyIsRunningInput`, and **bounded**: see §7.1.1 | Public API, no permission. Covers Zoom/Meet/Teams/huddles/recording uniformly, which is why the engine keys on *the microphone*, not on a list of app bundle ids it will always be behind on. |
| `cameraInUse` | CMIO `kCMIODevicePropertyDeviceIsRunningSomewhere` over `kCMIOHardwarePropertyDevices` | Same idea for video, and **shipped**. Public API, no Camera permission, no prompt, verified against `tccd`. A read failure is `nil`, never `false`. Four states with the same calibration guard as audio, because a virtual camera can hold a device open forever. This closes the camera-on / microphone-muted posture, which is the normal one on Teams and Meet, with no inference at all. |
| `recentCallContinuing` | The call latch: a capture device ran continuously for >= 45 s and stopped less than the hold budget ago | See §7.7. Named after what it asserts, not after what you might conclude from it. |
| `screenBeingShared` | **Nothing. This block cannot fire.** | `CGDisplayIsCaptured`, which this row used to name, is annotated `API_DEPRECATED("No longer supported", macos(10.0,10.9))` and does not compile from Swift. CoreMediaIO enumerates no display-capture device. ScreenCaptureKit needs the Screen Recording grant `docs/PRIVACY.md` §3.1 forbids hard-requiring. The weaker and honest claim: someone looked for a permission-free signal and did not find one. The mitigation this row promised was a manual toggle, and it never shipped; it does now, as "I am in a meeting" in the menu, time-boxed to two hours. `--doctor` prints this block as UNOBSERVABLE with the reason and says out loud that it never fires. |
| `presentationFullscreen` | **Nothing reaches it. This block cannot fire.** | The design was AX `kAXFullscreenAttribute` on the focused window **AND** (presentation-capable app **OR** camera/mic live), and nothing reads that attribute. `frontmostIsFullscreen` comes from window geometry instead: `AppModel` sets it from `ConcurrentStates.fullscreen`, true when any on-screen layer-0 window, from any app, matches a display's size (`SystemStateCollector.windowGeometry`). The other half never holds: `frontmostIsPresentationApp` is always `false` (§6), and `cameraRunning` has already returned `.cameraInUse` one line above. Fullscreen **alone is not a block** — developers work fullscreen all day, and blocking on it would mean never firing for half the user base. |
| `focusModeActive` | Not read. `SensorStack` passes `nil`, because there is no public API and the Focus database is not something this app opens | **Honest limitation:** Focus is not detected. What still holds: notifications go out at `.passive` for L1 and `.active` for L2 and L3 (`Notifier.interruptionLevel(for:)`), so a Focus mode silences them. L4 requests `.timeSensitive`, but the build does not carry the Time Sensitive entitlement (`com.apple.developer.usernotifications.time-sensitive` is absent from `app/Resources/sigstop.entitlements`, and a build signed ad hoc with no Team ID cannot carry a `com.apple.developer` entitlement), so macOS delivers it as an ordinary notification and a Focus silences it like any other. When Focus swallows a notification the engine cannot tell; the menu bar indicator is the safety net. |
| `screenLocked` / `systemSleeping` / `fastUserSwitched` | Workspace + distributed notifications | Nobody is there. |
| `settleInAfterBreak` | `now - lastBreakEndedAt < 5 min` | You do not tell someone who just sat back down to get up. |
| `imminentMeeting` | `minutesUntilNextBusyEvent <= 2` | The two minutes before a call are not free time. |

While hard-blocked: **`seamWaitElapsed` pauses and no notification is emitted on any channel.** A
two-hour meeting therefore costs the break cycle its deferral budget nothing — the cycle is
preserved, not consumed and not fired stale. The work clock's own behavior during that time is
governed by §4 rows 6 and 7, independently.

This paragraph used to say `totalElapsed` pauses too. It does not: `handleBreakDue` adds `dt` to it
unconditionally, before the verdict is even computed. §7.4 depends on the code's behaviour, not on
the old sentence, so the doc was the bug and this is the fix. It matters more now that the call
latch makes long hard blocks ordinary: a cycle that spends an hour blocked hits the stale ceiling
and is abandoned as an *excluded* opportunity, which is what stops a call quietly turning into a
prompt nobody asked for an hour later.

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
| `fullscreenExited` | **declared and never produced** | medium, as designed |
| `spaceSwitch` | **declared and never produced**: nothing observes `activeSpaceDidChangeNotification` | medium, as designed |
| `terminalCommandFinished` | **declared and never produced** | strong, as designed |

`AppModel` inserts only `.applicationSwitch` and `.idleBlip`.

**`meetingEnded` has no producer, and deliberately gains none.** A seam *delivers*: `verdict` returns
`.deliver` for any non-empty seam before the soft reasons are consulted at all. So emitting one the
instant the microphone stops would fire the prompt on "thanks everyone, bye", which is the complaint
this whole area exists to fix rather than a fix for it. The call latch's hold (§7.7) is what serves
the purpose the seam was invented for, and it serves it as a *block* rather than as a trigger. The
row stays in the table so the next person does not re-invent it.

`terminalCommandFinished` was designed around shell integration the user installs deliberately: a
`precmd`/`preexec` hook writing one byte to a Unix domain socket in the app's container. That is
planned, not built, and `terminalCommandRunning` is always `false` (§6), so the app **cannot** see
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
| **Nagging** | max 4 notifications per cycle; ≥ 5 min between any two; daily cap of 19 at the default settings (§4.2); snooze on level 1 prompts only, at most twice per cycle; an explicit skip; escalation ladder that ends permanently; backoff to 1 notification per cycle after 2 consecutive ignored cycles; ladder timing that stretches, never compresses. A skip neither trips that backoff nor clears it: it is an answer, so it is not an ignore, and it is not a break, so it does not earn a clean slate. |
| **Never firing** | soft deferrals are bounded at 15 min total; deep focus buys one extension, once; hard blocks pause rather than cancel; `absoluteMaxWork` floor at 90 min; the passive indicator is always live even during quiet hours, DND and cap exhaustion, so the information is never lost — only the interruption is. |

### 7.5 Channels

| Channel | Interrupts? | Allowed under |
|---|---|---|
| Passive menu-bar indicator (icon state + title) | no | **always**, including quiet hours, DND, daily cap, hard blocks |
| Standard notification (`.active`, silent by default) | yes | not hard-blocked, not rate-limited |
| Notification with sound | yes | escalation level 3+ only, never twice in a cycle, and never while a microphone or camera is live |
| Panel drawn by the app: full screen on every display, 78 % black, non-activating | yes | level 4 outside Low Power Mode, and any rung the system will not show as a notification: *Use macOS notifications instead* is off (the default), permission is denied, or the banner never appears. Level 4 becomes a notification in Low Power Mode (§7.6) |

Nothing in the app is ever modal, and the panel never activates the app. It does cover every
display until it is answered, and *Ignore it* is always one of its answers, so there is no
configuration in which the app can prevent the user from working.

Live capture suppresses the sound channel for the same reason low battery does, and it matters more
now that §7.1.1 lets a prompt reach a Mac with a microphone open: the rung still arrives, it just
does not chime into somebody's recording.

**The app's own prompt sound is separate from the channel.** With *Prompt sound* on, the default,
`AppModel.deliver` plays `PromptSound` on every rung that is delivered, whatever its channel: Tink
at L1, Morse at L2, Submarine at L3 and Sosumi at L4, louder at each rung. It is skipped while a
microphone or camera is running, read on the same tick, so it never lands in a call or a recording
either. So the table above describes the notification's own sound, and a rung whose channel is
silent can still be heard.

**Every rung is full screen.** When system notifications are off, which is the default, every rung
is drawn by the app itself, because there is no other channel. This section used to say that below
level 4 that drawing is a card in the corner of one screen. It is not, and no corner card exists in
the code: every rung is a panel built at `screen.frame` on every display and filled at 78 % black,
so an L1 `SIGTSTP` covers the machine exactly as `SIGSTOP` does. What separates the rungs is what
the panel offers. A rung whose channel is a notification (L1 to L3, and L4 on low power) offers the
notification's answers, as §9 lists. L4 on AC power offers *Take it* and *Ignore it*.

### 7.6 Low battery

Battery is an input about *cost and context*, never a reason to skip a break:

- Low Power Mode: level 4 takes the notification channel instead of the panel channel, and level 3
  loses its sound (`channelFor` in `BreakDecisionEngine`). The battery half of this rule has no
  input: `SensorStack` passes `batteryFraction: nil`, so a battery below 20 % changes nothing.
- There is no below-10 % rule that suppresses level 4. It was designed and never built.
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
| `held → closed` | `monotonic - lastLiveMono >= holdBudget`, or a ceiling, or a gap |

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
- **The forgiveness accumulates, and is bounded.** Refunding each short gap into `lastLiveMono` without
  a total meant a process throttled to 12-second samples — App Nap, or heavy load, §3.2 —
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
public func verdict(_ input: EngineInput, budget: CycleBudget) -> InterruptionVerdict {
    if let block = hardBlock(input, budget: budget) { return .hardBlocked(block) }
    if let limit = rateLimit(input, budget: budget) { return .rateLimited(limit) }

    if input.context.continuousWork >= policy.absoluteMaxWork { return .deliver }

    if budget.seamWaitElapsed < softBudget(input, budget: budget),
       budget.seamWaitTotal < policy.maxSeamWaitPerCycle {
        if !input.seams.isEmpty { return .deliver }
        if let reason = softDefer(input) { return .softDeferred(reason) }
    }
    return .deliver
}

public func hardBlock(_ input: EngineInput, budget: CycleBudget = CycleBudget()) -> HardBlock? {
    let s = input.signals
    if s.screenLocked { return .screenLocked }
    if s.systemSleeping { return .systemSleeping }
    if s.fastUserSwitched { return .fastUserSwitched }
    if s.audioInputRunning {
        if let c = input.calendar, c.eventInProgress, c.inProgressIsBusy, c.inProgressHasVideoLink {
            return .videoEventInProgress
        }
        if audioIsCorroborated(input)
            || budget.uncorroboratedAudioElapsed < policy.uncorroboratedAudioCeiling {
            return .audioInputInUse
        }
    }
    if s.cameraRunning { return .cameraInUse }
    if s.meetingLatch.isHolding { return .recentCallContinuing }
    if s.displayCaptured { return .screenBeingShared }
    if s.frontmostIsFullscreen && (s.frontmostIsPresentationApp || s.cameraRunning) {
        return .presentationFullscreen
    }
    if s.focusModeActive == true { return .focusModeActive }
    if let ended = input.lastBreakEndedAt,
       input.now.timeIntervalSince(ended) >= 0,
       input.now.timeIntervalSince(ended) < policy.settleInAfterBreak {
        return .settleInAfterBreak
    }
    if let minutes = input.calendar?.minutesUntilNextBusyEvent, minutes <= 2 { return .imminentMeeting }
    return nil
}
```

`InterruptionPolicy.verdict(_:budget:)` and `hardBlock(_:budget:)`, in
`app/Sources/SigstopCore/Decision/InterruptionPolicy.swift`. `rateLimit` checks quiet hours, the
daily cap, the per-cycle cap, minimum spacing and the ignore backoff, in that order. `softDefer`
checks typing, a running terminal command, a recent app switch, unattributed live capture, a
suspected call, an inferred meeting, the pre-meeting window, a calendar event in progress and deep
focus, in that order.

Order matters and is part of the spec: hard blocks precede rate limits (a blocked prompt should not
burn a cycle's notification budget), rate limits precede the floor, and a seam beats every soft reason.

---

## 9. Snooze semantics

- **One snooze length.** The notification and the stand-in panel offer one *Snooze (SIGALRM)*, and
  it lasts `snoozeMinutes`, 5 minutes by default. `init(settings:)` fills `snoozeDurations` with 1, 2
  and 3 times that, and the `.snooze` action takes the first entry `offeredSnoozes` returns, so the
  longer two are never used. Snooze is offered on level 1 prompts only; the rungs above it offer none.
- **Maximum 2 snoozes per cycle** (`maxSnoozesPerBreak`, 0 to 10 in `settings.json`), and
  `snoozeTotal` capped at 30 minutes (`maxSnoozeTotalPerCycle`, not a setting). With the default
  5-minute snooze the cap never binds; a longer one shrinks the last snooze to fit (with
  `snoozeMinutes` at 20: 20 minutes, then 10).
- **After the cap:** the prompt no longer offers snooze. The notification offers *Take it* and
  *Skip*, and the stand-in panel adds *Ignore it*. Removing the option is honest; offering a third
  snooze that silently behaves like the second is not.
- **What a snooze does to the work clock: nothing.** The clock keeps running. Snoozing defers the
  question, it does not buy credit. If you snooze 5 minutes at 45 minutes of work, you are at 50
  minutes of work when it returns, and the copy says so.
- **On snooze expiry:** re-enter `breakDue` with `seamWaitElapsed = 0` (a fresh seam window — the
  deferral machinery gets to do its job again) but `totalElapsed` continuing from the original
  `dueSince`, so snoozing cannot be used to outrun the stale ceiling.
- **A snooze costs a notification.** On expiry level 1 is sent again, it counts toward the four a
  cycle may send (§11, invariant 2), and if it is ignored the ladder starts again from its own `t0`.
  So a cycle snoozed once can spend its fourth notification on level 2 or 3, and that rung is then
  the last one: it gets the full `promptTimeout` to be answered, the same as level 4 (§11).
- **Snooze while hard-blocked** cannot happen — there is no prompt to snooze.
- **Skip** (`UserAction.skip`): closes the cycle, `skippedBreakCount += 1`, no reset, no break recorded,
  counted as a *missed* opportunity in compliance (it was a real, answered opportunity). The engine
  re-arms after another `rearmAfterSkip` (20 min) of continuous active work. This is the mid-deploy
  escape hatch and it is deliberately cheap to use.
- **Skip is not the cheap gesture, and the UI must not let it look like one.** Twenty minutes of
  silence is the longest suppression in the engine, so the control that buys it says so, and Escape
  does not call it. Escape and *Ignore it* take the panel down and tell the engine nothing (Escape
  reaches the panel only after a click on it, because the panel never takes the keyboard from the app
  you are in, which may be showing a password field), so the
  prompt stands in the engine: `promptTimeout` (90 s) after it was delivered it is classified
  ignored, which is what §10 means by ignored and what the product means by a rung you are allowed
  to catch. The next rung waits for its own ladder time (§11, L2 at `t0 + 5 min`), and after L4, or
  whichever rung spends the cycle's four notifications, has had its own `promptTimeout`, the
  cycle closes as `.ignoredExhausted` with its 25-minute cooldown.
- **The same answers with or without system notifications.** Any rung whose channel is a
  notification (L1, L2, L3, and L4 on low power) is drawn as a panel when system notifications are
  off, which is the default, or denied, and that panel offers what the notification would have:
  *Take it*, *Snooze (SIGALRM)* when `snoozeOffered` is not empty, *Skip*, and *Ignore it*. L4 on
  AC power is a panel by channel and offers *Take it* and *Ignore it*, so whether L4 offers Skip
  depends on the power state. The stand-in panel used to offer only *Take it* and *Ignore it*,
  which made Skip and Snooze unreachable without a permission, against `docs/PRIVACY.md` §3.1. Both
  surfaces label Skip with what it costs, `rearmAfterSkip` read from the policy: *Skip, quiet for
  20m*.
- **An ignored prompt keeps the snoozes already used.** The count travels into `ignored` and back,
  so letting a prompt time out cannot reset the per-cycle cap. `SnoozeCapTests` pins it.
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

A rule that kept an unconfirmed notification from climbing past level 2 was designed and not
built: Focus is never known, so the ladder climbs the same way whether or not a notification was
seen. The default is unaffected, because with system notifications off every rung is the app's own
panel, which no Focus mode can swallow.

---

## 11. Escalation ladder

`t0` = the moment the prompt was classified ignored.

| Level | Fires at | Channel | Counts toward caps | Behavior |
|---|---|---|---|---|
| **1 — Passive** | on delivery, `promptTimeout` before `t0` | `.notification`, which `Notifier` sends at the `.passive` interruption level | yes | The initial prompt, and the only rung that offers a snooze. Once it is classified ignored nothing more is sent at this level, and the indicator turns `.escalating`. |
| **2 — Quiet repeat** | `t0 + 5 min` | `.notification`, no notification sound (the app's own prompt sound still plays, §7.5) | yes | Different copy, acknowledging the elapsed time rather than repeating verbatim. |
| **3 — Seam-armed** | armed at `t0 + 12 min`, fires at the **first seam**, forced at `t0 + 20 min` | `.notificationWithSound` (the only rung whose notification carries a sound), or `.notification` in Low Power Mode or while a microphone or camera is live | yes | The engine stops guessing and waits for the user to break their own concentration. This is the level most likely to land. |
| **4 — Final** | `t0 + 35 min` | `.panel`, or `.notification` in Low Power Mode. A hard block when it is due postpones it (rule 4 below) and does not change its channel | yes | One assertive, still non-blocking presentation. Then the ladder **ends permanently for this cycle**. |

The channel is what `channelFor` in `BreakDecisionEngine` returns, and every rung that delivers adds
one to `notificationsThisCycle` and to the day's `notificationsDelivered`. With *Use macOS
notifications instead* off, the default, a `.notification` rung is drawn as the app's own panel
(§7.5), so the channel decides what the rung offers, not whether it covers the screen.

After level 4 with no response: cycle → `.ignoredExhausted`, `consecutiveIgnoredCycles += 1`, engine
returns to `working` with a **25-minute cooldown** before a new cycle may open. No further
notification about this cycle is ever emitted.

**The last prompt a cycle allows always gets `promptTimeout` to be answered, whichever rung it is.**
Level 4 is the last rung, but not always the last prompt: a snooze sends level 1 again and spends one
of the cycle's four notifications (invariant 2 below), so a cycle snoozed once meets the cap at level 2
or 3. The engine used to decide exhaustion in the same step that delivered that rung, so the step
carried `deliverPrompt`, `withdrawPrompt` and `closeCycle` together: the prompt sound played for a
prompt that was taken down in the same instant, and with system notifications the banner was posted
after its own withdrawal and stayed in Notification Center with buttons that did nothing. Whichever
delivery spends the ladder now records `Escalation.finalDeliveredAt`, exactly as level 4 always did,
and exhaustion waits `promptTimeout` of ladder time after it. No step delivers a prompt and withdraws
or closes its cycle; `DeliverAndWithdrawPropertyTests` holds that over random sequences of ticks,
snoozes, skips, breaks, pauses, absences and microphone holds, and `LastPromptTests` pins both
snoozed paths. `Notifier` no longer trusts the order either: `center.add` runs after an `await`, so
it checks again once it has permission, and again once macOS has taken the notification, that the
cycle still wants it, and takes it down if it was withdrawn in between. Each delivery has its own
identifier, so a withdrawn level 1 cannot be revived by the level 1 a snooze sends later.

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
6. **Daily cap** (19 at the default settings, §4.2) overrides everything above. On reaching it, the
   app goes passive-only until the next day boundary and records `quiet(.dailyCapReached)`. That
   state is terminal until the boundary
   and computes no verdict, so it writes no `gate` line either: the menu is the only place a user can
   find out, and it says so in words (`QuietCause.summary`). It drew as the literal title "quiet hours"
   for every cause until the counters started surviving a relaunch made it reachable in practice — a
   false label on an app that has gone quiet for the rest of the day is the failure this whole section
   exists to prevent.

Cap arithmetic: a well-matched day is ~9 cycles in 8 hours × 1 notification each = 9, under the
default cap of 19. A day where everything is ignored spends 4 notifications on each of the first two
cycles, then the backoff rule holds every later cycle to 1, so the cap is reached on the thirteenth
cycle. The caps bind in exactly the situation they are meant for.

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
window, the audio ceiling). Nothing is scheduled to make them true and nothing polls. They are
rendered short style through `DisplayLocale.english(from:)`: English with Latin digits, keeping the
reader's region and 12 or 24 hour clock, which is what the menu bar subtitle one row above uses. An
Arabic or Persian Mac would otherwise print native digits inside an English sentence. Every clock
and number the app prints goes through the same locale: the corpus slots, `WaitingLine`, the menu
bar subtitle and every SwiftUI root. The 24-hour `HH:mm` form is reserved for the quiet-hours
window, where the reader is comparing two ends of a range against the settings field that produced
it.

**Nothing is checked ahead of the state.** The confirmation that "ignore this input device" worked
used to be, and it therefore answered for every state for the full 30 minutes of the inhibit: on the
stuck-device Mac the button exists for, the device never stops running, so the line talked about the
microphone while the header said STOPPED, PAUSED or snoozed. It now sits inside `working`, below the
stand-downs — a cooldown is the reason the app is quiet, an ignored input device is not the reason for
anything, it is a button answering back.

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
public struct QuietHours: Sendable, Codable, Hashable {
    public var startMinute: Int
    public var endMinute: Int
    public var enabled: Bool

    public init(startMinute: Int = 22 * 60, endMinute: Int = 8 * 60, enabled: Bool = false) {
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.enabled = enabled
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return startMinute <= endMinute
            ? (m >= startMinute && m < endMinute)
            : (m >= startMinute || m < endMinute)
    }
}
```

`QuietHours`, in `app/Sources/SigstopCore/Model/Settings.swift`: one window for every day, 22:00 to
08:00, off by default.

- There are no computed boundaries. `contains` reads the hour and minute of the moment it is given,
  in the calendar it is given, on every call. Nothing is scheduled at a boundary and nothing adds
  86 400 to a `Date`.
- Quiet hours suppress **delivery only**. Measurement, the session model, and the rollup continue
  unchanged, so the daily summary of an evening session is complete and correct.
- **Entering** quiet hours withdraws any pending prompt and closes the cycle as `.quietSuppressed`
  (an *excluded* opportunity, §14).
- **Leaving** quiet hours never flushes a backlog. If work is currently owed a break, a fresh cycle
  opens with fresh deferral clocks.
- `quiet(.sustainedFocusMode)` exists for a Focus mode left on for more than 10 minutes, but nothing
  enters it today: Focus is never detected (`focusModeActive` is always `nil`), so the case is
  designed and unreachable.

---

## 13. Persistence & recovery

- Local store: plain JSON files under Application Support, one append-only event file per day
  (`docs/PRIVACY.md` §4). Nothing here is ever uploaded, and the app's own binary references no
  networking symbol at all (`docs/PRIVACY.md` §2.7).
- Persisted: session records, classified gaps, break records, cycle outcomes, daily counters, and
  the daily summaries, which keep the seconds of active work per bundle id and per activity for
  every day until *Delete everything*. None of it leaves the Mac (`docs/PRIVACY.md` §4.3).
- Not persisted: raw idle samples, keystroke timings, window titles, URLs.
- Nothing records the last tick, so §4 row 16 was not built: every launch starts a new session at
  zero, and a crash, a force-quit or a reboot loses the clock rather than crediting the gap.
- Raw events are kept 7 days, a constant rather than a setting. Summaries and badges are kept until
  *Delete everything*, the one-click erase (`docs/PRIVACY.md` §4.5).

---

## 14. Daily rollup

```swift
public struct DailySummary: Sendable, Codable, Hashable {
    public let day: CalendarDay

    public let totalActiveWork: TimeInterval
    public let activeWorkByActivity: [String: TimeInterval]
    public let applicationDistribution: [String: TimeInterval]
    public let longestContinuousSession: TimeInterval

    public let breakCount: Int
    public let breaksAccepted: Int
    public let breaksIdleInferred: Int
    public let breaksUserInitiated: Int
    public let breaksAbandoned: Int
    public let skippedBreakCount: Int
    public let snoozeCount: Int
    public let ignoredPromptCount: Int

    public let breakOpportunities: Int
    public let honoredOpportunities: Int
    public let excludedOpportunities: Int
    public let notificationsDelivered: Int
    public let sessionCount: Int

    public let malformedLines: Int
```

The stored fields of `DailySummary`, in `app/Sources/SigstopCore/Summary/DailyRollup.swift`.
`activeWorkByActivity` is keyed by the
`Activity` raw value, and compliance is computed rather than stored:

```swift
public var breakCompliance: Double? {
    let denominator = breakOpportunities - excludedOpportunities
    guard denominator > 0 else { return nil }
    return Double(honoredOpportunities) / Double(denominator)
}
```

**The day is Gregorian, whatever calendar the Mac uses.**
`CalendarDay.local(of:calendar:boundaryHour:)` takes only the time zone from the caller's calendar.
It numbers the day in Gregorian y/m/d, starting at the boundary hour, and never in the era of
`Calendar.current`. It has to: the store finds a day's events by loading the event files dated the
day before, the day itself and the day after, and those file names are Gregorian dates in UTC.
Measured on the same instant: the writer files it under `2025-09-22`, and Islamic Umm al-Qura
calls it `1447-03-30`, a file that never exists. `interval(boundaryHour:calendar:)` makes the same
substitution, and `CalendarSystemTests` pins both.

### 14.1 Definitions, exactly

- **`totalActiveWork`** — the sum of credited ticks (§3.3) across every session whose credit fell inside the
  day. Not wall clock, not app-foreground time. `applicationDistribution` partitions exactly this
  quantity: `applicationDistribution.values.sum() == totalActiveWork` is an invariant (§15).
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
2. `sum(applicationDistribution) == totalActiveWork` (± one tick per app, from bucket rounding).
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
