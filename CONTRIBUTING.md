# Contributing to sigstop

Thanks for looking. This file is short on ceremony and long on the two or three things that
will actually cost you an afternoon if nobody tells you.

## Read this one first, it will save you an afternoon

**macOS ties the Accessibility grant to the binary's cdhash.** `swift build` ad-hoc signs,
and the cdhash changes on every single build. So the grant you just gave silently evaporates
the next time you compile, System Settings fills up with stale `sigstop` entries, and you
will convince yourself the permission code is broken.

It is not. Create one stable self-signed identity and sign with it:

```sh
cd app
make dev-cert                      # prints the one-time Keychain Access steps
SIGN_IDENTITY=sigstop-dev make run # from then on the grant survives rebuilds
```

Never debug this by re-granting the permission. You are fighting TCC, and TCC wins.

## Getting set up

```sh
git clone https://github.com/Mohamed-Elshesheny/sigstop
cd sigstop/app
make run     # build, bundle, launch
make test    # 83 tests, no GUI session required
make doctor  # print exactly what the app can observe right now
make verify  # assert the privacy properties against the built binary
```

There is **no Xcode project and no Xcode requirement**; Command Line Tools are enough.
`open app/Package.swift` if you want the Xcode editor. **Do not add a `.xcodeproj`**: it
breaks the CI assumption and produces a generated XML file that conflicts on every
concurrent PR.

For the website: `cd web && npm run dev`.

## The rules that are not negotiable

These are in [`CLAUDE.md`](CLAUDE.md) in full. The short version, because a PR that breaks
one of them cannot be merged no matter how good it is:

**Layering is one way.** `App → Sensors → Core`. `SigstopCore` must never import AppKit.
That is what lets the engines be tested without a window server, which matters because
there is no Xcode here and therefore no UI test harness.

**Core never reads the clock.** It takes an injected `TimeSource`. "45 minutes of
continuous work triggers a break" is a microsecond unit test, not a hope.

**Never claim more confidence than the signals support.** When two activities cannot be
told apart, degrade to their shared parent. Never pick between siblings by guessing.
Telling someone they have been debugging for 61 minutes when they were writing docs
destroys the only thing this product has.

**The app works with zero permissions.** Accessibility and git context are upgrades. A
feature that hard-requires a permission is a design error.

**Never read content.** Window titles only, at Tier 1, redacted. Never document bodies,
keystrokes, clipboard, screen contents, or message text.

**One network call, and it is the update check.** No telemetry, no crash reporting, no
analytics, no font CDN. `make verify` enforces this against the built binary; adding a
second network call means changing `CLAUDE.md` first, in its own PR, with the argument
written out.

## Adding support for an app

This is the easiest useful contribution and it needs **zero changes to core code**. If it
does not, the extension point is wrong, and fixing the extension point is the better PR.

A provider is a pure function from signals to an observation: no state, no I/O, `Sendable`.
To test one, construct a `SignalContext` literal.

1. Add a provider in `app/Sources/SigstopSensors/Providers/`.
2. Declare its `AppClaim`s. Resolution ranks exact bundle id > prefix > executable name >
   regex, so `com.jetbrains.` as a prefix covers the whole family.
3. If you are not certain of a bundle id, mark it `// UNVERIFIED` rather than inventing one.
   Confirm with: `osascript -e 'id of app "Zed"'`

## Writing a joke

The 149 lines live in `app/Sources/SigstopCore/Message/corpus.json`, with structured
preconditions, so a line can be written to fire only in a specific situation:

```json
{
  "id": "xcode.friday.evening",
  "text": "...",
  "tone": "sarcastic",
  "minConfidence": 0.8,
  "claimsActivity": true,
  "when": [{ "p": "app", "in": ["xcode"] }, { "p": "workBand", "in": ["marathon"] }]
}
```

Packs ship in-tree only and that is deliberate, not a missing feature. A pack is data and
cannot execute anything, but it can carry hostile or manipulative *text*, and no schema
catches that. A human reading it before it ships does. The reasoning is in
[`docs/MESSAGE-ENGINE.md`](docs/MESSAGE-ENGINE.md) §7.3.

**The rails, and they apply at every tone including NUCLEAR:** never about body weight,
appearance, medical conditions, mental health, competence, or job security. Nuclear is
absurd and theatrical, never cruel.

**No medical claims anywhere**, in the app or on the site. Say "your posture", never "your
health". An attention or performance claim needs a citation with a resolvable DOI, and if a
paper disputes it, cite that one too. If you cannot find a real source, the claim does not
ship. Inventing a citation is the fastest way to destroy everything else on the page.

**Set `claimsActivity` honestly.** If a line names what the developer is doing, it must
declare that, so the engine can refuse to select it when confidence is low. A line that
requires `{branch}` is never selected when the branch is unknown.

## Commits and PRs

Every commit is a [Conventional Commit](https://www.conventionalcommits.org):

```
type(scope): subject
```

Short. Most commits are a subject line and nothing else. Add a body only for the one thing the
diff cannot tell you, and keep it to two or three lines. Longer reasoning goes in `docs/` or in
a doc comment, where it will be found.

Types: `feat` `fix` `refactor` `perf` `docs` `test` `build` `ci` `chore`.
Scopes: `core` `sensors` `app` `web` `docs`.

**No AI attribution.** No `Co-Authored-By` for an assistant, no "generated with" footers,
no tool names in the message or the author field. The commit log is a record of intent, and
intent belongs to a person.

Before you open a PR:

```sh
cd app && make test && make verify
cd ../web && npm run build
```

Keep `docs/` in sync in the same PR as the behaviour change. The design documents are
normative: if the code and a document disagree, one of them is a bug, and the PR should say
which and fix it.

## Reporting a bug

Run `sigstop --doctor` and paste the output. It exists for exactly this: it prints every
signal the app can see, which tier it came from, the inferred activity, the confidence, and
the evidence behind it, and it is honest about what is unavailable and why. It sends
nothing anywhere.

## Licence

Contributions are under [Apache 2.0](LICENSE). The name and the logo are not part of that
grant: see [`TRADEMARK.md`](TRADEMARK.md). Fork freely; a modified build needs its own name.
