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
| 15 | **Break engine state**: streak start, last break end, snooze count, next fire time | Derived from #1/#5/#7 | The actual product | Persisted, `state.json` | Overwritten in place; reset on delete | No |
| 16 | **Break interaction events**: prompted, taken, skipped, snoozed | UI callbacks | "You skipped 6 of 8 breaks today" and nothing more | Persisted as events | Same as #1 | Yes |
| 17 | **Daily aggregates**: minutes per category, breaks taken/skipped, longest streak | Derived from the event log nightly | Weekly view without keeping raw events | Persisted, `summaries/YYYY-MM.json` | Default 90 days | Yes |
| 18 | **Preferences**: interval, threshold, quiet hours, which app categories count as work, chosen message pack | User input | Configuration | Persisted, `settings.json` (plain JSON, human-editable) | Until you change or delete them | n/a |
| 19 | **App category map** (`com.apple.dt.Xcode → code`) | Static JSON shipped inside the bundle, plus your own overrides | Classify #1 without heuristics | Read-only in `App.app/Contents/Resources/categories.json`; overrides in `settings.json` | Ships with the app | n/a |
| 20 | **Break message packs** | Static JSON shipped inside the bundle | Text of the reminder | Read-only resource | Ships with the app | Yes, choose or disable |
| 21 | **Login-item registration** | `SMAppService.mainApp.register()` | Start at login, if you ask for it | A registration record owned by `launchservicesd`, outside the app's storage | Until unregistered | Yes — off by default |
| 22 | **Notification authorization status** | `UNUserNotificationCenter.notificationSettings()` | Decide whether to use a system notification or the in-app fallback window | Memory-only (the real record is TCC's) | n/a | n/a |
| 23 | **Unified log lines** | `os.Logger` | Debugging | System log, `/var/db/diagnostics`, rotated by macOS | Controlled by macOS, not by the app | See §8.6 |

That is the complete list. There is no row for network, account, device identifier, hardware serial,
IP address, locale beacon, install ID, or first-run ping, because none of those exist in the code.

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

### 2.7 No network transmission of any kind

This is the claim developers care about most, so here is the honest, layered version.

**In the sandboxed flavor (the default build):** the entitlement
`com.apple.security.network.client` is absent and `com.apple.security.network.server` is absent.
Under App Sandbox this is enforced by the kernel — a `connect(2)` from the process fails with
`EPERM` regardless of what the code tries to do. This is a real guarantee, not a policy.

**In the Accessibility flavor (§3.6):** the app cannot be sandboxed, so the missing entitlement
guarantees nothing. What remains is: no networking symbol in the binary, no networking code in the
tree, CI enforcement of both, and your own runtime monitor. That is weaker. It is stated plainly
in §8.1 rather than buried.

**Check.**
```
codesign -d --entitlements - --xml <APP> | plutil -p -    # look for network.client — must be absent
nm -u <BIN> | grep -E '^_(socket|connect|getaddrinfo|res_9_init|SCNetworkReachability)' # expect none
nm <BIN> | grep -E 'OBJC_CLASS_\$_(NSURLSession|NSURLConnection|NWConnection|NWBrowser)' # expect none
sudo lsof -i -a -p "$(pgrep -f '<BUNDLE_ID>')"            # expect no sockets, ever
```
See §6.3 for the Little Snitch / `nettop` procedure, and §8.1 for what `otool -L` can and cannot
prove.

### 2.8 No covert exfiltration channels

A process with no sockets can still leak. The following are also absent, and CI enforces each:

| Channel | Why it matters | Guard |
|---|---|---|
| `NSWorkspace.open(URL)` | Opening `https://collector/?data=…` in the browser exfiltrates without a socket in this process | Allowlisted: the only call sites pass a compile-time constant from `Links.swift`, and CI asserts the call appears nowhere else |
| `Process` / `NSTask` / `posix_spawn` | Shelling out to `curl` | Forbidden symbols; not referenced anywhere |
| `NSAppleScript` / `osascript` | Scripting another app into making the request | Forbidden symbols; no Automation usage string |
| `NSXPCConnection` to a helper | A helper could hold the network code | The app ships no helper tool, no `Contents/Library/LaunchServices`, no privileged helper. `ls <APP>/Contents` shows the whole bundle |
| `dlopen` / plugin loading | Loading code not in the reviewed binary | Hardened Runtime with Library Validation on, `com.apple.security.cs.disable-library-validation` absent |
| DNS via `CFHost` | Data in a hostname | Forbidden symbols |

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

### 3.3 What is never requested

Screen Recording. Input Monitoring. Full Disk Access. Automation / Apple Events. Calendar. Contacts.
Reminders. Photos. Microphone. Camera. Location. Local Network. Files and Folders (Desktop,
Documents, Downloads). Developer Tools.

The corresponding `Info.plist` usage-description keys are absent, which means macOS would terminate
the app with `TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION` if any code path ever attempted them. That is
a useful property: the absence of a usage string turns an attempted privacy violation into an
immediate, loud crash rather than a silent prompt.

A note on Calendar: reading EventKit would be the most accurate way to know you are in a meeting.
It was considered and rejected. It would mean access to every event title, attendee, and location on
your calendar to answer a yes/no question that a window title answers at a fraction of the exposure.

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
| Notifications + Accessibility | Same + meeting/terminal/editor detection | Best. Will not interrupt a call |

### 3.6 Two build flavors, and why

There is a genuine, unavoidable conflict: **an App-Sandboxed app cannot use the Accessibility API to
inspect other processes.** The sandbox denies the `com.apple.axserver` mach lookup, and the
exceptions that would restore it are not generally granted. So the choice is real:

- **Default flavor — sandboxed.** `com.apple.security.app-sandbox` = true, no network entitlements.
  "No network" is kernel-enforced. No window-title fidelity: the Accessibility toggle is hidden and
  the AX code path is compiled out with `#if !SANDBOXED`. Distributable through the Mac App Store.
- **AX flavor — unsandboxed, Hardened Runtime, notarized.** Window-title fidelity available. "No
  network" is enforced only by code review, CI symbol checks, and whatever monitor you run.

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

The menu has **Reveal Data Folder in Finder**, which opens whichever of the two is in use, so you
never have to guess.

### 4.2 Layout

```
<storage root>/                        (mode 0700)
├── settings.json                      (mode 0600)  your preferences
├── state.json                         (mode 0600)  break engine state, overwritten in place
├── events/
│   ├── 2026-09-18.jsonl               (mode 0600)  append-only, one JSON object per line
│   ├── 2026-09-19.jsonl
│   └── 2026-09-20.jsonl
└── summaries/
    └── 2026-09.json                   (mode 0600)  one object per day
```

There is no database, no binary blob, no `.sqlite`, and nothing encrypted or encoded. Formats were
chosen so that `cat` is a complete audit tool.

### 4.3 What you see if you open the files

`events/2026-09-20.jsonl`, verbatim and complete — this is the entire event vocabulary:

```
{"v":1,"t":"2026-09-20T08:58:03Z","e":"start"}
{"v":1,"t":"2026-09-20T08:58:03Z","e":"focus","app":"com.apple.dt.Xcode","cat":"code","sig":"editor"}
{"v":1,"t":"2026-09-20T09:14:41Z","e":"focus","app":"com.google.Chrome","cat":"browse","sig":"browser"}
{"v":1,"t":"2026-09-20T09:31:02Z","e":"idle_begin"}
{"v":1,"t":"2026-09-20T09:37:20Z","e":"idle_end","idle_s":378}
{"v":1,"t":"2026-09-20T09:48:10Z","e":"focus","app":"us.zoom.xos","cat":"meet","sig":"meeting"}
{"v":1,"t":"2026-09-20T10:20:00Z","e":"break_prompt","reason":"streak_50m","deferred":"meeting"}
{"v":1,"t":"2026-09-20T10:34:12Z","e":"break_prompt","reason":"streak_50m"}
{"v":1,"t":"2026-09-20T10:34:31Z","e":"break_response","action":"snooze","snooze_s":600}
{"v":1,"t":"2026-09-20T10:44:31Z","e":"break_response","action":"taken"}
{"v":1,"t":"2026-09-20T10:52:04Z","e":"lock"}
{"v":1,"t":"2026-09-20T11:31:55Z","e":"unlock"}
{"v":1,"t":"2026-09-20T18:02:11Z","e":"stop"}
```

Field reference:

| Field | Type | Meaning |
|---|---|---|
| `v` | int | Schema version. Bumped on any breaking change; readers reject unknown majors |
| `t` | string | ISO-8601 UTC, second resolution. Sub-second precision is deliberately discarded |
| `e` | string | One of: `start`, `stop`, `focus`, `idle_begin`, `idle_end`, `lock`, `unlock`, `sleep`, `wake`, `session_out`, `session_in`, `break_prompt`, `break_response` |
| `app` | string? | Bundle identifier. Absent if app tracking is off |
| `cat` | string? | One of `code`, `browse`, `meet`, `write`, `other` — from `categories.json` |
| `sig` | string? | Title signal. Present only if Accessibility fidelity is on. **Never the title itself** |
| `idle_s` | int? | Length of the idle period that just ended |
| `reason`, `action`, `snooze_s`, `deferred` | | Break engine bookkeeping |

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

### 4.6 Export and delete

**Export** (one menu item, `NSSavePanel`, no permission needed): writes a folder containing the raw
`.jsonl` files, the summaries, `settings.json`, a generated `events.csv` for spreadsheet users, and
a `README.txt` describing the schema. Nothing is transformed or filtered — the export is a copy, so
what you audit is what the app has.

**Delete everything** (one menu item, one confirmation): removes the storage directory recursively,
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

**Zero network calls by default. Zero network calls in the sandboxed flavor, ever, enforced by the
kernel.** No analytics, no crash reporting, no usage pings, no first-run beacon, no A/B
configuration fetch, no remote feature flags, no font or asset CDN.

### 5.2 Is opt-in analytics worth it? Recommendation: no.

The case for it is real. Without any telemetry the maintainers do not know which macOS versions are
in use, how often the AX path fails on a given app, or whether the default 50-minute interval is
sensible. Those are genuine product costs.

The recommendation is still no, for one architectural reason: **a binary that contains no networking
code is a categorically different object from a binary that contains networking code behind a flag.**
The first supports the sentence "this process cannot open a socket, here is `lsof` proving it." The
second supports only "this process did not open a socket while you were watching." Every
verification procedure in §6 collapses from a proof to a spot check the moment a URL session exists
in the binary. The whole privacy argument of the app rests on that distinction, and analytics is not
worth trading it for.

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

### 5.3 Update checking

An in-app update check is a network call. Calling it "just a version check" does not change that: it
reveals your IP address, your app version, and a timestamp, on a schedule that correlates with when
your machine is awake, to a server that can log it. It is exactly the thing this document claims the
app does not do.

**Recommendation: the app never checks for updates.** Distribution is:

1. **Homebrew cask** — `brew install --cask <name>`, `brew upgrade`. The network call is made by
   Homebrew, at a moment you chose, by a tool you already audit. The app itself has no update code.
2. **GitHub Releases** — signed, notarized, with SHA-256 published. Subscribe to the releases Atom
   feed if you want to be told about new versions; your feed reader makes that request, not the app.

A "Check for updates" menu item, if it exists at all, is a single `NSWorkspace.open` of the constant
releases URL in your browser — an action you took, in an app you control, visible in your browser
history. It is the one allowlisted `NSWorkspace.open` call site mentioned in §2.8.

The honest cost: some users will run an old build with a fixed bug for months. That is accepted. The
app is a break timer; a stale break timer is not a security incident. If a genuinely severe bug ever
ships, the mitigation is a loud advisory in the repository and the Homebrew cask, not a phone-home
channel kept alive for a hypothetical.

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

AX flavor — expected, in full:
```xml
<key>com.apple.security.cs.allow-jit</key><false/>
```
(that is, hardened runtime with nothing relaxed; no sandbox key, and therefore no network key to be
meaningful).

Also confirm the signature and notarization:
```bash
codesign -dv --verbose=4 "$APP"      # check TeamIdentifier and that runtime flag is set
spctl -a -vvv "$APP"                 # "accepted", "Notarized Developer ID"
```

### 6.2 Inspect the linked frameworks and symbols

```bash
BIN="$APP/Contents/MacOS/$(plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist")"
otool -L "$BIN"
```

Expected list, and nothing else: `AppKit`, `Foundation`, `CoreGraphics`, `CoreFoundation`,
`UserNotifications`, `ServiceManagement`, `ApplicationServices` (AX flavor only), `SwiftUI`,
`libobjc`, `libSystem`, and the Swift runtime libraries.

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
repository and releases URLs. This is the same check CI runs; see `scripts/verify-no-network.sh`.

### 6.3 Watch it at runtime

Running proof beats static proof. Any one of these is sufficient:

```bash
# 1. Sockets held by the process, sampled
PID=$(pgrep -f '<BUNDLE_ID>')
sudo lsof -i -a -p "$PID"              # expect: nothing, at any time

# 2. Per-process network accounting, live
nettop -p "$PID"                        # expect: no rows, no bytes

# 3. Every network syscall the process makes
sudo fs_usage -w -f network "$PID"      # expect: silence

# 4. Packet-level, for the paranoid
sudo tcpdump -n -i any "host not 127.0.0.1" -w /tmp/cap.pcap   # then correlate by time
```

Little Snitch or LuLu is the ergonomic version: install one, run the app for a week, and confirm it
never appears in the connection list. This is the recommended check for the AX flavor, where the
sandbox is not there to enforce the property for you.

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
| 1 | A contributor adds an analytics or "crash reporting" call | Maintainer under commercial pressure, or a contributor | CI privacy guard (§6.4) fails the PR on any networking symbol; the guard is a required status check; sandboxed flavor would fail at runtime anyway | Someone with merge rights can also edit the workflow. Mitigation: guard scripts and workflow live in a `CODEOWNERS`-protected path requiring two approvals |
| 2 | A dependency ships a malicious update | Upstream package | **Zero third-party runtime dependencies.** The app links only Apple frameworks. `Package.swift` has an empty `dependencies` array and CI asserts it stays empty. Dev-only tools (SwiftLint) are pinned by exact version and checksum and never enter the app binary | A future contributor could argue for a dependency. Policy: any new runtime dependency requires a documented review in `docs/DECISIONS.md` and vendoring with a pinned commit |
| 3 | Code is loaded at runtime that was never reviewed | Attacker with write access to the bundle | Hardened Runtime with Library Validation enabled; `disable-library-validation` and `allow-unsigned-executable-memory` entitlements absent, so only libraries signed by the same Team ID load. No `dlopen`, no plugin directory, no bundle loading, no JavaScriptCore | An attacker who can rewrite `/Applications` can also re-sign with their own identity — but then `spctl` and the published hash no longer match |
| 4 | A malicious **message pack** exfiltrates or executes | Contributor, or a user installing a third-party pack | Packs are data, not code: strict JSON, schema-validated on load, string fields only, length-capped. No URLs, no format specifiers, no templating engine, no HTML — text is rendered into `NSAttributedString` with attributes disabled. A pack cannot cause a network call because the binary has no networking code | A pack could still contain hostile or manipulative *text*. Defense is review: packs ship only in-tree, every pack change requires a human review, and third-party packs are not loadable from disk in the default build |
| 5 | The Accessibility grant is abused to read message/document contents | Malicious future version of the app | `verify-ax-isolation.sh` in CI; the AX code is one file and ~30 lines; the debug ring lets a user see exactly what is being read; the permission is off by default | **Real and unavoidable.** If you grant Accessibility, a future build could read anything. Defenses are social (review, reproducible hashes) not technical. See §8.2 |
| 6 | Exfiltration without a socket (open a URL, spawn `curl`, AppleScript another app) | Contributor | Forbidden-symbol guard covers `NSWorkspace.open` call sites, `Process`, `NSTask`, `posix_spawn`, `NSAppleScript`; the URL-literal allowlist in `verify-no-network.sh` catches a smuggled collector endpoint | A URL assembled at runtime from string fragments could evade the literal check. Partially mitigated: `NSWorkspace.open` may only be called with values from `Links.swift`, enforced by a grep in CI |
| 7 | Another local process reads the event log | Malware running as the user | Files are `0600` in a `0700` directory; the sandboxed flavor's container is additionally protected by the sandbox and by TCC's "app data" protections on recent macOS | Any process running as you can read your files. App-level encryption would not help, because the key would have to be available to the app as the same user. FileVault is the real defense. See §8.5 |
| 8 | Supply-chain attack on the release artifact | Attacker with repo or CI access | Notarized Developer ID signing; hashes published in release notes; signature-stripped binary hash independently reproducible; Homebrew cask carries its own `sha256` which a second party (the tap) must also update | A compromised signing key plus a compromised release note defeats this. Multi-party review of release PRs is the mitigation |
| 9 | Data reconstruction from an old backup | Anyone with your Time Machine disk | Retention defaults are short (7 days); the storage path is an ordinary user path, so it honors any backup exclusions you set | The app does not and should not set backup exclusions on your behalf. Documented, not defended |
| 10 | Someone infers sensitive facts from your event log (therapy appointments, job hunting) | A person with access to your machine | Only bundle IDs, not titles or URLs; short retention; one-click delete; the whole log is human-readable so you can see the inference risk yourself | Bundle IDs alone can be revealing (a job-board app, a health app). If that matters to you, disable app tracking and run the pure timer |

---

## 8. Limitations, stated plainly

These are the places where an honest answer is "we cannot prove that."

**8.1 The missing network entitlement only binds under the sandbox.** In the AX flavor the app is
unsandboxed, so `com.apple.security.network.client` being absent means nothing to the kernel —
unsandboxed processes may open sockets freely. The "no network" property in that flavor rests on
source review, CI symbol guards, and your own monitor. If you want the kernel-enforced version, use
the sandboxed flavor and accept the loss of window-title fidelity.

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

**8.8 Homebrew still makes a network request.** Saying "the app never phones home" is true, and it
is also true that installing or upgrading via Homebrew causes *your machine* to contact GitHub. The
difference is agency and auditability, not the absence of packets. It is stated this way rather than
as "zero network, period".

**8.9 Bundle identifiers are not innocuous.** A seven-day log of which apps you focused, with
timestamps, is meaningful data about you. It is less than a screen recorder collects by orders of
magnitude, but it is not nothing, and calling it "anonymous" would be false — it is on your machine,
about you, tied to you.

**8.10 Idle detection is session-wide.** `CGEventSourceSecondsSinceLastEventType` reflects input to
every application, not only this one. It reveals no content, but it does mean the app knows whether
you were typing *somewhere* — including in apps you have excluded from tracking.

---

## 9. Changes to this document

This file is versioned with the code. Any change to the data inventory, permissions, retention
defaults, or the network position requires a PR that also updates §1 and that carries the
`privacy-impacting` label; `CODEOWNERS` requires two approvals on that path. The release notes call
out any such change in the first line, not in a footnote.
