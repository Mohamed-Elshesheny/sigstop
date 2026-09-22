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

<img src="docs/images/prompt.png" width="100%" alt="A sigstop break prompt over a Mac desktop: Tab. Tab. Tab. Tab. You are 200 lines into a file you have never read. Take five and go meet your new codebase.">

</div>

## ✨ Not another timer

A timer fires in the middle of your standup. sigstop doesn't.

<img src="docs/images/compare.png" width="100%" alt="A timer versus sigstop. Fires during your standup: a timer does, sigstop waits for the call to end. Cuts you off mid-thought: a timer does, sigstop picks a pause. Knows Xcode from YouTube: a timer doesn't, sigstop does. Counts time you were away: a timer does, sigstop counts only real work. Tells you why it's quiet: a timer doesn't, sigstop has --doctor.">

- 😏 **Speaks your language.** 187 lines for editors, terminals, browsers, AI tools and Xcode, in four tones from friendly to nuclear.
- 📊 **Shows your day.** Active time, your longest unbroken stretch and the breaks you kept.
- 🔋 **Barely there.** It sleeps between checks, so you won't notice it on your battery or in your Mac's speed.
- 🔒 **Private by design.** Zero permissions required, and nothing leaves your Mac.

## 🧭 How it works

You're a process. sigstop only stops you at a safe point, and you come back with everything intact.

<img src="docs/images/terminal.png" width="100%" alt="A terminal: ps shows you running for 47 minutes in your editor. sigstop waits for a natural pause, sends kill -TSTP and you are stopped. Five minutes and a glass of water later, kill -CONT, and you continue with nothing lost.">

Keep ignoring it and it asks a little louder, in signals your shell already knows. The last one claims it can't be ignored. It can.

<img src="docs/images/ladder.png" width="100%" alt="The escalation ladder: SIGTSTP, a nudge. SIGINT, a bit rude. SIGTERM, your warning. SIGSTOP, the bluff. Snooze is SIGALRM, and coming back is SIGCONT, right where you left off.">

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

<details>
<summary><b>"sigstop can't be opened because Apple cannot check it"</b></summary>
<br>

That's the quarantine, not a malware warning. Run the Terminal command in [Install](#install) once.

</details>

<details>
<summary><b>It hasn't reminded me in a while. Is it broken?</b></summary>
<br>

Probably not. Ask it, and it tells you exactly why it's holding back:

```sh
/Applications/sigstop.app/Contents/MacOS/sigstop --doctor
```

</details>

<details>
<summary><b>It interrupted a call. How do I stop that?</b></summary>
<br>

Click **I'm in a meeting** in the menu bar. It holds breaks for up to two hours, or until you click **Not in a meeting**.

</details>

<details>
<summary><b>Does it read my code or what I type?</b></summary>
<br>

No. Out of the box it sees which app is in front, whether you're idle, and whether your mic or camera is on. Never keystrokes, clipboard or what's on screen. Window titles and your git branch are optional upgrades, and [PRIVACY.md](docs/PRIVACY.md) lists everything it stores.

</details>

<details>
<summary><b>Where is my data, and how do I delete it?</b></summary>
<br>

In `~/Library/Application Support/dev.sigstop.app`. **Settings → Data → Delete my data…** removes it all.

</details>

<details>
<summary><b>How do I uninstall it?</b></summary>
<br>

Quit sigstop from the menu bar, drag it to the Trash, then remove what it stored:

```sh
rm -rf ~/Library/Application\ Support/dev.sigstop.app
rm -rf ~/Library/Caches/dev.sigstop.app ~/Library/HTTPStorages/dev.sigstop.app
defaults delete dev.sigstop.app
```

</details>

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
