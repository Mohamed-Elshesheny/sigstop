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
| 1 | Frontmost app **bundle identifier** (`com.apple.dt.Xcode`) | `NSWorkspace.didActivateApplicationNotification` → `NSRunningApplication.bundleIdentifier` | Detect that you switched context; classify the activity as coding / meeting / reading / idle-ish so a break is not proposed mid-call | Persisted, `events/YYYY-MM-DD.jsonl`, and as a key of the day's summary, row 17 | 7 days in the event log. The day's summary keeps it, with the seconds you spent in the app, until you delete your data | No. There is no switch for it |
| 2 | Frontmost app **localized name** (`Xcode`) | same notification → `NSRunningApplication.localizedName` | Shown in the UI ("you've been in Xcode for 52 min"); fallback identifier for apps with no bundle ID | Persisted only when bundle ID is `nil` (rare: some helper processes) | Same as #1 | Same as #1 |
| 3 | Frontmost app **pid** | `NSRunningApplication.processIdentifier` | Needed as the argument to `AXUIElementCreateApplication` when window-title fidelity is on | Memory-only | Until the next app switch | n/a |
| 4 | Frontmost app **icon** | `NSRunningApplication.icon` | Drawn in the menu bar popover | Memory-only | Until the next app switch | n/a |
| 5 | **Activation timestamp** | `Date()` at notification delivery | Compute durations | Persisted, second resolution, UTC | Same as #1 | No (it is the timer) |
| 6 | **Seconds since last input event** (a single `Double`) | `CGEventSourceSecondsSinceLastEventType(.hidSystemState, kCGAnyInputEventType)` | Distinguish "working for 50 minutes" from "left the room 40 minutes ago" | Not persisted raw. Only the derived transitions `idle_begin` / `idle_end` and the idle duration are persisted | Same as #1 | No. There is no switch for it |
| 7 | **Idle/active state** | Derived from #6 against a threshold (default 90 s) | Pause and resume the streak timer | Persisted as events | Same as #1 | Follows #6 |
| 8 | **Screen locked / unlocked** | `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`, polled; plus the `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` distributed notifications as a fast path | Locked time is not work time; also the moment to reset a streak | Persisted as `lock` / `unlock` events | Same as #1 | No |
| 9 | **Display sleep / wake** | `NSWorkspace.screensDidSleepNotification`, `screensDidWakeNotification` | Same as #8 | Persisted as events | Same as #1 | No |
| 10 | **System sleep / wake** | `NSWorkspace.willSleepNotification`, `didWakeNotification` | Do not fire a break reminder into a closed lid; reset the streak across a long sleep | Persisted as events | Same as #1 | No |
| 11 | **Fast user switch** | `NSWorkspace.sessionDidResignActiveNotification` / `sessionDidBecomeActiveNotification` | Another user's session is not your work | Persisted as events | Same as #1 | No |
| 12 | **Focused window title** | `AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute)` then `kAXTitleAttribute` — **requires Accessibility permission** | Only to answer one question: does this window look like a live meeting, a terminal, an editor, a browser, or a document? A meeting is the one thing worth never interrupting | **The string itself is never persisted.** The provider that claims the frontmost app matches it against its own patterns (§1.5) and returns an `Activity`. That activity is persisted as `act`, row 32 | `act`: same as #1. String: memory-only, held until the next read replaces it | **Yes, and off by default** |
| 15 | **Break engine state**: streak start, last break end, snooze count, next fire time | Derived from #1/#5/#7 | The actual product | Memory-only; nothing writes it to disk. The day's budgets that have to survive a relaunch are in `counters.json` (§4.2) | Gone when the process exits | No |
| 16 | **Break interaction events**: prompted, taken, skipped, snoozed | UI callbacks | "You skipped 6 of 8 breaks today" and nothing more | Persisted as events | Same as #1 | Yes |
| 17 | **Daily summaries**: the seconds of active work in each app, by **bundle identifier**, and in each activity; the day's total and its longest unbroken stretch; counts of breaks, snoozes, skips, ignored prompts, notifications, sessions and break opportunities | Derived from the event log while the app runs, recomputed at most once a minute. Written only when the numbers differ from the last write, and then at most every ten minutes, except at once when the menu bar panel opens, a break ends, the day changes (a last write for the day that ended, then the first for the new one), your data is deleted, the Mac sleeps or locks, or the app quits | Badges that count days after those days' events are pruned. Nothing uses the per-app or per-activity seconds once they are on disk; they are there because the summary is written whole | Persisted, `summaries/YYYY-MM.json`, one object per day (§4.3). Never leaves the Mac | Every day, kept until you delete your data; never pruned (§4.5) | No. There is no switch for it |
| 18 | **Preferences**: interval, threshold, quiet hours, tone, prompt channel and sound | User input | Configuration | Persisted, `settings.json` (plain JSON, human-editable) | Until you change or delete them | n/a |
| 19 | **App category map** (`com.apple.dt.Xcode → code`) | Compiled into the binary: `AppKey` in `app/Sources/SigstopCore/Message/MessageContext.swift` names the app's family, and `AppModel.category(for:)` maps the family to one of four words | Classify #1 without heuristics | Code, not data. There is no category file in the bundle and no override in `settings.json` | Ships with the app | n/a |
| 20 | **Break message corpus** | Static JSON shipped inside the bundle, `Contents/Resources/sigstop_SigstopCore.bundle/corpus.json` | Text of the reminder | Read-only resource | Ships with the app | No. It is one pack and there is no setting to choose or disable it; the tone setting decides which of its lines can fire |
| 21 | **Unlocked badges**: which of the ten marks have unlocked, and the day each did | Derived from #17 and #16, entirely — no new signal, no new event field, nothing observed that was not already in this table | So a badge earned inside the 7-day event window is not silently lost when those events are pruned | Persisted, `badges.json` (a flat map of badge id to day) | Kept until you delete your data; never expires and never decreases | n/a |
| 22 | **Login-item registration** | `SMAppService.mainApp.register()` | Start at login, if you ask for it | A registration record owned by `launchservicesd`, outside the app's storage | Until you switch it off, or until *Delete my data…*, which unregisters it | Yes — off by default |
| 23 | **Notification authorization status** | `UNUserNotificationCenter.notificationSettings()` | Decide whether to use a system notification or the in-app fallback window | Memory-only (the real record is TCC's) | n/a | n/a |
| 24 | **Unified log lines** | None from the app's own code: nothing in `app/Sources` calls `os_log`, `Logger` or `NSLog`. Sparkle, which runs in this process, logs through `os_log` under the subsystem `org.sparkle-project.Sparkle`, and Apple's frameworks log about any app they run in | The app needs none of it | System log, `/var/db/diagnostics`, rotated by macOS | Controlled by macOS, not by the app | See §8.6 |
| 25 | **Audio input device in use** (one `Bool` per device, OR'd) | `kAudioDevicePropertyDeviceIsRunningSomewhere` on each device with input channels. **No Microphone permission; none is requested** | Do not interrupt a live call. This is the signal a hard block rests on | Not persisted. Only the derived verdict reaches the log, as a `reason` string | n/a | No — it is what stops a prompt landing in a meeting |
| 26 | **Camera device in use** (one `Bool` per device, OR'd) and the **device names** | `kCMIODevicePropertyDeviceIsRunningSomewhere` over `kCMIOHardwarePropertyDevices`. **No Camera permission; none is requested, and a probe generated no `tccd` activity** | Same, for the camera-on / microphone-muted posture, which is the normal one on Teams and Meet | Not persisted. Device names are printed by `--doctor` on request and held in memory only | Process lifetime | No |
| 27 | **Bundle identifiers of processes running audio input** | `kAudioHardwarePropertyProcessObjectList`, then `kAudioProcessPropertyBundleID` and `kAudioProcessPropertyIsRunningInput` per process object. **No permission; none is requested** | Say *which* app has the microphone, so the call hold names a fact rather than guessing, and so Siri, dictation and a permanently-open virtual device can be discounted instead of disabling the signal | Not persisted. Each identifier is matched against a fixed list and dropped. Nothing else about the process is read **on this path**: this row is CoreAudio's process object list and it yields a bundle identifier, nothing more. The one place the app reads an executable path is row 30, which is Tier 2, off by default, and bounded there | Memory-only, one sample | No |
| 28 | **Seconds the call hold has held a break today**, and the day they count for | Derived from #25, #26 and #27 by the call latch | So the three-hour daily ceiling on holding survives a relaunch instead of resetting to zero | Persisted, `call-hold.json` (a day index and a number of seconds) | Overwritten in place; reset on delete | Follows "Hold my break during calls" |
| 29 | **The focused window's document path** (`/Users/you/p/a.swift`) | `kAXDocument` on the focused window, read in the same call that reads the title. Tier 1 | Names the file you have open when the title does not, and tells the git collector which registered folder you are in | Memory-only, one sample. Anything that is not a local file URL is discarded before it is parsed, which is what keeps a browser's full page URL out (`AccessibilityCollector.fileURL(from:)`) | Until the next sample | Follows Tier 1 |
| 30 | **Which of a fixed list of developer tools is running**, as an enum case, never a string, plus one `Bool` for whether anything is under a debugger | One `sysctl(KERN_PROC_ALL)`, then `proc_pidpath` for the pids whose `p_comm` already matched the `ToolToken` allowlist in `app/Sources/SigstopSensors/SignalContext.swift`. **No permission is required and none is requested** | The only signal in this product that can tell `DEBUGGING` from `CODING`. Without it the app degrades to `CODING` rather than guess between siblings ("Never overclaim" in [the rules a PR cannot break](../CONTRIBUTING.md#the-rules-a-pr-cannot-break)) | **Not persisted, and nothing but the match survives.** The path is compared and dropped. A process matching nothing is not recorded, not counted, not reported. No command line, environment or working directory is read at all | Memory-only, one sample | **Yes, and off by default** |
| 31 | **Current git branch name** (`fix/retry-loop`), and whether a rebase, merge or bisect is in progress | The first line, at most 512 bytes, of `<repo>/.git/HEAD`, in a folder **you registered yourself** through an `NSOpenPanel`. In a worktree or submodule, first the `gitdir:` line of the `.git` file; mid-rebase, the `head-name` line. Plus `lstat` on `.git` and on the git directory, its `HEAD`, `objects` and `commondir`, one `realpath` of a `gitdir:` target, and four `access` checks, none of which opens a file (§2.10). No `git` process is ever spawned | Fills the `{branch}` slot so a line can say something true instead of something generic | **Memory-only.** Held for the lifetime of one `DeveloperContext` and replaced by the next sample. There is **no field in `LoggedEvent` that could hold it** (§4.3), `--doctor` prints its length rather than the name (§8.12), and it is **withheld from the system-notification channel** so that the one path out of this process cannot carry it (§8.11) | Until the next sample, or process exit | **Yes, and off by default** |
| 32 | **The activity at a focus event** (`act`: `coding`, `codeReview`, `documentation`…), one of the twelve `Activity` cases | Derived. From #1 alone at Tier 0; **with Tier 1 on, also from the window title (#12) and the document path (#29)**; with Tier 2 process context, also from #30 | So the log can say what kind of work a stretch was, not only which app it was in | Persisted, the `act` field of `focus` events (§4.3). A browser tab titled `Pull Request #12` is logged as `"act":"codeReview"` | Same as #1 | No switch of its own. It is title-derived only while Tier 1 is on |
| 33 | **The update check's URL cache**: the appcast URL, the time it was fetched, and the appcast itself | Foundation's URL cache, filled by Sparkle's request in this process when you press **Check for updates** | Nothing in this app asks for it. It is what Foundation does with an HTTP response by default | Persisted, `~/Library/Caches/<BUNDLE_ID>/Cache.db` and `fsCachedData/` | Controlled by Foundation and macOS, not by the app. *Delete my data…* does not remove it | Only by never pressing the button |
| 34 | **Foundation's HTTP storage** for this app | Created by the same request | As #33 | Persisted, `~/Library/HTTPStorages/<BUNDLE_ID>/`. On the Mac this was checked on it held one table, `alt_services`, and it was empty. Beside it, `~/Library/HTTPStorages/<BUNDLE_ID>.binarycookies` holds any cookie a server set | The folder: controlled by macOS. The cookie file: deleted by the app at every launch, before the updater starts (§2.9), so it can be left over from the last run. *Delete my data…* removes neither | Only by never pressing the button |
| 35 | **Sparkle's staging folders** | Sparkle | Where a downloaded update waits before `Autoupdate` installs it | `~/Library/Caches/<BUNDLE_ID>.sparkle/org.sparkle-project.Sparkle/`, holding `Installation` and `PersistentDownloads`. Both were empty on the Mac this was checked on | Until Sparkle clears them. *Delete my data…* does not remove them | n/a |
| 36 | **UserDefaults**: `SULastCheckTime` (when you last pressed **Check for updates**), `SUHasLaunchedBefore`, `SUEnableAutomaticChecks` and `SUSendProfileInfo` (both written `false`), and `NSStatusItem Preferred Position sigstop` (where the menu bar icon sits) | Sparkle, and AppKit's status item autosave | The two `false` values are how the app keeps Sparkle from scheduling a check or sending a profile (§2.7). The rest is Sparkle's and AppKit's own bookkeeping | Persisted, `~/Library/Preferences/<BUNDLE_ID>.plist`, read with `defaults read <BUNDLE_ID>` | Until `defaults delete <BUNDLE_ID>`. *Delete my data…* does not remove it | No |

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

**Row 31 reads first lines, and only of git's own pointer files**: `HEAD`, the `.git` file a
worktree or submodule has instead of a folder, and mid-rebase the `head-name` file that says which
branch is being rebased. Not a diff, not a commit message, not `.git/config`, not an object, not the
index, and never a file in your working tree. The repository state is four `access` calls, on
`.git/rebase-merge`, `.git/rebase-apply`, `.git/MERGE_HEAD` and `.git/BISECT_LOG`, each of which
returns a `Bool` and opens nothing: the app learns a rebase is in progress, never what is being
rebased. The `lstat` and `realpath` calls in the row say what kind of thing a path is and where a
`gitdir:` line leads, and open nothing either. The folder is one you picked in an `NSOpenPanel`.
The app never guesses a path from a window title or a project name, because guessing a path from a
name is the kind of invention "Never overclaim" forbids ([the rules a PR cannot break](../CONTRIBUTING.md#the-rules-a-pr-cannot-break)).

What a window title and a `kAXDocument` path **do** decide is *which* of the folders you added is
the one in front, and only that. Two of your folders answering means the app does not know which
project you are looking at, so it reports no branch rather than pick one, and `--doctor` says which
route answered and which abstained so a blank never looks like a bug.

That is the complete list. There is no row for account, device identifier, hardware serial, locale
beacon, install ID, or first-run ping, because none of those exist in the code.

There is one row's worth of network activity, and it is not in the table above because nothing about
it is *collected*: when you press **Check for updates**, the app fetches one static XML file over
HTTPS. It sends no identifier. What it leaves on this Mac is rows 33 to 36: Foundation's cache of
that file, Sparkle's folders, and the time of the last check. What it necessarily reveals is
your IP address and the time, to whoever serves that file. §5 is the whole account of it, including
the parts that cannot be proven from this side.

### 1.3 What a "focus" sample looks like end to end

The code is `FrontmostAppCollector` in
`app/Sources/SigstopSensors/Collectors/FrontmostAppCollector.swift`. `start()` subscribes to
activation, deactivation, launch and termination on `NSWorkspace.shared.notificationCenter`, and every
`NSRunningApplication` it is handed, by a notification or by the first read, is reduced to an
`AppIdentity` here:

```swift
private nonisolated static func identity(of app: NSRunningApplication) -> AppIdentity {
    AppIdentity(
        bundleID: app.bundleIdentifier,
        localizedName: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
        pid: app.processIdentifier
    )
}

private nonisolated static func readFrontmost() -> AppIdentity? {
    if let app = NSWorkspace.shared.frontmostApplication {
        return identity(of: app)
    }
    if let owner = NSWorkspace.shared.runningApplications.first(where: { $0.ownsMenuBar }) {
        return identity(of: owner)
    }
    return nil
}
```

Note what this API gives and does not give. `NSRunningApplication` exposes an identifier and a
display name. It does not expose window contents, document paths, or arguments. There is no
permission prompt because macOS does not consider the identity of the frontmost app to be private —
every app on your system can already see it.

### 1.4 Idle detection carries no input content

The code is `IdleCollector.read()` in `app/Sources/SigstopSensors/Collectors/IdleCollector.swift`.
It returns one number and the name of the source it came from. When the event source has no answer it
falls back to the `HIDIdleTime` property of `IOHIDSystem`, which is also a single number:

```swift
public func read() -> InputActivity {
    if let any = CGEventType(rawValue: ~0) {
        let seconds = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
        if seconds.isFinite, seconds >= 0 {
            return InputActivity(idleSeconds: seconds, source: .hidSystemState)
        }
    }
    if let seconds = Self.hidIdleSecondsFromIORegistry() {
        return InputActivity(idleSeconds: seconds, source: .ioRegistry)
    }
    return .unknown
}
```

The distinction between `CGEventSourceSecondsSinceLastEventType` and `CGEventTapCreate` is the whole
argument. The first is a counter read. The second is a keylogger primitive, needs Input Monitoring
or Accessibility, and is never called: `.github/scripts/check-forbidden-apis.py` (§6.4) fails CI if it appears.

### 1.5 The window-title redaction boundary

This is the most sensitive path in the app, so it is the most tightly bounded. Two attributes are
read through one private function, and a CI job fails the build if Accessibility code appears
anywhere else.

**This section used to be a fabrication, and that is worth saying rather than quietly deleting.**
It printed ninety lines of Swift under the paths `app/Sources/Observation/WindowTitleReader.swift`,
`TitleClassifier.swift` and `ActivitySampler.swift`, invited the reader to "read `TitleClassifier`
and you know the total vocabulary", and cited `scripts/verify-ax-isolation.sh` as the thing that
enforced the boundary. None of those files has ever existed. In a document whose entire argument is
*do not trust us, read the source*, a listing the reader cannot `cat` is the worst possible defect,
and it survived because nothing checked the prose against the tree. What follows is the real code,
with real paths, and the check that now runs in CI.

**Where Accessibility lives.** Two files, and `.github/scripts/check-ax-isolation.py` fails the
build if a third appears:

    app/Sources/SigstopSensors/Collectors/AccessibilityCollector.swift   the reads
    app/Sources/SigstopSensors/PermissionBroker.swift                    the trust check

**The one reader.** `AccessibilityCollector.read(pid:)` hands off to `readSync(pid:)`, which fetches
the focused window and asks it for exactly two attributes:

```swift
let title = copyString(window, kAXTitleAttribute)
let document = copyString(window, kAXDocumentAttribute)
return AXWindowInfo(
    title: title,
    documentURL: document.flatMap(Self.fileURL(from:)),
    browserHost: document.flatMap(Self.host(from:))
)
```

`AXUIElementCopyAttributeValue` appears twice in `AccessibilityCollector.swift`: once in `readSync`
for the focused window, and once inside `copyString`, which is `private` and is called only with
`kAXTitle` and `kAXDocument`:

```swift
private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
    var ref: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
    guard status == .success else {
        if status != .attributeUnsupported && status != .noValue {
            record(Self.failure(for: status))
        }
        return nil
    }
    guard let whole = ref as? String else { return nil }
    let string = String(decoding: Array(whole.utf16.prefix(Self.longestString)), as: UTF16.self)
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
```

A value is cut to its first 1,024 UTF-16 units (`longestString`) before anything reads it: no
provider needs more, and a page that sets a megabyte-long title cannot make every sample slow.

`kAXValue` is the attribute that would return a text field's contents. Nothing can reach it: the
function is private, its only two call sites are in the listing above, and the CI check means a
second reader cannot be added in another file without the build failing.

**There is no `TitleClassifier` and no `TitleSignal` enum.** The old listing described a six-value
vocabulary produced by one classifier. The real design is per-provider: each provider matches the
title against its own patterns and returns an `Activity`, and `BrowserTitlePatterns`
(`app/Sources/SigstopSensors/Providers/BuiltinProviders.swift`) holds the regexes for the
browser case. `docs/ACTIVITY-DETECTION.md` §5 explains why there is no universal format to classify
against. The consequence for this section is the same either way and is the part that matters: a
title is matched and dropped inside `observe`, and the string itself is never returned upward.

**What a title decides does reach the disk, as `act`.** This section used to say nothing
title-derived reached the disk, and that was false. `AppModel.logFocusIfNeeded` writes
`activity: context.activity` on every focus event, and with Tier 1 on a provider can pick that
activity from the title: `BrowserProvider` returns `codeReview` when `BrowserTitlePatterns.isReview`
matches, so a tab titled `Pull Request #12` is logged as `"act":"codeReview"`, and an editor
title naming a `.md` file can make it `documentation`. The value is one of the twelve `Activity`
cases, never the string, and it is inventory row 32. What is true is narrower: the `sig` field,
which exists and is documented in §4.3, is never populated, because `logFocusIfNeeded` passes
`titleSignal: nil`.

Outside the app's own files there was one more route, and it is closed. On the notification
channel, which is off by default, a prompt line could carry a project name parsed from a title
through the `{project}` slot, and macOS keeps notification text in its own store (§8.11). Both
`{branch}` and `{project}` are now withheld there. The parser also takes a project only from the
folder position in the title, never from a lone component, and refuses anything that looks like a
buffer's text rather than a folder (`•`, `://`, `@`, `=`, `Untitled-`), because the first line of
an untitled editor buffer can be the window title.

**And there is no raw-title debug ring.** Row 14 of the inventory promised "last 20 titles, memory
only, off by default, and the UI switch is labelled as such". There is no ring, no switch and no
setting. The row is struck from the table rather than kept as an aspiration, for the same reason
this section was rewritten. Row 13, which persisted a six-value "title classification result", is
struck for the same reason: that vocabulary does not exist, and what a title does leave on disk
is row 32.

A file path in a title, a pull-request name, a customer's name in a document title: none of it is
written to the app's files. The file and project names an editor's title yields do leave the
provider, into the evidence lines the menu bar and `--doctor` show, and into the `{project}` slot
above. §8.3 states the limitation honestly — the string does exist in
process memory for the duration of the call, and the code, not the operating system, is what stops
it going further.

---

## 2. What the app does not do, as enforceable properties

"We promise not to" is worth nothing. Each item below names the mechanism that makes the behavior
absent, and the command that shows you it is absent. `<APP>` is the installed bundle;
`<BIN>` is `<APP>/Contents/MacOS/<executable>`.

### 2.1 No source code, file contents, or document text

**Mechanism.** The app never opens a file it did not create, except its own read-only bundle
resources and, with Tier 2 git context on, the few git files §2.10 names, in folders you registered.
It requests no Full Disk Access. The app is not sandboxed (§3.6 describes a sandboxed flavor that is
planned, not built), so nothing in macOS confines its file access: the bound is the code. The
file-reading code in the tree is
`FileEventStore` (`app/Sources/SigstopCore/Storage/FileStore.swift`), `SettingsStore`
(`app/Sources/SigstopApp/Support.swift`) and `CallHoldLedger`, all scoped to the storage directory,
plus `GitCollector` for those git files.

**Check.** No script asserts anything about file-access entitlements, because without the sandbox
one would not constrain anything. `make verify` (`app/Scripts/verify.sh`) checks the entitlements
for a network server key, for any key that reopens injection, JIT or debugging, and for Library
Validation switched off on a build that has a Team ID; none of that is about files (§6.1). Read the
whole list yourself. On the shipped app, which is ad-hoc signed, it is two keys:

```
$ codesign -d --entitlements - --xml <APP> 2>/dev/null | plutil -p -
{
  "com.apple.security.automation.apple-events" => false
  "com.apple.security.cs.disable-library-validation" => true
}
```

The first is the one key in `app/Resources/sigstop.entitlements`. The second is added by
`app/Scripts/bundle.sh` to a build with no Team ID, because the Hardened Runtime could not load
`Sparkle.framework` without it (§2.9). Neither grants access to a file.

At runtime: `sudo fs_usage -w -f filesys $(pgrep -x sigstop)` and watch that the only paths touched
are the app bundle and the storage directory, plus, once you press **Check for updates**, the caches
in inventory rows 33 to 35.

### 2.2 No keystrokes

**Mechanism.** The app never calls `CGEventTapCreate` or `CGEventTapCreateForPSN`, and never reads
which keys are down. It has one `NSEvent.addGlobalMonitorForEvents`, in `AppMain.swift`, and it
asks only for `.leftMouseDown`, `.rightMouseDown` and `.otherMouseDown`: a click outside the menu
bar panel closes the panel. The handler ignores the event it is handed, and the monitor exists only
while the panel is open. `.github/scripts/check-forbidden-apis.py` fails CI if a global monitor asks
for anything but mouse events or if a key-reading API appears in the source, and `make verify`
checks the built binary for the same symbols. This section used to say the app never calls
`addGlobalMonitorForEvents` at all, which was false. The app does not appear in
System Settings → Privacy & Security → Input Monitoring, because it never asks.

**Check.**
```
nm -u <BIN> | grep -E 'CGEventTap|CGEventSourceKeyState|IOHIDManager'   # expect no output
python3 .github/scripts/check-forbidden-apis.py                         # from a checkout
```
Note the honest caveat: Accessibility permission, if you grant it, *would* allow a global monitor.
The defense there is the CI symbol check plus the AX isolation check, not the OS. See §8.2.

### 2.3 No clipboard access

**Mechanism.** `NSPasteboard` is never referenced. Not to read, not to write. There is no copy
button anywhere: the export (§4.6) writes a file through `NSSavePanel`, and `--doctor` prints to
your terminal, so this property stays absolute rather than conditional.

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
below the window level (the app reads three attributes, `kAXFocusedWindow`, `kAXTitle` and
`kAXDocument`, and the AX isolation guard fails the build on any other, including one written as a
string) or AppleEvents
scripting of Mail/Messages. `NSAppleScript`, `OSAScript`, `AEDeterminePermissionToAutomateTarget`
are never referenced and `NSAppleEventsUsageDescription` is absent from `Info.plist`, so macOS would
show no Automation prompt and would deny any attempt.

**Check.**
```
plutil -p <APP>/Contents/Info.plist | grep -i AppleEvents    # expect no output
grep -rhoE 'kAX[A-Za-z]+' app/Sources | sort -u    # expect the three attributes and the two *ChangedNotification
```

### 2.6 No screenshots or screen contents

**Mechanism.** Screen capture on modern macOS requires the Screen Recording TCC grant, which is
triggered by `CGWindowListCreateImage`, `SCStream`/ScreenCaptureKit, or `CGDisplayStream`. None are
called and ScreenCaptureKit is not linked. The app does call `CGWindowListCopyWindowInfo`, in
`SystemStateCollector` for the full-screen hint and in `BreakOverlay` to confirm its own panel is on
screen, and reads only a window's owner, layer, bounds and on-screen flag from it. It never reads
`kCGWindowName`, which is the *other* common way to get window titles and would need Screen
Recording, so the app uses Accessibility instead and asks for the narrower thing. The app will never
appear in Screen Recording's permission list.

**Check.**
```
otool -L <BIN> | grep -Ei 'ScreenCaptureKit'                          # expect no output
nm -u <BIN> | grep -E 'CGWindowListCreateImage|CGDisplayStream|SCStream'  # expect no output
grep -rn 'kCGWindowName' app/Sources                                  # expect no output
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
at no other time: there is no schedule and no launch check. `SUEnableAutomaticChecks` is `false` in
Info.plist and the app writes `automaticallyChecksForUpdates = false` on every launch, because the
plist key is only a default and the live value lives where anything on the machine could flip it.
If an update is offered, pressing the second button fetches the archive itself.

This paragraph used to describe "a daily schedule only if you ticked the box in Settings → About".
There is no such box. The toggle was removed so the app could force the value off rather than
offer a switch that governed a network call, and there is no schedule. The claim outlived the
feature it described, which in this document is the one thing that must not happen.

**What the app's own binary can do: still nothing.** This is the part that survived intact and is
worth checking yourself. `sigstop`'s executable links no networking framework and references no
networking symbol — not `NSURLSession`, not `socket`, not `getaddrinfo`. All the network code is
inside `Sparkle.framework`. **The download runs in that framework, in this process.** This section
claimed the opposite until it was checked: Sparkle bundles `Downloader.xpc`, but only uses it when
the app sets `SUEnableDownloaderService`, which is meant for sandboxed apps and which Sparkle
advises against otherwise. sigstop does not set it.

What is out of process is the install. `Autoupdate` is a separate executable and always has been,
so the code that replaces the app on disk is never the code holding your Accessibility grant. The
transfer is, and saying otherwise was a claim this document had not earned.

**What is enforced by the OS: nothing, and that was already true.** The app cannot be sandboxed
(§3.6), so the absence of `com.apple.security.network.client` never guaranteed anything on its own —
an unsandboxed process may open sockets freely. What is real is the symbol-level absence above, the
signature gate below, and your own runtime monitor. §8.1 states this without softening it.

**What cannot be claimed.** An HTTPS request reveals your IP address and a timestamp to whoever
serves the file, which today is GitHub. Nothing the client does changes that. If that matters to
you, never press the button and download new releases yourself, or build from source. The app makes no request at all
unless you ask it to.

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
plutil -p <APP>/Contents/Info.plist | grep -E 'SUFeedURL|SUEnableAutomaticChecks|SUSendProfileInfo|SUVerifyUpdateBeforeExtraction'

# no server entitlement: nothing listens
codesign -d --entitlements - --xml <APP> | plutil -p - | grep network.server   # expect none

# while it is running and you have not pressed anything
sudo lsof -i -a -p "$(pgrep -x sigstop)"                                        # expect no sockets
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
  From 0.1.8 on, Sparkle verifies it **before** the archive is unpacked or installed; an installed
  0.1.7 or earlier unpacks its next update first and checks it before installing. A signature that does not
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
| The updater's own request | A `GET` can carry data in a query string, a header, a cookie, or a hostname | The feed URL comes from `Info.plist`, sealed by the code signature, and a delegate in `UpdateChecker.swift` returns it, so a `SUFeedURL` written into the app's defaults by another process is ignored and cleared at launch. The same delegate allows no system-profile keys, so no parameters are appended whatever the defaults say, refuses every check that is not a press of the button, and tells Sparkle not to fetch a release-notes link a feed might name. The app deletes its own cookie file before the updater starts, so a cookie a server sets lives at most until the app quits and cannot follow you from one run to the next; refusing cookies outright would link CFNetwork into the app's binary, which §2.7 says it never does. `Accept-Language` is the constant `en`, and the user agent is the literal `"sigstop"`, with no app version. Measured against a local feed with every one of those defaults planted: two presses sent two identical `GET`s with no query string, and a scheduled check was refused. `make verify` asserts `SUSendProfileInfo` is not set in the plist |
| A second endpoint | One allowed URL is checkable; two is a policy | `make verify` extracts every URL string from the binary and fails on anything that is not an allowlisted `github.com/Mohamed-Elshesheny/sigstop` browser link. The feed URL is not even in the binary — it is a plist key |
| `NSWorkspace.open(URL)` | Opening `https://collector/?data=…` in the browser exfiltrates without a socket in this process | Every call site passes one of three things. The link rows in Settings pass a compile-time constant from the `Links` enum in `SettingsView.swift`. **Open releases in browser** passes `Links.releases`, or, when the appcast marks a release information-only, the link that release carries, and that link is opened only if it is `https` on `github.com` under `/Mohamed-Elshesheny/sigstop/`; anything else opens `Links.releases`. `PermissionBroker.openAccessibilitySettings` passes a constant `x-apple.systempreferences:` URL for the Accessibility pane. The URL check above covers the constants. The appcast link arrives at runtime, so the scheme, host and path check is what bounds it |
| `Process` / `NSTask` / `posix_spawn` | Shelling out to `curl` | Forbidden symbols; not referenced anywhere in app code |
| `NSAppleScript` / `osascript` | Scripting another app into making the request | Forbidden symbols; no Automation usage string |
| `NSXPCConnection` to a helper | A helper could hold the network code | The app ships no helper of its own. `Sparkle.framework` carries two XPC services, and only one is used. `Downloader.xpc` ships but is idle, because `SUEnableDownloaderService` is not set, so the download runs in this process (§2.7). `Installer.xpc` launches the installer, because `SUEnableInstallerLauncherService` is `true`, and the install itself runs in the separate `Autoupdate` executable. `ls <APP>/Contents/Frameworks` shows exactly one framework |
| `dlopen` / plugin loading | Loading code not in the reviewed binary | The app loads no plugins and has one `@rpath`, `Contents/Frameworks`. The Hardened Runtime is on, so dyld refuses `DYLD_INSERT_LIBRARIES`. Library Validation is off in the ad-hoc build, which is the caveat below |
| Analytics SDK arriving as a transitive dependency | The usual way telemetry actually gets in | Sparkle has no dependencies of its own, and `make verify` greps the whole bundle against a list of ~25 analytics and crash-reporting SDKs by name |
| DNS via `CFHost` | Data in a hostname | Forbidden symbols; checked by `make verify` |

**The Hardened Runtime is on, and Library Validation is off, and here is why both.** Without the
runtime, dyld honours `DYLD_INSERT_LIBRARIES`, so any process running as you can start the app's
binary with its own code inside. macOS ties the Accessibility grant to the app's executable, not to
what the process loads, so that code would inherit the grant. This was measured: a harmless probe
library was injected into a build without the runtime and refused by one with it. `make verify`
fails if the runtime flag is missing, or if an entitlement that reopens injection
(`allow-dyld-environment-variables`), JIT, unsigned executable memory or debugging appears.

The runtime also turns on Library Validation, which refuses a library signed by a different Team ID.
An ad-hoc signature has no Team ID, so the app and the embedded `Sparkle.framework` count as
different teams and the app dies at launch with *"mapping process and mapped file (non-platform)
have different Team IDs."* So an ad-hoc build carries `com.apple.security.cs.disable-library-validation`,
added by `app/Scripts/bundle.sh` at signing time and only to a build with no Team ID. This document
used to call the absence of that entitlement a guard. It was not one: without the runtime, Library
Validation is not enforced whatever the entitlements say, so the old build had neither protection
and this one has the first. A Developer ID build has a Team ID, needs neither entitlement, and keeps
Library Validation on; `make verify` fails if it is disabled on such a build.

What is still open, and it is wider than a write to `/Applications`: any process running as you
can copy the app somewhere else, swap `Sparkle.framework`'s binary in the copy for its own, and run
the copy. Without Library Validation the swapped library loads, and the copy's executable is
byte-identical to yours, so if you granted Accessibility, macOS may treat the copy as the app you
granted. A copy modified this way still runs and passes the default runtime validity check; only a
static `codesign --verify --deep --strict` notices. The app cannot check for this itself, because
the swapped library runs before any of the app's code. The only fix is a Developer ID, which gives
the app and Sparkle a Team ID and lets Library Validation stay on. Until then, the honest advice is
this: grant Accessibility only if you accept that anything already running as you could
borrow it through a copy of this app.

---

### 2.10 No repository contents, and no command lines

Two Tier 2 collectors read things nothing else in the app reads: one file inside `.git/`, and the
process table. Both are off by default, each behind its own switch. Both are bounded by what the
code is *capable* of, not by what it chooses, which is the only kind of bound worth writing down.

**Mechanism, git.** The collector opens `<folder>/.git/HEAD`, reads **at most 512 bytes**, which is
one line, and matches `ref: refs/heads/<name>`. Forty hex characters, or sixty-four in a SHA-256 repository, is a detached HEAD and is
reported as one rather than presented as a branch name. A repository that keeps its refs in
reftable (`git init --ref-format=reftable`) has a `HEAD` that always reads `ref: refs/heads/.invalid`,
a name git itself refuses; the real one is in `.git/reftable`, which is never opened, so that line is
reported as a branch kept in a format sigstop does not read, never as a branch called `.invalid` and
never as a detached HEAD. One indirection is followed and only one: in
a git worktree or a submodule `.git` is a *file* holding a `gitdir:` line, so that line is read (a
trailing carriage return ignored, as git ignores it) and `HEAD` is taken from the directory it names, absolute for a worktree and resolved against the
containing folder for a submodule. That directory is followed only if, after resolving links, it is
a git directory: it holds a `HEAD` file and either an `objects` folder or a `commondir` file, which
is what git writes for a repository, a worktree, a submodule and a `--separate-git-dir`. A `.git`
that is itself a link is refused.
Every file is opened with `O_NOFOLLOW | O_NONBLOCK` and read only if it is a plain file, so a link
cannot point the read elsewhere and a FIFO cannot hold it open. Mid-rebase, `HEAD` is a detached sha
and the branch you are on is in `rebase-merge/head-name` (or `rebase-apply/head-name`), which is read
for the same reason and nothing else in that directory is.
Every other filesystem call opens nothing: `lstat` on `.git` and on the git directory, its `HEAD`,
`objects` and `commondir`, which is how a link is refused and a git directory recognised; one
`realpath` on a `gitdir:` target; `fstat` on a file already opened, to check it is a plain file; and
the four `access` checks in row 31, which return a `Bool`. `git` is never spawned: `Process`,
`NSTask` and `posix_spawn` remain forbidden symbols (§2.9), so shelling out is not something this
binary can do, whatever a future contributor intends.

**Mechanism, processes.** One `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_ALL)` returns the table.
`p_comm` is compared against the allowlist, `proc_pidpath` confirms the executable's location for
the few that matched, and the path is dropped. `KERN_PROCARGS2` is not called, so no command line,
no argument and no environment variable is ever in this process's memory. `proc_pidinfo` is not
called either, so no process's working directory is read. What survives one scan is a set of enum
cases and two booleans.

**Check.**

Each of these was run as written, and the output pasted under it is the real one. Two of them used
to be written in a way that returned hits on their own prose and then told you to expect none, which
is worse than not offering a check at all: the reader's first move is to run it, and the first thing
it does is look like the claim is false.

```sh
# argv, environment and working directories are never read. The names appear nowhere
# in the source, and the source carries no comments that could mention them:
grep -rn 'KERN_PROCARGS2\|proc_pidinfo\|PROC_PIDVNODEPATHINFO' app/Sources
#   (no output)

# git is never shelled out to. `Process(` on its own also matches methods NAMED
# ...Process( -- Ev.debuggerProcess(, Ev.testRunnerProcess(, Ev.aiCLIProcess( and
# friends -- so the pattern requires that nothing identifier-shaped precedes it.
grep -rnE '(^|[^A-Za-z0-9_.])Process\(|NSTask|posix_spawn' app/Sources
#   (no output)

# every path fragment the git collector can build, in one grep. Ten lines: eight carry
# the only names it ever appends, and two use a bare "/" as a separator
grep -n '\"/' app/Sources/SigstopSensors/Collectors/GitCollector.swift
#   224:            let inside = roots.filter { path == $0 || path.hasPrefix($0 + "/") }
#   269:            switch readFirstLine(gitDirectory + "/HEAD") {
#   287:        let dot = folder + "/.git"
#   303:            let target = raw.hasPrefix("/") ? raw : folder + "/" + raw
#   317:        guard kind("") == S_IFDIR, kind("/HEAD") == S_IFREG else { return false }
#   318:        return kind("/objects") == S_IFDIR || kind("/commondir") == S_IFREG
#   342:        for candidate in ["/rebase-merge/head-name", "/rebase-apply/head-name"] {
#   355:        if exists("/rebase-merge") || exists("/rebase-apply") { return .rebaseInProgress }
#   356:        if exists("/MERGE_HEAD") { return .mergeInProgress }
#   357:        if exists("/BISECT_LOG") { return .bisecting }
# names:  /.git  /HEAD  /objects  /commondir  /rebase-merge  /rebase-apply  /MERGE_HEAD
#         /BISECT_LOG  /rebase-merge/head-name  /rebase-apply/head-name

# and the bound on how much of any of those files is read, which is 512 bytes
grep -n 'headReadLimit' app/Sources/SigstopSensors/Collectors/GitCollector.swift
#   22:    private static let headReadLimit = 512
#   372:        var buffer = [UInt8](repeating: 0, count: headReadLimit)
#   374:            Darwin.read(descriptor, raw.baseAddress, headReadLimit)
```

If you would rather not take the source's word for it, the same two claims hold against the built
binary, which is what `make verify` checks for the networking ones: `nm -u dist/sigstop.app/Contents/MacOS/sigstop`
lists no `_posix_spawn`, no `_proc_pidinfo` and no `_NSTask`.

At runtime: `sudo fs_usage -w -f filesys $(pgrep -x sigstop)` and watch that the only paths outside
the bundle and the storage directory are the git names above, under `.git` in folders you
registered or in the git directory a `.git` file there names.

---

## 3. Permissions

### 3.1 Design principle

**The app must be fully functional, at reduced fidelity, with zero permissions granted.** This is a
hard requirement on the architecture, not an aspiration. Nothing in the break engine may depend on a
permission being present; every permission-gated signal enters through an optional and has a defined
`nil` behavior.

There is no single test named for it, and this paragraph used to cite one,
`AppTests/ZeroPermissionModeTests.swift`, that does not exist. What does exist: `SigstopCore` cannot
see a permission at all, so every engine test in `app/Tests/SigstopCoreTests`, driven by
`EngineHarness`, runs the break engine without one, because the engine takes none as input; and
`PermissionStatusTests` in `app/Tests/SigstopSensorsTests` asserts that at zero permissions everything
but the OS facts is off. No test stubs every provider to "denied" and runs a whole day end to end.

### 3.2 What is requested, and when

| Permission | TCC service | When asked | What it buys | If denied |
|---|---|---|---|---|
| **Notifications** | `UNUserNotificationCenter` | At the first break, not at launch | Reminders appear as system notifications, respect Focus modes and Notification Center | Fallback: a borderless `NSWindow` at `.statusBar` level that the app draws itself. Needs no permission. Slightly more intrusive, does not respect Do Not Disturb — so the app's own quiet hours setting becomes the only mute |
| **Accessibility** | `kTCCServiceAccessibility` | Never. The app does not raise the macOS alert. **Open System Settings** in Settings → Access opens the Accessibility pane, you grant it there, and the "Window titles" switch decides whether the grant is used | Window-title fidelity (inventory rows 12, 29 and 32): the app can avoid interrupting a live meeting and can tell a terminal from a browser inside the same app | Everything still works from app identity alone. The app may propose a break during a Zoom call, because it can see you are in Zoom but not that a meeting is in progress |
| **Login item** | `SMAppService` (not TCC) | Only from the settings toggle | Starts at login | Start it yourself |
| **Git context (Tier 2)** | None. Not a TCC service. What you grant is a folder | Never automatically. Only when you add a project folder in Settings → Access | The branch name, and whether a rebase, merge or bisect is in progress, for the folders you added | Nothing degrades. `branch` is `nil`, the templates that need `{branch}` become unselectable by construction (`docs/MESSAGE-ENGINE.md` §5), every other line still fires |
| **Process context (Tier 2)** | None. `sysctl(KERN_PROC_ALL)` needs no grant and produces no prompt | Never automatically. Only from its own switch in Settings → Access | `DEBUGGING` becomes reachable instead of collapsing into `CODING` | `CODING`, and the UI says it cannot tell whether you are debugging |

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
2. Reads `kAXFocusedWindowAttribute`, then exactly two attributes on the resulting window:
   `kAXTitleAttribute` and `kAXDocumentAttribute`. Both go through one `private` function
   (`AccessibilityCollector.copyString`), which is private so there is no public path that could
   be pointed at `kAXValue`.
3. Hands them to the provider that claims the frontmost app, which matches the title against its
   own patterns and returns an `Activity`. The document is reduced to a file URL, or — only with
   the separate Tier 1b opt-in — to a bare host.
4. Lets the strings go out of scope. Not written to disk, not logged, not sent anywhere, not
   retained. `AppModel.logFocusIfNeeded` writes `titleSignal: nil` on every focus event, so the
   log's `sig` field is never populated at all.

It does register one observer, only while Accessibility is granted.
`AccessibilityCollector.startObserving(pid:)` calls
`AXObserverCreate` on the frontmost app and subscribes to exactly two notifications,
`kAXFocusedWindowChangedNotification` and `kAXTitleChangedNotification`. The callback carries no
content: it only says that something changed, and the app then reads the same two attributes
again, so a window switch is noticed without polling. It is torn down when that app leaves the
front.

What it never does: no `AXUIElementSetAttributeValue` (never writes), no traversal into
`kAXChildrenAttribute`, no `kAXValueAttribute`, no `AXUIElementPostKeyboardEvent`. `.github/scripts/check-ax-isolation.py`
fails the build if Accessibility code appears outside `AccessibilityCollector.swift` and the trust
check in `PermissionBroker.swift`. It runs on every push; it is the check the old text claimed for a
shell script that did not exist.

Settings → Access says this in plain language, above the grant, before anyone presses anything:
"macOS cannot limit this permission to window titles. Granting it means trusting this code, not
the operating system." The same pane links to the one file that reads a window,
`app/Sources/SigstopSensors/Collectors/AccessibilityCollector.swift`, under "check it".

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

### 3.6 One build flavor, a second planned, and why

There is a genuine, unavoidable conflict: **an App-Sandboxed app cannot use the Accessibility API to
inspect other processes.** The sandbox denies the `com.apple.axserver` mach lookup, and the
exceptions that would restore it are not generally granted. So the choice is real:

- **Planned, not built: a sandboxed flavor.** `com.apple.security.app-sandbox` = true and no network
  entitlement, so no in-app updater and a kernel-enforced "no network". No window titles either,
  since the sandbox blocks the Accessibility API. Nothing in the source builds it yet: there is no
  sandbox entitlement and no compile flag for it.
- **Shipped: unsandboxed.** Window-title fidelity available, and the in-app updater described in
  §2.7 and §2.8. There is no kernel guarantee here and there never was: an unsandboxed process may
  open sockets freely regardless of entitlements. What holds instead is that the app's own binary
  contains no networking code, all of it lives in one named framework, and every update is
  signature-verified before it can install.

**This is the flavor this repository currently builds.** The sandboxed flavor is described above
because it is the intended second target, not because it exists yet; §8 says so.

Today there is one binary. If the sandboxed flavor is ever built, it will come from the same
source with the same CI guards. The unsandboxed build trades a kernel guarantee for window titles
and the updater, and this section is where that trade is written down.

---

## 4. Storage

### 4.1 Location

```
~/Library/Application Support/<BUNDLE_ID>/
```

That is the only location, because the unsandboxed build is the only one there is. The planned
sandboxed flavor (§3.6), if it is ever built, would keep its data under
`~/Library/Containers/<BUNDLE_ID>/Data/Library/Application Support/<BUNDLE_ID>/` instead.

Settings → Data prints the path in use, as text you can select and copy, so you never have to
guess. A few things live outside it, most of them left by the update check, in
`~/Library/Caches`, `~/Library/HTTPStorages` and `~/Library/Preferences`: inventory rows 33 to 36.

### 4.2 Layout

```
<storage root>/                        (mode 0700)
├── settings.json                      (mode 0600)  your preferences
├── badges.json                        (mode 0600)  which badges have unlocked, and when
├── counters.json                      (mode 0600)  today's budgets, overwritten in place
├── call-hold.json                     (mode 0600)  seconds the call hold has held today, overwritten in place
├── .lock                              (mode 0600)  empty; held while sigstop runs, so a second copy leaves
├── events/
│   ├── 2026-09-18.jsonl               (mode 0600)  append-only, one JSON object per line
│   ├── 2026-09-19.jsonl
│   └── 2026-09-20.jsonl
└── summaries/
    ├── 2026-09.json                   (mode 0600)  one object per day
    └── 2026-08.json.unreadable        only if that month stopped decoding; see below
```

`counters.json` holds the day's budgets: how many notifications have been delivered, when
the last one was, how many cycles in a row went unanswered, the compliance tallies, and the
next cycle number. It exists because those were rebuilt from nothing on every launch, so
the "notifications per day" setting was never a real constraint for anyone who restarts the
app. It is counts and one timestamp; it adds nothing to the inventory in §1.2 that the
event log does not already hold, and nothing in it says what you were doing. When a launch
cannot restore it (not there, will not open, will not decode), cycle numbers start again from 0,
so the app first withdraws every sigstop notification still showing, including any an earlier run
left: a prompt answered from an old banner must not reach a new cycle with the same number.

`summaries/YYYY-MM.json.unreadable` exists only if a month's file stopped decoding. The next
write moves the bad file aside instead of overwriting it, and a second failure in the same
month goes to `.unreadable-2`, then `.unreadable-3`, so nothing already set aside is replaced.
These files are never pruned and never read back, so badge evidence stops counting their days.
They are still the JSON they were, so a month can be repaired by hand and renamed back.
*Delete everything* removes them with the rest. A month file that is there but will not open at
all (another owner, a `chmod`, a disk error, a symbolic link) is not moved and not written: that
month's summary is not saved, and the menu bar says "Could not write the daily summary". The app
tries again with the next summary write, ten minutes later, or sooner when a break ends, the
screen locks or the Mac sleeps, and the message goes once that month is written. The exception is a
month that has just ended: once the new month's first day is saved it is not tried again, and the
message stays until the next launch.

`badges.json` and `counters.json` are never set aside. If one is there but will not open, the app
carries on from what it holds in memory, writes nothing over the file, posts no "unlocked" note
while the ledger is out of reach, and says in the menu bar which file it left as it is. It reads
the file again at the next launch. `badges.json` is treated the same way when it opens but will
not decode, a ledger written by a newer sigstop before a downgrade included, because it is the
only record of a badge whose evidence has been pruned. A `counters.json` that will not decode, or
holds impossible numbers, is only the day's budgets, so the app starts them fresh and the next
write replaces the file. A badge write that fails for any other reason says "Could not write the
badges", is tried again with the next summary write, and the message goes once one succeeds.

| File | There, but will not open | Opens, but will not decode |
|---|---|---|
| `summaries/YYYY-MM.json` | left as it is, that month is not written | moved aside to `.unreadable`, the month starts again |
| `badges.json` | left as it is, nothing written over it | left as it is, nothing written over it |
| `counters.json` | left as it is, nothing written over it | started fresh, replaced at the next write |

There is no database, no binary blob, no `.sqlite`, and nothing encrypted or encoded. Formats were
chosen so that `cat` is a complete audit tool.

### 4.3 What you see if you open the files

`events/2026-09-20.jsonl`, verbatim and complete — this is the entire event vocabulary,
and it is checked against `EventKind` rather than written from memory. It drifted once:
`break_open`, `break_begin` and `break_end` shipped without appearing here, which made a
document that claims to be exhaustive quietly incomplete. Adding a kind without adding it
below is a bug, not a documentation chore: `docs/` is kept in sync in the same PR as the behaviour
change ([CONTRIBUTING.md](../CONTRIBUTING.md#commits-and-prs)).

```
{"e":"start","t":"2026-09-20T08:58:03Z","v":1}
{"act":"coding","app":"com.apple.dt.Xcode","cat":"code","e":"focus","t":"2026-09-20T08:58:03Z","v":1}
{"act":"browsing","app":"com.google.Chrome","cat":"browse","e":"focus","t":"2026-09-20T09:14:41Z","v":1}
{"e":"idle_begin","t":"2026-09-20T09:31:02Z","v":1}
{"e":"idle_end","idle_s":378,"t":"2026-09-20T09:37:20Z","v":1}
{"act":"communication","app":"us.zoom.xos","cat":"other","e":"focus","t":"2026-09-20T09:48:10Z","v":1}
{"cycle":4,"e":"break_open","t":"2026-09-20T10:19:55Z","v":1}
{"cycle":4,"e":"gate","gate":"audioInputInUse","t":"2026-09-20T10:20:00Z","v":1}
{"cycle":4,"e":"gate","gate":"delivered","t":"2026-09-20T10:34:07Z","v":1}
{"cycle":4,"e":"break_prompt","reason":"SIGTSTP","t":"2026-09-20T10:34:12Z","v":1}
{"action":"snoozed","cycle":4,"e":"break_response","snooze_s":300,"t":"2026-09-20T10:34:31Z","v":1}
{"action":"taken","cycle":4,"e":"break_response","t":"2026-09-20T10:39:31Z","v":1}
{"cycle":4,"e":"break_begin","origin":"accepted","t":"2026-09-20T10:39:31Z","v":1}
{"cycle":4,"dur_s":303,"e":"break_end","origin":"accepted","plan_s":300,"t":"2026-09-20T10:44:34Z","v":1}
{"cycle":4,"e":"cycle_close","outcome":"honored","t":"2026-09-20T10:44:34Z","v":1}
{"e":"lock","t":"2026-09-20T10:52:04Z","v":1}
{"e":"unlock","t":"2026-09-20T11:31:55Z","v":1}
{"e":"stop","t":"2026-09-20T18:02:11Z","v":1}
```

Field reference:

| Field | Type | Meaning |
|---|---|---|
| `v` | int | Schema version. Bumped on any breaking change; readers reject unknown majors |
| `t` | string | ISO-8601 UTC, second resolution. Sub-second precision is deliberately discarded |
| `e` | string | One of: `start`, `stop`, `focus`, `idle_begin`, `idle_end`, `lock`, `unlock`, `sleep`, `wake`, `display_sleep`, `display_wake`, `session_out`, `session_in`, `break_open`, `break_prompt`, `break_response`, `break_begin`, `break_end`, `cycle_close`, `gate` |
| `app` | string? | Bundle identifier. Absent when the frontmost app has none. There is no switch that turns it off |
| `cat` | string? | One of `code`, `browse`, `meet`, `other`, chosen in `AppModel.category(for:)` from the app's family. `meet` is the chat family, Slack and Discord; Zoom and Teams have no family of their own in `AppKey` and log `other` |
| `act` | string? | The activity inferred at that moment (`context.activity`), one of the `Activity` raw values such as `coding`, `browsing` or `communication`, and `unknown` when it could not tell. **With Tier 1 on it can be decided by the window title**: a browser tab titled `Pull Request #12` logs `codeReview` (§1.5, inventory row 32) |
| `sig` | string? | Title signal. In the schema, but the shipping app never writes it: `AppModel.logFocusIfNeeded` passes `titleSignal: nil`. **Never the title itself** |
| `idle_s` | int? | Length of the idle period that just ended |
| `cycle` | int? | Which break opportunity this line belongs to, so counters scope to a cycle |
| `origin` | string? | How a break started: `accepted`, `idleInferred`, `userInitiated` |
| `dur_s` | int? | Measured length of a break, in seconds |
| `plan_s` | int? | The length that break had to reach to count, in seconds. `dur_s >= plan_s` is the whole verdict, so the line can be re-judged without knowing what your settings were when it was written |
| `outcome` | string? | On `cycle_close`, how the opportunity ended: one of the six `CycleOutcome` values |
| `gate` | string? | On `gate`, why a prompt was or was not allowed: one of the twenty-nine `GateReason` values |
| `reason` | string? | On `break_prompt`, the signal that rung is named after: one of `SIGTSTP`, `SIGINT`, `SIGTERM`, `SIGSTOP` |
| `deferred` | string? | On `break_prompt`, why it was withheld: one of the `GateReason` values |
| `action`, `snooze_s` | | Break engine bookkeeping |

Every one of those is a fixed enum or a number in the source, apart from three strings: `app`
holds a bundle identifier, `category` is one of four fixed words chosen from the app's family,
and `sig` is written as `nil` on every focus event (§1.5). That matters more than it looks,
because the claim here is that nothing in `LoggedEvent` carries a window title. `reason` and
`deferred` were `String?` and quietly were that field. They are `SignalName?` and `GateReason?`
now, with the same words on disk, so old logs still parse and the claim is true again.

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
  a file path or anything you typed**, which is the guarantee "Never read content" asks for
  ([the rules a PR cannot break](../CONTRIBUTING.md#the-rules-a-pr-cannot-break)). Every
  other field here carries it too, except `act`, which a title can decide (§1.5).

  Three of the twenty-nine — `userSnoozed`, `userAway`, `breakRunning` — are not gate
  answers at all. They exist because the ten minute rule above was a claim the code did not
  keep: a snooze, an idle suspension and a running break each hold a cycle open while the
  gate is never asked, so the heartbeat had nothing to write and a thirty minute snooze
  produced thirty minutes of nothing. A reader following the rule would have concluded the
  app had died. These three name the silence instead, and are written on the heartbeat
  only, because the transition into each of those states already has its own line
  (`break_response`, `idle_begin`, `break_begin`).

`summaries/2026-09.json`, as `FileEventStore.writeSummary` wrote it for a made-up morning in three
apps with invented bundle identifiers. A real file holds one such object for every day the app ran
that month:
```json
{
  "days" : {
    "2026-09-20" : {
      "activeWorkByActivity" : {
        "browsing" : 1631,
        "coding" : 5515,
        "communication" : 830
      },
      "applicationDistribution" : {
        "com.example.browser" : 1631,
        "com.example.chat" : 830,
        "com.example.editor" : 5515
      },
      "breakCount" : 1,
      "breakOpportunities" : 1,
      "breaksAbandoned" : 0,
      "breaksAccepted" : 1,
      "breaksIdleInferred" : 0,
      "breaksUserInitiated" : 0,
      "day" : "2026-09-20",
      "excludedOpportunities" : 0,
      "honoredOpportunities" : 1,
      "ignoredPromptCount" : 0,
      "longestContinuousSession" : 3000,
      "malformedLines" : 0,
      "notificationsDelivered" : 1,
      "sessionCount" : 1,
      "skippedBreakCount" : 0,
      "snoozeCount" : 1,
      "totalActiveWork" : 7976
    }
  },
  "v" : 1
}
```

Every duration is in seconds. `applicationDistribution` is the seconds of active work in each app,
keyed by **bundle identifier**, and `activeWorkByActivity` the same seconds keyed by `Activity` raw
value. So this file is a record, for every day, of which apps you worked in and for how long. It is
kept until *Delete everything* (§4.5), it is not in the export (§4.6), and like everything else here
it never leaves the Mac. Nothing uses the per-app or per-activity seconds once they are on disk.
The file is read back only to add a day to it and to count badges, which use the counts and the
day's totals, and the menu bar shows the day's top app from the summary it computes in memory. They
are on disk because the summary is written whole, not because anything needs them there.

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
crashes the app and never silently changes your history. A day file that is there but will not
open, or opens and then fails to read, is not read as an empty day. When today's numbers need it, the menu bar says "Could not read
the event log for" that day, `--doctor` says the same, and no summary is computed from the gap,
so a good one is never replaced by zeros. The export names every such day.

**On ordering.** `t` is when the event happened, not when the line was written, and the
file is in write order. A session end is discovered after the fact and carries the timestamp
of the gap it describes, so a line stamped `04:23` can appear after one stamped `04:33`. That
is the contract, not a bug: the app never rewrites a line and never holds one back to make the
file look tidier, because either would mean buffering in front of a log you are invited to
`cat`. Everything that reads these files sorts by `t` first, and so should you.

### 4.4 The writer

The writer is `FileEventStore` in `app/Sources/SigstopCore/Storage/FileStore.swift`, behind the
`EventStore` protocol in `Store.swift`. A line is a `LoggedEvent` from `EventLog.swift`, encoded by
`EventLogCodec`. `append(contentsOf:)` groups events by their UTC day and hands each day's lines to
`SecureFile.append` in `SecureFile.swift`:

```swift
public static func append(_ data: Data, to url: URL) throws {
    let fd = open(url.path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else {
        throw StoreError.notWritable(path: url.path, reason: String(cString: strerror(errno)))
    }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0,
          info.st_mode & S_IFMT == S_IFREG,
          info.st_uid == getuid(),
          info.st_nlink == 1
    else {
        throw StoreError.notWritable(path: url.path, reason: "not a plain file of yours")
    }
```

The rest writes a newline if the file does not already end in one, then the lines, then `fsync`.
Append-only with `0600`, one file per day, so retention is a file deletion rather than a rewrite.
The file is opened without following a link and must be a plain file you own with one name, so a
link planted in the folder cannot steer the write elsewhere. Every other file here (settings,
counters, summaries, badges, the call hold) is written to a temporary file created with
`O_EXCL | O_NOFOLLOW` and renamed over the old one, which replaces a link rather than writing
through it.

### 4.5 Retention

| Data | Kept |
|---|---|
| Raw events | 7 days |
| Daily summaries, including the seconds spent in each app by bundle identifier | until *Delete everything* |
| Summary months set aside as `.unreadable` | until *Delete everything* |
| Unlocked badges | until *Delete everything*, see below |

The seven days are `Retention.defaultEventDays`, a constant. There is no retention setting in
`settings.json`. This section used to offer one, with a range of 0 to 365 days, a memory-only
mode, a 90-day window for summaries and a debug title ring. None of that was built, and nothing
prunes a summary.

So the seven days bound the event log, not what the app knows about which apps you used. Each day's
summary keeps the seconds of active work per bundle identifier and per activity (§4.3), for every
day the app ran, until *Delete everything*. It never leaves the Mac, and there is no switch that
stops it being written.

Pruning runs at launch and then once an hour, measured on the continuous clock. The rule is
one-sided: a day file is deleted only when its date is older than the window. This is the real
code, `PruneMath` in `app/Sources/SigstopCore/Storage/Store.swift`:

```swift
public static func cutoffDay(retentionDays: Int, asOf now: Date) -> CalendarDay? {
    guard retentionDays > 0 else { return nil }
    let today = CalendarDay.utc(of: now)
    return today.adding(days: -(retentionDays - 1))
}

public static func shouldDrop(_ day: CalendarDay, cutoff: CalendarDay?) -> Bool {
    guard let cutoff else { return true }
    return day < cutoff
}
```

Day files are named by their UTC date, so today and the six days before it survive. Because only
the old side is pruned, a clock running slow can only delete less than it should. A day dated
after today is never deleted, because that would trust today's clock over the file, and a slow
clock would then delete real days. It is kept until its date passes, and `--doctor` lists it under
"dated ahead". A clock that is ahead is the case this cannot protect: it moves the window forward
and prunes days that are still inside the real one. `RetentionTests` pins the window, a clock
three days behind, a clock reset to 2001, and a day dated 2030 that is kept and reported.

`badges.json` is deliberately not pruned either. Pruning it would mean a badge vanishing a week
after it was earned, which is the opposite of what a record of something you did is for. It stays
a few hundred bytes whatever happens, since ten ids and ten dates is its maximum size, and "Delete
everything" removes it with the rest, because delete means delete.

### 4.6 Export and delete

**Export** (one button in Settings → Data, `NSSavePanel`, no permission needed): writes one text
file. A commented header names the schema version, the source folder, the day range and every field
the log can hold; under it, grouped by day, is every event that parses, one JSON object per line.
It is the log as sigstop reads it, not a byte copy, and the header says so: each line is written
back out by this version, so a field it does not know is dropped; the lines are put in time order
within their day, where the day file is in write order (§4.3); and a line that does not parse is
left out: the header says how many and on which days, and the report in Settings says how many. A
day file that will not open is named at the end. For the bytes themselves, `cat` the files in
`events/`. Settings, badges and the summaries are not in it: they are the plain files in §4.2, and
`cat` is the export for those.

**Delete everything** (the **Delete my data…** button in Settings → Data, one confirmation):
removes everything in the storage directory, the settings file with it, except its empty `.lock`:
that stays held for the whole run, so a second copy started meanwhile still sees sigstop running and
leaves. A `.lock` that is not a plain file goes with the rest, and the app takes a new one at once.
It withdraws every sigstop notification still showing, an earlier run's too, unregisters the login
item if it is registered, puts the default settings back everywhere they apply (the break policy, the sensors,
the permission status), resets the call hold's daily total and the in-memory counters (a hold that is
running keeps running, so a call you declared is still protected), and reports what it
removed. The app keeps running, so the report says a new, empty log starts at once. It also tells
you the two things the app cannot clean up itself, because no app can:

```
Deleted: ~/Library/Application Support/<BUNDLE_ID>  (23 files, 412 KB)
Kept: its .lock, which is empty and held while sigstop runs, so a second copy leaves.
Removed 555 events across 7 day(s).
sigstop is still running, so a new, empty log starts from now.

Two things this app cannot remove for you:
  • The Accessibility permission you granted. Remove it in
    System Settings → Privacy & Security → Accessibility,
    or run:  tccutil reset Accessibility dev.sigstop.app
  • What the system log holds about the app: what macOS logged, such as
    launches and permission checks, and what the updater logged. None of
    it comes from sigstop's own code, which writes nothing there.

There is no archive, no tombstone, no soft delete, and no copy kept anywhere.
Removed: the login item.
```

The last line appears only when the login item was registered. If macOS refuses to remove it,
that line says so and names System Settings → General → Login Items instead.

What it does not remove, and the report does not mention, is everything outside the storage
directory in inventory rows 33 to 36: Foundation's cache of the appcast, the app's HTTP storage and
cookie file, Sparkle's staging folders and the app's UserDefaults, including the time of your last
update check.
With the app quit, these remove them:

```
defaults delete <BUNDLE_ID>
rm -rf ~/Library/Caches/<BUNDLE_ID> ~/Library/Caches/<BUNDLE_ID>.sparkle
rm -rf ~/Library/HTTPStorages/<BUNDLE_ID> ~/Library/HTTPStorages/<BUNDLE_ID>.binarycookies
```

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
| When | Only when you press **Check for updates**. There is no schedule and no launch check |
| At launch | Never |
| What is sent | A plain `GET`. No query string, no body, no cookie kept from an earlier run (the app deletes its cookie file at launch), no account, no install id, no machine id, no system profile, `Accept-Language: en` whatever your language is, and a user agent overridden to the constant `sigstop`, not even the app version |
| What is stored about it | Nothing in the app's own files, and there is no server side to this codebase. On your Mac, Sparkle records the time of the last check in UserDefaults and Foundation caches the file under `~/Library/Caches` (inventory rows 33 to 36) |
| What it necessarily reveals | Your IP address and the time of the request, to whoever serves the file. This cannot be avoided by any client |
| What protects the download | EdDSA signature verification against a public key compiled into the app. See §2.8 |

This position is weaker than the one this document held before the updater existed, and the earlier
text is not being quietly edited to pretend otherwise. §5.3 is the argument for the change, kept
next to the argument it replaced.

### 5.2 Is opt-in analytics worth it? Recommendation: no.

The case for it is real. Without any telemetry the maintainers do not know which macOS versions are
in use, how often the AX path fails on a given app, or whether the default 45-minute interval is
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
- **`--doctor`** (`make doctor`, or the app's executable run with `--doctor`) prints to your
  terminal what the app can observe right now: the settings that shape a break, each permission
  and switch, every signal it reads and what it inferred from them, and where it stores data. You
  read it, you decide, you paste what you choose into a GitHub issue yourself. The app never
  transmits it and never puts it on the pasteboard. This bullet used to describe a
  "Save Diagnostics Report…" command that was never built.
- Product questions get answered in the repository's discussions, where the sample is
  self-selected but at least honest about being so.
- Defaults are argued for in `docs/BREAK-DECISION.md` §3.3 and §4.2 with the reasoning visible,
  rather than tuned by telemetry nobody can inspect. There is no `docs/DECISIONS.md`; this bullet
  used to name one.

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
| "reveals your app version" | Answered. The user agent is overridden to the constant `sigstop`, and the updater's delegate allows no system-profile keys. The version comparison happens on your machine against a file that is the same for everyone |
| "on a schedule that correlates with when your machine is awake" | Answered outright. There is no schedule. The app writes Sparkle's scheduling flag off on every launch, so there is no daily check, no launch check and no toggle that could turn one on |
| "reveals your IP address and a timestamp" | **Admitted. Not fixable.** Any HTTPS request does this. If it matters to you, never press the button, and download releases yourself. Nothing else in the app will make the request for you |
| "to a server that can log it" | Admitted, and defanged where it counts: the server cannot make you install anything, because of §2.8 |

**What did NOT change.** There is still no telemetry, still no payload, still nothing about you in
the request. "The app can now fetch an update" is not a licence for "the app can now report."
§5.2 is still a no.

**The other routes still exist and are still the most private option.** Downloading from GitHub
Releases and building from source both work, and in both cases the network request is made by a tool you chose at
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

The sandboxed flavor is planned, not built (§3.6), so there is no bundle to run this against. If it
is built, this is what it should carry, in full:
```xml
<key>com.apple.security.app-sandbox</key><true/>
```
That would be the entire list. In particular these must be **absent**:
`com.apple.security.network.client`, `com.apple.security.network.server`,
`com.apple.security.files.all`, `com.apple.security.device.camera`,
`com.apple.security.device.microphone`, `com.apple.security.personal-information.*`,
`com.apple.security.automation.apple-events`,
`com.apple.security.cs.allow-unsigned-executable-memory`,
`com.apple.security.cs.allow-dyld-environment-variables`.

The shipped, unsandboxed build: the entitlements file is almost empty by design. It holds one key,
`com.apple.security.automation.apple-events`, set to `false`. The signed app carries a second,
`com.apple.security.cs.disable-library-validation`, which `bundle.sh` adds to a build with no Team ID
(§2.9). `make verify` checks that `com.apple.security.network.server` is absent (nothing listens),
that the Hardened Runtime is on, and that nothing reopens injection, JIT or debugging. Without the
App Sandbox, the absence of `network.client` is not meaningful and this document does not pretend it is.

Also confirm the signature:
```bash
codesign -dv --verbose=4 "$APP"      # TeamIdentifier, and whether the runtime flag is set
spctl -a -vvv "$APP"                 # see the note below before reading anything into this
```

**Do not expect `spctl` to say "Notarized Developer ID" for a build from this repository.** The app
is ad-hoc signed — no Developer ID, no Team ID and no notarization. The Hardened Runtime is on, and
Library Validation is off because there is no Team ID to validate against (§2.9). That is a real gap and it is why update integrity rests on Sparkle's
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
`Foundation`, `CoreGraphics`, `CoreFoundation`, `CoreAudio`, `CoreMediaIO` (the camera's in-use
flag), `IOKit`, `UserNotifications`, `ServiceManagement`, `ApplicationServices`, `SwiftUI`,
`libobjc`, `libSystem`, and the Swift runtime libraries.

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
nm -u "$BIN" | grep -E 'CGEventTap|CGWindowListCreateImage|CGDisplayStream|SCStream|SecItem'
strings -a "$BIN" | grep -E '^https?://' | sort -u
```

All of the above should produce no output except the last, which should show only links into
`github.com/Mohamed-Elshesheny/sigstop`, the ones the app hands to your browser. On the current
build that is six: the repository, the Accessibility collector's source, this document, the
new-issue page, the releases and the docs folder.

```
https://github.com/Mohamed-Elshesheny/sigstop
https://github.com/Mohamed-Elshesheny/sigstop/blob/main/app/Sources/SigstopSensors/Collectors/AccessibilityCollector.swift
https://github.com/Mohamed-Elshesheny/sigstop/blob/main/docs/PRIVACY.md
https://github.com/Mohamed-Elshesheny/sigstop/issues/new/choose
https://github.com/Mohamed-Elshesheny/sigstop/releases
https://github.com/Mohamed-Elshesheny/sigstop/tree/main/docs
```

Note what is *not* in that list: the update feed URL. It is not a string in the executable at all;
it lives in `Info.plist` as `SUFeedURL`, where `plutil -p` will show it to you.

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
PID=$(pgrep -x sigstop)
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

**This section used to describe a different repository.** It printed a source tree with an
`Observation/` folder, a `Storage/` folder, a top-level `Links.swift`, a `scripts/`
directory holding four `verify-*.sh` guards, and a `.github/workflows/privacy-guard.yml`
described as a required check. Two of the four scripts were printed here in full, "so you
can run it before you trust CI". None of it existed, at any point. A reader who did the
thing this section asks them to do found four hundred lines of fiction, which costs more
than the section was ever worth. What is below is the tree that is there.

```
app/Sources/
├── SigstopCore/                      pure domain. Imports no macOS UI framework at all
│   ├── Model/                        Activity, Confidence, Evidence, Settings
│   ├── Session/                      the work clock, and the gap classifier
│   ├── Decision/                     the engine: when a break is due and when it is not
│   ├── Message/                      template selection, and corpus.json
│   ├── Badges/                       the ten, and the ledger
│   ├── Storage/                      EventLog, the daily summaries, retention
│   └── Summary/                      the rollup behind the uptime panel
├── SigstopSensors/                   the ONLY layer that touches a macOS API
│   ├── Collectors/
│   │   ├── AccessibilityCollector.swift   ← the only AX reading in the project
│   │   ├── GitCollector.swift             ← one open+read of .git/HEAD, Tier 2
│   │   └── ProcessCollector.swift         ← one sysctl, allowlisted names, Tier 2
│   ├── PermissionBroker.swift        asks whether the grant exists. Asks, never reads
│   ├── ContextEngine.swift           builds one sample and publishes it
│   └── Providers/                    pure functions: a SignalContext in, a verdict out
├── SigstopApp/                       menu bar, break overlay, settings, updates
│   ├── UpdateChecker.swift           the one place Sparkle is spoken to
│   ├── Doctor.swift                  what `--doctor` prints
│   └── Views/                        SettingsView carries every URL the app can open
└── Scenarios/                        scripted days run against the real engine

app/Scripts/verify.sh                 the guard. Runs in CI on every push
.github/scripts/check-ax-isolation.py keeps Accessibility in the two files named above
.github/scripts/check-forbidden-apis.py no clipboard, screen, keys, processes or AppleScript
.github/scripts/check-corpus.py       the humour rails, docs/MESSAGE-ENGINE.md §4
.github/workflows/ci.yml              runs all of the above, plus the test suite
```

**Start with `AccessibilityCollector.swift` if you are suspicious.** It is the only file in
the repository that reads anything through the Accessibility API, and that is a property
somebody checks rather than a sentence somebody wrote:

```sh
python3 .github/scripts/check-ax-isolation.py
```

It fails if an AX symbol appears in any other file, if `PermissionBroker.swift` does
anything beyond asking whether the grant exists, or if the collector asks an element for
an attribute that is not on its allowlist. That last one is the point: adding an attribute
widens what the app can see, so it has to be argued for in §1.5 and allowlisted in the
same pull request. All four of those failure modes were tested by breaking the tree on
purpose and watching the check catch them.

**The guard that runs against the built binary** is `app/Scripts/verify.sh`, and it is not
printed here, for the same reason the old scripts should not have been: a copy of a script
in a document is a copy that goes stale. Read it, or run it:

```sh
cd app && make verify-shipped
```

It asserts, against the bundle rather than the source: no networking framework linked into
the app's own binary, no networking symbol referenced, exactly one embedded framework, no
analytics SDK, no network-server entitlement, that `SUPublicEDKey` is a real Ed25519 key,
that no private key is anywhere in the repository, that the feed URL is HTTPS, that every
URL string in the binary is an allowlisted link to this repository, and that nothing
schedules an update check on its own.

`verify-shipped` rather than `verify` on purpose. The shipped image carries two
architectures, and `nm` and `otool` read only the native one by default, so a symbol
present in the Intel half alone used to come back clean. The script splits the binary and
runs every assertion against each slice.

### 6.5 Reproducible builds

What is offered, honestly:

- There is no `make verify-build`, no `SOURCE_DATE_EPOCH` and no pinned Xcode. This bullet used to
  promise all three.
- The release notes publish no hashes. They are generated from commit subjects and hold nothing
  else (`docs/RELEASING.md` §0.5). `make dmg` and `release.sh` print the SHA-256 of the image
  they built.
- The hash you can try to reproduce is the main binary's with its signature stripped:
  `codesign --remove-signature` on a copy, then `shasum -a 256`. The image's hash can only be
  compared, not recreated.

What cannot be promised: bit-identical signed artifacts, and full independence from Apple's
toolchain. Swift's compiler is not guaranteed deterministic across patch releases, so a mismatch may
mean "different Xcode" rather than "tampered". The release notes cannot record the toolchain build
number, because they hold only commit subjects. See §8.7.

---

## 7. Threat model

Scope: a local-first app with no server and no accounts. Excluded from scope, because no app-level
design defends against them: a compromised macOS kernel, a root-level attacker, a malicious Xcode
toolchain, and physical access to an unlocked machine.

| # | Threat | Actor | Structural defense | Residual risk |
|---|---|---|---|---|
| 1 | A contributor adds an analytics or "crash reporting" call | Maintainer under commercial pressure, or a contributor | `make verify` fails on any networking symbol in the app's own binary, on any URL literal outside the allowlist, and on ~25 analytics and crash-reporting SDKs by name, checked against the built bundle | Someone with merge rights can also edit the check. There is no `CODEOWNERS` file, so nothing but review protects `app/Scripts/verify.sh`; it runs in CI on every push, so an edit to it is at least visible |
| 2 | A dependency ships a malicious update | Upstream package | **Exactly one third-party runtime dependency: Sparkle, pinned with `exact:` rather than a range, so a new upstream tag cannot enter a build without a commit that says so.** It is attached to `SigstopApp` only; `SigstopCore` and `SigstopSensors` remain dependency-free, and `make verify` asserts Sparkle is the only embedded framework | A malicious Sparkle release that someone then deliberately bumps to. Mitigation is the pin plus review of the bump. The argument for admitting the dependency at all is §2.8, and the rule it had to clear is "One dependency" in [the rules a PR cannot break](../CONTRIBUTING.md#the-rules-a-pr-cannot-break) |
| 3 | Code is loaded at runtime that was never reviewed | Another process running as you, or one that can write to the bundle | The Hardened Runtime is on, so `DYLD_INSERT_LIBRARIES` is refused, and `make verify` fails if the runtime flag goes or `allow-dyld-environment-variables`, `allow-unsigned-executable-memory` or `get-task-allow` appears. One `@rpath`, `Contents/Frameworks`. No `dlopen`, no plugin directory, no bundle loading, no JavaScriptCore | Library Validation is off in the ad-hoc build, because it cannot load the embedded framework without a Team ID (§2.9). A process that can rewrite the bundle in `/Applications` could replace a library inside it and keep the Accessibility grant, which replacing the executable would lose. A Developer ID would close this |
| 3b | A malicious update is served to users | Attacker who compromises GitHub, the CDN, or the network path | **EdDSA signature verification (§2.8).** The private key is in the maintainer's login keychain only; the public key is compiled into the app; Sparkle refuses an archive whose signature does not verify | Theft of the private key. Rotation does not reach installs that already hold the old public key. `docs/RELEASING.md` §6 |
| 4 | A malicious **message pack** exfiltrates or executes | Contributor, or a user installing a third-party pack | Packs are data, not code: strict JSON, schema-validated on load, string fields only, length-capped. No URLs, no format specifiers, no templating engine, no HTML — text is rendered into `NSAttributedString` with attributes disabled. A pack cannot cause a network call: the app's own binary has no networking code at all, and the only URL the bundle can fetch is the compile-time feed constant | A pack could still contain hostile or manipulative *text*. Defense is review: packs ship only in-tree, every pack change requires a human review, and third-party packs are not loadable from disk in the default build |
| 5 | The Accessibility grant is abused to read message/document contents | Malicious future version of the app | `.github/scripts/check-ax-isolation.py` in CI; the AX code is two files and one `private` reader that touches two attribute constants; the permission is off by default | **Real and unavoidable.** If you grant Accessibility, a future build could read anything. Defenses are social (review, reproducible hashes) not technical. Two of the mitigations this row used to claim — a shell script and a raw-title debug ring — did not exist. See §8.2 |
| 6 | Exfiltration without a socket (open a URL, spawn `curl`, AppleScript another app) | Contributor | `.github/scripts/check-forbidden-apis.py` fails CI on `Process`, `NSTask`, `posix_spawn`, `NSAppleScript`, `NSPasteboard` and screen capture in the source, and `make verify` checks the binary for the same symbols; the URL-literal allowlist in `make verify` catches a smuggled collector endpoint. `NSWorkspace.open` is called with a `Links` constant, the Accessibility pane's constant URL, or an appcast link that must be `https` on `github.com` under `/Mohamed-Elshesheny/sigstop/` (§2.9) | A URL assembled at runtime from string fragments could evade the literal check, and nothing but review stops a new `NSWorkspace.open` call site: no check counts them |
| 6b | Exfiltration *through* the update request | Contributor, or another process writing the app's defaults | The feed URL is a plist constant with no query string, pinned by a delegate so a defaults override is ignored; the delegate allows no system-profile keys and refuses release-notes fetches and background checks; the cookie file is deleted at launch; the user agent is overridden to a constant carrying no version; there is no second endpoint and the allowlist check fails if one appears | A contributor could add a delegate that appends feed parameters. That would be a visible code change to one file, and would have to survive review against this row |
| 7 | Another local process reads the event log | Malware running as the user | Files are `0600` in a `0700` directory. Nothing else: the app is not sandboxed, so there is no container and no sandbox protection on it (§3.6) | Any process running as you can read your files. App-level encryption would not help, because the key would have to be available to the app as the same user. FileVault is the real defense. See §8.5 |
| 8 | Supply-chain attack on the release artifact | Attacker with repo or CI access | **EdDSA signing, done on the maintainer's machine from a key that is never in the repository or in CI.** An attacker with full repository and CI access can therefore publish a release and still cannot produce an update an installed copy will accept. A first download is different: it is whatever the release page serves, so it rests on GitHub alone. The release notes carry no hashes (§6.5). | A compromised signing key defeats this. There is no Developer ID and no notarization to fall back on (§8.1), so the EdDSA key is the single point of failure and is treated as one in `docs/RELEASING.md` |
| 9 | Data reconstruction from an old backup | Anyone with your Time Machine disk | Raw events are kept 7 days; the storage path is an ordinary user path, so it honors any backup exclusions you set | The daily summaries, with the seconds spent in each app, are kept until you delete them, so a backup holds every day up to when it was made. The app does not and should not set backup exclusions on your behalf. Documented, not defended |
| 10 | Someone infers sensitive facts from your event log or the daily summaries (therapy appointments, job hunting) | A person with access to your machine | Bundle IDs and closed-vocabulary fields (one of which, `act`, a title can decide under Tier 1), not titles or URLs; seven days of events; one-click delete; every file is human-readable so you can see the inference risk yourself | Bundle IDs alone can be revealing (a job-board app, a health app). There is no switch that stops them being logged. The event log keeps them seven days, but the daily summaries keep the seconds spent in each app, by bundle ID, for every day, until *Delete my data…* (§4.5). Deleting is what there is |

---

## 8. Limitations, stated plainly

These are the places where an honest answer is "we cannot prove that."

**8.1 The app makes one network request, and nothing in the OS stops it making others.** The app is
unsandboxed, and the sandboxed flavor in §3.6 is planned, not built, so `com.apple.security.network.client` being absent means nothing to the
kernel — unsandboxed processes may open sockets freely, entitlements or not. That was already true
before the updater existed; what changed is that there is now something in the bundle that uses the
freedom. What holds the line instead is checkable but static: the app's own binary references no
networking symbol, the only network code is one named and versioned framework, the only endpoint is
a plist constant, and `make verify` fails on any of those changing. A runtime monitor is the only
conclusive test, and it only proves what happened while it was watching.

**8.1b The update channel reveals your IP address and the time you checked.** Not to this project —
there is no server here — but to GitHub, which serves the file. No client-side choice avoids it. If
that matters, never press the button, and download releases yourself or build from source. The app
makes no request at all unless you ask it to.

**8.1c The EdDSA private key is a single point of failure.** Update integrity rests entirely on it,
because the build has no Developer ID and no notarization to fall back on. If it is stolen, an
attacker can sign updates that every installed copy will accept, and rotating the key does not reach
anyone already running an older build — they verify against the key compiled into the copy they
have. `docs/RELEASING.md` §6 describes what a rotation would actually involve, which is mostly
"tell people to reinstall by hand."

**8.1d Library Validation is off in the default build.** The Hardened Runtime is on, so another
process cannot inject code by environment variable, but Library Validation cannot load the embedded
framework without a Team ID, so the ad-hoc build turns it off (§2.9). Any process running as you
could run a copy of the app with a swapped library, and with Accessibility granted that copy may
inherit the grant. A Developer ID would fix this properly and this project does not have one.

**8.2 Accessibility cannot be scoped, and the app's restraint is not enforced by macOS.** If you
grant it, you grant the ability to read most UI text across your system and to synthesize input.
Every defense listed here is a code-review defense. A malicious future release, signed by the same
team ID, would inherit your existing grant silently.

**8.3 A window title exists in the app's memory, briefly.** The claim is that it is never persisted,
never logged, never transmitted, and dropped when the next read replaces it, which is at most a
minute later while you are active (`ContextEngine`'s title cache). It is not a claim that
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

**8.6 System logs and crash reports are outside the app's control.** The app's own code writes
nothing to the unified log: `grep -rnE 'os_log|Logger|NSLog|OSLog' app/Sources` prints nothing. What
does write there from inside the process is code this repository did not write. Sparkle logs through
`os_log` under the subsystem `org.sparkle-project.Sparkle` (`nm -u` on its binary lists
`__os_log_impl` and `__os_log_error_impl`), SwiftUI compiles a runtime-issue `os_log` call into the
app's binary (`nm -u <BIN> | xcrun swift-demangle | grep -i log` shows it as
`SwiftUI.Log.runtimeIssuesLog`), and AppKit and the rest of macOS log about any app they run, such
as its launch and its permission checks. The app controls none of those lines and none of their
retention. Separately, if macOS crash reporting is enabled in *your* system settings, a crash report
may be sent to Apple by the OS. That is a system setting, not an app behavior, and the app cannot
suppress it.

**8.7 Reproducible builds are partial.** Signed artifacts are not bit-reproducible. Only the
signature-stripped binary hash can be independently recreated, and only with the exact same
toolchain.

**8.8 Installing and upgrading makes network requests whichever route you take.** Through a browser
or `git` it is you contacting GitHub; through the in-app updater it is this app contacting GitHub. The
difference between those is agency and auditability, not the absence of packets, and this document
says so rather than claiming "zero network, period."

**8.9 Bundle identifiers are not innocuous.** A seven-day log of which apps you focused, with
timestamps, is meaningful data about you, and so is what outlives it: a total for every day of how
many seconds you worked in each app, by bundle identifier, kept until you delete it (§4.3, §4.5).
It is less than a screen recorder collects by orders of magnitude, but it is not nothing, and
calling it "anonymous" would be false — it is on your machine, about you, tied to you.

**8.11 A branch name and a tool name exist in the app's memory while Tier 2 is on.** The same caveat
as §8.3 and for the same reason: the claim is that neither is persisted, logged or transmitted, not
that neither existed. A branch name may carry a ticket id, a customer, or an unreleased product. It
may appear in a memory dump, in swap, or in a crash report if a crash happens inside the collector.
If that matters to you, leave Tier 2 off, which is where it ships.

*Memory-only has a delivery channel attached to it.* A break prompt can be drawn by the app or
handed to `UNUserNotificationCenter`, and those are not the same thing. A notification body is
copied into notificationd's own store under `~/Library/Group Containers/group.com.apple.usernoted`,
drawn on the lock screen, and mirrored to whatever display is attached; there is no call this app
can make that takes it back. Lines in the corpus that name a branch or a project are, on the
notification route, simply not selectable, or fall back to their generic wording:
`AppModel.deliver` withholds the `{branch}` and `{project}` slots before a line is chosen, so both
are absent from the slot table rather than trusted to stay out of the string. `{project}` is parsed
from a window title, which can be a buffer's first line. Turning "Deliver prompts through macOS
notifications" off, or hitting escalation 4, which the app always draws itself, gets you those
lines back in a window this process owns. Without the
withholding, the switch would have quietly written a branch name to somebody else's database, and
"memory-only" in row 31 would have been false through a switch rather than through a bug.

**8.12 `--doctor` knows your branch, and you are asked to paste `--doctor` into public issues.** That
combination is the one place Tier 2 could leak something you did not mean to publish, so `--doctor`
prints the *length* of the branch name and not the name. Settings → Access shows the name itself,
on the line marked READ under the branch-name row, along with the folder it came from and which
of the two routes matched it:
that is the only place in the app the branch is displayed in full, it is on your own machine, and it
is not going anywhere. The redaction leans on that row existing, so the row is part of the claim
rather than a nicety. This is not a claim that the redaction is airtight: a length
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
you were typing *somewhere*, in any app. There is no per-app exclusion.

---

## 9. Changes to this document

This file is versioned with the code. Any change to the data inventory, permissions, retention
defaults, or the network position requires a PR that also updates §1 and that carries the
`privacy-impacting` label. There is no `CODEOWNERS` file, so no second approval is enforced. The
release notes hold nothing but commit subjects, and only commits that change what ships are
eligible, so they cannot call such a change out, and a change to this file alone does not reach
them at all. This file and §9.1 are
where the change is recorded.

### 9.1 Changelog of positions

| What changed | From | To |
|---|---|---|
| Network | "No network transmission of any kind." Zero requests, ever | One HTTPS `GET` of a static appcast, on a button press, with no identifier. §2.7, §5 |
| Update checking | "The app never checks for updates"; a menu item that opens a browser | An in-app updater with EdDSA signature verification. §5.3 keeps the old argument in full and says which sentence of it was wrong |
| Dependencies | Zero third-party runtime dependencies | Exactly one: Sparkle, pinned with `exact:`, linked into the app target only. §7 row 2 |
| Hardened Runtime | On, with Library Validation | On. Library Validation is off in the ad-hoc build, because it cannot load an embedded framework without a Team ID. §2.9, §8.1d |
| Update integrity | Notarized Developer ID signing | EdDSA signing with a key held only by the maintainer, verified before install. §2.8, §8.1c |
| Tier 2 | Two switches that read nothing, and a `--doctor` that said so | Two collectors: executable basenames against a fixed allowlist, and the first line of `.git/HEAD`, with the few pointer files §2.10 names, in folders you register. Inventory rows 29 to 31, §2.10, §3.5, §8.11 to §8.13 |
| Tier 2 command lines | `docs/ACTIVITY-DETECTION.md` mandated `KERN_PROCARGS2` for the full argv | argv is never read. The justification for reading it (a 16-character `p_comm` limit) was measurably wrong, and `proc_pidpath` answers the same question with no permission. The cost, six tool tokens that become undetectable, is named in §4.3(b) of that file |

Nothing in the earlier positions was deleted to make room for these. The arguments that were
replaced are quoted where they were replaced, because a privacy document that silently rewrites its
own history is not evidence of anything.
