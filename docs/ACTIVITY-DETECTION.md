# Activity Detection Architecture

Local-first macOS menu bar app · Swift 6 · SwiftUI · macOS 14+ · built with SwiftPM (no full Xcode)

---

## 0. Scope, and the one thing this document refuses to do

The app wants to answer two questions:

1. **Which app is the developer in?** — this is cheap, reliable, and needs no permission.
2. **What high-level activity is that?** — this is *inference*, it is frequently wrong, and it must
   carry a confidence score that honestly reflects how thin the evidence is.

The governing rule for this entire subsystem:

> **The app must never render a claim more precisely than its signals support.** If the only thing
> observable is "VS Code is frontmost and the keyboard was touched 3 seconds ago", the app says
> `CODING @ 0.55`, not `DEBUGGING the auth module @ 0.9`. Where a distinction is not detectable,
> the app emits the **parent class at lower confidence** rather than guessing between children.

A large part of this document is a list of things macOS **will not tell us**. That list is the most
valuable part of the design, because every competitor-style feature that sounds impressive
("we know which function you were editing") is either a lie, requires Screen Recording, or requires
a keylogger-shaped permission. Section 12 records the capabilities that were deliberately declined.

---

## 1. Build & distribution constraints (these drive the architecture)

Authoring machine for this document: macOS 27.0 (26A428), Swift 6.2. Target floor: macOS 14.

### 1.1 SwiftPM without Xcode

`swift build` gives a Mach-O executable. It does **not** give an app bundle. Consequences:

| Need | Xcode-only? | SwiftPM workaround |
|---|---|---|
| `.app` bundle + `Info.plist` | no | hand-assemble in a `Makefile` / `Scripts/bundle.sh` |
| `LSUIElement = true` (menu bar only, no Dock icon) | no | key in the hand-written `Info.plist` |
| Asset catalogs (`.xcassets` → `actool`) | **yes** | forbidden. Menu bar icon must be an **SF Symbol** (`NSImage(systemSymbolName:)`) or drawn in code |
| Storyboards / XIBs (`ibtool`) | **yes** | forbidden. SwiftUI + `MenuBarExtra` only |
| Core Data model compiler (`momc`) | **yes** | forbidden. Persist with SQLite/GRDB or Codable+files |
| Metal shader precompilation (`metal`/`metallib`) | **yes** | forbidden. Not needed |
| SwiftUI Previews | **yes** | forbidden. Develop against a live debug build |
| `codesign`, `notarytool` | no | ship with Command Line Tools |

So the deliverable is a **hand-bundled, Developer-ID-signed, notarized `.app`** produced by a script,
not by `xcodebuild`.

### 1.2 The App Sandbox is not an option if we want Tier 1

**The Accessibility API cannot be used to inspect other applications from a sandboxed process.**
There is no public App Sandbox entitlement that grants it. This is why every window-title-reading
utility on macOS (window managers, launchers, time trackers) ships non-sandboxed via Developer ID.

Therefore:

- The app is **non-sandboxed**, hardened runtime on, Developer ID signed, notarized.
- It is **not distributable on the Mac App Store**. That is a product consequence, and it must be
  decided now rather than discovered later.
- Tier 0 alone *would* work sandboxed. If a Mac App Store SKU is ever wanted, it is a Tier-0-only
  build, and the confidence ceiling drops to 0.55 (§6.3). The architecture supports this by making
  tier availability a runtime value, not a compile-time one.

### 1.3 TCC grants are keyed to the code signature — this will bite during development

Accessibility permission is recorded against the binary's **cdhash**. `swift build` produces an
ad-hoc-signed binary whose cdhash changes on every rebuild, so **the Accessibility grant silently
evaporates after every `swift build`**, and the app appears in System Settings as a stale entry.

Mitigation, required in the dev workflow:

```sh
# Scripts/bundle.sh — stable identity so TCC keeps the grant across rebuilds
swift build -c release
mkdir -p build/App.app/Contents/MacOS build/App.app/Contents/Resources
cp Resources/Info.plist build/App.app/Contents/
cp .build/release/AppExecutable build/App.app/Contents/MacOS/
codesign --force --options runtime \
         --sign "Developer ID Application: ..." \
         build/App.app        # or a stable self-signed cert locally
```

Without a *stable* signing identity, expect to re-grant Accessibility dozens of times a day. Note
this in `CONTRIBUTING`, not just here.

---

## 2. What macOS actually permits

This section is deliberately pedantic. Each row states the permission genuinely required, not the
permission people assume.

### 2.1 Tier 0 — zero permission, zero prompts, always on

| Signal | API | Notes / honest caveats |
|---|---|---|
| Frontmost app identity | `NSWorkspace.shared.frontmostApplication` → `bundleIdentifier`, `localizedName`, `processIdentifier` | Rock solid. Works sandboxed. This is ~70% of the product's value. |
| App switch events | `NSWorkspace.shared.notificationCenter` → `didActivateApplicationNotification`, `didDeactivateApplicationNotification` | **Must** use `NSWorkspace.shared.notificationCenter`, *not* `NotificationCenter.default`. Classic bug: subscribing on the wrong center silently delivers nothing. |
| App launch / quit | `didLaunchApplicationNotification`, `didTerminateApplicationNotification` | Lets us know Docker/Zoom/a simulator is *running* even when not frontmost. |
| Full running-app list | `NSWorkspace.shared.runningApplications` | Filter `activationPolicy == .regular`; ignore `.accessory` / `.prohibited` for "frontmost app" purposes. |
| Menu bar owner | `NSRunningApplication.ownsMenuBar` | Useful tiebreaker when `frontmostApplication` lags during a switch. |
| **User idle time** | `CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: <any>)` | No permission. Returns *time since last HID event* — it does **not** expose what was typed. See §2.5 for a correctness gotcha in the Swift import. |
| Screen locked | `DistributedNotificationCenter` `"com.apple.screenIsLocked"` / `"com.apple.screenIsUnlocked"`; cross-check `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]` | **Undocumented** but stable for a decade. Treat as best-effort; never the sole basis for anything destructive. |
| Display sleep | `NSWorkspace` `screensDidSleepNotification` / `screensDidWakeNotification` | Documented, reliable. |
| System sleep/wake | `NSWorkspace` `willSleepNotification` / `didWakeNotification` | Documented. Use to invalidate elapsed-time accounting. |
| Fast user switching | `NSWorkspace` `sessionDidResignActiveNotification` / `sessionDidBecomeActiveNotification` | Documented. Must suspend sampling on resign. |
| Thermal pressure | `ProcessInfo.processInfo.thermalState` + `.thermalStateDidChangeNotification` | Documented. Used to shed sampling load. |
| Low Power Mode | `ProcessInfo.processInfo.isLowPowerModeEnabled` + `.NSProcessInfoPowerStateDidChange` | Documented. |
| On AC vs battery | `IOPSGetTimeRemainingEstimate()` == `kIOPSTimeRemainingUnlimited` | Cheapest correct check; no permission. |
| **Mic in use** (meeting proxy) | CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` | **No microphone permission required** — we read a device property, we never open a stream. See §2.3 for the substantial caveats. |
| Window *geometry* (not titles) | `CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)` | Returns `kCGWindowOwnerPID`, `kCGWindowBounds`, `kCGWindowLayer`, `kCGWindowNumber` **without permission**. `kCGWindowName` is *omitted* unless Screen Recording is granted. See §2.4. |
| Same-user process list | `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_ALL)`, plus `proc_pidpath` | Public, no permission, and it returns other users' and SIP-protected processes too. `p_comm` is truncated to 16 chars (`MAXCOMLEN`); `proc_pidpath` returns the **full, untruncated** executable path, which is why argv is not needed (§4.3b). `kp_proc.p_flag & P_TRACED` comes in the same buffer and says a process is under a debugger right now. Promoted to Tier 2 in this design for *privacy* reasons, not permission reasons (§4.3). |

### 2.2 Tier 1 — Accessibility (`AXUIElement`), optional, user-granted

Unlocks: **the focused window's title**, and for document-based apps, **the document's file URL**.

```swift
// Prompting. Only ever call with prompt:true from an explicit user action.
let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(opts)
```

- `AXIsProcessTrusted()` is the poll-safe, non-prompting check. **`AXAPIEnabled()` is deprecated** —
  do not use it.
- `kAXFocusedWindowAttribute` → `kAXTitleAttribute` gives the window title.
- `kAXDocumentAttribute` on a window gives a `file://` URL for document-based apps (Xcode, TextEdit,
  many native editors). This is *much* better than parsing a title — it is a real path. Electron
  apps (VS Code, Cursor, Slack, Discord, Figma) do **not** provide it.
- **AX calls are synchronous IPC into the target process and can block.** If the target is beachballed,
  the call hangs until the messaging timeout. Two non-negotiable rules:
  - `AXUIElementSetMessagingTimeout(element, 0.25)` on every element we create.
  - Never call AX on the main actor. All AX work lives in a dedicated `AccessibilityActor` on a
    background thread that owns its own `CFRunLoop`.
- **Prefer `AXObserver` over polling.** `kAXFocusedWindowChangedNotification` and
  `kAXTitleChangedNotification` turn title tracking into an *event stream*, which is the single
  biggest reason this app can be energy-negligible.
- **Electron caveat:** VS Code / Cursor expose a shallow, sometimes-empty AX tree unless the user
  enables their own accessibility support. The **window title on `AXWindow` is always present**
  regardless. Therefore the design depends on window titles *only* and never walks an Electron
  app's AX tree. This is a deliberate robustness choice.
- **Privacy line, enforced in code:** we read `kAXTitle`, `kAXDocument`, and element *roles*. We
  **never** read `kAXValue` of a text area or text field. Reading `kAXValue` would give us the user's
  actual source code / message drafts. The `AccessibilityActor` has no API surface that can return
  a text value; the capability is absent, not merely unused.

### 2.3 Microphone-in-use detection, honestly

```swift
var addr = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
    mScope:    kAudioObjectPropertyScopeGlobal,
    mElement:  kAudioObjectPropertyElementMain)   // macOS 12+; not ...ElementMaster
```

We enumerate `kAudioHardwarePropertyDevices`, keep those with a non-empty input
`kAudioDevicePropertyStreamConfiguration`, and OR their `DeviceIsRunningSomewhere`. We register
`AudioObjectAddPropertyListenerBlock` per device so this is **event-driven, not polled**, plus a
listener on `kAudioHardwarePropertyDevices` to handle hot-plug.

What this genuinely tells us: *some process on this machine is running input I/O on an audio device.*

What it does **not** tell us, and we must not pretend otherwise:

- **Who.** Not from *this* property. This sentence used to end "there is no permission-free
  attribution of a running audio device to a process", and that was false. See §2.3a.
- **Why.** Dictation, Voice Control, a voice memo, a browser tab, or a game all trip it.
- **Persistent holders.** Krisp, Loopback, BlackHole, some headset daemons, and certain audio
  interfaces keep an input device "running somewhere" *permanently*. On such a machine the signal is
  a constant `true` and is worthless.
  - **Mitigation (implementable):** a calibration guard. If the OR'd signal has been continuously
    `true` for > 4 hours, or is `true` for > 85% of the last 24h of awake time, mark the audio
    signal `.unreliable` and stop contributing it to `MEETING` at all. Surface this in the UI as
    "microphone signal disabled on this Mac — it never turns off."
  - **This guard is no longer what ends the silence, and its thresholds are unchanged.** It needs an
    hour of awake observation before the duty-cycle clause may fire at all, it is held in memory and
    so is re-served on every launch, and a holder that briefly releases the device evades it
    entirely. Two faster answers now sit in front of it: per-process attribution (§2.3a job 4) for a
    driver-level holder, and a ceiling in the engine (docs/BREAK-DECISION.md §7.1.1) for an app-level
    one. The guard stays exactly as it is, as the long-run judgement about signal *quality*, which is
    what it is good at. Its numbers were never validated against a real virtual device and retuning
    numbers nobody validated, to fix a symptom two other layers already cover, is how this got here.
- **Meeting-over ≠ mic-off.** Zoom holds the device briefly after a call, and holds it in a waiting
  room. Expect ±30s of edge error; never bill meeting duration to the second off this signal alone.
- If the user has *no* input device, the signal is absent, not `false`. Model it as
  `enum AudioInputState { case running, notRunning, noInputDevice, unreliable }` — four states, not a `Bool`.

### 2.3a Per-process microphone attribution — Tier 0, shipped

`AudioProcessCollector` reads `kAudioHardwarePropertyProcessObjectList` on the system object, then
`kAudioProcessPropertyBundleID` and `kAudioProcessPropertyIsRunningInput` per process object. macOS
14+, which is this package's deployment target. **No Microphone permission is required and none is
requested**, and a probe of it generated no `tccd` activity at all. Listeners are registered on the
list and per object, so it is event-driven like its device-level sibling; bundle identifiers are
cached per object id, because reading all of them is an IPC round trip each.

Three jobs, and it is used for nothing else:

1. **Naming.** "Slack has the microphone" rather than "something does". This is what lets the call
   latch (docs/BREAK-DECISION.md §7.7) adopt an anchor from a fact instead of from which window is
   in front.
2. **Repairing `.unreliable`.** A persistent holder holds the *device*; it does not make Slack's
   process object report input. So on a Krisp / Loopback / BlackHole Mac, where the device signal
   is worthless and meeting detection would otherwise be switched off entirely, an attributed
   call-capable holder still counts.

   This repair reaches both edges of the call, and it took two changes to do it. The first was the
   latch's trailing edge, which is all attribution can give on its own. The second is the call
   itself: `SystemSignals.audioInputRunning` is `.running`-only and therefore false for the whole of
   a real call on this Mac, so `HardBlock.audioInputInUse` never fires and the latch's `.live` phase
   was the only thing left — and it used to be deliberately silent there, on the reasoning that the
   device-level block already covered it. On this Mac it does not. So the latch is now told whether
   the policy's live blocks are covering the instant (`MeetingLatchInput.liveCaptureAlreadyBlocks`),
   holds during the live call when they are not, and charges itself for that time so the episode and
   daily ceilings keep applying. On every Mac with a reliable device signal nothing changes: the
   more precise block still explains it, and the latch is charged nothing.
3. **Not being fooled.** A readable-and-empty table is evidence of *absence*. A table whose only
   holders are Siri and dictation is not a call. `com.apple.CoreSpeech` was observed holding input
   for a single sample and releasing it.
4. **Ending the invisible hour.** The hard block asks this too now, and used not to: it took the
   bare device bit while `micLiveForLatch` one method above asked the attributed question, so on a
   Mac where a driver holds the device and no process has it, the two disagreed in the same instant
   from the same signal. The latch correctly declined to arm and the block fired anyway, until the
   calibration guard below rescued it an hour later. `SensorStack.audioDeviceHold` is that question,
   and docs/BREAK-DECISION.md §7.1.1 is what the engine does with the answer.

   Two conditions on it, both load-bearing. A process that **is** running input but reports no
   bundle id used to be dropped while the set was still reported as readable-and-empty, which is
   exactly what a command-line recorder looks like; `unnamedInputHolders` counts those, because
   "nobody has the microphone" turning out to be false in that direction converts a silence bug into
   an interruption bug. And the empty reading has to hold for 30 s before it drops a block, because
   the per-object listener's latency against the device property has never been measured.

   What this does **not** cover, said plainly because the collector's own doc comment names Krisp
   first: Krisp is an app and holds input through its own process, so the table is not empty and
   attribution buys nothing there. That case is covered by the Core ceiling in §7.1.1, not here.

Caveats that do not go away, and are printed in `--doctor` rather than smoothed over:

- Audio attributes to **helper processes**: Chrome's is `com.google.Chrome.helper`, and Teams' media
  path is `com.microsoft.vcxpc`, which is not even under the `com.microsoft.teams2` prefix. Matching
  is therefore by prefix against a hand-checked list, and it will age badly when a vendor reshuffles
  helpers. It degrades to the unattributed device bit, visibly.
- Safari routes page audio through `com.apple.WebKit.GPU`, which serves every WebKit client and
  therefore names no app. It is deliberately **not** in the list: including it would let any Safari
  tab playing a podcast anchor a call.
- A process appears only once it has touched CoreAudio. This is not a roster of running apps.

Camera-in-use via CoreMediaIO `kCMIODevicePropertyDeviceIsRunningSomewhere` **is shipped**, as
`CameraDeviceCollector`. This paragraph used to ask for it behind a feature flag while the code said
the API did not exist; the doc was right and the code was the bug (CLAUDE.md §1). It enumerates
`kCMIOHardwarePropertyDevices`, reads the in-use bit per device, registers CMIO listeners so it is
event-driven, and treats a read failure as `nil` and never as `false`. Probed on this machine: three
devices (two Continuity, one FaceTime HD), `running=false` for each, **no Camera permission, no
prompt, no `tccd` entry**. It carries the same four states and the same calibration guard as the
audio collector, because OBS Virtual Camera and a permanently attached Continuity Camera are the
camera analogue of Krisp. The thresholds are inherited from audio and have not been validated
against a virtual camera; `--doctor` prints the state so the data can arrive before anyone retunes
them.

### 2.4 Screen Recording — explicitly avoided

`CGWindowListCopyWindowInfo` still returns entries **without** the `kCGWindowName` key when Screen
Recording is not granted (behavior since macOS 10.15). We use it for geometry only:

- number of on-screen windows per PID,
- whether a `kCGWindowLayer == 0` window covers a full display (a fullscreen-ish state),
- transient small floating windows (weak "picture-in-picture / HUD" hint).

Honesty about durability: `CGWindowListCreateImage` and relatives were **deprecated in macOS 14.4**
in favour of ScreenCaptureKit. `CGWindowListCopyWindowInfo` has not been formally deprecated as of
this writing, but it is plainly on the same trajectory, and ScreenCaptureKit requires the Screen
Recording TCC grant we are refusing. Therefore: **window geometry is a garnish signal, never
load-bearing.** It is feature-detected at launch (`optionOnScreenOnly` returning an empty array when
windows are demonstrably on screen ⇒ mark unavailable) and every consumer treats it as optional.

**We will not request Screen Recording.** It is a whole-desktop-contents grant, users are right to
refuse it, and nothing in the activity model is worth it.

### 2.5 Known API traps

- **`CGEventType(rawValue: ~0)!`** — the idiomatic "any input event type" constant. `CGEventType` is
  imported into Swift as an enum; `init?(rawValue:)` returns `nil` for values it does not recognise,
  so the widely-copied force-unwrap is a latent crash if the import ever changes. **Do not force
  unwrap.** Write it defensively and keep an IOKit fallback:

  ```swift
  func systemIdleSeconds() -> TimeInterval {
      if let any = CGEventType(rawValue: ~0) {
          return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
      }
      return hidIdleSecondsFromIORegistry()   // IOHIDSystem → "HIDIdleTime" (nanoseconds)
  }
  ```

- **`.hidSystemState` vs `.combinedSessionState`** — `.combinedSessionState` also counts *synthetic*
  events posted by other processes, so mouse jigglers, automation tools, and some conferencing apps
  make the user look permanently active. Use `.hidSystemState` to stay closer to real human input,
  and say so in the UI copy.
- **`NSWorkspace.launchedApplications`** — long deprecated. Use `runningApplications`.
- **`AXAPIEnabled()`** — deprecated. Use `AXIsProcessTrusted()`.
- **`NSWorkspace` notifications are delivered on the main thread**; AX callbacks arrive on whatever
  run loop the observer source was added to. Under Swift 6 strict concurrency these are two
  different isolation domains and must be bridged explicitly (§9).
- **`AXUIElement`, `CFDictionary`, `AudioObjectID` are not `Sendable`.** They never cross an actor
  boundary in this design; only extracted `String`/`Double`/`enum` values do.

### 2.6 Approaches considered and rejected

| Approach | Why rejected |
|---|---|
| AppleScript / Apple Events (`tell app "Safari" to get URL of current tab`) | Requires the **Automation** TCC grant, prompts **per target app**, is blocked under sandbox, and breaks whenever a vendor changes their scripting dictionary. A second permission for a worse signal. |
| `CGEventTap` keystroke/WPM counting | Requires **Input Monitoring** — a keylogger-shaped grant. Declined on principle (§12). |
| `IOHIDManager` input device taps | Same permission, same objection. |
| EndpointSecurity for live process exec events | Needs a **restricted entitlement Apple grants case-by-case**; also requires a system extension. Disproportionate. |
| Private `MediaRemote.framework` for "is media playing" | Private framework. Breaks on update, risks notarization posture. |
| ScreenCaptureKit / OCR of the screen | Requires Screen Recording. Absolutely not. |
| dyld-loaded third-party plugin bundles | Hardened runtime + notarization make loading unsigned third-party code hostile and unsafe. Extensibility is solved declaratively instead (§5.5). |

---

## 3. Core model

```swift
import Foundation

// MARK: - Activity taxonomy

public enum Activity: String, Sendable, Codable, CaseIterable {
    case coding
    case debugging
    case testing
    case codeReview
    case terminalWork
    case aiCoding
    case documentation
    case browsing
    case communication
    case meeting
    case idle
    case unknown

    /// The class to fall back to when a child cannot be distinguished from its siblings.
    /// Degrading to the parent is ALWAYS preferred over guessing between children.
    public var parent: Activity? {
        switch self {
        case .debugging, .testing, .aiCoding, .documentation: return .coding
        case .codeReview:                                     return .browsing
        case .meeting:                                        return .communication
        case .terminalWork, .coding, .browsing,
             .communication, .idle, .unknown:                 return nil
        }
    }
}

// MARK: - Tiers

public enum SignalTier: Int, Sendable, Codable, CaseIterable {
    case tier0 = 0   // zero permission, always available
    case tier1 = 1   // Accessibility, user-granted
    case tier2 = 2   // explicit opt-in: local git context + process introspection
}

public struct SignalTierSet: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let tier0 = SignalTierSet(rawValue: 1 << 0)
    public static let tier1 = SignalTierSet(rawValue: 1 << 1)
    public static let tier2 = SignalTierSet(rawValue: 1 << 2)
}

// MARK: - Confidence

/// A probability in 0...1 that cannot be constructed out of range.
public struct Confidence: Sendable, Codable, Hashable, Comparable {
    public let value: Double
    public init(_ v: Double) { self.value = min(max(v, 0.0), 1.0) }
    public static func < (a: Self, b: Self) -> Bool { a.value < b.value }

    public static let none    = Confidence(0.0)
    /// Reserved for OS facts only (screen locked, session inactive). Nothing inferred reaches this.
    public static let certain = Confidence(0.99)
}

// MARK: - Evidence

public struct EvidenceID: Sendable, Codable, Hashable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ s: String) { self.rawValue = s }
}

/// A single reason the app believes something, expressed in log-odds so that
/// independent reasons compose by addition. `summary` is user-facing: the app must
/// always be able to answer "why do you think that?".
public struct Evidence: Sendable, Codable, Hashable {
    public let id: EvidenceID
    public let tier: SignalTier
    public let logOdds: Double
    public let summary: String
}

// MARK: - Identity & context

public struct AppIdentity: Sendable, Codable, Hashable {
    public let bundleID: String?          // nil for bundle-less processes
    public let localizedName: String
    public let pid: pid_t
}

/// Everything optional. A field is nil when the tier that would populate it is unavailable.
/// There is no "unknown" sentinel string: absence is modelled as absence.
public struct ActivityContext: Sendable, Codable, Hashable {
    public var projectName: String?       // tier1, parsed from window title (heuristic)
    public var fileName: String?          // tier1
    public var fileExtension: String?     // tier1
    public var documentURL: URL?          // tier1, kAXDocument — a REAL path, not a guess
    public var branch: String?            // tier2, read from .git/HEAD
    public var repoState: RepoState?      // tier2
    public var browserHost: String?       // tier1b opt-in; HOST ONLY, never path or query
}

public enum RepoState: String, Sendable, Codable {
    case clean, rebaseInProgress, mergeInProgress, bisecting, detachedHead
}

/// States that are NOT mutually exclusive with the primary activity.
/// You can be in a meeting while coding. Modelling MEETING as a peer of CODING
/// would force a false choice, so it is a separate axis.
public struct ConcurrentStates: Sendable, Codable, Hashable {
    public var inMeeting: Bool = false
    public var meetingConfidence: Confidence = .none
    public var screenLocked: Bool = false
    public var onBattery: Bool = false
}

// MARK: - The output

public struct ActivityObservation: Sendable, Codable, Hashable {
    public let timestamp: Date
    public let activity: Activity
    public let confidence: Confidence
    public let evidence: [Evidence]        // ordered by |logOdds| descending
    public let app: AppIdentity
    public let context: ActivityContext
    public let concurrent: ConcurrentStates
    public let providerID: ProviderID
    public let tiersUsed: SignalTierSet
}
```

---

## 4. The tiered signal model

### 4.1 Tier 0 — always on, no prompt, no ask

Everything in §2.1. Produces: app identity, switch history, idle time, session/lock/sleep state,
power and thermal state, audio-input state, coarse window geometry.

**What Tier 0 can conclude:** which app, for how long, whether the human is present, whether a
microphone is hot. **What it cannot conclude:** anything about *content* — no project, no file, no
branch, no URL, no distinction between writing code and reading code.

Tier 0 alone is a genuinely useful product (accurate per-app time, accurate idle, decent meeting
detection). It is the default state, not a degraded state, and the UI should not nag.

### 4.2 Tier 1 — Accessibility

Adds: focused window title (event-driven via `AXObserver`), and `kAXDocument` file URLs where the
app provides them. From a title we can heuristically parse project name, file name, and file
extension — see §7.

**Honest limits of window-title parsing:**

- VS Code's title is controlled by the user's `window.title` setting. The default is roughly
  `"<file> — <folder>"` (em dash) but users change it constantly, and there is a `●` prefix for
  unsaved changes. Parsers must be defensive and must be allowed to return `nil`.
- A title gives a project *name*, not a *path*. Mapping name → path requires Tier 2.
- Zed, JetBrains, and Xcode each use different separators and orderings. Per-provider parsing
  (§5) exists precisely because there is no universal format.
- A title says nothing about *mode*. A VS Code window mid-debug-session looks identical to one that
  is idle. This is the core reason `DEBUGGING` is hard (§7.2).

**Tier 1b (separately opt-in): browser URL host.** Chrome-family browsers expose the omnibox as an
AX text field and a web area with `kAXURL`; Safari similarly. This is technically Tier 1 but is a
real privacy escalation, so it is a **separate toggle**, and even when enabled the app extracts and
retains **only the host** (`github.com`), never the path or query. The raw URL never leaves the
`AccessibilityActor`.

### 4.3 Tier 2 — explicit opt-in local context

Two independent opt-ins, each with its own switch:

**(a) Git context.** For user-registered project folders only (chosen via `NSOpenPanel`, so the user
grants the folder explicitly):

- Read `.git/HEAD` → branch, or detached HEAD. One tiny file read.
- Presence of `.git/rebase-merge/`, `.git/rebase-apply/`, `.git/MERGE_HEAD`, `.git/BISECT_LOG` →
  `RepoState`.
- **We never shell out to `git`.** Spawning a process on a timer is the classic way these apps
  become a measurable battery cost, and `git status` in a large repo can take seconds.
- TCC gotcha: repos under `~/Documents`, `~/Desktop`, `~/Downloads` are protected by the "Files and
  Folders" TCC service and will prompt. Repos under `~/code`, `~/Developer`, `~/src` are not.
  Surface this so the user understands why one folder prompted and another did not, and make the
  collector distinguish *no repository here* from *not allowed to look*: an `EPERM` or `EACCES` on
  the read is a different fact from a missing `.git`, and reporting the second when it was the first
  is the kind of quiet wrong answer §4.1 of `CLAUDE.md` exists to stop.

**Where the path comes from, and where it does not.** A registered folder is the only thing the
collector may open. Nothing infers a path from a name, because inventing a path from a project name
is exactly the guess `CLAUDE.md` §4.1 forbids. What the other tiers supply is not a path but an
*answer to which registered folder you are in*, and there are two of them, both Tier 1:

- a `kAXDocument` file URL that lies inside a registered folder. Measured on this machine, that
  arrives for Terminal.app (where it is the focused tab's working directory, kept current by
  `update_terminal_cwd` in `/etc/zshrc_Apple_Terminal`), for TextEdit, and for native `NSDocument`
  apps including Xcode. It does **not** arrive for the Electron editors: VS Code and Cursor both
  return `kAXDocument` with status `.success` and an **empty string**, so code that branches on the
  `AXError` alone will believe it got a document. Chrome returns a full page URL including the path,
  which `AccessibilityCollector.fileURL(from:)` already discards because it is not a file URL.
- the project name parsed out of the window title, matched against the last path component of a
  registered folder. This is what covers VS Code, Cursor, Zed and JetBrains. It is a match against a
  closed set the user typed in themselves, not a path conjured from a string.

Two registered folders that both match means the app cannot tell which one you are in, and it
reports no branch rather than picking. So does zero matches.

**The consequence, stated rather than hidden:** with Accessibility off there is no way to tell which
of several registered folders is in front, so the branch is not read. Tier 2 git is an upgrade on an
upgrade. `--doctor` says which route answered and which abstained, so this never looks like a bug.

**Do not use a `DispatchSource` file watch on `.git/HEAD`.** An earlier version of this section
prescribed one and called it "event-driven, zero polling". Measured: git replaces `HEAD` by renaming
a lockfile over it, so the watched inode is orphaned and the source fires **once**, on the first
checkout, and then stays silent forever. Watching the containing `.git` directory instead does
survive, at twelve events per checkout from index and lockfile churn. Neither is worth it: the whole
walk-and-parse costs about 50 microseconds warm (measured, 2000 iterations, four directory levels),
so the collector reads on demand behind a short memo instead. The real cost of this read is not CPU,
it is that a `stat` on a sleeping or network volume can block for seconds, which is an argument for
keeping it off the main actor, not for a watcher.

**(b) Process introspection.** One `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_ALL)` for the table, which
carries `p_comm`, `e_ppid` and `kp_proc.p_flag`, and `proc_pidpath` for the handful of pids that
matched, to confirm the executable is where that tool actually lives.

This needs **no permission** — it is placed in Tier 2 for *privacy*, because knowing what somebody
runs is knowing something about them. The rules are absolute:

- Only the **basename** of the executable is examined, and only against a static allowlist that
  lives in the source where anyone can read and correct it. Anything unmatched is not recorded, not
  counted, not reported. There is no inventory.
- `kp_proc.p_flag & P_TRACED` is read from the same buffer. It is set on the process being debugged,
  so it says *something has this process under `ptrace` right now* rather than *a binary with this
  name exists*, which is nearer an OS fact than any name match can be. Measured baseline on a
  developer machine: 0 of 1003 processes, and exactly 1 the instant a real `debugserver` attached.
  Cost of the whole scan, measured: **0.17 ms**, which is why it needs no timer of its own.
- **`KERN_PROCARGS2` is not called.** This section used to mandate it, on the grounds that "`p_comm`
  alone is truncated to 16 characters, which is why `KERN_PROCARGS2` is needed at all." That
  reasoning was wrong, and the measurement is one-sided: `proc_pidpath` returns the complete,
  untruncated path with no permission at all, for every process on the machine including root-owned
  and SIP-protected ones. No name on the allowlist exceeds 15 characters, so `p_comm` holds them
  whole anyway. Since the only thing argv bought was a name available another way, and argv is the
  one field on a developer's machine where a password is routinely in plain text, it is not read.
  Reading it also costs about 43x more and copies half a megabyte of argv **and environment**, which
  is where `AWS_SECRET_ACCESS_KEY` lives.
- The cost of refusing argv, stated rather than hidden: a tool that is a shebang script is named by
  its arguments, not by its executable. A `#!/usr/bin/env node` script called `jest` is `node` to the
  kernel and a `#!/usr/bin/env python3` script called `pytest` is `Python`. So `nodeInspect`,
  `debugpy`, `goTest`, `cargoTest`, `swiftTesting`, `swiftBuild`, `pytest`, `jest`, `vitest`,
  `playwright`, `rspec` and `phpunit` are **not detected**, and `--doctor` says so in those words
  instead of reporting them absent. Bare `node` is not matched either: eleven were running on this
  machine, every one of them an editor helper.
- What survives is every tool that is its own Mach-O binary carrying its own name, which includes
  the whole debugger set: `debugserver`, `lldb`, `gdb`, `delve`. That is the trade. `DEBUGGING`
  becomes genuinely reachable; `TESTING` keeps only `xctest` and stays mostly where it was.
- A read failure is "no information", never "not running". A zero-length table is a failure, not an
  empty machine: under a sandbox profile without `sysctl-read` the call returns nothing and sets no
  errno a caller would notice, so the snapshot must be `nil` rather than an empty set of matches.

### 4.4 Tier availability is a runtime value

```swift
public actor SignalAvailability {
    public private(set) var tiers: SignalTierSet = [.tier0]
    public func refresh() async   // re-checks AXIsProcessTrusted() and user opt-ins
    public var stream: AsyncStream<SignalTierSet> { get }
}
```

Tier 1 can be revoked by the user at any moment from System Settings, with no notification. The app
therefore re-checks `AXIsProcessTrusted()` on every app-activation event (it is cheap and does not
prompt) and degrades immediately — including recomputing the confidence ceiling — rather than
continuing to emit stale high-confidence observations.

---

## 5. Provider architecture

### 5.1 The protocol

```swift
public struct ProviderID: Sendable, Codable, Hashable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ s: String) { self.rawValue = s }
}

/// How a provider declares the apps it claims.
public struct AppClaim: Sendable, Hashable {
    public enum Match: Sendable, Hashable {
        case bundleID(String)          // exact       — specificity 300
        case bundleIDPrefix(String)    // "com.jetbrains." — specificity 200 + prefix.count
        case bundleIDRegex(String)     // last resort — specificity 100
        case executableName(String)    // for bundle-less processes — specificity 150
    }
    public let match: Match
    public var specificity: Int {
        switch match {
        case .bundleID:              return 300
        case .bundleIDPrefix(let p): return 200 + p.count
        case .executableName:        return 150
        case .bundleIDRegex:         return 100
        }
    }
    public func matches(_ app: AppIdentity) -> Bool { /* ... */ }
}

/// A provider is a pure function from signals to an observation.
/// It owns NO state, performs NO I/O, and is `Sendable`. All I/O happened upstream
/// in the collectors; providers only interpret. This makes every provider trivially
/// unit-testable by constructing a `SignalContext` literal — which matters a lot,
/// because there is no Xcode and thus no UI test harness.
public protocol ActivityProvider: Sendable {
    static var identifier: ProviderID { get }

    /// Which apps this provider claims.
    var claims: [AppClaim] { get }

    /// Tiebreaker when two providers claim at equal specificity. Higher wins.
    /// Built-ins use 0; third-party overrides should use 100 so they win by default.
    var priority: Int { get }

    /// Return nil to decline — e.g. a provider that only recognises a specific
    /// window-title shape and sees none. Declining passes the app to the next
    /// ranked provider, and ultimately to `GenericProvider`, which never declines.
    func observe(_ context: SignalContext) -> ProviderVerdict?
}

/// A provider proposes an activity and the evidence for it. It does NOT compute the
/// final confidence — `ConfidenceEngine` does, so that tier ceilings and calibration
/// are applied in exactly one place and cannot be bypassed by a third-party provider.
public struct ProviderVerdict: Sendable {
    public let activity: Activity
    public let evidence: [Evidence]
    public let context: ActivityContext
    /// If the provider knows it cannot distinguish between children, it names the
    /// parent here and the engine will not let confidence exceed `parentCeiling`.
    public let degradedFromAmbiguity: Bool
}
```

### 5.2 What providers receive

```swift
public struct SignalContext: Sendable {
    public let now: Date
    public let available: SignalTierSet

    // Tier 0
    public let frontmost: AppIdentity
    public let frontmostSince: Date
    public let recentApps: [AppSwitch]        // ring buffer, last 20 switches
    public let runningBundleIDs: Set<String>  // for "is Zoom/Docker/a simulator running"
    public let input: InputActivity
    public let session: SessionState
    public let power: PowerState
    public let audioInput: AudioInputState
    public let windowGeometry: WindowGeometrySnapshot?   // nil if feature-detected unavailable

    // Tier 1
    public let windowTitle: String?
    public let documentURL: URL?
    public let browserHost: String?           // tier1b only

    // Tier 2
    public let processes: ProcessSnapshot?
    public let git: GitSignal?
}

public struct AppSwitch: Sendable, Hashable, Codable {
    public let app: AppIdentity
    public let enteredAt: Date
    public let leftAt: Date?
}

public struct InputActivity: Sendable, Hashable {
    public let idleSeconds: TimeInterval
    public let source: IdleSource            // .hidSystemState or .ioRegistryFallback
}

public struct SessionState: Sendable, Hashable {
    public let screenLocked: Bool
    public let displaysAsleep: Bool
    public let sessionActive: Bool           // false during fast user switching
}

public enum AudioInputState: Sendable, Hashable {
    case running
    case notRunning
    case noInputDevice
    case unreliable          // calibration decided this Mac's mic never turns off
}

public struct ProcessSnapshot: Sendable {
    /// Allowlist-matched tool tokens only. Raw argv is never stored here.
    public let matchedTools: Set<ToolToken>
    /// Tools whose parent process is the frontmost app — a much stronger signal.
    public let childrenOfFrontmost: Set<ToolToken>
    public let capturedAt: Date
}

public enum ToolToken: String, Sendable, Codable, CaseIterable {
    // debuggers
    case lldb, debugserver, gdb, delve, debugpy, nodeInspect
    // test runners
    case pytest, jest, vitest, xctest, goTest, cargoTest, swiftTesting, rspec, phpunit, playwright
    // terminal editors
    case vim, nvim, helix, emacs, nano
    // AI CLIs
    case claudeCLI, aider, codexCLI, gooseCLI
    // build / vcs
    case gitProcess, ghCLI, xcodebuild, gradle, cargo, swiftBuild, tsc, webpack, vite
    // remote
    case ssh, mosh, kubectl
}
```

### 5.3 Resolution and ranking

```swift
public actor ProviderRegistry {
    public func register(_ provider: any ActivityProvider)
    public func registerAll(_ providers: [any ActivityProvider])
    public func loadManifests(from directory: URL) throws -> [ProviderID]

    /// Ordered best-first. Never empty: GenericProvider is always appended last.
    public func resolve(for app: AppIdentity) -> [any ActivityProvider]
}
```

Resolution algorithm:

1. Collect every provider with at least one `AppClaim` matching the frontmost `AppIdentity`.
2. Rank by (highest matching claim `specificity`, then `priority`, then `identifier` for stable
   ordering — determinism matters for tests and for not flapping between equal candidates).
3. Call `observe(_:)` on each in order; the **first non-nil verdict wins**.
4. `GenericProvider` claims `.bundleIDRegex(".*")` at specificity 100 / priority `Int.min` and
   never returns nil, so resolution always terminates with a verdict.

Verdicts are **not merged** across providers. Merging two interpretations produces a blend that
neither provider would endorse and makes the evidence list incoherent. One provider owns the verdict;
everything else is evidence fed into it via `SignalContext`.

### 5.4 Built-in providers

| Provider | Claims | Primary job |
|---|---|---|
| `VSCodeProvider` | VS Code + Insiders, exact IDs | title → project/file; delegates to shared `ElectronEditorTitleParser` |
| `CursorProvider` | Cursor's ToDesktop ID | same parser, plus AI-CLI-child awareness |
| `ZedProvider` | `dev.zed.*` prefix | Zed title format |
| `JetBrainsProvider` | `com.jetbrains.` prefix + `com.google.android.studio` | one provider for the whole family; titles share a format |
| `XcodeProvider` | `com.apple.dt.Xcode` | uses `kAXDocument` (real path!) and `debugserver`/`xctest` children |
| `TerminalProvider` | Terminal, iTerm2, Warp, Ghostty, Alacritty, Kitty | almost entirely process-driven |
| `BrowserProvider` | Chrome, Arc, Safari, Firefox | CODE_REVIEW vs BROWSING vs MEETING |
| `CommunicationProvider` | Slack, Discord, Zoom | COMMUNICATION, and meeting corroboration |
| `DesignProvider` | Figma | a single low-confidence class; we do not pretend to read Figma state |
| `AIAssistantProvider` | Claude, ChatGPT/Codex | AI_CODING only with corroboration (§7.6) |
| `GenericProvider` | `.*` | category from a bundle-ID catalog, else UNKNOWN |

### 5.5 Third-party extension without touching core

Two mechanisms, in order of preference.

**(a) Declarative manifest — no code, no rebuild.** Drop a JSON file into
`~/Library/Application Support/<the app>/providers/`. It is parsed into a `DeclarativeProvider` at
launch (and on an FSEvents change). This covers the ~80% case, which is "recognise my editor and
parse its title".

```jsonc
{
  "schemaVersion": 1,
  "identifier": "com.example.nova-provider",
  "priority": 100,
  "claims": [{ "bundleID": "com.panic.Nova" }],
  "titleRules": [
    {
      // Named capture groups map directly onto ActivityContext fields.
      "pattern": "^(?<fileName>[^—]+) — (?<projectName>.+)$",
      "activity": "coding",
      "logOdds": 1.2,
      "summary": "Nova window title matched '<file> — <project>'"
    },
    {
      "pattern": "\\.(md|mdx|rst)\\b",
      "activity": "documentation",
      "logOdds": 1.6,
      "summary": "Editing a prose file"
    }
  ],
  "defaultActivity": "coding",
  "defaultLogOdds": 0.4
}
```

Safety properties that make this acceptable to load from disk:

- It is **data, not code**. No dyld loading, no scripting engine, no eval.
- Regexes are compiled with `NSRegularExpression` under a **match timeout and a complexity budget**;
  a manifest cannot hang the app with catastrophic backtracking.
- A manifest supplies `logOdds` but **cannot set confidence**. `ConfidenceEngine` still applies tier
  ceilings and calibration, so a hostile or over-eager manifest cannot manufacture `0.99`.
- Manifest `logOdds` values are additionally **clamped to ±2.0** each.
- Unknown `activity` strings fail the manifest at load time with a visible error, rather than
  silently mapping to `unknown`.

**(b) Swift package.** For providers that need real logic (cross-referencing processes, custom
state machines), a third party depends on the `ActivityCore` module, conforms to `ActivityProvider`,
and exposes a `ProviderBundle`:

```swift
public protocol ProviderBundle: Sendable {
    static var providers: [any ActivityProvider] { get }
}
```

The host app links the package and calls `registry.registerAll(MyBundle.providers)`. This requires a
rebuild — which is the honest trade, because loading arbitrary third-party binary code into a
non-sandboxed process holding an Accessibility grant would be irresponsible.

### 5.6 Bundle identifier catalog

**Verification legend**

- ✅ **VERIFIED** — read from the actual `Info.plist` or LaunchServices on the authoring machine
  (macOS 27.0) at the time this document was written.
- ⚠️ **UNVERIFIED** — not installed on the authoring machine. The value is from documentation and
  prior knowledge and **must be confirmed before shipping**. These are candidates for being wrong.

Verify any row with:

```sh
osascript -e 'id of app "Zed"'
# or, authoritative — read the bundle directly, bypassing LaunchServices name resolution:
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "/Applications/Zed.app/Contents/Info.plist"
```

**Editors / IDEs**

| App | Bundle ID | Status |
|---|---|---|
| VS Code | `com.microsoft.VSCode` | ✅ VERIFIED |
| VS Code Insiders | `com.microsoft.VSCodeInsiders` | ⚠️ UNVERIFIED |
| Cursor | `com.todesktop.230313mzl4w4u92` | ✅ VERIFIED — note this is a ToDesktop-generated opaque ID and is *not* stable across a rebrand; keep a `localizedName == "Cursor"` fallback claim |
| Zed | `dev.zed.Zed` | ⚠️ UNVERIFIED (also expect `dev.zed.Zed-Preview`, `dev.zed.Zed-Dev` — claim via `.bundleIDPrefix("dev.zed.")`) |
| IntelliJ IDEA (Ultimate) | `com.jetbrains.intellij` | ⚠️ UNVERIFIED |
| IntelliJ IDEA (Community) | `com.jetbrains.intellij.ce` | ⚠️ UNVERIFIED |
| WebStorm | `com.jetbrains.WebStorm` | ⚠️ UNVERIFIED (note the capitalisation — JetBrains is inconsistent across products, which is exactly why `JetBrainsProvider` claims by **prefix** `com.jetbrains.` rather than enumerating) |
| PyCharm (Pro) | `com.jetbrains.pycharm` | ⚠️ UNVERIFIED |
| PyCharm (Community) | `com.jetbrains.pycharm.ce` | ⚠️ UNVERIFIED |
| Android Studio | `com.google.android.studio` | ⚠️ UNVERIFIED |
| Xcode | `com.apple.dt.Xcode` | ⚠️ UNVERIFIED on this machine, but this one is genuinely well-known and stable |

**Terminals**

| App | Bundle ID | Status |
|---|---|---|
| Terminal | `com.apple.Terminal` | ✅ VERIFIED |
| iTerm2 | `com.googlecode.iterm2` | ⚠️ UNVERIFIED |
| Warp | `dev.warp.Warp-Stable` | ⚠️ UNVERIFIED |
| Ghostty | `com.mitchellh.ghostty` | ⚠️ UNVERIFIED |
| Alacritty | `org.alacritty` | ⚠️ UNVERIFIED |
| Kitty | `net.kovidgoyal.kitty` | ⚠️ UNVERIFIED |

**Browsers**

| App | Bundle ID | Status |
|---|---|---|
| Google Chrome | `com.google.Chrome` | ✅ VERIFIED |
| Arc | `company.thebrowser.Browser` | ✅ VERIFIED |
| Safari | `com.apple.Safari` | ✅ VERIFIED |
| Firefox | `org.mozilla.firefox` | ⚠️ UNVERIFIED |

**Communication**

| App | Bundle ID | Status |
|---|---|---|
| Slack | `com.tinyspeck.slackmacgap` | ✅ VERIFIED |
| Discord | `com.hnc.Discord` | ✅ VERIFIED |
| Zoom | `us.zoom.xos` | ✅ VERIFIED |

**Design / tools / AI / notes**

| App | Bundle ID | Status |
|---|---|---|
| Figma | `com.figma.Desktop` | ✅ VERIFIED |
| Postman | `com.postmanlabs.mac` | ✅ VERIFIED |
| Docker Desktop | `com.docker.docker` | ✅ VERIFIED (read from `/Applications/Docker.app`). **Caveat worth recording:** LaunchServices on the authoring machine resolved the *name* "Docker Desktop" to `com.electron.dockerdesktop`, which is an Electron helper, not the app. Claim `com.docker.docker` and treat `com.electron.dockerdesktop` as a secondary claim. This is a concrete example of why name-based lookup is untrustworthy and bundles must be read directly. |
| Claude (desktop) | `com.anthropic.claudefordesktop` | ✅ VERIFIED |
| ChatGPT (desktop) | `com.openai.codex` | ✅ VERIFIED — **and this is a surprise worth flagging.** `/Applications/ChatGPT.app` on the authoring machine (v26.901.51231) reports `com.openai.codex`, not the historically documented `com.openai.chat`. Claim **both**; treat `com.openai.chat` as ⚠️ UNVERIFIED-legacy. Do not assume either is correct on an arbitrary user's machine. |
| Linear | `com.linear` | ✅ VERIFIED |
| Notion | `notion.id` | ✅ VERIFIED |
| Obsidian | `md.obsidian` | ⚠️ UNVERIFIED |

**Design consequence:** because roughly half this table could not be verified and two of the
verified rows contradicted expectation, **bundle IDs are shipped as a data file, not as Swift
literals**. `Resources/app-catalog.json` is loaded at launch, is overridable by the user's own
manifests, and every unrecognised app falls through to `GenericProvider` rather than being
misclassified. A wrong ID in the catalog is then a one-line data fix, not a release.

---

## 6. Confidence

### 6.1 Composition

Evidence is expressed in **log-odds** so independent evidence composes by addition:

```swift
public enum ConfidenceEngine {
    /// Prior for any inferred activity before evidence. 0.15 ⇒ we start sceptical.
    static let prior: Double = log(0.15 / 0.85)      // ≈ -1.735

    @inlinable static func sigmoid(_ x: Double) -> Double { 1.0 / (1.0 + exp(-x)) }

    public static func combine(
        evidence: [Evidence],
        tiers: SignalTierSet,
        degradedFromAmbiguity: Bool,
        isOSFact: Bool = false
    ) -> Confidence {
        let sum = evidence.reduce(prior) { $0 + max(-2.0, min(2.0, $1.logOdds)) }
        let raw = sigmoid(sum)
        let cap = isOSFact ? 0.99 : ceiling(for: tiers, degraded: degradedFromAmbiguity)
        return Confidence(min(raw, cap))
    }

    static func ceiling(for tiers: SignalTierSet, degraded: Bool) -> Double {
        var c: Double
        if tiers.contains(.tier2)      { c = 0.93 }
        else if tiers.contains(.tier1) { c = 0.85 }
        else                           { c = 0.55 }
        if degraded { c = min(c, 0.60) }
        return c
    }
}
```

### 6.2 Invariants (enforced by tests, not by convention)

1. `confidence <= ceiling(for: tiersUsed)` — **always**. A provider cannot exceed its tier.
2. `confidence < 1.0` — **always**. Nothing is certain.
3. `confidence >= 0.99` only when `isOSFact` — i.e. screen locked, display asleep, session
   inactive. Those are not inferences; they are things the kernel told us.
4. Every `Evidence` must cite a tier that is present in `tiersUsed`. An observation cannot be
   justified by a signal that was not available.
5. `evidence.isEmpty` ⇒ `activity == .unknown` and `confidence <= 0.2`.

### 6.3 Ceilings

| Available tiers | Ceiling | Rationale |
|---|---|---|
| Tier 0 only | **0.55** | We know the app and whether a human is present. That is barely more than a coin flip about *what they are doing*, and the number should say so. |
| Tier 0 + 1 | **0.85** | A window title is strong but user-configurable, ambiguous about mode, and absent for some windows. |
| Tier 0 + 1 + 2 | **0.93** | Branch + running tool processes is about as good as observation gets without reading content. |
| Any, but provider degraded to a parent class | **0.60** | Saying "CODING, might be debugging" should never look confident. |
| OS facts (lock / sleep / session) | **0.99** | Not inference. |

### 6.4 Decay and hysteresis

- **Decay.** Confidence decays toward the class prior with a 90-second half-life since the last
  corroborating evidence. Sitting in VS Code for 40 minutes with no input and no title change is
  *less* evidence of coding over time, not the same amount.
- **Dwell gate.** An app switch does not immediately change the published activity. A new app must
  be frontmost for **≥ 8 s** before it can change the class — this suppresses the flicker from
  alt-tabbing through windows or clicking a notification. Exception: a switch *into* a locked or
  idle state publishes immediately.
- **Sticky terminal/browser.** Momentary 2-second visits to a browser from an editor do not reset
  a coding session; the ring buffer (`recentApps`) lets providers see "this is a 3-second lookup
  inside a 25-minute editor session" and keep the parent session intact.

---

## 7. Classification rules

For each class: the signals that justify it, the tier they need, and the honest confidence band.
Where a distinction is not reliably detectable, the rule says so and names the fallback.

### 7.1 CODING

| Evidence | Tier | log-odds |
|---|---|---|
| Frontmost app is a claimed editor/IDE | 0 | +1.6 |
| Idle < 60 s | 0 | +0.7 |
| Window title parsed into `file + project` | 1 | +1.1 |
| File extension is a code extension | 1 | +0.9 |
| `kAXDocument` resolved to a real file path | 1 | +1.3 |
| Terminal-editor child process (`nvim`, `vim`, `helix`, `emacs`) | 2 | +1.8 |

Bands: **Tier 0 only → 0.50–0.55.** Tier 0+1 → 0.75–0.85. All tiers → up to 0.93.

### 7.2 DEBUGGING — the honest answer

**You cannot tell debugging from coding in VS Code from the window title.** The title does not change
when a debug session starts. Any product that claims otherwise is either using Screen Recording, a
vendor extension, or making it up.

What *is* detectable, and how:

| Evidence | Tier | log-odds | Notes |
|---|---|---|---|
| A process is under `ptrace` (`P_TRACED`) and descends from the frontmost app | 2 | **+3.0** | Unambiguous, and it is a kernel flag rather than a name. Something has that process under a debugger, and it is yours. |
| A process is under `ptrace` anywhere on the machine | 2 | +1.8 | Real, but it may be another project's debugger. Honest at this weight. |
| `debugserver` running as a descendant of Xcode | 2 | **+3.0** | Unambiguous. `debugserver` exists for exactly one reason. Verified live on this machine. |
| `lldb` / `gdb` / `delve` descending from the app in front | 2 | +2.2 | Strong. Ancestry is what makes it yours. |
| `lldb` / `gdb` / `delve` running anywhere else | 2 | +0.3 | Cited, and close to weightless. A debugger left alive in another project is very nearly a constant on a developer's Mac. |
| `node --inspect` / `--inspect-brk` / `debugpy` | — | — | **Not detected.** Both are named only by their arguments and argv is not read (§4.3b). |
| A debug-tool process is a **child of the frontmost app** | 2 | +0.8 (additive) | Distinguishes "I am debugging" from "a debugger is running in another project". |
| Rapid alternation between editor and a browser/simulator, < 5 s dwell each, ≥ 4 cycles/min | 0 | +0.5 | Weak, real, and honest about being weak. Do not let this alone produce DEBUGGING. |

**Rule:** a name is never enough. `DEBUGGING` requires a debugger that **descends from the app in
front**, or `P_TRACED` — under the frontmost app, or elsewhere while a debugger this app can also
name is running. A bare machine-wide name match decides nothing: it is cited as evidence and the
window in front answers first, because one `dlv dap` left alive by a Go extension used to mean the
app said "you have been chasing one bug for fifty minutes" at 0.90 while you were editing a README,
which is the failure CLAUDE.md §4.1 names by hand. The `P_TRACED`-elsewhere route is capped at
**0.80** rather than 0.90, so the corroboration changes a number somebody can see instead of being
decorative: what that debugger is attached to is, by definition, not under the app you are in.

**Rule:** `DEBUGGING` requires **Tier 2**. With Tier 0 or Tier 0+1 only, the app emits `CODING` with
`degradedFromAmbiguity = true` (ceiling 0.60) and, in the UI, the phrase "coding — can't tell if
you're debugging". It does **not** emit `DEBUGGING` at low confidence, because a wrong specific
answer is worse than a right vague one.

Ceiling for `DEBUGGING` even with all tiers: **0.90**. A debugger process can be attached and idle.

### 7.3 TESTING

| Evidence | Tier | log-odds |
|---|---|---|
| `pytest` / `jest` / `vitest` / `xctest` / `go test` / `cargo test` / `rspec` / `phpunit` / `playwright` process | 2 | +2.6 |
| That process is a child of the frontmost editor or terminal | 2 | +0.8 |
| Window title contains a test-file pattern (`*.test.*`, `*_test.go`, `test_*.py`, `*Tests.swift`, `*.spec.*`) | 1 | +1.5 |
| Terminal frontmost while a test process is alive | 0+2 | +0.6 |

**With Tier 2, honestly:** only `xctest` in that first row is its own executable. `pytest`, `jest`,
`vitest`, `playwright`, `rspec` and `phpunit` are shebang scripts that the kernel calls `Python` or
`node`, and `go test` / `cargo test` / `swift test` are subcommands. Naming them would mean reading
argv, which §4.3(b) refuses. So Tier 2 makes `DEBUGGING` reachable and leaves `TESTING` roughly
where Tier 1 left it. That asymmetry is printed in `--doctor` rather than left to be discovered.

**Without Tier 2:** a title match alone gives `TESTING` at ≤ 0.72 (Tier-1 ceiling applies, and we
deduct for the fact that *editing* a test file is not *running* tests — an important distinction the
title cannot make). If there is no title match either, fall back to `CODING`.

Test runs are short and bursty. The process poller (§8) uses a **5 s interval while a terminal or
editor is frontmost and the user is active**, precisely so a 20-second test run is not missed
entirely — but it is honest that sub-5-second runs *will* be missed, and the app must not present
test-run counts as exhaustive.

### 7.4 CODE_REVIEW

| Evidence | Tier | log-odds |
|---|---|---|
| Browser title matches `Pull Request #\d+`, `· Merge request !\d+`, `Files changed`, `Review changes`, `Reviewing \d+ files` | 1 | +2.4 |
| Browser title matches a commit/diff shape (`Comparing .* · `, `Commit .{7,40} ·`) | 1 | +1.4 |
| Host is a known forge (`github.com`, `gitlab.com`, `bitbucket.org`) | 1b | +0.6 |
| Frontmost is a dedicated review app | 0 | +1.8 |

**Honest limits:**

- **Host alone is never enough.** `github.com` is equally an issue tracker, a docs site, and a place
  to read someone's README. Host contributes +0.6, never enough on its own to clear the bar.
- **Without Tier 1 (no window title), CODE_REVIEW is undetectable.** Tier 0 sees "Chrome is
  frontmost". The app emits `BROWSING @ ≤0.55`. It does not guess.
- Reviewing in an IDE (JetBrains' review tool, VS Code's PR extension) produces no distinguishing
  title in the general case → `CODING`, degraded.

### 7.5 TERMINAL_WORK

| Evidence | Tier | log-odds |
|---|---|---|
| Frontmost is a claimed terminal | 0 | +2.0 |
| Idle < 60 s | 0 | +0.6 |
| `ssh` / `mosh` / `kubectl` child | 2 | +0.9 |

`TERMINAL_WORK` is the **default** for a frontmost terminal and yields to a more specific class only
when Tier 2 identifies the tool: an editor child → `CODING`, a test runner → `TESTING`, a debugger →
`DEBUGGING`, an AI CLI → `AI_CODING`. With Tier 0 only, a terminal is honestly just a terminal:
**0.55**.

### 7.6 AI_CODING

The genuinely reliable case and the genuinely unreliable case differ enormously, and the design
treats them differently.

**Reliable (Tier 2):** an AI CLI (`claude`, `aider`, `codex`, `goose`) running as a child of the
frontmost terminal → **+3.0**, confidence up to 0.93. This is as solid as `debugserver`.

**Unreliable (Tier 0):** a desktop AI assistant app is frontmost. This tells us nothing about
*whether it is about code*. The user could be asking about a recipe.

Rule for the desktop-app case — `AI_CODING` requires **corroboration**:

- AI app frontmost: **+1.0**
- AND an editor/IDE/terminal was frontmost within the last **5 minutes** (from `recentApps`): **+1.2**
- Without that corroboration, the class is `UNKNOWN` at ≤ 0.35, **not** `AI_CODING`.

Ceiling with Tier 0 only: **0.55**, with the UI wording "AI assistant" rather than "AI coding" —
the label itself degrades, not just the number.

**Explicitly not detectable:** in-editor AI usage (Copilot, Cursor's inline chat, an AI side panel).
It produces no observable signal at any tier we are willing to use. The app classifies it as
`CODING` and says nothing about AI. We do not infer it from typing cadence.

### 7.7 DOCUMENTATION

| Evidence | Tier | log-odds |
|---|---|---|
| Editor title's file extension ∈ {`md`, `mdx`, `rst`, `adoc`, `txt`, `org`} | 1 | +2.4 |
| Frontmost is a notes app (Obsidian, Notion) | 0 | +1.5 |
| Project name contains `docs`/`documentation`/`wiki` | 1 | +0.7 |

Tier 0 only: a notes app gives `DOCUMENTATION @ ≤0.55`; an editor gives `CODING` (we cannot see the
extension). Honest note: Notion is also a project-management tool, so the notes-app signal is
weaker than it looks; it is capped at 0.55 even with Tier 1 unless a title confirms a document.

### 7.8 BROWSING

The browser fallback. Frontmost browser: **+1.8**. It is what the app reports whenever
`CODE_REVIEW`, `DOCUMENTATION`, or `MEETING` cannot be established, and that is a feature.

Known-forge / docs hosts nudge toward a sub-class only at Tier 1b, and never past 0.85.

### 7.9 COMMUNICATION

Frontmost Slack/Discord/Zoom/Mail/Messages: **+2.0**. Reliable at Tier 0 because the *app* is the
signal and we need nothing inside it. Tier 0 only: 0.55; with a title confirming a channel/DM view:
0.80.

We do **not** try to distinguish "reading Slack" from "writing in Slack". No permission-free signal
separates them, and idle time is too coarse (reading is idle).

### 7.10 MEETING — modelled as a concurrent state

`MEETING` is a member of `Activity` for reporting, but internally it lives on `ConcurrentStates`
because **a meeting overlaps other activity**. Forcing a choice between "in a meeting" and "coding"
produces wrong answers for anyone who codes during a standup.

| Evidence | Tier | log-odds |
|---|---|---|
| Audio input `.running` | 0 | +1.8 |
| A conferencing app is **running** (need not be frontmost) | 0 | +1.0 |
| A conferencing app is frontmost | 0 | +0.8 (additive) |
| Zoom window title == `"Zoom Meeting"` (vs `"Zoom"` when idle) | 1 | +1.6 |
| Browser title contains `Meet - `, `| Microsoft Teams`, `Zoom Meeting` | 1 | +1.6 |
| Camera in use (§2.3a, shipped) | 0 | not wired into this ledger |

The camera bit is a **hard block** (docs/BREAK-DECISION.md §7.1), not a term in this inference. It
is deliberately kept out of the ledger for now: a fact that already prevents an interruption on its
own does not also need to move a confidence number, and adding it would mean re-calibrating the
bands above against a signal nobody has watched for a week yet.

One thing this ledger cannot fix, and which §7.8 of the break-decision spec works around instead:
`meetingConfidence` is clamped to the Tier 0 ceiling of **0.55**, and the specific-claim threshold is
**0.60**. So `ConcurrentStates.inMeeting` is structurally false for a user who has granted nothing,
whatever the evidence, and every consumer of it is unreachable in the zero-permission configuration
CLAUDE.md §4.2 promises. The ceiling is right and is not being raised to let a guess through; the
call latch gets its deferral from a capture fact instead.
| Audio input `.unreliable` | 0 | **contributes nothing** |

Bands: mic + conferencing app running → **0.75**. Plus a title match → **0.88**. Never above 0.90 —
a waiting room, a lingering device hold, and a dictation session all look identical to the best
signal we have.

If `audioInput == .unreliable` and there is no Tier 1 title, **meeting detection is switched off
entirely** and the UI says so. A permanently-on detector is worse than no detector.

### 7.11 IDLE

The only class that reaches high confidence, because it is the only one grounded in OS facts.

| Condition | Class | Confidence |
|---|---|---|
| Screen locked | `IDLE` | **0.99** (OS fact) |
| Displays asleep | `IDLE` | **0.99** (OS fact) |
| Session inactive (fast user switching) | `IDLE` | **0.99** (OS fact) |
| `idleSeconds > 300` | `IDLE` | 0.90 |
| `120 < idleSeconds <= 300` | *previous activity*, decayed | multiply by 0.6 |

The 120–300 s band is deliberately **not** `IDLE`. Reading code, reading a PR, and thinking are all
input-idle and are all work. Calling that "idle" is the single most common way time trackers lie to
their users. The app keeps the prior activity and lowers confidence instead, and exposes the
distinction as "away" (locked/asleep, certain) versus "no input" (soft, inferred).

### 7.12 UNKNOWN

A first-class, frequently-correct answer. Emitted when the frontmost app is not in the catalog and no
other signal discriminates, or when evidence is empty. Confidence ≤ 0.2.

`UNKNOWN` must be displayed plainly — "not sure" — and must be easy for the user to correct. A
correction writes a user-scoped manifest entry (§5.5), which is how the catalog improves without a
release.

### 7.13 Summary of what is honestly not detectable

| Wanted | Verdict | What the app does instead |
|---|---|---|
| Debugging vs coding in an Electron editor, no Tier 2 | **not detectable** | `CODING`, degraded, ceiling 0.60 |
| In-editor AI assistant usage | **not detectable** | `CODING`, no AI claim at all |
| Reading vs writing in any app | **not detectable** | single class; no read/write split shipped |
| Which file/function, without Accessibility | **not detectable** | no file context, and no placeholder text pretending otherwise |
| Code review inside an IDE | **not detectable** | `CODING`, degraded |
| Who is using the microphone | **not detectable** | meeting confidence capped at 0.90 |
| Meeting participants / title / calendar link | **not detectable** from these signals | out of scope for this subsystem |
| Productivity, focus, or "deep work" scores | **refuse** | not attempted; see §12 |

---

## 8. Sampling and polling

### 8.1 Event-driven by default

| Source | Mechanism | Wakeups |
|---|---|---|
| App activate/deactivate/launch/quit | `NSWorkspace.shared.notificationCenter` | only on real switches |
| Focused window / title change | `AXObserver` + `CFRunLoopSource` (Tier 1) | only on real changes |
| Mic start/stop | `AudioObjectAddPropertyListenerBlock` | only on real changes |
| Screen lock / unlock | `DistributedNotificationCenter` | only on real changes |
| Display & system sleep/wake, session switch | `NSWorkspace` notifications | rare |
| Thermal / power state | `ProcessInfo` notifications | rare |
| Branch change | read on demand, memoized on the resolved git dir (Tier 2) | one `open`+`read` of one line, ~50 us, at most once per memo window. A file watch was tried and does not work: see §4.3(a) |

On a machine where the user is heads-down in one editor, this subsystem does **approximately zero
work** — no timer fires, nothing is polled.

### 8.2 What is actually polled, and why

| What | Interval | Gated on | Cost |
|---|---|---|---|
| Idle-threshold crossing | **self-scheduling**, not periodic | always | ~2 wakeups per idle transition |
| Process snapshot (Tier 2) | not polled at all: taken inside the sample the engine was already going to build | the process opt-in on **AND** frontmost is editor/terminal **AND** `idleSeconds < 120` **AND** thermal `.nominal`/`.fair` **AND** not (on battery AND Low Power Mode), then memoized for a few seconds | **0.17 ms** per scan, mean of 200 scans of the real table over 1006 processes, release build. At one scan every five seconds that is 0.003% of one core |
| Window geometry | **on demand only** | on app-activation events | sub-ms |
| AX title reconciliation | 60 s, leeway 30 s | Tier 1 on and not idle | guards against a missed `AXObserver` notification |

**The idle timer deserves explanation**, because polling idle every second is the standard mistake.
We never poll. We read `idleSeconds` once and schedule a **single** timer for exactly the remaining
time until the next threshold:

```swift
/// Fires exactly once, when the user will next cross an idle threshold.
/// If the user touches the keyboard first, an NSWorkspace/AX event cancels
/// and reschedules it. Steady-state cost: ~2 timer fires per idle episode,
/// versus 3,600/hour for naive 1 Hz polling.
func scheduleNextIdleCheck() {
    let idle = systemIdleSeconds()
    let next = idleThresholds.first { $0 > idle } ?? idleThresholds.last!
    let delay = max(1.0, next - idle)
    timer.schedule(deadline: .now() + delay, leeway: .seconds(Int(delay * 0.25)))
}
```

### 8.3 Timer discipline

- All timers are `DispatchSourceTimer` with an explicit **`leeway` of ≥ 25% of the interval** so the
  OS can coalesce our wakeups with other processes'. Timer coalescing is the largest single lever on
  idle power draw for a background app.
- **One** timer source for the whole subsystem. Every periodic task is a tick counter on that source.
  N timers = N independent wakeup trains.
- `Timer`/`RunLoop` is avoided in favour of `DispatchSourceTimer` (better leeway control, and it does
  not require the main run loop to be alive in a particular mode).

### 8.4 Suspension

Everything periodic is **fully suspended** — source cancelled, not merely skipped — on:

- screen locked, displays asleep, system sleeping,
- session inactive (fast user switching),
- `idleSeconds > 300`,
- `thermalState >= .serious`,
- Low Power Mode **and** on battery (Tier 2 process scanning only).

Resumed on the corresponding wake/unlock/activity event. This is worth more than every other
optimisation combined: a laptop lid-closed for 8 hours must cost exactly zero.

### 8.5 Energy budget and how to verify it without Xcode

Targets:

- **< 0.1% average CPU** over an 8-hour session.
- **< 1 wakeup/second** average while active; **0** while suspended.
- **< 30 MB** resident.
- Must not appear in Activity Monitor's "Apps Using Significant Energy".

Without Xcode's Energy gauge, verify with Command Line Tools:

```sh
# Energy impact and wakeups attributed to our process
sudo powermetrics -n 10 -i 1000 --samplers tasks --show-process-energy \
  | grep -i -E '<executable name>|Name'

# Idle-state sanity: confirm zero wakeups while the screen is locked
sudo powermetrics -n 5 -i 5000 --samplers tasks --show-process-energy

# Timer/wakeup attribution over a longer window
sudo /usr/bin/timerfires -p $(pgrep -x '<executable name>') 2>/dev/null || \
  sudo dtrace -n 'profile-97 /pid == $target/ { @[ustack()] = count(); }' \
       -p $(pgrep -x '<executable name>')
```

Ship a `make energy-check` target that runs the first command and **fails CI on regression** against
a recorded baseline. An energy budget that is not measured in CI is a wish.

---

## 9. Concurrency (Swift 6 strict)

```swift
/// Owns all AX interaction. Runs off the main actor on a thread with its own CFRunLoop
/// (required by AXObserver). No AXUIElement ever escapes this actor — only extracted
/// Strings and URLs, which are Sendable.
///
/// Deliberately has NO method that returns the value of a text element. Reading a user's
/// source code is not a capability this type possesses.
actor AccessibilityActor {
    func focusedWindowTitle(pid: pid_t) async -> String?
    func focusedDocumentURL(pid: pid_t) async -> URL?
    func startObserving(pid: pid_t) async
    func stopObserving(pid: pid_t) async
    var events: AsyncStream<AXEvent> { get }
}

/// NSWorkspace notifications arrive on the main thread.
@MainActor final class WorkspaceMonitor {
    var events: AsyncStream<WorkspaceEvent> { get }
}

/// Merges every collector into one ordered signal stream, applies dwell gating
/// and decay, resolves a provider, and publishes observations.
public actor ActivityEngine {
    public init(registry: ProviderRegistry, availability: SignalAvailability)
    public func start() async
    public func stop() async
    public var observations: AsyncStream<ActivityObservation> { get }
    /// Current best guess, for the menu bar to render synchronously.
    public func current() async -> ActivityObservation
}
```

Notes that matter under strict concurrency:

- `AXUIElement`, `AudioObjectID`, `CFDictionary` are **not** `Sendable`. They are confined to their
  owning actor and never appear in an `AsyncStream` element type.
- `AXObserver` callbacks are C function pointers with a `void *` refcon. The bridge uses an
  `Unmanaged`-boxed token plus an `AsyncStream.Continuation` captured in a `@unchecked Sendable`
  box — one carefully-reviewed unsafe boundary, documented and isolated in a single file, rather
  than `@unchecked Sendable` scattered through the codebase.
- Providers are `Sendable` **pure functions**. They do no I/O, so they need no isolation and are
  callable from anywhere. This is why the whole classification layer is unit-testable by building
  a `SignalContext` literal — essential given there is no Xcode UI test harness.

---

## 10. Data, storage, privacy

- **Everything stays on the device.** No network code exists in this subsystem, and nothing it
  produces is ever transmitted. The app's single network request is the update check in
  `docs/PRIVACY.md` §5, which sends nothing and knows nothing about any of this.
- **What is stored:** timestamp, activity class, confidence, evidence IDs and summaries, bundle ID,
  and the optional `ActivityContext` fields the user's tier choices populate.
- **What is never stored, at any tier:** keystrokes, keystroke counts, text-field contents,
  screenshots, full URLs, process argv, clipboard contents, file contents.
- Window titles are stored only as **parsed fields** (`projectName`, `fileName`, `fileExtension`).
  The raw title is used for matching and discarded. Titles routinely contain customer names and
  ticket subjects; retaining them wholesale is not justified by anything the product does with them.
- Browser data is reduced to a **host** and only under the separate Tier 1b opt-in.
- Every observation is **explainable**: the menu bar can show "why?" and list the evidence summaries.
  If the app cannot explain a conclusion in one sentence, it should not be drawing it.
- A visible, always-available **pause** that suspends all collection, and a one-click **delete all
  history**.

---

## 11. Testing without Xcode

- Providers are pure → `swift test` with `SignalContext` fixtures covers all of §7. Target: every
  row in every table in §7 has a test.
- **Invariant tests** for §6.2, property-based over random evidence sets: confidence never exceeds
  the tier ceiling, never reaches 1.0, and never cites an unavailable tier.
- **Golden-title corpus**: a checked-in file of real window titles per editor, with expected parses.
  This is how title-format drift is caught — when a vendor changes their format, a test fails
  instead of a user seeing garbage.
- **Permission-matrix tests**: run the full fixture suite under each of `[tier0]`, `[tier0,tier1]`,
  `[tier0,tier1,tier2]` and assert graceful degradation, not crashes and not silently-stale context.
- Collectors (AX, CoreAudio, sysctl) sit behind protocols with fake implementations; the real ones
  are exercised by a small manual harness, since they cannot be tested in CI without a logged-in
  GUI session and a TCC grant. **Be honest in CI about what is not covered** rather than mocking it
  and claiming green.

---

## 12. Capabilities deliberately declined

Recorded here so that "can't we just…" has a written answer.

1. **Keystroke / WPM / typing-cadence metrics.** Requires Input Monitoring — a keylogger-shaped
   grant. Declined outright. This also removes the most tempting route to distinguishing "writing"
   from "reading", and we accept the resulting ambiguity.
2. **Screen Recording for window titles.** `CGWindowListCopyWindowInfo` would hand us titles for
   every app including ones we do not claim. Declined; Accessibility is narrower and is the right
   grant for this job.
3. **Screenshot OCR / screen content analysis.** Would answer nearly every question in §7.13.
   Declined; the permission is disproportionate to a time tracker.
4. **Reading `kAXValue` of text areas.** Technically available the moment Accessibility is granted,
   and it would give us the actual code being edited. The `AccessibilityActor` has no API for it.
5. **AppleScript browser-tab enumeration.** Declined: second permission, per-app prompts, brittle.
6. **Full URL retention.** Host only, and only behind its own toggle.
7. **Productivity / focus / "deep work" scoring.** The signals do not support a claim about the
   quality of someone's work, and a number that looks objective but is not is actively harmful.
   The app reports what it observed and how sure it is. Nothing more.
8. **Inferring DEBUGGING without Tier 2.** The temptation is strong, the signal is not there, and a
   confidently wrong specific label is worse than an honest vague one.

---

## 13. Open questions to resolve before implementation

1. Verify every ⚠️ UNVERIFIED bundle ID in §5.6 on a machine with those apps installed. Two of the
   verified rows already contradicted expectation, so assume a nontrivial error rate in the rest.
2. Confirm whether `CGEventType(rawValue: ~0)` returns non-nil on the target OS floor (macOS 14) —
   and ship the IOKit fallback regardless.
3. Confirm `CGWindowListCopyWindowInfo` deprecation status on the shipping OS; if it goes, the
   window-geometry signal is dropped and §7 loses only the fullscreen hint. Verify nothing else
   became load-bearing on it in the meantime.
4. Decide the Mac App Store question (§1.2) explicitly. A Tier-0-only sandboxed SKU is architecturally
   supported but caps every activity claim at 0.55, and that needs to be a product decision made in
   the open rather than a surprise.
5. Calibrate the log-odds weights in §7 against a real labelled session before shipping. The numbers
   here are *reasoned priors, not measured ones* — they are the honest starting point, and saying so
   is part of the design.
