# Trademark policy

Short version: **the code is yours, the name is not.**

Fork it, change it, sell it, embed it in something else, ship it inside your
company. That is all explicitly fine and we would rather you did than asked.
What you cannot do is ship your modified version still calling itself
`sigstop`, or still wearing the sigstop logo.

## Why the project is GPL-3.0

The licence answers one question the owner asked directly: **nobody takes this, closes it,
and sells the closed version.** Under the [GNU General Public License v3](LICENSE) anyone
may use it, change it, and charge money for it, and anyone who distributes a changed copy
has to hand over the source on the same terms. Selling is fine. Selling a locked box is
not.

That is a deliberate trade and it costs two things worth naming rather than discovering:

**The Mac App Store is closed to this.** Its terms conflict with GPLv3's requirements, which
is why VLC was pulled from it in 2011. If this ever wants to be there, the licence has to
change first, and changing it needs every contributor's agreement.

**The licence itself says nothing about the name.** Apache-2.0 has a trademark clause and
the GPL does not, so the protection below rests on trademark law rather than on a line in
the licence. That is weaker on paper and unchanged in practice: a licence has never been
what stops someone shipping a fork called sigstop, and the reason it must not happen is in
the next section.

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
terms: the code there is GPL-3.0, the name and the mark it draws are not.

## Questions

Open an issue. If you are unsure whether your use is fine, it probably is, and
asking costs nothing.
