<div align="center">

<img src="docs/images/icon.png" width="112" alt="sigstop icon">

# sigstop

**You're a developer. Not a server.**

Break reminders that know what you're doing, and when not to interrupt.

[![Download for macOS](https://img.shields.io/badge/Download_for_macOS-000000?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/Mohamed-Elshesheny/sigstop/releases/latest/download/sigstop.dmg)

macOS 14+ · Apple Silicon and Intel · Free and open source · [Website](https://sigstop-app.vercel.app)

[![CI](https://github.com/Mohamed-Elshesheny/sigstop/actions/workflows/ci.yml/badge.svg)](https://github.com/Mohamed-Elshesheny/sigstop/actions/workflows/ci.yml)
[![336 tests](https://img.shields.io/badge/tests-336%20passing-3fb950?style=flat-square)](#build)
[![GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)](LICENSE)

<img src="docs/images/prompt.png" width="800" alt="A sigstop break prompt over a Mac desktop: Tab. Tab. Tab. Tab. You are 200 lines into a file you have never read. Take five and go meet your new codebase.">

</div>

## ✨ What it does

A timer fires in the middle of your standup. sigstop doesn't.

- 🧠 **Knows what you're doing.** Which app is in front, how long you've really been at it, and how sure it is.
- 🎙️ **Stays quiet on calls.** A live camera or a call on your mic means it waits.
- ⏸️ **Waits for a pause.** It picks a natural gap in your work, not the middle of a thought.
- 😏 **Speaks your language.** 187 lines for editors, terminals, browsers, AI tools and Xcode, in four tones from friendly to nuclear.
- 📊 **Shows your day.** Active time, your longest unbroken stretch and the breaks you kept.
- 🔋 **Barely there.** It sleeps between checks, so you won't notice it on your battery or in your Mac's speed.
- 🔒 **Private by design.** Zero permissions required, and nothing leaves your Mac.

## 🧭 How it decides

```
45 min of real work          idle time doesn't count
  → what's in front?         an editor, a terminal, a call
  → how sure am I?           unsure means it says less, never more
  → mic or camera live?      then it waits
  → a natural pause?         then it asks
```

Keep ignoring it and it asks a little louder, in signals your shell already knows. The last one claims it can't be ignored. It can.

<img src="docs/images/ladder.png" width="760" alt="The escalation ladder: SIGTSTP, a nudge. SIGINT, a bit rude. SIGTERM, your warning. SIGSTOP, the bluff. Snooze is SIGALRM, and coming back is SIGCONT, right where you left off.">

<a id="install"></a>

## 📦 Install

1. [Download `sigstop.dmg`](https://github.com/Mohamed-Elshesheny/sigstop/releases/latest/download/sigstop.dmg)
2. Open it and drag **sigstop** into **Applications**
3. Clear the quarantine once (below), then open it

> [!IMPORTANT]
> sigstop isn't signed with a paid Apple Developer ID, so macOS blocks it the first time. That's expected, not a malware warning, and you only do it once.

**Recommended: Terminal**

```sh
xattr -dr com.apple.quarantine /Applications/sigstop.app
```

Then open sigstop as usual. It lives in your menu bar.

**Or: System Settings**

1. Open sigstop and close the warning
2. Go to **System Settings → Privacy & Security** and scroll down
3. Click **Open Anyway** and confirm (needs an admin account)

Want proof it's the real build? Compare the `sha256` on the [release page](https://github.com/Mohamed-Elshesheny/sigstop/releases/latest), or [build it yourself](#build).

**Updates:** Settings → About → **Check for updates**. Every update is verified against a signing key built into the app before it installs.

## 🔒 Privacy

- 👀 Reads **which** app is in front, never what's in it. No code, keystrokes, clipboard or screen.
- 🙅 **Needs zero permissions.** Accessibility (window titles) and your git branch are optional upgrades.
- 📡 **One network request**, only when you press Check for updates. No analytics, no account, no ID.
- 💾 **Stays on your Mac.** Raw events are deleted after 7 days.

Don't take our word for it: `make verify` checks these claims against the built app, and [PRIVACY.md](docs/PRIVACY.md) lists everything it stores.

## ❓ FAQ

**"sigstop can't be opened because Apple cannot check it"**
That's the quarantine. Run the Terminal command in [Install](#install).

**It hasn't reminded me in a while. Why?**
Ask it. It explains itself:

```sh
/Applications/sigstop.app/Contents/MacOS/sigstop --doctor
```

**It interrupted a call.**
Click **I'm in a meeting** in the menu bar. It holds breaks for up to two hours, or until you click **Not in a meeting**.

**Where is my data, and how do I delete it?**
In `~/Library/Application Support/dev.sigstop.app`. **Settings → Data → Delete everything** removes it all.

## 🗑️ Uninstall

Quit sigstop from the menu bar, drag it to the Trash, then remove what it stored:

```sh
rm -rf ~/Library/Application\ Support/dev.sigstop.app
defaults delete dev.sigstop.app
```

<a id="build"></a>

## 🛠️ Build from source

Command Line Tools are enough. No Xcode.

```sh
git clone https://github.com/Mohamed-Elshesheny/sigstop
cd sigstop/app
make run     # build and launch
make test    # the test suite, no GUI needed
```

How it works is in [`docs/`](docs). Want to help? Start with [CONTRIBUTING.md](CONTRIBUTING.md).

## 📄 License

[GPL-3.0](LICENSE). The name and logo are not covered; see [TRADEMARK.md](TRADEMARK.md).
