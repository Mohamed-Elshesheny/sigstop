# Contributing to sigstop

## Read this first, it will save you an afternoon

**macOS keys the Accessibility grant to the binary's cdhash, and `swift build` ad-hoc signs,
so the cdhash changes on every compile.** The grant you just gave can vanish the next time
you build, System Settings fills with stale `sigstop` entries, and you will be certain the
permission code is broken.

Create one stable identity and sign with it:

```sh
cd app
make dev-cert                      # prints the one-time Keychain Access steps
SIGN_IDENTITY=sigstop-dev make run
```

Never debug this by re-granting the permission. Check with `make doctor`, which reports the
window title as `readable` only when the process is genuinely trusted.

## Setup

```sh
git clone https://github.com/Mohamed-Elshesheny/sigstop
cd sigstop/app
make run      # build, bundle, launch
make test     # the badge export check, then the suites; no GUI session required
make doctor   # exactly what the app can observe right now
make verify   # assert the privacy properties against the built binary
make smoke    # run the built app as if on somebody else's Mac
make bench    # what it costs a battery, idle and during a break
```

There is **no Xcode project and no Xcode requirement**. `open app/Package.swift` if you want
the editor. Do not add a `.xcodeproj`.

The landing site is a separate repository,
[`sigstop-web`](https://github.com/Mohamed-Elshesheny/sigstop-web).

## The rules a PR cannot break

All of these are in [`CLAUDE.md`](CLAUDE.md) with the reasoning. The short version:

| | |
|---|---|
| **Layering is one way** | `App -> Sensors -> Core`. `SigstopCore` never imports AppKit. |
| **Core never reads the clock** | It takes an injected `TimeSource`. That is why the engine is testable without a window server. |
| **Never overclaim** | When two activities cannot be told apart, degrade to their shared parent. Never guess between siblings. |
| **Zero permissions works** | Accessibility and git context are upgrades. A feature that requires a permission is a design error. |
| **Never read content** | Window titles only, redacted. Never bodies, keystrokes, clipboard, screen or messages. |
| **One network call** | The update check. `make verify` enforces it. A second one changes `CLAUDE.md` first, in its own PR. |

## Adding support for an app

The easiest useful contribution, and it needs **zero changes to core code**. If it does, the
extension point is wrong and fixing that is the better PR.

A provider is a pure function from signals to an observation: no state, no I/O, `Sendable`.
To test one, construct a `SignalContext` literal.

1. Add it in `app/Sources/SigstopSensors/Providers/`.
2. Declare its `AppClaim`s. Resolution ranks exact bundle id > prefix > executable name, so
   `com.jetbrains.` covers the family.
3. Confirm the bundle id rather than inventing it: `osascript -e 'id of app "Zed"'`. If you
   cannot, cap the verdict low with `ProviderVerdict.maximumConfidence` and add the id to the
   table in `docs/ACTIVITY-DETECTION.md` §5.6 marked ⚠️ UNVERIFIED. That table is where
   verification status lives; Swift source carries no comments, so there is nowhere else.

## Writing a joke

The 187 lines live in `app/Sources/SigstopCore/Message/corpus.json` with structured
preconditions, so a line can fire only in the situation it is about:

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

**The rails, at every tone including NUCLEAR:** never about body weight, appearance, medical
conditions, mental health, competence, or job security. Nuclear is absurd, never cruel.

**No medical claims.** "Your posture", never "your health". An attention or performance claim
needs a citation with a resolvable DOI, and if a paper disputes it, cite that one too.
Inventing a citation is the fastest way to destroy everything else on the page.

**Set `claimsActivity` honestly.** A line that names what someone is doing must declare it, so
the engine can refuse it when confidence is low.

Packs ship in-tree deliberately. A pack cannot execute anything, but it can carry manipulative
*text*, and no schema catches that. A human reading it does.

## Renaming a badge

The ten names exist in this repository and in the site's `copy.ts`. `make test` runs
`make badges-check` first and fails if `app/Exports/badges.json` has drifted from the Swift
catalogue, so a rename shows up as a one-line diff that tells you the site is affected.

Rename in `Badge.swift`, run `make badges`, commit the export, and open the matching PR on
the site. The check cannot force the other repository to follow; it makes sure nobody misses
that it has to.

## Commits and PRs

[Conventional Commits](https://www.conventionalcommits.org). Types: `feat` `fix` `refactor`
`perf` `docs` `test` `build` `ci` `chore`. Scopes: `core` `sensors` `app` `docs` `ui`.
`ui` files a `feat`, `fix` or `perf` under 🎨 UI in the release notes, as does any such change
whose shipped files are all under `SigstopApp/Views/` or are `Scripts/dmg.sh`.

**Keep them short.** Most commits are a subject line. A body is for the one thing the diff
cannot say, two or three lines.

**One fix, one commit, straight onto `main`.** No merge commits: a branch cut before a fix
landed carries the old file, and merging it reverts that fix silently.

**No AI attribution.** No `Co-Authored-By` for an assistant, no generated-with footers. The
commit log is a record of intent, and intent belongs to a person.

Before opening a PR: `make test && make verify`. Keep `docs/` in sync in the same PR as the
behaviour change; the design documents are normative.

## Reporting a bug

Run `make doctor` and paste the output. It prints every signal the app can see, its tier, the
inferred activity, the confidence and the evidence, and it is honest about what is
unavailable and why. It sends nothing anywhere. Read it before you post it.

Anything with a security consequence goes to [`SECURITY.md`](SECURITY.md) instead, privately.

## Licence

Contributions are under [GPL-3.0](LICENSE). The name and the logo are not part of that grant:
see [`TRADEMARK.md`](TRADEMARK.md). Fork freely; a modified build needs its own name.
