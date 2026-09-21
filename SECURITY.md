# Security policy

## Reporting a vulnerability

Use GitHub's
[Report a vulnerability](https://github.com/Mohamed-Elshesheny/sigstop/security/advisories/new)
form. It is private until we publish it together. Do not open a normal issue for anything
with a security consequence, because the tracker is public and so is the exploit.

You should get a first reply within a few days, and you will be kept informed until it is
fixed and announced. Credit is yours unless you ask otherwise.

Report a flaw in a dependency to whoever maintains it. The only third-party code shipped in
the binary is [Sparkle](https://github.com/sparkle-project/Sparkle).

## What is worth reporting

This app is unsandboxed, runs at login, and on a machine where the user has granted it
Accessibility it can read window titles. The things that would matter most:

- Anything that reads content the app has no business reading: file contents, keystrokes,
  the clipboard, screen contents, message text. `docs/PRIVACY.md` lists what it may read,
  and anything beyond that list is a bug whether or not it is exploitable.
- Anything that sends data anywhere. There is exactly one network call, a `GET` of a static
  appcast, and `make verify` asserts that against the built binary. A second one is a
  finding.
- A way to make the updater install something the maintainer did not sign. Updates are
  gated on an EdDSA signature checked against a key compiled into the app, and that check
  is the thing standing between a compromised CDN and arbitrary code on your machine.
- Anything that writes outside `~/Library/Application Support/dev.sigstop.app`, or that
  leaves a file in it readable by another user on the same Mac.

## What is already known and is not a vulnerability

**Builds are ad-hoc signed and not notarized.** macOS refuses to open a download until the
quarantine flag is cleared, and the README says how. This is a cost decision, not an
oversight, and it is written down in `docs/RELEASING.md`.

**`--doctor` prints what the app can currently see**, including a redacted window title,
and the bug form asks people to paste it. Read it before you paste it. That is a documented
trade, not a leak, but if you find something in that output nobody would expect to be
there, report it.

**The app cannot tell whether your screen is being shared.** There is no permission-free
way to know, and asking for Screen Recording would mean asking for the one permission that
would let this app read your screen. `docs/PRIVACY.md` states the consequence plainly.
