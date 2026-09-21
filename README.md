<div align="center">

<img src="docs/images/icon.png" width="104" alt="">

# sigstop

**You're a developer. Not a server.**

A macOS menu bar app that works out what you are doing, then interrupts at a defensible
moment instead of on a timer.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111?style=flat-square)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?style=flat-square)](#building)
[![GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)](LICENSE)
[![281 tests](https://img.shields.io/badge/tests-281%20passing-3fb950?style=flat-square)](#building)

</div>

---

`SIGSTOP` is the one signal a process cannot catch, block, or ignore. `SIGCONT` resumes it
exactly where it left off, registers and memory intact. That is what a break is, and it is
not a restart.

## Install

[![Download for macOS](https://img.shields.io/badge/Download%20for-macOS-000000?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/Mohamed-Elshesheny/sigstop/releases/latest/download/sigstop.dmg)

Open the `.dmg` and drag **sigstop** into `/Applications`.

> [!IMPORTANT]
> There is no Apple Developer account behind this build, so macOS refuses to open it the
> first time. Clear it once and it opens like anything else afterwards.

```sh
xattr -dr com.apple.quarantine /Applications/sigstop.app
```

System Settings, Privacy and Security, **Open Anyway** does the same thing, but it can
fail and it does nothing for a user without admin rights.

Both routes mean trusting a binary somebody else built. Check the `sha256` on the
[release](https://github.com/Mohamed-Elshesheny/sigstop/releases/latest), or
[build it yourself](#building) and trust nobody.

## How it decides

A timer knows one thing: that time passed. It will fire in the middle of your standup.

```
45 min of genuinely active work
  -> which app is in front, and what does that suggest?
  -> how sure am I, honestly?
  -> is a microphone or camera live?
  -> wait for a natural seam
  -> SIGCONT
```

**If a capture device is live, it does not fire.** Not quietly. It does not fire.

Confidence is acted on rather than displayed. Below the threshold the app names no
activity, and when it cannot separate two it reports their shared parent. Telling someone
they have been debugging for an hour when they were writing docs destroys the only thing
this product has.

## Privacy

It reads **which** application is in front, never what is inside it.

| It reads | It cannot read |
|---|---|
| Frontmost app name and bundle id | Your source code |
| Seconds since the last keypress | Your keystrokes |
| Whether a capture device is running | Your clipboard |
| Window titles, only with Accessibility | Your screen |

Zero permissions are required. Accessibility and git context are opt-in upgrades, never
gates. One network call exists and it is the update check, on a button press.

Do not take that on trust:

```sh
make verify    # 15 assertions against the built binary, not the source
make doctor    # everything the app can see about you, right now
```

## Building

Command Line Tools are enough. There is no Xcode requirement and no `.xcodeproj`.

```sh
git clone https://github.com/Mohamed-Elshesheny/sigstop
cd sigstop/app
make run        # build, bundle, launch
make test       # 281 tests, no GUI session needed
```

### Requirements

| | |
|---|---|
| macOS | 14 or later |
| Swift | 6.2 (Command Line Tools) |
| Dependencies | one: [Sparkle](https://sparkle-project.org) 2.10.0, for signed updates |

## Architecture

```
App  ->  Sensors  ->  Core
```

**Core** is pure domain and never imports AppKit. It takes an injected `TimeSource`, so
"45 minutes of work triggers a break" is a microsecond unit test. **Sensors** is the only
layer that touches macOS APIs. **App** is the menu bar, the prompt and settings.

Providers are pure functions from signals to an observation, so supporting a new editor is
a provider and a bundle id with no changes to core code.

| Document | Owns |
|---|---|
| [`ACTIVITY-DETECTION.md`](docs/ACTIVITY-DETECTION.md) | Signal tiers, providers, the confidence model |
| [`BREAK-DECISION.md`](docs/BREAK-DECISION.md) | The session clock and the interruption policy |
| [`MESSAGE-ENGINE.md`](docs/MESSAGE-ENGINE.md) | Template selection, tone, escalation |
| [`PRIVACY.md`](docs/PRIVACY.md) | Data inventory and the enforceable properties |
| [`RELEASING.md`](docs/RELEASING.md) | Signing, naming and publishing a release |

These were written before the code. If they disagree with it, one of them is a bug.

## The escalation ladder

POSIX already ships a ladder ordered by how easy each signal is to ignore.

| | Signal | Meaning |
|---|---|---|
| 1 | `SIGTSTP` | Catchable. You are allowed to ignore it. |
| 2 | `SIGINT` | Catchable, but ignoring it is rude. |
| 3 | `SIGTERM` | This is your warning. |
| 4 | `SIGSTOP` | Cannot be caught, blocked, or ignored by anyone, ever. |

Snooze is `SIGALRM` and resume is `SIGCONT`, never "Dismiss". There is no `SIGKILL`: it is
unrecoverable, and it would destroy the thing the name promises.

## Contributing

[`CONTRIBUTING.md`](CONTRIBUTING.md) first. It opens with the one thing that will cost you
an afternoon: macOS keys the Accessibility grant to the binary's cdhash.

The 155 message lines are one JSON file with structured preconditions, so a line can be
written to fire only in the situation it is about.

This repository is the app. The landing site is
[`sigstop-web`](https://github.com/Mohamed-Elshesheny/sigstop-web).

## Licence

[GPL-3.0](LICENSE). Use it, change it, sell it. Distribute a changed copy and the source
goes with it, on the same terms. Nobody closes this and sells the locked version.

The name and the logo are not part of that grant. A fork needs its own name, and
[`TRADEMARK.md`](TRADEMARK.md) explains why in a page: "sigstop makes no network calls"
stops being checkable the moment there is more than one sigstop.
