# sigstop

> `SIGSTOP` is the one signal a process cannot catch, block, or ignore.
> `SIGCONT` resumes it exactly where it left off: registers, memory, file descriptors,
> all intact.
>
> That is what a break is. It is not a restart.

An open-source macOS menu bar app that infers what a developer is *doing*, not just how long
they have been sitting, and interrupts at a defensible moment with a context-aware joke.

## 0. The name is the spec

The product's hardest objection is not "I don't have time." It is **"if I stop now I lose the
stack I've been holding for forty minutes."** The name answers it: a stopped process keeps
everything and continues at the exact instruction. Copy, UI labels and docs all inherit this,
so the vocabulary below is **normative, not decorative.**

| Concept | Signal | Why |
|---|---|---|
| Escalation 1 | `SIGTSTP` | Catchable. You are allowed to ignore it. |
| Escalation 2 | `SIGINT` | Catchable, but ignoring it is rude. |
| Escalation 3 | `SIGTERM` | Catchable. This is your warning. |
| Escalation 4 | `SIGSTOP` | Cannot be caught, blocked, or ignored by anyone, ever. |
| Snooze | `SIGALRM` | Wake me later. |
| Resume from break | `SIGCONT` | The resume button is never labelled "Dismiss". |
| Daily summary | `uptime` | How long you have been going, and how hard. `jobs` was here first and was wrong: it lists suspended work, and this panel shows active time, the longest unbroken stretch, the breaks kept and the app that took the day. `uptime` is a multi-stat readout of exactly that shape, and no developer has to look it up. |
| Reload settings | `SIGHUP` | Its honest daemon meaning: re-read the config. |

**Two hard rules, from the naming review:**

1. **`SIGKILL` never appears at level 4, or anywhere.** SIGKILL is unrecoverable and destroys
   exactly the thing the name promises to preserve. The ladder tops out at `SIGSTOP`, which is
   already uncatchable *and* destroys nothing. Using SIGKILL for a laugh contradicts the product.
2. **`SIGHUP` is never an escalation rung.** Its default disposition is *terminate*, so an L1
   labelled SIGHUP would quietly mean "die." It is reserved for reloading settings.

**The tone risk this name carries.** The metaphor casts the app as the kernel and the developer
as an uncooperative process. Played straight, that is an authority scolding the user, which is
the relationship people uninstall. The app must stay self-aware that *"cannot be ignored" is a
bluff the user is in on*: a menu bar app cannot suspend anyone. The app is on your side; it is
the thing that guarantees you come back intact. Write it as a deadpan accomplice, never a warden.

This file is the operating manual for anyone (human or agent) working in this repo.
Read it before editing. The rules in **Invariants** are not stylistic preferences.

---

## 1. Repo layout

```
sigstop/
├── app/          macOS app: Swift 6, SwiftUI, SwiftPM (no .xcodeproj)
├── docs/         Architecture. Written before the code and kept in sync.
└── CLAUDE.md
```

**This repository is the app.** The landing site was split out and lives in
[`sigstop-web`](https://github.com/Mohamed-Elshesheny/sigstop-web). They share a name and nothing
else: different language, toolchain, audience and release cadence. Nothing here builds, serves or
tests the site, and a change to the page does not belong in a pull request here.

One thing does cross the line, and §5 says what to do about it: the ten badge names are printed by
both.

Design docs are normative, not aspirational. If code and `docs/` disagree, one of them is a bug.
Decide which, fix it, and say so in the PR.

| Doc | Owns |
|---|---|
| `docs/ACTIVITY-DETECTION.md` | Signal tiers, providers, the confidence model |
| `docs/BREAK-DECISION.md` | Session clock, engine state machine, interruption policy |
| `docs/MESSAGE-ENGINE.md` | Template selection, tone, escalation, corpus format |
| `docs/PRIVACY.md` | Data inventory and the enforceable no-collection properties |
| `docs/RELEASING.md` | Cutting a release: EdDSA signing, the appcast, and publishing |

---

## 2. Build and run

```sh
cd app
make build          # swift build -c release
make bundle         # assemble + sign sigstop.app
make run            # bundle, then launch
make test           # badge check, then swift test: Core only, no GUI session required
make doctor         # print exactly what the app can observe right now
make verify         # assert the §4.3 claims against the BUILT bundle, not the source
make badges         # rewrite Exports/badges.json from the Swift catalogue (§5)
```

There is **no Xcode project and no Xcode requirement**. Command Line Tools are enough.
`swift build` compiles SwiftUI and AppKit fine; `make bundle` assembles the `.app` by hand.
Do not add a `.xcodeproj`. It breaks CI and produces merge conflicts for no gain.

---

## 3. Architecture rules

### 3.1 Dependency direction is one-way

```
App  ──▶  Sensors  ──▶  Core
```

- **`Core`** is pure domain. **Must not import AppKit, Cocoa, or any macOS UI framework.**
  Session clock, decision engine, message engine live here.
- **`Sensors`** is the *only* layer that touches macOS APIs. Everything it exposes is a protocol.
- **`App`** is the SwiftUI menu bar, the break overlay and settings.

`Core` never learns that macOS exists. This is what makes the engines testable without a GUI
session, which matters enormously here, because there is no Xcode and therefore no UI test
harness. A test that needs a logged-in window server is a test that never runs in CI.

### 3.2 Time is injected, never read

`Core` must never call `Date()`, `Date.now`, or `DispatchTime.now()`. It takes a `TimeSource`.
Production passes the system clock; tests pass a fake one and advance it by hand.

Consequence: "45 minutes of continuous work triggers a break" is a unit test that runs in
microseconds, not a thing we hope works.

### 3.3 Providers are pure functions

An `ActivityProvider` owns no state and performs no I/O. All I/O happens upstream in collectors;
providers only *interpret* a `SignalContext`. To test one, construct a `SignalContext` literal.

Adding support for a new app = adding a provider + its `AppClaim`s. It must require zero changes
to core code. If it doesn't, the extension point is wrong. Fix the extension point.

### 3.4 The tick loop must not trust its own interval

Never compute elapsed time as `ticks × interval`. The machine sleeps, the process gets throttled,
the user closes the lid. Always diff real timestamps and classify the gap. See
`docs/BREAK-DECISION.md` §3.2.

---

## 4. Invariants

These are product promises with architectural teeth. Breaking one is not a regression, it is a
betrayal of the reason this app exists. Do not "temporarily" break one.

### 4.1 Never claim more confidence than the signals support

`Confidence` is clamped at construction and `.certain` (0.99) is reserved for **OS facts only**
(screen locked, session inactive). Nothing *inferred* may reach it.

When two child activities cannot be distinguished, degrade to the shared `parent`
(`debugging` → `coding`). **Never pick between siblings by guessing.** Silently guessing wrong and
saying "You've been debugging for 61 minutes" when the user was writing docs destroys the core
illusion, which is that the app actually knows.

Every `Evidence` value carries a user-facing `summary`. The app must always be able to answer
"why do you think that?". `make doctor` exists so a skeptic can check.

### 4.2 The app must be fully functional with zero permissions granted

Tier 0 (frontmost app, idle time, mic-in-use, screen lock, thermal state) requires **no permission
and produces no prompts**. This is empirically verified, see §6.

Accessibility (Tier 1) and git context (Tier 2) are *upgrades*, never gates. A feature that
hard-requires a permission is a design error.

### 4.3 The app opens exactly one connection, only when you ask, and verifies what comes back

This invariant used to read "the app never opens a network connection." It does not say that any
more, and the change was made here, in its own commit, before the code, which is what the last
paragraph of the old version demanded and is the only reason it was allowed to change at all.

**What is true now:**

- The app makes **one** kind of request: a `GET` of the appcast at `SUFeedURL`, a static XML file
  that is byte-identical for every user.
- It is made **only** when someone presses *Check for updates* in Settings → About. There is no
  schedule, no launch check and no timer. `SUEnableAutomaticChecks` is `<false/>` in Info.plist and
  `UpdateChecker` writes `automaticallyChecksForUpdates = false` on every launch, because the plist
  key is only a default and the live value lives in `UserDefaults` where it survives an update and
  where anything on the machine can turn it on. Sparkle's first-run "may I check automatically?"
  prompt is answered `no` without being shown.
- There used to be a toggle for the daily schedule. It was removed, and removing a switch that
  governs a network call is not a UI change: the scheduler does not go away with its checkbox, so
  the app now forces the value instead of offering it. A network path the user can neither see nor
  revoke is worse than one they can.
- It carries **no identifier**: no account, no install id, no machine id, no system profile
  (`SUEnableSystemProfiling` is `<false/>`), and the user agent is overridden to the constant
  `"sigstop"` so it does not carry the app version either.
- Nothing downloads or installs without a second, separate press.
- **Every update is verified before it can run.** Sparkle checks an EdDSA signature against
  `SUPublicEDKey`, which is compiled into the app; the private half lives only in the maintainer's
  login keychain. A compromised GitHub account, CDN, or network can serve a malicious archive and
  still not get it installed.

**What is still true and still structural:** the app's *own* binary links no networking framework
and references no networking symbol: not `NSURLSession`, not a socket, not `getaddrinfo`. All the
network code in the bundle lives in `Sparkle.framework`, which you can name, version and diff, and
the download itself runs in Sparkle's out-of-process XPC service. There is no network **server**
entitlement: nothing listens.

**What cannot be claimed:** an HTTPS request reveals the client's IP address and a timestamp to
whoever serves the file. No client-side choice changes that. `docs/PRIVACY.md` §5 says so plainly
rather than talking around it.

`make verify` asserts all of the above against the built bundle. It is no longer "prove there is no
networking"; it is "prove the only networking is Sparkle's, prove nothing schedules itself, prove
updates are signature-gated". Read `app/Scripts/verify.sh`, which is commented with what each check is
for and why the old one was not just deleted.

Adding a **second** endpoint, a launch-time check, or anything that sends state upward requires
changing this file first, in its own PR, with the argument written out. Do not bundle it with a
feature.

### 4.4 Never read content

Window **titles** only, at Tier 1, redacted per `docs/PRIVACY.md` §1.5. Never document bodies,
never keystrokes, never clipboard, never screen contents, never message text.

The app's pitch is "this watches your workflow, not your code." That sentence must stay literally
true at the source level.

### 4.5 Humor has rails, and claims carry sources

Never about body weight, appearance, medical conditions, mental health, competence, or job
security. `NUCLEAR` tone is absurd and theatrical, never cruel. Rubric and the CI lint that
enforces the structural parts: `docs/MESSAGE-ENGINE.md` §4.

**On health and performance claims.** This rule used to be "no claims, ever", which was the
safe position rather than the honest one. The current position is narrower and harder:

- **No medical claims, still.** Not healthier, not prevents injury, not treats anything.
  The app says "your posture", never "your health". It is not a health product and has no
  business behaving like one.
- **An attention or performance claim is allowed only with a citation**, and only where the
  reader can see it: the claim, the paper, the DOI, next to each other.
- **Cite the disagreement too.** Citing only the half that flatters the product is the move
  this audience is scanning for, and getting caught at it costs more than the claim was worth.

**Where this bites in this repository.** The surfaces that can make a claim here are the message
corpus, `app/Sources/SigstopCore/Message/corpus.json`, and the copy in Settings and the break
overlay. None of them currently asserts an effect, and several lines sit deliberately close to the
line without crossing it: "let your attention reset before the next file" is advice in the second
person, not an assertion that it works. The moment a line claims the effect, it needs the citation
or it does not ship.

**The worked example lives in the site repository**, because that is where the claim it carries
lives: [`sigstop-web`](https://github.com/Mohamed-Elshesheny/sigstop-web), `src/content/copy.ts`,
`comparison.evidence`. The comparison table there claims sigstop makes you a better engineer, and
the evidence block under it carries Ariga & Lleras (2011), which supports the mechanism, *and*
Helton & Russell (2012), which failed to replicate it, each with its DOI. Copy the shape, not the
path, and do not transcribe the DOIs back into this repository: one copy of a citation cannot go
stale against another.

If you cannot find a real source with a resolvable DOI, the claim does not ship. Inventing
a citation is the single fastest way to destroy everything else on the page.

---

## 5. Conventions

**Swift** is the only language here. Swift 6 language mode, strict concurrency. Public API in
`Core` is `Sendable`. Prefer `struct` + `enum`; reach for a class only for genuine identity or
lifetime. No force-unwraps outside tests. **Exactly one third-party dependency, Sparkle, and it is
attached to `SigstopApp` only.** `SigstopCore` and `SigstopSensors` are dependency-free and must
stay that way: they must not import Sparkle, and the layering rule in §3.1 still holds. A second
dependency needs the same argument Sparkle had to make, below.

**Motion.** Every animation must respect `@Environment(\.accessibilityReduceMotion)` and resolve
to no animation when it is on, not to a faster one.

**Dependencies.** The bar is high. The app has **one**: Sparkle, pinned to an exact version,
linked into `SigstopApp` only. "It's only 4kb" is not an argument.

The bar Sparkle cleared, written down so the next proposal has something to clear too. The app is
distributed outside the App Store and is **ad-hoc signed with no Team ID**, so Apple's code
signature proves nothing about who produced a build: Gatekeeper would be checking a signature
against nobody. An updater that downloads and installs therefore has to carry its own proof of
authorship, and Sparkle's is EdDSA: signed with a key that never leaves the maintainer's keychain,
verified against a public key compiled into the app, refused if it does not match. The only way to
avoid the dependency was to write download-and-verify by hand, and hand-rolled verification of
signed executables is the single worst thing in this repo to get subtly wrong. One audited,
widely-deployed dependency beat one bespoke security-critical code path. *That* is the shape of
argument a new dependency needs, not convenience, not line count.

**The ten badge names exist in two repositories, and only one of them is the source.**
`app/Sources/SigstopCore/Badges/Badge.swift` defines them. `sigstop-web` advertises the same ten
names and the same ten motif ids on its badge wall. Nothing structural stopped those drifting after
the split, and a page naming a badge the app does not have is precisely the kind of small lie this
project exists to avoid.

So `app/Exports/badges.json` is the committed machine-readable copy, regenerated by `make badges`
and checked by `make test`, which now fails before it compiles anything if the export disagrees
with the Swift. It is not there for this repository's benefit, and nothing here reads it at
runtime. It is there so that a rename shows up as a diff in the pull request that caused it,
instead of as a wrong sentence on a page nobody looked at, and so the site has a stable file to
read rather than a Swift enum to parse. The site runs its own check in the other direction. The
order of operations is in `CONTRIBUTING.md`.

Only the three fields that must be identical are exported: the id, the name and the motif. The
prose around each badge is written twice on purpose, in each surface's own voice.

---

## 6. Environment facts (verified on this machine, not assumed)

macOS 27.0 · Swift 6.2 · Command Line Tools only (no `xcodebuild`).

Probed directly, and all Tier 0 signals work with **zero** permissions:

| Signal | API | Result |
|---|---|---|
| Frontmost app + bundle ID | `NSWorkspace.frontmostApplication` | ✅ |
| System idle seconds | `CGEventSource.secondsSinceLastEventType` | ✅ |
| Mic in use (meeting signal) | `kAudioDevicePropertyDeviceIsRunningSomewhere` | ✅ |
| Camera in use (meeting signal) | `kCMIODevicePropertyDeviceIsRunningSomewhere` | ✅ 3 devices enumerated, no prompt, no `tccd` entry |
| Which app has the mic | `kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningInput` | ✅ 36 process objects, no prompt |
| Screen being shared | none | ❌ `CGDisplayIsCaptured` is deprecated since 10.9 and does not compile; ScreenCaptureKit needs the Screen Recording grant. Reported as unobservable, never as false |
| Thermal / low-power | `ProcessInfo` | ✅ |
| Window title (Tier 1) | `AXUIElement` | `AXIsProcessTrusted() == false` → clean error `-25211` |

That last row is the important one: Tier 1 fails *gracefully*, which is what lets §4.2 hold.

### The codesign trap, read this before debugging a "permissions keep resetting" bug

macOS records the Accessibility grant against the binary's **cdhash**. `swift build` ad-hoc-signs,
and the cdhash changes on every rebuild, so **the grant silently evaporates after every build**
and System Settings fills up with stale entries.

Fix: sign with a *stable* self-signed identity. `make dev-cert` creates one once.
Never debug this by re-granting permission repeatedly; you are fighting TCC, and TCC wins.

**Measured on macOS 27.0, 2026-09-21, because the above is the received wisdom and it did not
reproduce here.** The bundle's designated requirement really is `cdhash H"..."` alone and really
does change every build, but the Accessibility grant survived repeated rebuilds and
`AXIsProcessTrusted()` kept returning true. So treat the trap as real but not certain, and check it
rather than assuming it: `--doctor` reports the window title as `readable` only when the process is
genuinely trusted. A pane that says "not granted" while `--doctor` says `readable` is a stale view,
not a lost grant, and that bug was real and is fixed.

---

## 7. Working style in this repo

- Prefer being correct and honest over being impressive. The audience reads source adversarially.
- When a detection heuristic is unreliable, say so in the code and degrade. Do not paper over it.
- Landing copy is developer-native. No "revolutionize your productivity." If a sentence could
  appear on a generic SaaS page, delete it.
- Keep `docs/` in sync in the same PR as the behavior change.

---

## 8. Commits

**Every commit message is a [Conventional Commit](https://www.conventionalcommits.org).**

```
type(scope): subject

body explaining WHY, not what. The diff already says what.
```

**Types:** `feat` `fix` `refactor` `perf` `docs` `test` `build` `ci` `chore`
**Scopes:** `core` `sensors` `app` `docs`. Omit when the change spans the repo.

Rules:
- Subject in the imperative, lowercase after the colon, no trailing full stop, under 72 chars.
- A breaking change gets `!` before the colon (`feat(core)!: ...`) and a `BREAKING CHANGE:`
  footer explaining the migration.
- **Keep it short.** Most commits are a subject line and nothing else. A body is for the one
  thing a future reader cannot reconstruct from the diff, and it is two or three lines, not an
  essay. If the reasoning genuinely needs paragraphs it belongs in `docs/` or in a doc comment
  next to the code, where someone will actually find it. A commit log nobody reads is a commit
  log nobody reads, however well argued.

```
feat(core): degrade to the parent activity below the confidence floor
fix(app): half fill the menu bar mark so it reads as a timer
refactor(sensors): resolve providers by claim specificity
chore: scaffold repo, architecture docs and Core contract
```

**One fix, one commit, straight onto `main`. No merge commits.**

Work in a branch or a worktree and merging it back loses things, and it has already nearly
happened here: a branch cut before a fix landed carries the old file, and its merge quietly
reverts the fix. That one was caught by reading the diff. The next one would not be.

So: land each change as its own commit on `main`, in order. If work was done somewhere else,
cherry-pick the individual commits rather than merging the branch, and rebase onto current `main`
first so the diff is against what is actually there. A change that spans several concerns is
several commits, not one merge.

**No AI attribution.** Commits carry no `Co-Authored-By` for an assistant, no "generated
with" footers, and no tool names in the message or the author field. Author and committer
are the human whose account the work ships under. This is not about hiding anything; the
commit log is a record of intent, and intent belongs to a person.
