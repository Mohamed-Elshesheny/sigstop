# sigstop

> `SIGSTOP` is the one signal a process cannot catch, block, or ignore.
> `SIGCONT` resumes it exactly where it left off — registers, memory, file descriptors,
> all intact.
>
> That is what a break is. It is not a restart.

An open-source macOS menu bar app that infers what a developer is *doing* — not just how long
they have been sitting — and interrupts at a defensible moment with a context-aware joke.

## 0. The name is the spec

The product's hardest objection is not "I don't have time." It is **"if I stop now I lose the
stack I've been holding for forty minutes."** The name answers it: a stopped process keeps
everything and continues at the exact instruction. Copy, UI labels and docs all inherit this —
so the vocabulary below is **normative, not decorative.**

| Concept | Signal | Why |
|---|---|---|
| Escalation 1 | `SIGTSTP` | Catchable. You are allowed to ignore it. |
| Escalation 2 | `SIGINT` | Catchable, but ignoring it is rude. |
| Escalation 3 | `SIGTERM` | Catchable. This is your warning. |
| Escalation 4 | `SIGSTOP` | Cannot be caught, blocked, or ignored by anyone, ever. |
| Snooze | `SIGALRM` | Wake me later. |
| Resume from break | `SIGCONT` | The resume button is never labelled "Dismiss". |
| Daily summary | `jobs` | Everything you had suspended today. |
| Reload settings | `SIGHUP` | Its honest daemon meaning: re-read the config. |

**Two hard rules, from the naming review:**

1. **`SIGKILL` never appears at level 4, or anywhere.** SIGKILL is unrecoverable and destroys
   exactly the thing the name promises to preserve. The ladder tops out at `SIGSTOP`, which is
   already uncatchable *and* destroys nothing. Using SIGKILL for a laugh contradicts the product.
2. **`SIGHUP` is never an escalation rung.** Its default disposition is *terminate*, so an L1
   labelled SIGHUP would quietly mean "die." It is reserved for reloading settings.

**The tone risk this name carries.** The metaphor casts the app as the kernel and the developer
as an uncooperative process. Played straight, that is an authority scolding the user — which is
the relationship people uninstall. The app must stay self-aware that *"cannot be ignored" is a
bluff the user is in on*: a menu bar app cannot suspend anyone. The app is on your side; it is
the thing that guarantees you come back intact. Write it as a deadpan accomplice, never a warden.

This file is the operating manual for anyone (human or agent) working in this repo.
Read it before editing. The rules in **Invariants** are not stylistic preferences.

---

## 1. Repo layout

```
sigstop/
├── app/          macOS app — Swift 6, SwiftUI, SwiftPM (no .xcodeproj)
├── web/          Landing site — Next.js 16, React 19, Tailwind v4, TypeScript
├── docs/         Architecture. Written before the code and kept in sync.
└── CLAUDE.md
```

Design docs are normative, not aspirational. If code and `docs/` disagree, one of them is a bug —
decide which, fix it, and say so in the PR.

| Doc | Owns |
|---|---|
| `docs/ACTIVITY-DETECTION.md` | Signal tiers, providers, the confidence model |
| `docs/BREAK-DECISION.md` | Session clock, engine state machine, interruption policy |
| `docs/MESSAGE-ENGINE.md` | Template selection, tone, escalation, corpus format |
| `docs/PRIVACY.md` | Data inventory and the enforceable no-collection properties |

---

## 2. Build and run

### App

```sh
cd app
make build          # swift build -c release
make bundle         # assemble + sign sigstop.app
make run            # bundle, then launch
make test           # swift test — Core only, no GUI session required
make doctor         # print exactly what the app can observe right now
```

There is **no Xcode project and no Xcode requirement**. Command Line Tools are enough.
`swift build` compiles SwiftUI and AppKit fine; `make bundle` assembles the `.app` by hand.
Do not add a `.xcodeproj` — it breaks CI and produces merge conflicts for no gain.

### Web

```sh
cd web
npm run dev
npm run build
```

> **Note on this machine:** the global npm cache at `~/.npm/_cacache` has a permission fault that
> makes `npm install` fail with `EACCES`/`EEXIST`. Workaround that touches nothing in `$HOME`:
> `npm install --cache /tmp/npmcache`. This is a local environment issue, not a repo issue.

---

## 3. Architecture rules

### 3.1 Dependency direction is one-way

```
App  ──▶  Sensors  ──▶  Core
```

- **`Core`** — pure domain. **Must not import AppKit, Cocoa, or any macOS UI framework.**
  Session clock, decision engine, message engine live here.
- **`Sensors`** — the *only* layer that touches macOS APIs. Everything it exposes is a protocol.
- **`App`** — SwiftUI menu bar, break overlay, settings.

`Core` never learns that macOS exists. This is what makes the engines testable without a GUI
session — which matters enormously here, because there is no Xcode and therefore no UI test
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
to core code. If it doesn't, the extension point is wrong — fix the extension point.

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
illusion — that the app actually knows.

Every `Evidence` value carries a user-facing `summary`. The app must always be able to answer
"why do you think that?" — `make doctor` exists so a skeptic can check.

### 4.2 The app must be fully functional with zero permissions granted

Tier 0 (frontmost app, idle time, mic-in-use, screen lock, thermal state) requires **no permission
and produces no prompts**. This is empirically verified — see §6.

Accessibility (Tier 1) and git context (Tier 2) are *upgrades*, never gates. A feature that
hard-requires a permission is a design error.

### 4.3 The app never opens a network connection

No telemetry, no update check, no crash reporting, no font CDN, no "anonymous" anything.
This is enforced structurally, not by policy: the network entitlement is absent and no networking
framework is linked. It is verifiable with `otool -L` and `codesign -d --entitlements`.

Adding *any* network call to the app requires changing this file first, in its own PR, with the
argument written out. Do not bundle it with a feature.

### 4.4 Never read content

Window **titles** only, at Tier 1, redacted per `docs/PRIVACY.md` §1.5 — never document bodies,
never keystrokes, never clipboard, never screen contents, never message text.

The app's pitch is "this watches your workflow, not your code." That sentence must stay literally
true at the source level.

### 4.5 Humor has rails

Never about body weight, appearance, medical conditions, mental health, competence, or job
security. `NUCLEAR` tone is absurd and theatrical — never cruel. No medical claims anywhere, in
the app or on the site: this is a workflow tool, not a health product. Say "your posture," never
"your health." Rubric and the CI lint that enforces the structural parts: `docs/MESSAGE-ENGINE.md` §4.

---

## 5. Conventions

**Swift** — Swift 6 language mode, strict concurrency. Public API in `Core` is `Sendable`.
Prefer `struct` + `enum`; reach for a class only for genuine identity/lifetime. No force-unwraps
outside tests. No third-party dependencies in the app, at all.

**TypeScript / web** — Copy lives in `src/content/`, never inline in components, so the writing can
be reviewed as writing. Components are presentational and take props. Server Components by default;
`"use client"` only where there is real interactivity.

**Motion** — Every animation must respect `prefers-reduced-motion`. No motion library; CSS
animations plus `IntersectionObserver` are sufficient and keep the bundle honest.

**Dependencies** — The bar is high in both trees. The app has zero. The site has Next, React,
Tailwind and nothing else. "It's only 4kb" is not an argument.

---

## 6. Environment facts (verified on this machine, not assumed)

macOS 27.0 · Swift 6.2 · Command Line Tools only (no `xcodebuild`) · Node 24 · npm 11.

Probed directly — all Tier 0 signals work with **zero** permissions:

| Signal | API | Result |
|---|---|---|
| Frontmost app + bundle ID | `NSWorkspace.frontmostApplication` | ✅ |
| System idle seconds | `CGEventSource.secondsSinceLastEventType` | ✅ |
| Mic in use (meeting signal) | `kAudioDevicePropertyDeviceIsRunningSomewhere` | ✅ |
| Thermal / low-power | `ProcessInfo` | ✅ |
| Window title (Tier 1) | `AXUIElement` | `AXIsProcessTrusted() == false` → clean error `-25211` |

That last row is the important one: Tier 1 fails *gracefully*, which is what lets §4.2 hold.

### The codesign trap — read this before debugging a "permissions keep resetting" bug

macOS records the Accessibility grant against the binary's **cdhash**. `swift build` ad-hoc-signs,
and the cdhash changes on every rebuild — so **the grant silently evaporates after every build**
and System Settings fills up with stale entries.

Fix: sign with a *stable* self-signed identity. `make dev-cert` creates one once.
Never debug this by re-granting permission repeatedly; you are fighting TCC, and TCC wins.

---

## 7. Working style in this repo

- Prefer being correct and honest over being impressive. The audience reads source adversarially.
- When a detection heuristic is unreliable, say so in the code and degrade — do not paper over it.
- Landing copy is developer-native. No "revolutionize your productivity." If a sentence could
  appear on a generic SaaS page, delete it.
- Keep `docs/` in sync in the same PR as the behavior change.
