# Trademark policy

Short version: **the code is yours, the name is not.**

Fork it, change it, sell it, embed it in something else, ship it inside your
company. That is all explicitly fine and we would rather you did than asked.
What you cannot do is ship your modified version still calling itself
`sigstop`, or still wearing the sigstop logo.

## Why the project is Apache-2.0 and not MIT

MIT is a fine license and it is shorter. We chose
[Apache License 2.0](LICENSE) for two clauses MIT does not have:

**Section 6, Trademarks.** Apache-2.0 states in the license itself that it
grants no permission to use the licensor's names or marks. MIT is silent on
the subject. Trademark law applies either way, but a reader should not have to
know trademark law to understand the rules of a project. Putting it in the
license means the answer is in the file everyone already reads.

**Section 3, Patents.** Apache-2.0 includes an express patent grant from
contributors, and terminates that grant for anyone who starts patent
litigation over the software. MIT grants no patent rights explicitly at all.
For anything a company might install on developer machines, that matters.

The trade-off, stated honestly: Apache-2.0 is 201 lines where MIT is 21, and
it requires you to keep the `NOTICE` file and state your changes. If that is
genuinely a problem for your use case, open an issue and make the argument.

## What you may do without asking

- Fork the repository and modify anything in it.
- Distribute your fork, free or paid.
- Use the code in a commercial or closed-source product.
- Say your project "is based on sigstop", "is a fork of sigstop", or "is
  compatible with sigstop". Describing the origin truthfully is explicitly
  allowed by Section 6, and is also just accurate.
- Use the name in articles, talks, reviews, comparisons, and tutorials. You do
  not need permission to write about software.
- Build and run unmodified sigstop yourself, including inside a company.

## What requires a different name

- Distributing a **modified** build still named `sigstop`.
- Using the sigstop logo, wordmark, or menu bar icon as the mark of your
  project, product, or company.
- A package, cask, app bundle id, or domain that implies it is the official
  sigstop when it is not.
- Anything that would lead a reasonable developer to believe your version is
  this project.

The reason is not ownership for its own sake. If a fork with different
behaviour ships under this name, then "sigstop makes exactly one network
request, only when you press the button, and verifies every update against a key
compiled into the app" stops being a claim anyone can verify, because there would
be more than one sigstop. The name is doing load-bearing work in the privacy promise, which is
the whole product.

## Renaming a fork

Pick your own name and replace these:

| Where | Current value |
|---|---|
| Bundle identifier | `dev.sigstop.app` |
| Executable / product | `sigstop` |
| Swift modules | `SigstopCore`, `SigstopSensors`, `SigstopApp` |
| App icon | `app/Resources/sigstop.icns` |
| Menu bar mark | `app/Sources/SigstopApp/Views/MenuBarIcon.swift` |

Keep the `NOTICE` file and the `LICENSE`. Attribution stays; identity changes.

The wordmark is not in this repository. It is drawn by the landing site, which lives in
[`sigstop-web`](https://github.com/Mohamed-Elshesheny/sigstop-web) and is under exactly these
terms: the code there is Apache-2.0, the name and the mark it draws are not.

## Questions

Open an issue. If you are unsure whether your use is fine, it probably is, and
asking costs nothing.
