# Privacy and Data Architecture

This document describes what the app observes, what it stores, what it cannot do, and how you can
verify all of that yourself from the source tree and from the shipped binary.

It is written for people who will not take any of it on faith. Every claim below is either
(a) verifiable with a command you can run on the built app, (b) verifiable by reading a named file
in this repository, or (c) explicitly marked as a limitation that cannot be proven and must be
trusted or independently monitored. Section 8 collects the limitations in one place so you do not
have to hunt for them.

Placeholders used throughout: `<BUNDLE_ID>` is the app's bundle identifier (example:
`com.example.app`), `<APP>` is the path to the installed bundle (example: `/Applications/App.app`).

---

## 1. Data inventory

The app's job is to know roughly when you started working and whether you are still at the machine,
so it can interrupt you at a sensible moment. Everything below exists to serve that and nothing else.

### 1.1 Legend

- **Persisted** — written to disk, survives a restart.
- **Memory-only** — exists in process memory, dies with the process, never written to disk.
- **Derived** — computed from another row; the input is not kept.

### 1.2 Inventory

| # | Datum | Producing macOS API | Why it is needed | Storage | Retention | Optional? |
|---|-------|---------------------|------------------|---------|-----------|-----------|
| 1 | Frontmost app **bundle identifier** (`com.apple.dt.Xcode`) | `NSWorkspace.didActivateApplicationNotification` → `NSRunningApplication.bundleIdentifier` | Detect that you switched context; classify the activity as coding / meeting / reading / idle-ish so a break is not proposed mid-call | Persisted, `events/YYYY-MM-DD.jsonl` | Default 7 days | Yes — turning it off leaves a pure wall-clock timer |
| 2 | Frontmost app **localized name** (`Xcode`) | same notification → `NSRunningApplication.localizedName` | Shown in the UI ("you've been in Xcode for 52 min"); fallback identifier for apps with no bundle ID | Persisted only when bundle ID is `nil` (rare: some helper processes) | Same as #1 | Same as #1 |
| 3 | Frontmost app **pid** | `NSRunningApplication.processIdentifier` | Needed as the argument to `AXUIElementCreateApplication` when window-title fidelity is on | Memory-only | Until the next app switch | n/a |
| 4 | Frontmost app **icon** | `NSRunningApplication.icon` | Drawn in the menu bar popover | Memory-only | Until the next app switch | n/a |
| 5 | **Activation timestamp** | `Date()` at notification delivery | Compute durations | Persisted, second resolution, UTC | Same as #1 | No (it is the timer) |
| 6 | **Seconds since last input event** (a single `Double`) | `CGEventSourceSecondsSinceLastEventType(.combinedSessionState, kCGAnyInputEventType)` | Distinguish "working for 50 minutes" from "left the room 40 minutes ago" | Not persisted raw. Only the derived transitions `idle_begin` / `idle_end` and the idle duration are persisted | Same as #1 | Yes — off means idle time counts as work time |
| 7 | **Idle/active state** | Derived from #6 against a threshold (default 120 s) | Pause and resume the streak timer | Persisted as events | Same as #1 | Follows #6 |
| 8 | **Screen locked / unlocked** | `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`, polled; plus the `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` distributed notifications as a fast path | Locked time is not work time; also the moment to reset a streak | Persisted as `lock` / `unlock` events | Same as #1 | No |
| 9 | **Display sleep / wake** | `NSWorkspace.screensDidSleepNotification`, `screensDidWakeNotification` | Same as #8 | Persisted as events | Same as #1 | No |
| 10 | **System sleep / wake** | `NSWorkspace.willSleepNotification`, `didWakeNotification` | Do not fire a break reminder into a closed lid; reset the streak across a long sleep | Persisted as events | Same as #1 | No |
| 11 | **Fast user switch** | `NSWorkspace.sessionDidResignActiveNotification` / `sessionDidBecomeActiveNotification` | Another user's session is not your work | Persisted as events | Same as #1 | No |
| 12 | **Focused window title** | `AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute)` then `kAXTitleAttribute` — **requires Accessibility permission** | Only to answer one question: does this window look like a live meeting, a terminal, an editor, a browser, or a document? A meeting is the one thing worth never interrupting | **The string itself is never persisted by default.** It is classified into a five-value enum inside one function and released. Only the enum is persisted | Enum: same as #1. String: memory-only, lifetime of one function call | **Yes, and off by default** |
| 13 | **Title classification result** (`meeting`/`terminal`/`editor`/`browser`/`document`/`none`) | Derived from #12 | see #12 | Persisted | Same as #1 | Follows #12 |
| 14 | **Raw title debug ring** (last 20 titles) | Derived from #12 | Lets you see exactly what the app is reading, so you can audit the permission you granted | Memory-only, capacity 20, cleared on quit | Process lifetime | Yes — **off by default**, and the UI switch is labelled as such |
| 15 | **Break engine state**: streak start, last break end, snooze count, next fire time | Derived from #1/#5/#7 | The actual product | Memory-only; nothing writes it to disk. The day's budgets that have to survive a relaunch are in `counters.json` (§4.2) | Gone when the process exits | No |
| 16 | **Break interaction events**: prompted, taken, skipped, snoozed | UI callbacks | "You skipped 6 of 8 breaks today" and nothing more | Persisted as events | Same as #1 | Yes |
| 17 | **Daily aggregates**: minutes per category, breaks taken/skipped, longest streak | Derived from the event log nightly | Weekly view without keeping raw events | Persisted, `summaries/YYYY-MM.json` | Default 90 days | Yes |
| 18 | **Preferences**: interval, threshold, quiet hours, tone, prompt channel and sound | User input | Configuration | Persisted, `settings.json` (plain JSON, human-editable) | Until you change or delete them | n/a |
| 19 | **App category map** (`com.apple.dt.Xcode → code`) | Static JSON shipped inside the bundle, plus your own overrides | Classify #1 without heuristics | Read-only in `App.app/Contents/Resources/categories.json`; overrides in `settings.json` | Ships with the app | n/a |
| 20 | **Break message packs** | Static JSON shipped inside the bundle | Text of the reminder | Read-only resource | Ships with the app | Yes, choose or disable |
| 21 | **Unlocked badges**: which of the ten marks have unlocked, and the day each did | Derived from #17 and #16, entirely — no new signal, no new event field, nothing observed that was not already in this table | So a badge earned inside the 7-day event window is not silently lost when those events are pruned | Persisted, `badges.json` (a flat map of badge id to day) | Kept until you delete your data; never expires and never decreases | n/a |
| 22 | **Login-item registration** | `SMAppService.mainApp.register()` | Start at login, if you ask for it | A registration record owned by `launchservicesd`, outside the app's storage | Until unregistered | Yes — off by default |
| 23 | **Notification authorization status** | `UNUserNotificationCenter.notificationSettings()` | Decide whether to use a system notification or the in-app fallback window | Memory-only (the real record is TCC's) | n/a | n/a |
| 24 | **Unified log lines** | `os.Logger` | Debugging | System log, `/var/db/diagnostics`, rotated by macOS | Controlled by macOS, not by the app | See §8.6 |
| 25 | **Audio input device in use** (one `Bool` per device, OR'd) | `kAudioDevicePropertyDeviceIsRunningSomewhere` on each device with input channels. **No Microphone permission; none is requested** | Do not interrupt a live call. This is the signal a hard block rests on | Not persisted. Only the derived verdict reaches the log, as a `reason` string | n/a | No — it is what stops a prompt landing in a meeting |
| 26 | **Camera device in use** (one `Bool` per device, OR'd) and the **device names** | `kCMIODevicePropertyDeviceIsRunningSomewhere` over `kCMIOHardwarePropertyDevices`. **No Camera permission; none is requested, and a probe generated no `tccd` activity** | Same, for the camera-on / microphone-muted posture, which is the normal one on Teams and Meet | Not persisted. Device names are printed by `--doctor` on request and held in memory only | Process lifetime | No |
| 27 | **Bundle identifiers of processes running audio input** | `kAudioHardwarePropertyProcessObjectList`, then `kAudioProcessPropertyBundleID` and `kAudioProcessPropertyIsRunningInput` per process object. **No permission; none is requested** | Say *which* app has the microphone, so the call hold names a fact rather than guessing, and so Siri, dictation and a permanently-open virtual device can be discounted instead of disabling the signal | Not persisted. Each identifier is matched against a fixed list and dropped. Nothing else about the process is read **on this path**: this row is CoreAudio's process object list and it yields a bundle identifier, nothing more. The one place the app reads an executable path is row 30, which is Tier 2, off by default, and bounded there | Memory-only, one sample | No |
| 28 | **Seconds the call hold has held a break today**, and the day they count for | Derived from #25, #26 and #27 by the call latch | So the three-hour daily ceiling on holding survives a relaunch instead of resetting to zero | Persisted, `call-hold.json` (a day index and a number of seconds) | Overwritten in place; reset on delete | Follows "Hold my break during calls" |
| 29 | **The focused window's document path** (`/Users/you/p/a.swift`) | `kAXDocument` on the focused window, read in the same call that reads the title. Tier 1 | Names the file you have open when the title does not, and tells the git collector which registered folder you are in | Memory-only, one sample. Anything that is not a local file URL is discarded before it is parsed, which is what keeps a browser's full page URL out (`AccessibilityCollector.fileURL(from:)`) | Until the next sample | Follows Tier 1 |
| 30 | **Which of a fixed list of developer tools is running**, as an enum case, never a string, plus one `Bool` for whether anything is under a debugger | One `sysctl(KERN_PROC_ALL)`, then `proc_pidpath` for the pids whose `p_comm` already matched the `ToolToken` allowlist in `app/Sources/SigstopSensors/SignalContext.swift`. **No permission is required and none is requested** | The only signal in this product that can tell `DEBUGGING` from `CODING`. Without it the app degrades to `CODING` rather than guess between siblings (`CLAUDE.md` §4.1) | **Not persisted, and nothing but the match survives.** The path is compared and dropped. A process matching nothing is not recorded, not counted, not reported. No command line, environment or working directory is read at all | Memory-only, one sample | **Yes, and off by default** |
| 31 | **Current git branch name** (`fix/retry-loop`), and whether a rebase, merge or bisect is in progress | One read of the first 512 bytes of `<repo>/.git/HEAD`, in a folder **you registered yourself** through an `NSOpenPanel`, plus four `access` checks. No `git` process is ever spawned | Fills the `{branch}` slot so a line can say something true instead of something generic | **Memory-only.** Held for the lifetime of one `DeveloperContext` and replaced by the next sample. There is **no field in `LoggedEvent` that could hold it** (§4.3), and `--doctor` prints its length rather than the name (§8.12) | Until the next sample, or process exit | **Yes, and off by default** |

Rows 25 to 27 are **property reads on device and process objects**. No stream is opened, no capture
session is created, no frame or sample is ever available to this process, and the capability to do
so is absent rather than merely unused. The difference matters and is the reason these rows sit in
the inventory rather than under §3.3: reading "is some process using the camera" is a different
operation from using the camera, in the same way that `ps` is a different operation from debugging.
macOS agrees, which is why neither read produces a prompt.

Rows 30 and 31 touch the process table and the filesystem, which nothing else here does, so the
boundaries belong next to the rows rather than three sections away.

**Row 30 reads an executable path and nothing else.** Not the command line, not the environment, not
the working directory, not memory. A command line is the one place on a developer's machine where a
password is routinely written in plain text, `psql "postgres://user:hunter2@host/db"` being the
canonical example, which is exactly why `KERN_PROCARGS2` is not called. §2.10 gives the mechanism
and the commands that check it.

**Row 31 reads one line of one file.** Not a diff, not a commit message, not `.git/config`, not an
object, not the index, and never a file in your working tree. The repository state is four `access`
calls, on `.git/rebase-merge`, `.git/rebase-apply`, `.git/MERGE_HEAD` and `.git/BISECT_LOG`, each of
which returns a `Bool` and opens nothing: the app learns a rebase is in progress, never what is
being rebased. The folder is one you picked in an `NSOpenPanel`. The app never guesses a path from a
window title or a project name, because guessing a path from a name is the kind of invention
`CLAUDE.md` §4.1 forbids.

What a window title and a `kAXDocument` path **do** decide is *which* of the folders you added is
the one in front, and only that. Two of your folders answering means the app does not know which
project you are looking at, so it reports no branch rather than pick one, and `--doctor` says which
route answered and which abstained so a blank never looks like a bug.

That is the complete list. There is no row for account, device identifier, hardware serial, locale
beacon, install ID, or first-run ping, because none of those exist in the code.

There is one row's worth of network activity, and it is not in the table above because nothing about
it is *collected*: when you press **Check for updates**, the app fetches one static XML file over
HTTPS. It sends no identifier and stores nothing about the request. What it necessarily reveals is
your IP address and the time, to whoever serves that file. §5 is the whole account of it, including
the parts that cannot be proven from this side.

### 1.3 What a "focus" sample looks like end to end

```swift
// app/Sources/Observation/FrontmostAppObserver.swift
import AppKit

/// Emits an event whenever the frontmost application changes.
/// Requires NO TCC permission of any kind. This is the app's primary signal.
final class FrontmostAppObserver {

    struct Focus {
        let bundleID: String?       // persisted
        let localizedName: String?  // persisted only when bundleID == nil
        let pid: pid_t              // memory-only, never persisted
        let at: Date
    }

    private var tokens: [NSObjectProtocol] = []
    private let onChange: (Focus) -> Void

    init(onChange: @escaping (Focus) -> Void) { self.onChange = onChange }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self?.onChange(Focus(bundleID: app.bundleIdentifier,
                                 localizedName: app.localizedName,
                                 pid: app.processIdentifier,
                                 at: Date()))
        }
        tokens.append(token)

        if let app = NSWorkspace.shared.frontmostApplication {
            onChange(Focus(bundleID: app.bundleIdentifier,
                           localizedName: app.localizedName,
                           pid: app.processIdentifier,
                           at: Date()))
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach(center.removeObserver)
        tokens.removeAll()
    }
}
```

Note what this API gives and does not give. `NSRunningApplication` exposes an identifier and a
display name. It does not expose window contents, document paths, or arguments. There is no
permission prompt because macOS does not consider the identity of the frontmost app to be private —
every app on your system can already see it.

### 1.4 Idle detection carries no input content

```swift
// app/Sources/Observation/IdleMonitor.swift
import CoreGraphics

enum IdleMonitor {
    /// Seconds since the last HID input event anywhere in the session.
    ///
    /// This is a scalar. It contains no key codes, no characters, no modifier
    /// state, no mouse coordinates, and no indication of which app received the
    /// input. It is NOT an event tap: the app never calls CGEventTapCreate, and
    /// therefore never appears in Input Monitoring and never sees an event.
    static func secondsSinceLastInput() -> TimeInterval {
        let anyInput = CGEventType(rawValue: ~0)!   // kCGAnyInputEventType
        return CGEventSourceSecondsSinceLastEventType(.combinedSessionState, anyInput)
    }
}
```

The distinction between `CGEventSourceSecondsSinceLastEventType` and `CGEventTapCreate` is the whole
argument. The first is a counter read. The second is a keylogger primitive, needs Input Monitoring
or Accessibility, and is never called — see the CI guard in §6.4.

### 1.5 The window-title redaction boundary

This is the most sensitive path in the app, so it is the most tightly bounded. Titles enter exactly
one function and a small enum comes out.

```swift
// app/Sources/Observation/WindowTitleReader.swift
import ApplicationServices

/// The ONLY file in this repository permitted to reference AXUIElement.
/// scripts/verify-ax-isolation.sh fails the build if `AXUIElement` appears
/// in any other source file.
enum WindowTitleReader {

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt. Called only from the settings toggle, never at launch.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Title of the focused window of `pid`, or nil.
    /// Callers MUST classify and discard; they must not store the return value.
    static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let app = AXUIElementCreateApplication(pid)
        // Never block the main thread on a wedged application.
        AXUIElementSetMessagingTimeout(app, 0.25)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let raw = windowRef,
              CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        let window = raw as! AXUIElement

        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String, !title.isEmpty
        else { return nil }

        return title
    }
}
```

```swift
// app/Sources/Observation/TitleClassifier.swift

/// The only thing that survives a window title.
enum TitleSignal: String, Codable {
    case meeting, terminal, editor, browser, document, none
}

enum TitleClassifier {
    /// Substring rules, all lowercase, all shipped in the binary and readable here.
    private static let rules: [(TitleSignal, [String])] = [
        (.meeting,  ["zoom meeting", "google meet", "meet -", "webex", "teams meeting", "huddle"]),
        (.terminal, ["— zsh", "— bash", "— fish", "ssh "]),
        (.editor,   [".swift", ".ts", ".tsx", ".py", ".rs", ".go", ".java", ".kt"]),
        (.browser,  ["— google chrome", "— safari", "— firefox", "— arc"]),
        (.document, [".pdf", ".docx", "— pages", "— notes"]),
    ]

    static func classify(_ title: String) -> TitleSignal {
        let lower = title.lowercased()
        for (signal, needles) in rules where needles.contains(where: { lower.contains($0) }) {
            return signal
        }
        return .none
    }
}
```

```swift
// app/Sources/Observation/ActivitySampler.swift  (the call site)

func titleSignal(for pid: pid_t) -> TitleSignal {
    guard settings.windowTitleFidelityEnabled else { return .none }
    // `title` is local. It is not returned, not logged, not encoded,
    // and not captured by any escaping closure.
    guard let title = WindowTitleReader.focusedWindowTitle(pid: pid) else { return .none }
    if settings.showRawTitlesInDebugPanel {          // default false
        debugRing.append(title)                      // memory-only, capacity 20
    }
    return TitleClassifier.classify(title)
}
```

Read `TitleClassifier` and you know the total vocabulary the app extracts from a window title:
six values, five bits of information per sample. A file path in a title, a pull-request name, a
customer's name in a document title — none of it leaves that function. §8.3 states the limitation
honestly: the string does exist in process memory for the duration of the call, and the code, not
the operating system, is what stops it from going further.

---

## 2. What the app does not do, as enforceable properties

"We promise not to" is worth nothing. Each item below names the mechanism that makes the behavior
absent, and the command that shows you it is absent. `<APP>` is the installed bundle;
`<BIN>` is `<APP>/Contents/MacOS/<executable>`.

### 2.1 No source code, file contents, or document text

**Mechanism.** The app never opens a file it did not create, except its own read-only bundle
resources. It requests no Full Disk Access. In the sandboxed flavor (§3.6) the App Sandbox confines
file access to the app's own container; there is no `com.apple.security.files.user-selected.read-only`
entitlement except in the export path, which is a *write* panel. The only file-reading code in the
tree is `Storage/EventStore.swift` and `Storage/SettingsStore.swift`, both scoped to the storage
directory.

**Check.** `scripts/verify-entitlements.sh <APP>` asserts the absence of every file-access
entitlement. At runtime: `sudo fs_usage -w -f filesys $(pgrep -f '<BUNDLE_ID>')` and watch that the
only paths touched are the app bundle and the storage directory.

### 2.2 No keystrokes

**Mechanism.** The app never calls `CGEventTapCreate`, `CGEventTapCreateForPSN`, or
`NSEvent.addGlobalMonitorForEvents`. Those are the only three ways to observe keystrokes from
another process. A CI guard (§6.4) fails the build if any of those symbols appear in the source or
in the binary's symbol table. The app does not appear in
System Settings → Privacy & Security → Input Monitoring, because it never asks.

**Check.**
```
nm -u <BIN> | grep -E 'CGEventTap|addGlobalMonitor'     # expect no output
```
Note the honest caveat: Accessibility permission, if you grant it, *would* allow a global monitor.
The defense there is the CI symbol check plus the AX isolation check, not the OS. See §8.2.

### 2.3 No clipboard access

**Mechanism.** `NSPasteboard` is never referenced. Not to read, not to write. The "copy diagnostics"
feature deliberately writes a file through `NSSavePanel` instead of putting anything on the
pasteboard, precisely so that this property stays absolute rather than conditional.

**Check.**
```
nm <BIN> | grep 'OBJC_CLASS_\$_NSPasteboard'            # expect no output
grep -rn 'NSPasteboard' app/Sources                      # expect no output
```

### 2.4 No passwords or credentials

**Mechanism.** The app has no accounts, no login, no sync, and no Keychain usage. `Security.framework`
is not linked; `SecItemAdd`/`SecItemCopyMatching` never appear. There is nothing to authenticate to,
because there is no server (§5).

**Check.** `otool -L <BIN> | grep Security` — expect no output.

### 2.5 No message, email, or chat content

**Mechanism.** Reading another app's message content would require either the Accessibility tree
below the window level (the app reads exactly two attributes, `kAXFocusedWindow` and `kAXTitle`, and
the AX isolation guard proves no other attribute constant appears in the tree) or AppleEvents
scripting of Mail/Messages. `NSAppleScript`, `OSAScript`, `AEDeterminePermissionToAutomateTarget`
are never referenced and `NSAppleEventsUsageDescription` is absent from `Info.plist`, so macOS would
show no Automation prompt and would deny any attempt.

**Check.**
```
plutil -p <APP>/Contents/Info.plist | grep -i AppleEvents    # expect no output
grep -rn 'kAX' app/Sources | sort -u                          # expect only kAXFocusedWindow / kAXTitle / kAXTrustedCheckOptionPrompt
```

### 2.6 No screenshots or screen contents

**Mechanism.** Screen capture on modern macOS requires the Screen Recording TCC grant, which is
triggered by `CGWindowListCreateImage`, `SCStream`/ScreenCaptureKit, or `CGDisplayStream`. None are
called and ScreenCaptureKit is not linked. Critically, the app also avoids
`CGWindowListCopyWindowInfo` with `kCGWindowName`, which is the *other* common way to get window
titles — it would require Screen Recording, so the app uses Accessibility instead and asks for the
narrower thing. The app will never appear in Screen Recording's permission list.

**Check.**
```
otool -L <BIN> | grep -Ei 'ScreenCaptureKit|CoreMedia'   # expect no output
nm -u <BIN> | grep -E 'CGWindowList|CGDisplayStream'      # expect no output
```

### 2.7 No network transmission of your data, and exactly one network request

This section used to be titled "No network transmission of any kind" and it is not called that any
more. The app now contains an in-app updater (Sparkle), so the old sentence became false the moment
that shipped, and an untrue privacy claim is worse than no claim. Here is the replacement, layered
the same way.

**What is transmitted about you: nothing.** No event, no summary, no bundle ID, no window title, no
duration, no setting, no identifier of any kind ever leaves the machine. The updater sends a `GET`
with no query string and no body. There is no endpoint that accepts data from this app, because the
only endpoint is a static file.

**What requests exist: one.** An HTTPS `GET` of the appcast at `SUFeedURL`, which is a static XML
file on GitHub Pages, identical for everyone. It is made when you press **Check for updates**, and
on a daily schedule only if you ticked the box in Settings → About, which is off by default. If an
update is offered, pressing the second button fetches the archive itself.

**What the app's own binary can do: still nothing.** This is the part that survived intact and is
worth checking yourself. `sigstop`'s executable links no networking framework and references no
networking symbol — not `NSURLSession`, not `socket`, not `getaddrinfo`. All the network code is
inside `Sparkle.framework`, and the download runs in Sparkle's own out-of-process XPC service, so
the process holding your Accessibility grant is not the process doing the transfer.

**What is enforced by the OS: nothing, and that was already true.** The app cannot be sandboxed
(§3.6), so the absence of `com.apple.security.network.client` never guaranteed anything on its own —
an unsandboxed process may open sockets freely. What is real is the symbol-level absence above, the
signature gate below, and your own runtime monitor. §8.1 states this without softening it.

**What cannot be claimed.** An HTTPS request reveals your IP address and a timestamp to whoever
serves the file, which today is GitHub. Nothing the client does changes that. If that matters to
you, never press the button, leave the daily check off, and install from Homebrew instead — the app
makes no request at all unless you ask it to.

**What replaces the old guarantee: signature verification.** See §2.8.

**Check.**
```
BIN=<APP>/Contents/MacOS/sigstop

# the app's own binary references no networking at all
nm -u "$BIN" | grep -E '^_(socket|connect|getaddrinfo|res_9_init)$'            # expect none
nm -u "$BIN" | grep -E 'NSURLSession|NSURLConnection|NWConnection|CFHost'      # expect none
otool -L "$BIN" | grep -Ei 'CFNetwork|Network\.framework'                      # expect none

# the only networking in the bundle, named and versioned
ls <APP>/Contents/Frameworks                                                   # expect: Sparkle.framework

# the only endpoint
plutil -p <APP>/Contents/Info.plist | grep -E 'SUFeedURL|SUEnableAutomaticChecks|SUEnableSystemProfiling'

# no server entitlement: nothing listens
codesign -d --entitlements - --xml <APP> | plutil -p - | grep network.server   # expect none

# while it is running and you have not pressed anything
sudo lsof -i -a -p "$(pgrep -f '<BUNDLE_ID>')"                                 # expect no sockets
```
`make verify` runs the whole set against a built bundle and prints a line per assertion. See §6.3
for the Little Snitch / `nettop` procedure, and §8.1 for what `otool -L` can and cannot prove.

### 2.8 Updates cannot install unless the maintainer signed them

This is the property that made an in-app updater defensible at all, and it is stronger than what
Apple's code signing would give this project.

The app is distributed outside the App Store and is **ad-hoc signed: there is no Developer ID and no
Team ID.** Gatekeeper therefore has no identity to check an update against. An updater that
downloads and runs code, with nothing but TLS between it and the user, would be trusting whoever
controls the server — and "whoever controls the server" includes anyone who compromises a GitHub
account or a CDN edge.

Sparkle closes that with EdDSA (Ed25519):

- The **private key** exists in exactly one place: the maintainer's macOS login keychain, as a
  generic password under service `https://sparkle-project.org`, account `sigstop`. It is not in this
  repository, not in CI, and not on any build server. `make verify` greps the whole tree for a
  private key and fails if one appears.
- The **public key** is compiled into the app as `SUPublicEDKey` in `Info.plist`. You can read it
  with `plutil -p`.
- Every release archive is signed with `sign_update` and the signature is written into the appcast.
  Sparkle verifies it **before** the archive is unpacked or installed. A signature that does not
  verify is not a warning; the update simply does not happen.

The consequence, stated as plainly as it deserves: **an attacker who fully owns the update server
can stop you getting updates, and cannot make this app run their code.** That is a different and
much better position than TLS alone.

The honest limit: this protects the *channel*, not the *maintainer*. If the private key is stolen,
signed malicious updates become possible, and the only remedy is key rotation — which does not reach
anyone already running an old build, because they verify against the key inside the copy they have.
`docs/RELEASING.md` §6 says what that would actually involve. §8 lists it as a limitation rather
than pretending it away.

### 2.9 No covert exfiltration channels

A process with no sockets can still leak, and now that one framework in the bundle *does* have
sockets, the channels below matter more rather than less. Each is absent, with the guard named:

| Channel | Why it matters | Guard |
|---|---|---|
| The updater's own request | A `GET` can carry data in a query string, a header, or a hostname | The feed URL is a compile-time constant in `Info.plist` with no query string; `SUEnableSystemProfiling` is `false` so Sparkle appends no parameters; `sendsSystemProfile` is set `false` in code as well; the user agent is overridden to the literal `"sigstop"` and does not even carry the app version. `make verify` asserts the plist keys |
| A second endpoint | One allowed URL is checkable; two is a policy | `make verify` extracts every URL string from the binary and fails on anything that is not an allowlisted `github.com/Mohamed-Elshesheny/sigstop` browser link. The feed URL is not even in the binary — it is a plist key |
| `NSWorkspace.open(URL)` | Opening `https://collector/?data=…` in the browser exfiltrates without a socket in this process | Allowlisted: the only call sites pass a compile-time constant from the `Links` enum in `SettingsView.swift`, and the URL check above covers them |
| `Process` / `NSTask` / `posix_spawn` | Shelling out to `curl` | Forbidden symbols; not referenced anywhere in app code |
| `NSAppleScript` / `osascript` | Scripting another app into making the request | Forbidden symbols; no Automation usage string |
| `NSXPCConnection` to a helper | A helper could hold the network code | The app ships no helper of its own. It does ship Sparkle's two XPC services inside `Sparkle.framework`, which is the point — the downloader and the installer are deliberately *not* in the app process. `ls <APP>/Contents/Frameworks` shows exactly one framework |
| `dlopen` / plugin loading | Loading code not in the reviewed binary | `com.apple.security.cs.disable-library-validation` is absent and `make verify` fails if it ever appears. **But see the honest caveat below: the shipped build no longer has Hardened Runtime enabled.** |
| Analytics SDK arriving as a transitive dependency | The usual way telemetry actually gets in | Sparkle has no dependencies of its own, and `make verify` greps the whole bundle against a list of ~25 analytics and crash-reporting SDKs by name |
| DNS via `CFHost` | Data in a hostname | Forbidden symbols; checked by `make verify` |

**The Hardened Runtime regression, stated rather than buried.** Before Sparkle, the bundle was
signed with `--options runtime`, which enables Library Validation. That is no longer possible for
ad-hoc builds: Library Validation makes dyld refuse a library whose Team ID differs from the main
executable's, ad-hoc signatures carry no Team ID, and so an ad-hoc-signed app with an embedded
framework passes `codesign --verify --deep --strict` and then dies at launch with *"mapping process
and mapped file (non-platform) have different Team IDs."*

The two ways out were a real Developer ID certificate, or turning Library Validation off with
`com.apple.security.cs.disable-library-validation`. The second was refused, because the absence of
that entitlement is the guard in the `dlopen` row above and trading it away to keep a checkbox would
be exactly backwards. So `make bundle` signs without Hardened Runtime by default, and
`HARDENED=1 make bundle` turns it back on for anyone who has a Developer ID. The comment in
`app/Scripts/bundle.sh` explains this at the point where somebody would otherwise "fix" it.

What this costs: a local attacker who can already write to the app bundle could inject a library.
That attacker could also simply replace the binary, so the practical loss is smaller than it sounds
— but it is a real reduction from the previous position and it is listed in §8.

---

### 2.10 No repository contents, and no command lines

Two Tier 2 collectors read things nothing else in the app reads: one file inside `.git/`, and the
process table. Both are off by default, each behind its own switch. Both are bounded by what the
code is *capable* of, not by what it chooses, which is the only kind of bound worth writing down.

**Mechanism, git.** The collector opens `<folder>/.git/HEAD`, reads **at most 512 bytes**, which is
one line, and matches `ref: refs/heads/<name>`. Forty hex characters is a detached HEAD and is
reported as one rather than presented as a branch name. One indirection is followed and only one: in
a git worktree or a submodule `.git` is a *file* holding a `gitdir:` line, so that line is read and
`HEAD` is taken from the directory it names, absolute for a worktree and resolved against the
containing folder for a submodule. Mid-rebase, `HEAD` is a detached sha and the branch you are on is
in `rebase-merge/head-name`, which is read for the same reason and nothing else in that directory is.
Every other filesystem call is one of the four `access` checks above, which return a `Bool` and open
nothing. `git` is never spawned: `Process`, `NSTask` and `posix_spawn` remain forbidden symbols
(§2.9), so shelling out is not something this binary can do, whatever a future contributor intends.

**Mechanism, processes.** One `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_ALL)` returns the table.
`p_comm` is compared against the allowlist, `proc_pidpath` confirms the executable's location for
the few that matched, and the path is dropped. `KERN_PROCARGS2` is not called, so no command line,
no argument and no environment variable is ever in this process's memory. `proc_pidinfo` is not
called either, so no process's working directory is read. What survives one scan is a set of enum
cases and two booleans.

**Check.**

```sh
# argv, environment and working directories are never read
grep -rn 'KERN_PROCARGS2\|proc_pidinfo\|PROC_PIDVNODEPATHINFO' app/Sources   # expect no output
# git is never shelled out to
grep -rn 'Process(\|NSTask\|posix_spawn' app/Sources                          # expect no output
# every path fragment the git collector can build, in one grep. Eight lines: six are the
# only names it ever appends, and two are a bare "/" used as a separator
grep -n '\"/' app/Sources/SigstopSensors/Collectors/GitCollector.swift
#   names:  /.git  /HEAD  /rebase-merge  /rebase-apply  /MERGE_HEAD  /BISECT_LOG
# and the bound on how much of HEAD is read, which is 512 bytes
grep -n 'headReadLimit' app/Sources/SigstopSensors/Collectors/GitCollector.swift
```

At runtime: `sudo fs_usage -w -f filesys $(pgrep -x sigstop)` and watch that the only paths outside
the bundle and the storage directory are `HEAD` files in folders you registered.

---

## 3. Permissions

### 3.1 Design principle

**The app must be fully functional, at reduced fidelity, with zero permissions granted.** This is a
hard requirement on the architecture, not an aspiration. Nothing in the break engine may depend on a
permission being present; every permission-gated signal enters through an optional and has a defined
`nil` behavior.

There is a test for it: `AppTests/ZeroPermissionModeTests.swift` runs the whole break engine with
every permission provider stubbed to "denied" and asserts reminders still fire correctly.

### 3.2 What is requested, and when

| Permission | TCC service | When asked | What it buys | If denied |
|---|---|---|---|---|
| **Notifications** | `UNUserNotificationCenter` | At the first break, not at launch | Reminders appear as system notifications, respect Focus modes and Notification Center | Fallback: a borderless `NSWindow` at `.statusBar` level that the app draws itself. Needs no permission. Slightly more intrusive, does not respect Do Not Disturb — so the app's own quiet hours setting becomes the only mute |
| **Accessibility** | `kTCCServiceAccessibility` | Never automatically. Only when you flip "Detect meetings and terminals from window titles" in settings, with the explanation text shown first | Window-title fidelity (inventory rows 12–14): the app can avoid interrupting a live meeting and can tell a terminal from a browser inside the same app | Everything still works from app identity alone. The app may propose a break during a Zoom call, because it can see you are in Zoom but not that a meeting is in progress |
| **Login item** | `SMAppService` (not TCC) | Only from the settings toggle | Starts at login | Start it yourself |
| **Git context (Tier 2)** | None. Not a TCC service. What you grant is a folder | Never automatically. Only when you add a project folder in Settings → Signals | The branch name, and whether a rebase, merge or bisect is in progress, for the folders you added | Nothing degrades. `branch` is `nil`, the templates that need `{branch}` become unselectable by construction (`docs/MESSAGE-ENGINE.md` §5), every other line still fires |
| **Process context (Tier 2)** | None. `sysctl(KERN_PROC_ALL)` needs no grant and produces no prompt | Never automatically. Only from its own switch in Settings → Signals | `DEBUGGING` becomes reachable instead of collapsing into `CODING` | `CODING`, and the UI says it cannot tell whether you are debugging |

Neither Tier 2 row is in §3.3's list of permissions never requested, because neither is a
permission. Both are things macOS lets any process do without asking. They are behind switches for
privacy reasons, not permission reasons, and that distinction is the whole design of Tier 2.

### 3.3 What is never requested

Screen Recording. Input Monitoring. Full Disk Access. Automation / Apple Events. Calendar. Contacts.
Reminders. Photos. Microphone. Camera. Location. Local Network. Files and Folders (Desktop,
Documents, Downloads). Developer Tools.

The corresponding `Info.plist` usage-description keys are absent, which means macOS would terminate
the app with `TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION` if any code path ever attempted them. That is
a useful property: the absence of a usage string turns an attempted privacy violation into an
immediate, loud crash rather than a silent prompt.

**Microphone and Camera are on this list, and inventory rows 25 to 27 are not a contradiction.** The
app reads whether a device is *running* and which process is running input. It never opens a stream
or a capture session, so no audio and no frame is ever available to it, and those usage-description
keys stay absent: if a future change ever did try to capture, the app would crash rather than ask.
The absence of a prompt is not the app being sneaky, it is macOS agreeing that a property read is
not a capture. Anyone can check with
`log show --last 5m --predicate 'process == "tccd"'` after running `make doctor`.

**Screen sharing cannot be detected at all, and the app says so rather than reporting `false`.**
`CGDisplayIsCaptured` has been deprecated since macOS 10.9 and no longer compiles; CoreMediaIO
enumerates no display-capture device; ScreenCaptureKit needs the Screen Recording grant on this
list. So `HardBlock.screenBeingShared` never fires, `--doctor` prints that consequence in those
words, and the only real mitigation is the manual "I'm in a meeting" hold in the menu.

A note on Calendar: reading EventKit would be the most accurate way to know you are in a meeting.
It was considered and rejected. It would mean access to every event title, attendee, and location on
your calendar to answer a yes/no question that a window title answers at a fraction of the exposure.

**Files and Folders stays on this list, and the git collector is not an exception to it.** The app
never asks for that service. A folder you choose in an open panel is a grant you hand over for that
folder, one at a time, and nothing else is ever opened. If macOS refuses the read anyway, which is
what a repository under `~/Desktop`, `~/Documents` or `~/Downloads` can do, the collector reports
*not allowed to look* rather than *no repository*, and `--doctor` prints which of those it was. This
has not been exercised against a live TCC prompt here, and that is said in §8.12 rather than implied
away.

**A process's working directory was considered and refused.** `proc_pidinfo` with
`PROC_PIDVNODEPATHINFO` returns the working directory of every process running as you, with no
permission, and would have removed the need to register folders at all. It was refused for the same
reason EventKit was: it answers a small question by taking a large amount. The working directory of
every process you are running is every directory you have anything open in, which is far more than
"what branch is this repo on". You pick the folders.

### 3.4 The honest account of the Accessibility permission

Accessibility is the most powerful grant on macOS short of Full Disk Access. Read this before you
grant it to anything, including this app.

When you add an app to System Settings → Privacy & Security → Accessibility, macOS gives that app
the ability to:

- read the entire accessibility tree of every running application — not just window titles, but text
  field contents, including in some cases the contents of a password field's surrounding UI, message
  bodies, document text, and web page contents in browsers that expose AX;
- post synthetic keyboard and mouse events to any application;
- observe focus and value-change notifications across the system.

macOS offers **no way to scope this grant**. There is no "titles only" variant. If you grant it, you
are trusting the code, not the operating system.

What this app actually does with it, in full:

1. Calls `AXUIElementCreateApplication(pid)` for the frontmost app only.
2. Reads exactly two attributes: `kAXFocusedWindowAttribute`, then `kAXTitleAttribute` on the
   resulting window.
3. Passes the string to `TitleClassifier.classify`, which returns one of six enum values.
4. Lets the string go out of scope. It is not written to disk, not logged, not sent anywhere,
   not retained beyond that function — unless you explicitly turn on the debug ring (row 14), which
   keeps the last 20 in memory so that you can see exactly what is being read.

What it never does with it: no `AXUIElementSetAttributeValue` (never writes), no
`AXObserverCreate` on other processes, no traversal into `kAXChildrenAttribute`, no
`kAXValueAttribute`, no `AXUIElementPostKeyboardEvent`. `scripts/verify-ax-isolation.sh` fails the
build if any AX symbol appears outside `WindowTitleReader.swift`, or if that file references any AX
attribute constant other than the three listed above.

The app's settings screen says this in plain language before showing the prompt, including the
sentence: "macOS cannot limit this permission to window titles. You are trusting our code. Here is
where to read it." — with a link to `WindowTitleReader.swift`.

**If you are not comfortable with that, leave it off.** The app is designed to be good without it.

### 3.5 Fidelity ladder

| Granted | What the app knows | Quality |
|---|---|---|
| Nothing | App switches, idle time, lock/sleep, time | Good. Correct break timing, correct pausing when you leave |
| Notifications | Same + reminders integrate with the system | Good, less intrusive |
| Notifications + Accessibility | Same + meeting/terminal/editor detection | Very good. Will not interrupt a call |
| Notifications + Accessibility + the two Tier 2 switches | Same + the branch you are on, and whether a debugger is attached | Best. `DEBUGGING` stops being a guess and becomes an observation |

The last row is the only one that is not a permission. Tier 2 is two switches, not a grant, and the
ladder includes it because fidelity is what it changes, not because macOS is involved.

### 3.6 Two build flavors, and why

There is a genuine, unavoidable conflict: **an App-Sandboxed app cannot use the Accessibility API to
inspect other processes.** The sandbox denies the `com.apple.axserver` mach lookup, and the
exceptions that would restore it are not generally granted. So the choice is real:

- **Default flavor — sandboxed.** `com.apple.security.app-sandbox` = true, **and no network
  entitlement at all, which also means no in-app updater**: Sparkle needs
  `com.apple.security.network.client` to make its one request, and a sandboxed build deliberately
  does not get it. So in this flavor "no network" really is kernel-enforced, and updates come from
  the Mac App Store or Homebrew instead. No window-title fidelity either: the Accessibility toggle
  is hidden and the AX code path is compiled out with `#if !SANDBOXED`.
- **AX flavor — unsandboxed.** Window-title fidelity available, and the in-app updater described in
  §2.7 and §2.8. There is no kernel guarantee here and there never was: an unsandboxed process may
  open sockets freely regardless of entitlements. What holds instead is that the app's own binary
  contains no networking code, all of it lives in one named framework, and every update is
  signature-verified before it can install.

**This is the flavor this repository currently builds.** The sandboxed flavor is described above
because it is the intended second target, not because it exists yet; §8 says so.

Both flavors are built from the same source with the same CI guards. The release page states which
binary is which and publishes both hashes. Choosing the AX flavor is a deliberate trade of a kernel
guarantee for a feature, and the download page says so in those words.

---

## 4. Storage

### 4.1 Location

Unsandboxed (AX) flavor:
```
~/Library/Application Support/<BUNDLE_ID>/
```
Sandboxed flavor:
```
~/Library/Containers/<BUNDLE_ID>/Data/Library/Application Support/<BUNDLE_ID>/
```

Settings → Data prints whichever of the two is in use, as a path you can select and copy, so you
never have to guess.

### 4.2 Layout

```
<storage root>/                        (mode 0700)
├── settings.json                      (mode 0600)  your preferences
├── badges.json                        (mode 0600)  which badges have unlocked, and when
├── counters.json                      (mode 0600)  today's budgets, overwritten in place
├── call-hold.json                     (mode 0600)  seconds the call hold has held today, overwritten in place
├── events/
│   ├── 2026-09-18.jsonl               (mode 0600)  append-only, one JSON object per line
│   ├── 2026-09-19.jsonl
│   └── 2026-09-20.jsonl
└── summaries/
    └── 2026-09.json                   (mode 0600)  one object per day
```

`counters.json` holds the day's budgets: how many notifications have been delivered, when
the last one was, how many cycles in a row went unanswered, the compliance tallies, and the
next cycle number. It exists because those were rebuilt from nothing on every launch, so
the "notifications per day" setting was never a real constraint for anyone who restarts the
app. It is counts and one timestamp; it adds nothing to the inventory in §1.2 that the
event log does not already hold, and nothing in it says what you were doing.

There is no database, no binary blob, no `.sqlite`, and nothing encrypted or encoded. Formats were
chosen so that `cat` is a complete audit tool.

### 4.3 What you see if you open the files

`events/2026-09-20.jsonl`, verbatim and complete — this is the entire event vocabulary,
and it is checked against `EventKind` rather than written from memory. It drifted once:
`break_open`, `break_begin` and `break_end` shipped without appearing here, which made a
document that claims to be exhaustive quietly incomplete. Adding a kind without adding it
below is a bug under CLAUDE.md §7, not a documentation chore.

```
{"v":1,"t":"2026-09-20T08:58:03Z","e":"start"}
{"v":1,"t":"2026-09-20T08:58:03Z","e":"focus","app":"com.apple.dt.Xcode","cat":"code","sig":"editor"}
{"v":1,"t":"2026-09-20T09:14:41Z","e":"focus","app":"com.google.Chrome","cat":"browse","sig":"browser"}
{"v":1,"t":"2026-09-20T09:31:02Z","e":"idle_begin"}
{"v":1,"t":"2026-09-20T09:37:20Z","e":"idle_end","idle_s":378}
{"v":1,"t":"2026-09-20T09:48:10Z","e":"focus","app":"us.zoom.xos","cat":"meet","sig":"meeting"}
{"v":1,"t":"2026-09-20T10:19:55Z","e":"break_open","cycle":4}
{"v":1,"t":"2026-09-20T10:20:00Z","e":"gate","gate":"audioInputInUse","cycle":4}
{"v":1,"t":"2026-09-20T10:34:07Z","e":"gate","gate":"delivered","cycle":4}
{"v":1,"t":"2026-09-20T10:34:12Z","e":"break_prompt","reason":"SIGTSTP","cycle":4}
{"v":1,"t":"2026-09-20T10:34:31Z","e":"break_response","action":"snoozed","snooze_s":600,"cycle":4}
{"v":1,"t":"2026-09-20T10:44:31Z","e":"break_response","action":"taken","cycle":4}
{"v":1,"t":"2026-09-20T10:44:31Z","e":"break_begin","origin":"accepted","cycle":4}
{"v":1,"t":"2026-09-20T10:49:34Z","e":"break_end","origin":"accepted","dur_s":303,"cycle":4}
{"v":1,"t":"2026-09-20T10:49:34Z","e":"cycle_close","outcome":"honored","cycle":4}
{"v":1,"t":"2026-09-20T10:52:04Z","e":"lock"}
{"v":1,"t":"2026-09-20T11:31:55Z","e":"unlock"}
{"v":1,"t":"2026-09-20T18:02:11Z","e":"stop"}
```

Field reference:

| Field | Type | Meaning |
|---|---|---|
| `v` | int | Schema version. Bumped on any breaking change; readers reject unknown majors |
| `t` | string | ISO-8601 UTC, second resolution. Sub-second precision is deliberately discarded |
| `e` | string | One of: `start`, `stop`, `focus`, `idle_begin`, `idle_end`, `lock`, `unlock`, `sleep`, `wake`, `display_sleep`, `display_wake`, `session_out`, `session_in`, `break_open`, `break_prompt`, `break_response`, `break_begin`, `break_end`, `cycle_close`, `gate` |
| `app` | string? | Bundle identifier. Absent if app tracking is off |
| `cat` | string? | One of `code`, `browse`, `meet`, `write`, `other` — from `categories.json` |
| `sig` | string? | Title signal. Present only if Accessibility fidelity is on. **Never the title itself** |
| `idle_s` | int? | Length of the idle period that just ended |
| `cycle` | int? | Which break opportunity this line belongs to, so counters scope to a cycle |
| `origin` | string? | How a break started: `accepted`, `idleInferred`, `userInitiated` |
| `dur_s` | int? | Measured length of a break, in seconds |
| `outcome` | string? | On `cycle_close`, how the opportunity ended: one of the six `CycleOutcome` values |
| `gate` | string? | On `gate`, why a prompt was or was not allowed: one of the twenty-nine `GateReason` values |
| `reason` | string? | On `break_prompt`, the signal that rung is named after: one of `SIGTSTP`, `SIGINT`, `SIGTERM`, `SIGSTOP` |
| `deferred` | string? | On `break_prompt`, why it was withheld: one of the `GateReason` values |
| `action`, `snooze_s` | | Break engine bookkeeping |

Every one of those is a fixed enum in the source, not a free string. That matters more than
it looks: the type's own doc comment claims there is no field in `LoggedEvent` that could
hold a window title, and that this is enforced by the type rather than by review
convention. `reason` and `deferred` were `String?` and quietly were that field. They are
`SignalName?` and `GateReason?` now, with the same words on disk, so old logs still parse
and the claim is true again.

**Tier 2 adds no field here, and is not allowed to.** A branch name is free text by definition, so it
has nowhere to go: the paragraph above is a property of `LoggedEvent`'s type and a branch would have
to break it. A tool name is *not* free text — `ToolToken` is a closed enum exactly like
`GateReason` — and it is still refused, which takes the extra sentence this deserves. The log
already gains everything Tier 2 buys, through a field it has always had: `activity` can now say
`debugging` where it used to say `coding`. A `tool` column would add something different, an
inventory of which debuggers you run, day by day, for seven days. That is a new kind of fact about
you, not a new encoding of one already here.

Two of those kinds were added because their absence was itself a privacy-adjacent problem,
in the sense that matters here: an app that cannot show its working cannot be audited.

* **`cycle_close`** says how a break opportunity ended. Without it a cycle could be closed
  as `expired`, `quietSuppressed`, `dailyCapReached`, `ignoredExhausted`, `skipped` or
  `honored` and leave no trace, so `cat` could not tell "the user said no" from "the app
  gave up". The value is the `CycleOutcome` enum, never a sentence.
* **`gate`** says why the app was holding a prompt. It is written when the answer
  **changes**, debounced over two ticks, plus once per open cycle every ten minutes so an
  open cycle is never silent for longer than that. Writing it on every five second tick
  would turn a 555 line day into a 17,000 line one and stop `cat` being an audit tool;
  writing it never, which is what the app used to do, meant a fourteen minute hold
  computed the same answer 168 times and kept none of them. Expect roughly 20–60 lines a
  day. The value is the `GateReason` enum, a closed vocabulary of twenty-nine listed in
  `app/Sources/SigstopCore/Decision/GateReason.swift`, every one of them a fact about the
  machine or a name for a rate limit. **None of them is derived from a window title, a URL,
  a file path or anything you typed**, which is the same guarantee every other field here
  carries (CLAUDE.md §4.4).

  Three of the twenty-nine — `userSnoozed`, `userAway`, `breakRunning` — are not gate
  answers at all. They exist because the ten minute rule above was a claim the code did not
  keep: a snooze, an idle suspension and a running break each hold a cycle open while the
  gate is never asked, so the heartbeat had nothing to write and a thirty minute snooze
  produced thirty minutes of nothing. A reader following the rule would have concluded the
  app had died. These three name the silence instead, and are written on the heartbeat
  only, because the transition into each of those states already has its own line
  (`break_response`, `idle_begin`, `break_begin`).

`summaries/2026-09.json`:
```json
{
  "v": 1,
  "days": {
    "2026-09-20": {
      "active_min": 412,
      "by_cat": { "code": 258, "browse": 91, "meet": 54, "other": 9 },
      "breaks_prompted": 8, "breaks_taken": 5, "breaks_skipped": 3,
      "longest_streak_min": 97
    }
  }
}
```

`badges.json`:
```json
{
  "unlocked" : {
    "stopped-1" : "2026-09-20",
    "unmasked" : "2026-09-24"
  },
  "v" : 1
}
```

That is the whole file. It holds ten possible keys, each a fixed badge id, each pointing at a day —
no counters, no history, no per-badge progress, and nothing that says what you were doing when a
badge unlocked. It exists because raw events are pruned after 7 days (§4.5) and a record of
something you did should not disappear with the evidence for it; every badge is otherwise computed
from rows 16 and 17 of the inventory in §1.2, which were already being kept.

If a line in the event log does not parse, the reader skips it and counts it; a corrupt file never
crashes the app and never silently changes your history.

### 4.4 The writer

```swift
// app/Sources/Storage/EventStore.swift
import Foundation

struct Event: Codable {
    let v: Int
    let t: String
    let e: String
    var app: String?
    var cat: String?
    var sig: String?
    var idle_s: Int?
    var reason: String?
    var action: String?
    var snooze_s: Int?
    var deferred: String?
}

final class EventStore {
    private let eventsDir: URL
    private let queue = DispatchQueue(label: "events.writer", qos: .utility)
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]   // keep the file readable
        return e
    }()

    init(root: URL) throws {
        eventsDir = root.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(
            at: eventsDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func append(_ event: Event) {
        queue.async { [weak self] in try? self?.write(event) }
    }

    private func write(_ event: Event) throws {
        let day = String(event.t.prefix(10))                     // "2026-09-20"
        let url = eventsDir.appendingPathComponent("\(day).jsonl")

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path, contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        var line = try encoder.encode(event)
        line.append(0x0A)

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)                        // single small append
    }
}
```

Append-only with `0600`, one file per day, so retention is a file deletion rather than a rewrite.

### 4.5 Retention

Defaults, all user-changeable in `settings.json`:

| Data | Default | Range |
|---|---|---|
| Raw events | 7 days | 0 (memory-only mode) – 365 days |
| Daily summaries | 90 days | 0 – forever |
| Unlocked badges | kept | not pruned — see below |
| Debug title ring | 20 entries, memory-only | fixed |

Pruning runs at launch and once an hour. "0 days" for raw events is a real mode: the store becomes
a no-op writer and only the in-memory engine state exists, so the app works and your disk stays
clean. The summary job then aggregates from memory at midnight.

```swift
// app/Sources/Storage/Retention.swift
func pruneEvents(olderThan days: Int, in eventsDir: URL, now: Date = Date()) throws {
    guard days > 0 else {          // 0 == keep nothing; the writer is disabled upstream
        try FileManager.default.contentsOfDirectory(at: eventsDir, includingPropertiesForKeys: nil)
            .forEach { try FileManager.default.removeItem(at: $0) }
        return
    }
    let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now)!
    let stamp = ISO8601DateFormatter.dayOnly.string(from: cutoff)   // "2026-09-13"
    for url in try FileManager.default.contentsOfDirectory(at: eventsDir, includingPropertiesForKeys: nil)
    where url.pathExtension == "jsonl" && url.deletingPathExtension().lastPathComponent < stamp {
        try FileManager.default.removeItem(at: url)
    }
}
```

String comparison works here because the filenames are zero-padded ISO dates; the test
`RetentionTests.swift` pins that assumption.

`badges.json` is deliberately not pruned, and it is the one file here that is not. Pruning it would
mean a badge vanishing a week after it was earned, which is the opposite of what a record of
something you did is for. It stays a few hundred bytes whatever happens — ten ids and ten dates is
its maximum size — and "Delete everything" removes it with the rest, because delete means delete.

### 4.6 Export and delete

**Export** (one button in Settings → Data, `NSSavePanel`, no permission needed): writes one text
file. A commented header names the schema version, the source folder, the day range and every field
the log can hold; under it is every event on disk, verbatim, one JSON object per line, grouped by
day. Nothing is transformed or filtered, so what you audit is what the app recorded. Settings, badges
and the summaries are not in it: they are the plain files in §4.2, and `cat` is the export for those.

**Delete everything** (one button in Settings → Data, one confirmation): removes the storage directory recursively,
resets in-memory state, and reports what it removed. The dialog also tells you the two things the
app cannot clean up itself, because no app can:

```
Deleted: ~/Library/Application Support/<BUNDLE_ID>  (23 files, 412 KB)

Two things this app cannot remove for you:
  • The Accessibility permission you granted. Remove it in
    System Settings → Privacy & Security → Accessibility,
    or run:  tccutil reset Accessibility <BUNDLE_ID>
  • System log entries macOS wrote. Run:  sudo log erase --all   (clears the whole system log)
```

There is no "archive", no tombstone, no soft delete, and no copy kept anywhere.

---

## 5. Telemetry

### 5.1 Position

**Zero telemetry. One request, and only when you ask for it.**

No analytics, no crash reporting, no usage pings, no first-run beacon, no A/B configuration fetch,
no remote feature flags, no font or asset CDN. None of that exists in the binary and `make verify`
checks the bundle against a list of analytics SDKs by name.

The single exception is the update check, and it is worth stating precisely rather than generously:

| | |
|---|---|
| How many endpoints | One. A static `appcast.xml`, the same bytes for everyone |
| When | When you press **Check for updates**, and daily only if you switched that on. Off by default |
| At launch | Never |
| What is sent | A plain `GET`. No query string, no body, no cookie, no account, no install id, no machine id, no system profile, and a user agent overridden to the constant `sigstop` — not even the app version |
| What is stored about it | Nothing, on either side of this codebase |
| What it necessarily reveals | Your IP address and the time of the request, to whoever serves the file. This cannot be avoided by any client |
| What protects the download | EdDSA signature verification against a public key compiled into the app. See §2.8 |

This position is weaker than the one this document held before the updater existed, and the earlier
text is not being quietly edited to pretend otherwise. §5.3 is the argument for the change, kept
next to the argument it replaced.

### 5.2 Is opt-in analytics worth it? Recommendation: no.

The case for it is real. Without any telemetry the maintainers do not know which macOS versions are
in use, how often the AX path fails on a given app, or whether the default 50-minute interval is
sensible. Those are genuine product costs.

The recommendation is still no, and the reason survives the arrival of the updater largely intact:
**a binary whose networking is one named framework doing one thing is a categorically different
object from a binary with a general-purpose reporting path behind a flag.** The first supports
"here is the only thing it can fetch, and here is the assertion in `make verify` that fails if a
second URL ever appears." The second supports only "this process did not report anything while you
were watching."

Analytics would also be a *different kind* of network use from the updater: the updater pulls a
static file that is identical for every user, and analytics pushes a payload that by construction is
about you. One of those is checkable from the outside and the other is not, which is why the
existence of the first is not an argument for the second.

Secondary reasons: an opt-in rate low enough to be privacy-respecting is too biased to be useful;
an analytics SDK is a supply-chain dependency with its own update channel; and "opt-in" tends to
decay into "opt-in, but we ask every launch".

**Instead:**
- **Save Diagnostics Report…** writes a plain-text file (OS version, app version, which permissions
  are granted, last 50 internal log lines with identifiers redacted, no event data). You read it,
  you decide, you attach it to a GitHub issue yourself. The app never transmits it and never puts
  it on the pasteboard.
- Product questions get answered in the repository's discussions, where the sample is
  self-selected but at least honest about being so.
- Defaults are argued for in `docs/DECISIONS.md` with the reasoning visible, rather than tuned by
  telemetry nobody can inspect.

### 5.3 Update checking — the position, and why it changed

**The old position, kept verbatim so the change is legible:**

> An in-app update check is a network call. Calling it "just a version check" does not change that:
> it reveals your IP address, your app version, and a timestamp, on a schedule that correlates with
> when your machine is awake, to a server that can log it.
>
> **Recommendation: the app never checks for updates.** A "Check for updates" menu item, if it
> exists at all, is a single `NSWorkspace.open` of the constant releases URL in your browser.
>
> The honest cost: some users will run an old build with a fixed bug for months. That is accepted.
> The app is a break timer; a stale break timer is not a security incident.

**The sentence that argument got wrong.** "A stale break timer is not a security incident" is true
of the timer and false of the *installation*. This app is unsandboxed and holds an Accessibility
grant when the user turns Tier 1 on. A machine full of installs that can never be updated is a
machine where a bug in an app with that grant is permanent. The old position optimised for the
purity of a claim and accepted an unbounded tail of un-updatable installs to keep it; that was the
wrong trade for this particular app.

**The current position.** The app has an in-app updater, built on Sparkle, shaped so that every
concrete objection in the quoted text is either answered or admitted:

| Old objection | Now |
|---|---|
| "reveals your app version" | Answered. The user agent is overridden to the constant `sigstop`; `SUEnableSystemProfiling` is off. The version comparison happens on your machine against a file that is the same for everyone |
| "on a schedule that correlates with when your machine is awake" | Answered outright. There is no schedule. The app writes Sparkle's scheduling flag off on every launch, so there is no daily check, no launch check and no toggle that could turn one on |
| "reveals your IP address and a timestamp" | **Admitted. Not fixable.** Any HTTPS request does this. If it matters to you, never press the button, and use Homebrew. Nothing else in the app will make the request for you |
| "to a server that can log it" | Admitted, and defanged where it counts: the server cannot make you install anything, because of §2.8 |

**What did NOT change.** There is still no telemetry, still no payload, still nothing about you in
the request. "The app can now fetch an update" is not a licence for "the app can now report."
§5.2 is still a no.

**The other distribution routes still exist and are still the most private option.** Homebrew cask
and GitHub Releases both work, and in both cases the network request is made by a tool you chose at
a moment you chose. The in-app updater is for the people who would otherwise never update at all,
which — the old text was right about this — is most people.

The release process, including exactly how an archive gets signed and how the appcast is generated,
is in `docs/RELEASING.md`.

---

## 6. Verifiability

### 6.1 Inspect the entitlements

```bash
APP=/Applications/<App>.app
codesign -d --entitlements - --xml "$APP" | plutil -convert xml1 -o - -
```

Sandboxed flavor — expected, in full:
```xml
<key>com.apple.security.app-sandbox</key><true/>
```
That is the entire list. In particular these must be **absent**:
`com.apple.security.network.client`, `com.apple.security.network.server`,
`com.apple.security.files.all`, `com.apple.security.device.camera`,
`com.apple.security.device.microphone`, `com.apple.security.personal-information.*`,
`com.apple.security.automation.apple-events`,
`com.apple.security.cs.disable-library-validation`,
`com.apple.security.cs.allow-unsigned-executable-memory`,
`com.apple.security.cs.allow-dyld-environment-variables`.

AX flavor — the entitlements file is almost empty by design, and the two that matter are the two
that are *not* there: `com.apple.security.network.server` (nothing listens) and
`com.apple.security.cs.disable-library-validation` (§2.9). Without the App Sandbox, the absence of
`network.client` is not meaningful and this document does not pretend it is.

Also confirm the signature:
```bash
codesign -dv --verbose=4 "$APP"      # TeamIdentifier, and whether the runtime flag is set
spctl -a -vvv "$APP"                 # see the note below before reading anything into this
```

**Do not expect `spctl` to say "Notarized Developer ID" for a build from this repository.** The app
is ad-hoc signed — no Developer ID, no Team ID, no notarization, and (see §2.9) no Hardened Runtime
in the default `make bundle`. That is a real gap and it is why update integrity rests on Sparkle's
EdDSA signature rather than on Apple's chain. The EdDSA key is checkable and does not depend on
anyone's certificate:

```bash
plutil -extract SUPublicEDKey raw "$APP/Contents/Info.plist"
```

### 6.2 Inspect the linked frameworks and symbols

```bash
BIN="$APP/Contents/MacOS/$(plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist")"
otool -L "$BIN"
```

Expected list, and nothing else: `@rpath/Sparkle.framework/Versions/B/Sparkle`, `AppKit`,
`Foundation`, `CoreGraphics`, `CoreFoundation`, `CoreAudio`, `IOKit`, `UserNotifications`,
`ServiceManagement`, `ApplicationServices` (AX flavor only), `SwiftUI`, `libobjc`, `libSystem`, and
the Swift runtime libraries.

The Sparkle line is the one addition, and it is the whole of the app's network capability. Check
what is behind it:

```bash
ls "$APP/Contents/Frameworks"          # expect exactly: Sparkle.framework
plutil -extract CFBundleShortVersionString raw \
  "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
```

Now the important part, stated honestly: **`otool -L` cannot prove the absence of networking.**
`libSystem` contains `socket(2)` and every process links it. `Foundation` transitively reaches
`CFNetwork`. So the absence of `Network.framework` in the list is weak evidence, not proof. The
stronger binary-level check is the undefined-symbol table, which shows what this binary actually
references:

```bash
nm -u "$BIN" | grep -E '^_(socket|connect|bind|sendto|sendmsg|recvfrom|getaddrinfo|gethostbyname)$'
nm "$BIN"    | grep -E 'OBJC_CLASS_\$_(NSURLSession|NSURLConnection|NSURLRequest|NWConnection|NWBrowser|NWPathMonitor|NSXPCConnection|NSAppleScript|NSTask|NSPasteboard)'
nm -u "$BIN" | grep -E 'CGEventTap|CGWindowList|CGDisplayStream|SCStream|SecItem'
strings -a "$BIN" | grep -E '^https?://' | sort -u
```

All of the above should produce no output except the last, which should show only the project's
repository, releases and privacy-document URLs — the links the app hands to your browser. Note what
is *not* in that list: the update feed URL. It is not a string in the executable at all; it lives in
`Info.plist` as `SUFeedURL`, where `plutil -p` will show it to you.

**This is the check that carries the claim now.** "The app's own binary contains no networking" is
still literally true and still mechanically checkable, even though the bundle as a whole can make
one request. `make verify` runs all of the above and fails the build on any hit; read
`app/Scripts/verify.sh`.

### 6.3 Watch it at runtime

Running proof beats static proof. Any one of these is sufficient:

The expectation is no longer "silence forever." It is **silence until you press the button, and
then one HTTPS connection to the feed host and nothing else.** That is a sharper test than the old
one, because you get to choose the moment and watch both halves of it.

```bash
# 1. Sockets held by the process, sampled
PID=$(pgrep -f '<BUNDLE_ID>')
sudo lsof -i -a -p "$PID"              # expect: nothing, until you press Check for updates

# 2. Per-process network accounting, live
nettop -p "$PID"                        # expect: no rows, no bytes, until you press the button

# 3. Every network syscall the process makes
sudo fs_usage -w -f network "$PID"      # expect: silence, until you press the button

# 4. Packet-level, for the paranoid
sudo tcpdump -n -i any "host not 127.0.0.1" -w /tmp/cap.pcap   # then correlate by time
```

Little Snitch or LuLu is the ergonomic version, and it is now a *better* test than it used to be
rather than a worse one. Install one, run the app for a week without pressing anything, and confirm
it never appears in the connection list. Then press **Check for updates** and confirm that exactly
one rule prompt appears, for the feed host, and that nothing else ever follows. A tool that shows
you both the silence and the single exception proves more than a tool that only ever showed you
silence.

For the storage claims, run the app for a day and then just read the files:
```bash
cat ~/Library/Application\ Support/<BUNDLE_ID>/events/$(date +%F).jsonl
```
Every window title you had open that day is absent. Every keystroke is absent. What is present is
bundle identifiers and timestamps, which is the deal.

### 6.4 Read the source, in this order

```
app/Sources/
├── Observation/
│   ├── FrontmostAppObserver.swift   ← the primary signal; no permissions involved
│   ├── IdleMonitor.swift            ← 12 lines; the entire idle story
│   ├── PowerAndLockObserver.swift   ← sleep/lock/session notifications
│   ├── WindowTitleReader.swift      ← the ONLY AX code in the project. Start here if suspicious
│   ├── TitleClassifier.swift        ← the complete vocabulary extracted from a title
│   └── ActivitySampler.swift        ← the call site showing the title is discarded
├── Storage/
│   ├── EventStore.swift             ← the only code that writes event data
│   ├── SettingsStore.swift
│   ├── Retention.swift              ← deletion policy
│   └── ExportService.swift          ← export and delete-everything
├── Break/BreakEngine.swift          ← pure state machine, no I/O, unit-tested
├── UI/                              ← menu bar, settings, fallback overlay window
├── Links.swift                      ← every URL constant in the app, in one file
└── Resources/
    ├── categories.json
    └── MessagePacks/*.json
scripts/
├── verify-no-network.sh
├── verify-entitlements.sh
├── verify-ax-isolation.sh
└── verify-forbidden-apis.sh
.github/workflows/privacy-guard.yml  ← runs all four on every PR; required check
```

`scripts/verify-no-network.sh`, in full, so you can run it before you trust CI:

```bash
#!/usr/bin/env bash
# Fails if the built binary references any networking or exfiltration primitive.
set -euo pipefail
BIN="${1:?usage: verify-no-network.sh /path/to/App.app/Contents/MacOS/App}"

fail() { echo "PRIVACY GUARD FAILED: $1" >&2; exit 1; }

UNDEF_FORBIDDEN='^_(socket|connect|bind|listen|accept|sendto|sendmsg|recvfrom|recvmsg|getaddrinfo|gethostbyname|res_9_init|CFHostStartInfoResolution|CFSocketCreate|SCNetworkReachabilityCreateWithName)$'
CLASS_FORBIDDEN='OBJC_CLASS_\$_(NSURLSession|NSURLConnection|NSURLRequest|NWConnection|NWBrowser|NWListener|NWPathMonitor|NSNetService|NSXPCConnection|NSAppleScript|NSTask|NSPasteboard)'
API_FORBIDDEN='(CGEventTapCreate|CGWindowListCreateImage|CGWindowListCopyWindowInfo|CGDisplayStreamCreate|SCStreamConfiguration|SecItemCopyMatching|SecItemAdd|dlopen)'

nm -u "$BIN" | awk '{print $NF}' | grep -Eq "$UNDEF_FORBIDDEN" && fail "networking syscall referenced"
nm    "$BIN" | grep -Eq "$CLASS_FORBIDDEN"                      && fail "forbidden class referenced"
nm -u "$BIN" | grep -Eq "$API_FORBIDDEN"                        && fail "forbidden API referenced"

# Every URL literal in the binary must be on the allowlist.
ALLOWED='^https://github\.com/(ORG)/(REPO)(/releases)?/?$'
while read -r url; do
  [[ "$url" =~ $ALLOWED ]] || fail "unexpected URL literal in binary: $url"
done < <(strings -a "$BIN" | grep -Eo 'https?://[^[:space:]"]+' | sort -u)

echo "privacy guard: OK"
```

`scripts/verify-ax-isolation.sh` is the same idea at source level:

```bash
#!/usr/bin/env bash
set -euo pipefail
SRC=app/Sources
ALLOWED_FILE="$SRC/Observation/WindowTitleReader.swift"

# 1. No AX usage outside the one permitted file.
if grep -rln 'AXUIElement\|AXIsProcessTrusted\|AXObserver' "$SRC" | grep -v "^$ALLOWED_FILE$"; then
  echo "PRIVACY GUARD FAILED: Accessibility API used outside WindowTitleReader.swift" >&2; exit 1
fi

# 2. That file may reference only these AX attribute constants.
UNEXPECTED=$(grep -o 'kAX[A-Za-z]*' "$ALLOWED_FILE" | sort -u \
  | grep -v -E '^kAX(FocusedWindowAttribute|TitleAttribute|TrustedCheckOptionPrompt)$' || true)
[ -z "$UNEXPECTED" ] || { echo "PRIVACY GUARD FAILED: new AX attributes: $UNEXPECTED" >&2; exit 1; }

echo "ax isolation: OK"
```

### 6.5 Reproducible builds

What is offered, honestly:

- The build is pinned: exact Xcode version, exact macOS SDK, `SOURCE_DATE_EPOCH` set from the git
  commit date, no timestamps in resources, deterministic resource ordering. `make verify-build`
  builds twice in separate directories and diffs.
- Release notes publish the SHA-256 of the notarized `.dmg`, of the `.app` bundle, and of the
  **unsigned, signature-stripped** main binary:
  `codesign --remove-signature` on a copy, then `shasum -a 256`.
- The third hash is the one you can reproduce. The signature embeds a certificate and a secure
  timestamp that you cannot reproduce without the signing key, so the `.dmg` hash can only be
  compared, not recreated.

What cannot be promised: bit-identical signed artifacts, and full independence from Apple's
toolchain. Swift's compiler is not guaranteed deterministic across patch releases, so a mismatch may
mean "different Xcode" rather than "tampered". The build workflow therefore records the exact
toolchain build number in the release notes. See §8.4.

---

## 7. Threat model

Scope: a local-first app with no server and no accounts. Excluded from scope, because no app-level
design defends against them: a compromised macOS kernel, a root-level attacker, a malicious Xcode
toolchain, and physical access to an unlocked machine.

| # | Threat | Actor | Structural defense | Residual risk |
|---|---|---|---|---|
| 1 | A contributor adds an analytics or "crash reporting" call | Maintainer under commercial pressure, or a contributor | `make verify` fails on any networking symbol in the app's own binary, on any URL literal outside the allowlist, and on ~25 analytics and crash-reporting SDKs by name, checked against the built bundle | Someone with merge rights can also edit the check. Mitigation: `app/Scripts/verify.sh` lives in a `CODEOWNERS`-protected path requiring two approvals |
| 2 | A dependency ships a malicious update | Upstream package | **Exactly one third-party runtime dependency: Sparkle, pinned with `exact:` rather than a range, so a new upstream tag cannot enter a build without a commit that says so.** It is attached to `SigstopApp` only; `SigstopCore` and `SigstopSensors` remain dependency-free, and `make verify` asserts Sparkle is the only embedded framework | A malicious Sparkle release that someone then deliberately bumps to. Mitigation is the pin plus review of the bump. The argument for admitting the dependency at all is in CLAUDE.md §5 |
| 3 | Code is loaded at runtime that was never reviewed | Attacker with write access to the bundle | `disable-library-validation` and `allow-unsigned-executable-memory` are absent and `make verify` fails if they appear. No `dlopen`, no plugin directory, no bundle loading, no JavaScriptCore | **Weakened.** Hardened Runtime is no longer enabled in the default ad-hoc build, because Library Validation cannot coexist with an embedded framework when neither has a Team ID (§2.9). `HARDENED=1 make bundle` restores it for anyone with a Developer ID. An attacker who can rewrite `/Applications` could inject a library — though they could equally replace the binary outright |
| 3b | A malicious update is served to users | Attacker who compromises GitHub, the CDN, or the network path | **EdDSA signature verification (§2.8).** The private key is in the maintainer's login keychain only; the public key is compiled into the app; Sparkle refuses an archive whose signature does not verify | Theft of the private key. Rotation does not reach installs that already hold the old public key. `docs/RELEASING.md` §6 |
| 4 | A malicious **message pack** exfiltrates or executes | Contributor, or a user installing a third-party pack | Packs are data, not code: strict JSON, schema-validated on load, string fields only, length-capped. No URLs, no format specifiers, no templating engine, no HTML — text is rendered into `NSAttributedString` with attributes disabled. A pack cannot cause a network call: the app's own binary has no networking code at all, and the only URL the bundle can fetch is the compile-time feed constant | A pack could still contain hostile or manipulative *text*. Defense is review: packs ship only in-tree, every pack change requires a human review, and third-party packs are not loadable from disk in the default build |
| 5 | The Accessibility grant is abused to read message/document contents | Malicious future version of the app | `verify-ax-isolation.sh` in CI; the AX code is one file and ~30 lines; the debug ring lets a user see exactly what is being read; the permission is off by default | **Real and unavoidable.** If you grant Accessibility, a future build could read anything. Defenses are social (review, reproducible hashes) not technical. See §8.2 |
| 6 | Exfiltration without a socket (open a URL, spawn `curl`, AppleScript another app) | Contributor | Forbidden-symbol guard covers `NSWorkspace.open` call sites, `Process`, `NSTask`, `posix_spawn`, `NSAppleScript`; the URL-literal allowlist in `make verify` catches a smuggled collector endpoint | A URL assembled at runtime from string fragments could evade the literal check. Partially mitigated: `NSWorkspace.open` may only be called with values from the `Links` enum, enforced by the URL allowlist |
| 6b | Exfiltration *through* the update request | Contributor | The feed URL is a plist constant with no query string; `SUEnableSystemProfiling` is off and asserted by `make verify`; the user agent is overridden to a constant carrying no version; there is no second endpoint and the allowlist check fails if one appears | A contributor could add a delegate that appends feed parameters. That would be a visible code change to one file, and would have to survive review against this row |
| 7 | Another local process reads the event log | Malware running as the user | Files are `0600` in a `0700` directory; the sandboxed flavor's container is additionally protected by the sandbox and by TCC's "app data" protections on recent macOS | Any process running as you can read your files. App-level encryption would not help, because the key would have to be available to the app as the same user. FileVault is the real defense. See §8.5 |
| 8 | Supply-chain attack on the release artifact | Attacker with repo or CI access | **EdDSA signing, done on the maintainer's machine from a key that is never in the repository or in CI.** An attacker with full repository and CI access can therefore publish a release and still cannot produce one the app will install. Hashes are published in release notes; the Homebrew cask carries its own `sha256` which the tap must also update | A compromised signing key defeats this. There is no Developer ID and no notarization to fall back on (§8.1), so the EdDSA key is the single point of failure and is treated as one in `docs/RELEASING.md` |
| 9 | Data reconstruction from an old backup | Anyone with your Time Machine disk | Retention defaults are short (7 days); the storage path is an ordinary user path, so it honors any backup exclusions you set | The app does not and should not set backup exclusions on your behalf. Documented, not defended |
| 10 | Someone infers sensitive facts from your event log (therapy appointments, job hunting) | A person with access to your machine | Only bundle IDs, not titles or URLs; short retention; one-click delete; the whole log is human-readable so you can see the inference risk yourself | Bundle IDs alone can be revealing (a job-board app, a health app). If that matters to you, disable app tracking and run the pure timer |

---

## 8. Limitations, stated plainly

These are the places where an honest answer is "we cannot prove that."

**8.1 The app makes one network request, and nothing in the OS stops it making others.** The AX
flavor is unsandboxed, so `com.apple.security.network.client` being absent means nothing to the
kernel — unsandboxed processes may open sockets freely, entitlements or not. That was already true
before the updater existed; what changed is that there is now something in the bundle that uses the
freedom. What holds the line instead is checkable but static: the app's own binary references no
networking symbol, the only network code is one named and versioned framework, the only endpoint is
a plist constant, and `make verify` fails on any of those changing. A runtime monitor is the only
conclusive test, and it only proves what happened while it was watching.

**8.1b The update channel reveals your IP address and the time you checked.** Not to this project —
there is no server here — but to GitHub, which serves the file. No client-side choice avoids it. If
that matters, leave the daily check off, never press the button, and install and upgrade through
Homebrew instead. The app makes no request at all unless you ask it to.

**8.1c The EdDSA private key is a single point of failure.** Update integrity rests entirely on it,
because the build has no Developer ID and no notarization to fall back on. If it is stolen, an
attacker can sign updates that every installed copy will accept, and rotating the key does not reach
anyone already running an older build — they verify against the key compiled into the copy they
have. `docs/RELEASING.md` §6 describes what a rotation would actually involve, which is mostly
"tell people to reinstall by hand."

**8.1d Hardened Runtime is off in the default build.** See §2.9 for the full mechanism; the short
version is that Library Validation and an embedded framework cannot coexist without a Team ID, and
the alternative — adding `disable-library-validation` — would have cost more than it bought. A
Developer ID would fix this properly and this project does not have one.

**8.2 Accessibility cannot be scoped, and the app's restraint is not enforced by macOS.** If you
grant it, you grant the ability to read most UI text across your system and to synthesize input.
Every defense listed here is a code-review defense. A malicious future release, signed by the same
team ID, would inherit your existing grant silently.

**8.3 A window title exists in the app's memory, briefly.** The claim is that it is never persisted,
never logged, never transmitted, and discarded at the end of one function. It is not a claim that
the string never existed. It may appear in a memory dump, in a swap file if memory is paged (the
app does not mark the buffer non-swappable), and potentially in a crash report if a crash occurs
inside the classification path.

**8.4 `otool -L` cannot prove the absence of networking**, because `libSystem` (linked by everything)
contains the socket API and `Foundation` reaches `CFNetwork` transitively. The undefined-symbol
check is stronger but still static. A runtime monitor is the only conclusive test, and it only
proves what happened while it was watching.

**8.5 On-disk data is not encrypted at rest by the app.** Files are `0600`. Any process running as
your user can read them. Encrypting with a Keychain-held key would be theater: the app would hold
the key as the same user, so the same attacker gets both. FileVault is the correct control and it is
not this app's to provide.

**8.6 System logs and crash reports are outside the app's control.** `os_log` lines may persist in
the unified log; the app logs no bundle identifiers at default level and marks dynamic values
`%{private}`, but it does not control retention. Separately, if macOS crash reporting is enabled in
*your* system settings, a crash report may be sent to Apple by the OS. That is a system setting, not
an app behavior, and the app cannot suppress it.

**8.7 Reproducible builds are partial.** Signed artifacts are not bit-reproducible. Only the
signature-stripped binary hash can be independently recreated, and only with the exact pinned
toolchain.

**8.8 Installing and upgrading makes network requests whichever route you take.** Through Homebrew
it is Homebrew contacting GitHub; through the in-app updater it is this app contacting GitHub. The
difference between those is agency and auditability, not the absence of packets, and this document
says so rather than claiming "zero network, period."

**8.9 Bundle identifiers are not innocuous.** A seven-day log of which apps you focused, with
timestamps, is meaningful data about you. It is less than a screen recorder collects by orders of
magnitude, but it is not nothing, and calling it "anonymous" would be false — it is on your machine,
about you, tied to you.

**8.11 A branch name and a tool name exist in the app's memory while Tier 2 is on.** The same caveat
as §8.3 and for the same reason: the claim is that neither is persisted, logged or transmitted, not
that neither existed. A branch name may carry a ticket id, a customer, or an unreleased product. It
may appear in a memory dump, in swap, or in a crash report if a crash happens inside the collector.
If that matters to you, leave Tier 2 off, which is where it ships.

**8.12 `--doctor` knows your branch, and you are asked to paste `--doctor` into public issues.** That
combination is the one place Tier 2 could leak something you did not mean to publish, so `--doctor`
prints the *length* of the branch name and not the name. Settings → Signals shows it on your own
machine, where it is not going anywhere. This is not a claim that the redaction is airtight: a length
is a fact about the string, and the surrounding lines still name your apps and the folders you
registered. Read what you paste.

**8.13 The Files-and-Folders behaviour of the git collector has not been exercised here.** Whether
macOS prompts, or silently refuses, when a registered folder sits under `~/Desktop`, `~/Documents` or
`~/Downloads` was reasoned about and not tested, because testing it means putting a modal on
somebody's screen and leaving a permanent entry in their privacy settings. The collector is written
to report *not allowed to look* separately from *no repository* precisely so that, when somebody does
hit it, the app says which one happened instead of looking broken.

**8.10 Idle detection is session-wide.** `CGEventSourceSecondsSinceLastEventType` reflects input to
every application, not only this one. It reveals no content, but it does mean the app knows whether
you were typing *somewhere* — including in apps you have excluded from tracking.

---

## 9. Changes to this document

This file is versioned with the code. Any change to the data inventory, permissions, retention
defaults, or the network position requires a PR that also updates §1 and that carries the
`privacy-impacting` label; `CODEOWNERS` requires two approvals on that path. The release notes call
out any such change in the first line, not in a footnote.

### 9.1 Changelog of positions

| What changed | From | To |
|---|---|---|
| Network | "No network transmission of any kind." Zero requests, ever | One HTTPS `GET` of a static appcast, on a button press, with no identifier. §2.7, §5 |
| Update checking | "The app never checks for updates"; a menu item that opens a browser | An in-app updater with EdDSA signature verification. §5.3 keeps the old argument in full and says which sentence of it was wrong |
| Dependencies | Zero third-party runtime dependencies | Exactly one: Sparkle, pinned with `exact:`, linked into the app target only. §7 row 2 |
| Hardened Runtime | On, with Library Validation | Off in the default ad-hoc build, because it cannot coexist with an embedded framework without a Team ID. §2.9, §8.1d |
| Update integrity | Notarized Developer ID signing | EdDSA signing with a key held only by the maintainer, verified before install. §2.8, §8.1c |
| Tier 2 | Two switches that read nothing, and a `--doctor` that said so | Two collectors: executable basenames against a fixed allowlist, and one line of `.git/HEAD` in folders you register. Inventory rows 29 to 31, §2.10, §3.5, §8.11 to §8.13 |
| Tier 2 command lines | `docs/ACTIVITY-DETECTION.md` mandated `KERN_PROCARGS2` for the full argv | argv is never read. The justification for reading it (a 16-character `p_comm` limit) was measurably wrong, and `proc_pidpath` answers the same question with no permission. The cost, six tool tokens that become undetectable, is named in §4.3(b) of that file |

Nothing in the earlier positions was deleted to make room for these. The arguments that were
replaced are quoted where they were replaced, because a privacy document that silently rewrites its
own history is not evidence of anything.
