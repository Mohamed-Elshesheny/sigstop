<div align="center">

# sigstop

**You're a developer. Not a server.**

An open-source macOS menu bar app that works out what you are actually doing,
then interrupts at a defensible moment with a joke you will recognise.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111?style=flat-square)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?style=flat-square)](#building)
[![Apache 2.0](https://img.shields.io/badge/license-Apache--2.0-blue?style=flat-square)](LICENSE)
[![125 tests](https://img.shields.io/badge/tests-125%20passing-3fb950?style=flat-square)](#tests)

</div>

---

`SIGSTOP` is the one signal a process cannot catch, block, or ignore.
`SIGCONT` resumes it exactly where it left off, registers and memory intact.

That is what a break is. It is not a restart.

The hardest objection to taking a break is not "I don't have time". It is **"if I stop now
I lose the stack I have been holding for forty minutes."** The name is the answer to that
objection, and the product is built around it.

## This is not a pomodoro timer

A timer knows one thing: that time passed. It will fire in the middle of your standup.

sigstop reads which app is in front, how long you have genuinely been active, and whether
this is a sane moment to interrupt at all.

```
45 min of genuinely active work
  → which app is in front?
  → what does that suggest you are doing?
  → how sure am I, honestly?
  → is the microphone live? is the screen shared? is it fullscreen?
  → wait for a natural seam
  → say something worth reading
  → SIGCONT
```

**If the microphone is on, it does not fire.** Not "fires quietly". Does not fire.

## It says what it does not know

Confidence is a number the app acts on, not decoration. Below the threshold it refuses to
name an activity rather than guess:

```
$ sigstop --doctor

INFERENCE
  activity         working
  confidence       0.32

  EVIDENCE  (log-odds; the prior is about -1.74)
    +1.00  t0  Cursor is the frontmost app
```

Saying "you have been debugging for 61 minutes" to someone who was writing documentation
destroys the only thing this product has. When it cannot tell two activities apart it
reports their shared parent instead.

## Privacy

The app reads **which** application is in front, never what is inside it.

| It reads | It cannot read |
|---|---|
| Frontmost app name and bundle id | Your source code |
| Seconds since you last touched the keyboard | Your keystrokes |
| Whether an audio input device is running | Your clipboard |
| Session duration | Your messages |
| Window titles, only if you grant Accessibility | Your screen |

**It works fully with zero permissions granted.** Accessibility and git context are
upgrades you opt into, never gates.

Do not take that on trust. `make verify` asserts fifteen properties against the built
binary, including that the app's own executable references no networking symbol at all:

```
ok  no networking framework linked into the app binary
ok  no networking symbol referenced by the app binary
ok  exactly one embedded framework, and it is Sparkle
ok  downloads run in Sparkle's out-of-process XPC service
ok  none of the known analytics or crash-reporting SDKs are present
ok  no private signing key anywhere in the repository
```

The one network request is the update check, it runs only when you press the button, it
sends no identifier, and every update is EdDSA signed and verified before it can install.
Full inventory: [`docs/PRIVACY.md`](docs/PRIVACY.md).

## Building

Command Line Tools are enough. **There is no Xcode requirement and no `.xcodeproj`**, which
keeps CI simple and stops a generated XML file from conflicting on every PR.

```sh
git clone https://github.com/Mohamed-Elshesheny/sigstop
cd sigstop/app
make run        # build, bundle, launch
make test       # 125 tests, no GUI session needed
make doctor     # print exactly what the app can see about you
make verify     # prove the privacy claims against the binary
```

`open app/Package.swift` gives you the full Xcode experience if you prefer one. Nothing in
the repo depends on it.

### Requirements

| | |
|---|---|
| macOS | 14 or later |
| Swift | 6.2 (Command Line Tools) |
| Dependencies | one: [Sparkle](https://sparkle-project.org) 2.10.0, for signed updates |

## How it is put together

```
App  ──▶  Sensors  ──▶  Core
```

- **Core** is pure domain and never imports AppKit. It takes an injected `TimeSource`, so
  "45 minutes of continuous work triggers a break" is a microsecond unit test rather than
  something we hope works.
- **Sensors** is the only layer that touches macOS APIs, all behind protocols.
- **App** is the menu bar, the prompt and the settings.

Providers are pure functions from signals to an observation. Adding support for a new
editor is a provider and a bundle id, with **zero changes to core code**.

| Document | Owns |
|---|---|
| [`ACTIVITY-DETECTION.md`](docs/ACTIVITY-DETECTION.md) | Signal tiers, providers, the confidence model |
| [`BREAK-DECISION.md`](docs/BREAK-DECISION.md) | The session clock and the interruption policy |
| [`MESSAGE-ENGINE.md`](docs/MESSAGE-ENGINE.md) | Template selection, tone, escalation |
| [`PRIVACY.md`](docs/PRIVACY.md) | Data inventory and the enforceable properties |
| [`RELEASING.md`](docs/RELEASING.md) | Signing and publishing a release |

These were written before the code and are kept in sync with it. If they disagree with the
source, one of them is a bug.

## The escalation ladder

POSIX already ships a ladder ordered by exactly the property that matters here, how easy
each signal is to ignore. Nothing was invented:

| | Signal | Meaning |
|---|---|---|
| 1 | `SIGTSTP` | Catchable. You are allowed to ignore it. |
| 2 | `SIGINT` | Catchable, but ignoring it is rude. |
| 3 | `SIGTERM` | Catchable. This is your warning. |
| 4 | `SIGSTOP` | Cannot be caught, blocked, or ignored by anyone, ever. |

Snooze is `SIGALRM`. The resume button is `SIGCONT`, never "Dismiss". **There is no
`SIGKILL`**: it is unrecoverable, and it would destroy the exact thing the name promises.

## Contributing

Read [`CONTRIBUTING.md`](CONTRIBUTING.md) first. It has one thing that will save you an
afternoon: macOS keys the Accessibility grant to the binary's cdhash, so the grant
evaporates after every `swift build` unless you sign with a stable identity.

The 149 jokes live in one JSON file with structured preconditions, so a line can be written
to fire only when someone has been in Xcode for ninety minutes on a Friday.

## Licence

[Apache 2.0](LICENSE). Fork it, change it, ship it, sell it.

The name and the logo are not part of that grant, which is what Apache section 6 is for. A
modified build needs its own name. [`TRADEMARK.md`](TRADEMARK.md) explains why in one page:
"sigstop makes no network calls" stops being verifiable the moment there is more than one
sigstop.
