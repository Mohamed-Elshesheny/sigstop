# Releasing sigstop

How a build gets from this repository onto somebody's machine, and what makes that safe.

This is an operational document. It assumes you are the maintainer, on the machine that holds the
signing key. If you are reading it to audit the process rather than to run it, §1 and §6 are the
interesting parts.

Related: `docs/PRIVACY.md` §2.7 (what the network use is), §2.8 (why signatures carry the guarantee),
§5.3 (why the project changed its mind about in-app updates), and `CLAUDE.md` §4.3.

---

## 0. What a release is called

Every release carries a codename, and the codename is **chosen by a person**. It is worth
saying why, because the obvious assumption is wrong: the project this convention was
modelled on looks like it has a bot inventing names, and reading its workflow shows the
title comes from a pull request somebody wrote by hand. Nothing generates "Flying Rabbit".

**The family: animals that suspend completely and resume with nothing lost.** A wood frog
freezes solid, stops its heart, and thaws in spring with its memory intact. That is the
whole product in one image, and it is the same claim `SIGSTOP` and `SIGCONT` make about a
process. It also gives decades of names without repeating, and the list gets more charming
the further into it you go, which is the opposite of how version numbers age.

    v0.1.x    Sleeping Dormouse 🐿️
    v0.2.x    Wood Frog 🐸
    v0.3.x    Hibernating Bear 🐻
    v0.4.x    Torpid Hummingbird 🐦

**The codename belongs to the minor version, not the patch.** Every `v0.2.x` is Wood Frog.
A patch release is the same animal with a bug fixed, and changing the name every time
would make the name carry no information at all.

The release title is the tag and the name together, which is what shows in the list:

    v0.2.0 Wood Frog 🐸

One rule about the emoji, since there is exactly one: it is the animal, and nothing else.
No rockets, no sparkles, no party poppers. A release is not a celebration, it is a build
somebody is about to run on their own machine.

Cutting it is one command, and everything after the name is automated so no step gets
skipped at two in the morning:

```sh
cd app
make release VERSION=0.2.0 NAME="Wood Frog 🐸"
```

It refuses to run if `Info.plist` and the version disagree, if the tag exists, or if the
working tree is dirty, and it runs the tests, `make verify` and the scenario suite before
it publishes anything. A release that cannot prove its own claims does not go out.

## 0.5 What the notes say

The notes used to be the install instructions and nothing else, identical on every release,
so the one question somebody opens a release page to answer — what is different — was the
one thing it did not say.

**A release with something to say puts it in `app/Resources/RELEASE_HIGHLIGHTS.md`.** Whatever
is in that file goes at the top of the notes, above the generated list, in whatever words the
release deserves. The release consumes it: the file is emptied and committed as part of
cutting the tag, so a sentence written for v0.2.0 cannot reappear on v0.2.1. That is the
failure mode of every hand-kept changelog, and the reason this one is empty by default.

Most patch releases need nothing there. A commit subject is a fine bullet; a release that
changes how the app feels is not.

`Scripts/changelog.py` reads the Conventional Commit subjects between the previous tag and
`HEAD` and groups them: breaking changes first, then Added, Fixed, Faster, Changed and
Documentation, each line prefixed with its scope. CI, build, test and chore commits are
counted in one closing sentence rather than listed, because a reader downloading a build is
not shopping for a workflow tweak. The appcast commit the release makes for itself is
dropped outright.

Nothing is hand-maintained. CLAUDE.md §8 already requires every commit to be a Conventional
Commit, so the changelog is a view of the log rather than a second file that drifts from it.
A commit with a lazy subject line shows up as a lazy bullet on a page strangers read, which
is the right pressure to put on it.

## 1. What makes this safe, in one paragraph

sigstop is distributed outside the App Store and is **ad-hoc signed: no Apple Developer ID, no Team
ID, no notarization.** Apple's code signature therefore proves nothing about who produced a build —
Gatekeeper would be checking a signature against nobody. What makes the update channel safe is
**EdDSA (Ed25519)**: every release archive is signed with a private key that exists only in the
maintainer's login keychain, and the app refuses to install anything whose signature does not verify
against the public key compiled into it. The consequence is worth stating plainly, because it is the
reason this design was chosen: **an attacker who completely owns GitHub, the CDN and the network can
stop users getting updates, and cannot make the app run their code.**

Everything below exists to keep that sentence true.

---

## 2. The keys

### 2.1 Where the private key is

| | |
|---|---|
| Location | macOS **login keychain** on the maintainer's machine |
| Item type | Generic password |
| Service | `https://sparkle-project.org` |
| Account | `sigstop` |
| Description | `private key` |

Inspect the item (this prints metadata, not the key):

```sh
security find-generic-password -a sigstop -s "https://sparkle-project.org"
```

**It is not in this repository, not in CI, and not on any build server, and it must never be.**
`make verify` greps the whole tree for a private key and fails the build if one appears. Releases
are cut on the maintainer's machine for exactly this reason: a CI secret is a key that many people
and one supply chain can reach.

### 2.2 Where the public key is

`app/Resources/Info.plist`, as `SUPublicEDKey`. Current value:

```
v0rY/NWn8izKVHcZl7vVyqRCsrV929pkGNyJpThhv6s=
```

Read it back out of any installed build:

```sh
plutil -extract SUPublicEDKey raw /Applications/sigstop.app/Contents/Info.plist
```

### 2.3 If you need to recreate the pair

Only on a machine that has never had one, or after §6.

```sh
cd app
swift package resolve                                  # puts the Sparkle tools in .build
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin

"$SPARKLE_BIN"/generate_keys --account sigstop         # creates the pair, prints the PUBLIC key
"$SPARKLE_BIN"/generate_keys --account sigstop -p      # print the public key again, any time
```

`generate_keys` will **not** overwrite an existing key: if one is already in the keychain it reuses
it and prints the matching public half. That is the behaviour you want; it means running the command
twice cannot silently orphan every installed copy of the app.

### 2.4 Backing the key up

Losing the private key means you can never ship another update to anyone who already has the app,
and no amount of repository access fixes that. Export it once, to somewhere offline:

```sh
cd app
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account sigstop -x ~/sigstop-ed25519.key
```

Put that file on an encrypted volume or in a password manager, then **delete it from disk**:

```sh
rm -P ~/sigstop-ed25519.key
```

To restore it on a new machine:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account sigstop -f /path/to/sigstop-ed25519.key
```

---

## 3. Cutting a release

### 3.0 Prerequisites, once per machine

```sh
cd app
swift package resolve   # fetches Sparkle's binary artifact, which carries the signing tools
```

Nothing else. `Scripts/appcast.sh` locates `generate_appcast` inside `.build/artifacts` itself,
because the path carries Sparkle's version in it and an exported variable goes stale the first time
the pin moves.

### 3.1 Bump the version

Two keys in `app/Resources/Info.plist`:

- `CFBundleShortVersionString` — the human version, e.g. `0.2.0`. This is what Sparkle compares and
  what the About pane shows.
- `CFBundleVersion` — a monotonically increasing build number. Sparkle uses it to order updates.
  **It must go up every release, without exception.** Two releases sharing a build number produce an
  appcast Sparkle cannot order.

```sh
cd app
plutil -replace CFBundleShortVersionString -string "0.2.0" Resources/Info.plist
plutil -replace CFBundleVersion            -string "2"     Resources/Info.plist
```

Commit this on its own, as a `chore` or `build` commit, before anything is built.

### 3.2 Build, and prove the claims still hold

```sh
cd app
make test             # the Core and Sensors suites. No GUI session, no Xcode
make verify-shipped   # builds the UNIVERSAL bundle and asserts the claims against it
swift run -c release Scenarios
```

Counts are deliberately not written down here. Two of them used to be, they disagreed with each
other and with the suite, and a number in a document is a number nobody updates. `make test` prints
the real one, and CI checks the one on the README against the run.

**`make verify-shipped`, not `make verify`.** They run the same assertions; the difference is what
they run them against. `make verify` checks whatever `make bundle` last produced, which on a
developer's machine is one architecture. The image people download carries two, and `nm` and
`otool` read the native slice by default, so a symbol present only in the Intel half used to come
back clean. `verify-shipped` builds both and the script splits them and checks each.

A note on `make bundle`: it signs **without** Hardened Runtime by default. That is not laziness, and
`docs/PRIVACY.md` §2.9 has the full explanation. Library Validation refuses a framework whose Team
ID differs from the executable's, ad-hoc signatures have no Team ID, and so an ad-hoc-signed app with
an embedded framework builds, verifies, and then dies at launch. If you ever obtain a Developer ID:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" HARDENED=1 make bundle
```

### 3.3 Cut it

One command, and the order inside it matters more than the command does.

```sh
cd app
make release VERSION=0.2.0 NAME="Wood Frog 🐸"
```

In order, it:

1. runs `make test`, `make verify-shipped` and the `Scenarios` harness, and stops on any failure;
2. builds the disk image with `UNIVERSAL=1`, and `dmg.sh` **refuses a single-slice bundle** — 0.1.0
   went out arm64 only under release notes promising Intel, and this is the check that replaced the
   good intentions;
3. runs `Scripts/appcast.sh`, which signs the image just built and writes `updater/appcast.xml`,
   then commits it. **This happens before the tag**, so a release whose feed cannot be signed fails
   with nothing published rather than after the announcement;
4. tags, pushes the tag, and creates the GitHub release with both disk image names — the stable
   `sigstop.dmg` the site links to, and the versioned one a human can read a year later.

Then push `main`, which is what publishes the feed:

```sh
git push
```

`.github/workflows/pages.yml` deploys `updater/` to
`https://mohamed-elshesheny.github.io/sigstop/`, which is `SUFeedURL`. It refuses to deploy a feed
whose enclosure carries no `sparkle:edSignature`.

**This is the step 0.1.0 shipped without.** The feed URL was compiled into every copy of the app,
GitHub Pages was never enabled, and the address returned 404, so *Check for updates* failed for
everyone. Nothing upstream noticed, because nothing upstream can: the feed lives outside the build.

### 3.4 Signing by hand, if you ever have to

`Scripts/appcast.sh` is the supported path. These are the same commands, for when something has gone
wrong and you need to see it happen.

```sh
cd app
export SPARKLE_BIN="$(find .build/artifacts -type d -name bin -path '*Sparkle*' | head -1)"

"$SPARKLE_BIN"/generate_appcast \
  --account sigstop \
  --download-url-prefix "https://github.com/Mohamed-Elshesheny/sigstop/releases/download/v${VERSION}/" \
  --link "https://github.com/Mohamed-Elshesheny/sigstop" \
  -o ../updater/appcast.xml <directory holding the .dmg>
```

`--account sigstop` is not optional. The private key is in the login keychain under the account
`sigstop`, and Sparkle's tools default to `ed25519`. Without the flag they print *"Private key for
account ed25519 not found in the Keychain"* and stop, which reads like the key is gone when it is
only named something else.

The `<enclosure>` must carry `sparkle:edSignature`:

```sh
grep -o 'sparkle:edSignature="[^"]*"' ../updater/appcast.xml
```

**No `edSignature` means no signature, which means no user will ever be able to install it.** That is
Sparkle failing safe, and it is the correct behaviour, but it is silent until somebody reports "the
update never installs." `appcast.sh` refuses to write a feed without one for exactly this reason.

To sign or check a single file:

```sh
"$SPARKLE_BIN"/sign_update --account sigstop "dist/sigstop-${VERSION}-<codename>.dmg"
```

**The signature is over the bytes of the file that is published.** Sign the image you upload, not a
rebuild of it: two builds of the same commit are not byte-identical, and a feed signed over the
wrong copy fails verification on every machine while looking perfectly well-formed here.

### 3.5 Verify it end to end, as a user would

Do not skip this. The feed is the one artifact no local command can prove.

```sh
# 1. The feed is reachable and is XML
curl -sSI https://mohamed-elshesheny.github.io/sigstop/appcast.xml | head -3

# 2. The download URL in the feed resolves, and is the size the feed claims
URL=$(curl -s https://mohamed-elshesheny.github.io/sigstop/appcast.xml \
  | grep -o 'url="[^"]*\.dmg"' | head -1 | cut -d'"' -f2)
curl -sSIL "$URL" | grep -iE '^(HTTP|content-length)'

# 3. The published image really does carry both architectures
curl -sSL "$URL" -o /tmp/check.dmg
hdiutil attach /tmp/check.dmg -nobrowse -quiet -mountpoint /tmp/checkmnt
lipo -archs /tmp/checkmnt/sigstop.app/Contents/MacOS/sigstop   # expect: x86_64 arm64
hdiutil detach /tmp/checkmnt -quiet

# 4. An older build actually offers, downloads, verifies and installs the update
```

For (4), keep a copy of the previous release, run it, and press **Check for updates** in
Settings → About. Watch it go: *Asking the feed… → n.n.n is available → Downloading… → Signature
verified. Unpacking… → verified and ready*. If it stops at an error, the message in the About pane is
Sparkle's own and names the reason.

There is no substitute for this test. Everything upstream of it can be green while the feed is a 404,
the tag is misspelled, or the signature was generated against a key the shipped build does not carry.
All three of those have happened here.

---

## 4. The release checklist

Copy this into the release PR.

- [ ] `CFBundleShortVersionString` bumped
- [ ] `CFBundleVersion` bumped, and higher than the last release
- [ ] `SGReleaseName` set to the codename, because the About pane reads it and `release.sh` checks it
- [ ] `make release VERSION=… NAME=…` ran clean, with no step skipped
- [ ] The published image is `x86_64 arm64`, checked against the uploaded file, not the local one
- [ ] `sparkle:edSignature` present on the new enclosure in `updater/appcast.xml`
- [ ] `main` pushed, Pages deployed, and the feed URL returns 200
- [ ] Previous build updates itself successfully, end to end
- [ ] `docs/PRIVACY.md` reviewed if anything about the network behaviour changed (§9 requires it)

---

## 5. Things that will bite you

**Archiving with a plain `zip`.** This pipeline ships a disk image and `hdiutil` gets this right,
but if you ever archive by hand, `zip` flattens `Sparkle.framework`'s version symlinks: the update
installs and the app then will not launch. `ditto -c -k --sequesterRsrc --keepParent`, never `zip`.

**Signing a rebuild instead of the file you upload.** The EdDSA signature is over the bytes. Two
builds of the same commit are not byte-identical, so a feed signed over a local rebuild fails
verification on every machine while looking perfectly well-formed on yours. `release.sh` signs and
uploads the same file; keep it that way.

**Shipping one architecture.** 0.1.0 went out arm64 only under release notes that promise Intel,
and an Intel user finds out by the app refusing to open. `dmg.sh` now refuses a single-slice bundle,
and step 3.5 checks the *published* file rather than the local one, because those are different
questions.

**Forgetting `CFBundleVersion`.** Sparkle orders updates by it. Two releases with the same build
number produce a feed it cannot order, and the symptom is an update that is never offered.

**Editing `appcast.xml` by hand after signing.** The appcast itself can be signed; any manual edit
invalidates it. Re-run `generate_appcast` rather than patching the XML.

**Changing `SUFeedURL`.** An installed build only ever reads the URL compiled into *itself*. If the
site moves to a custom domain, you must ship a release pointing at the new URL **and keep the old URL
serving** until you are willing to strand everyone who did not take that release. There is no way to
redirect an installed app except by being reachable at the address it already knows.

**Shipping a single-architecture build without meaning to.** `swift build` produces a native slice
only, so a release cut on Apple silicon carries `arm64` and `generate_appcast` faithfully writes
`<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>` into the feed. Sparkle then
correctly refuses to offer that update to an Intel Mac, which looks exactly like "the updater is
broken" from the other side.

`swift build --arch arm64 --arch x86_64` is the obvious fix and **it does not work here**: that flag
routes through `xcbuild`, which ships with Xcode, and this repository deliberately requires only
Command Line Tools (`CLAUDE.md` §2). It fails with *"xcbuild executable ... does not exist."*

Build the two slices separately and `lipo` them, which does work with CLT alone. **Order matters:**
`lipo` invalidates the code signature, so the fattening has to happen before the bundle is sealed,
not after.

```sh
cd app

# 1. Both slices.
swift build -c release                                       # native (arm64 here)
swift build -c release --triple x86_64-apple-macosx14.0 \
                       --scratch-path .build-x86             # the other one

# 2. Assemble and sign as usual.
make bundle

# 3. Replace the executable with the fat one, then re-seal the bundle.
lipo -create -output /tmp/sigstop-universal \
     .build/release/sigstop .build-x86/x86_64-apple-macosx/release/sigstop
cp /tmp/sigstop-universal dist/sigstop.app/Contents/MacOS/sigstop
codesign --force --sign "${SIGN_IDENTITY:--}" \
         --entitlements Resources/sigstop.entitlements dist/sigstop.app

# 4. Confirm, and re-run the checks against what you actually just signed.
lipo -info dist/sigstop.app/Contents/MacOS/sigstop           # expect: x86_64 arm64
codesign --verify --deep --strict dist/sigstop.app
./Scripts/verify.sh
```

Do **not** run `make bundle` again after step 3: it re-runs `swift build` and copies the
native-only product back over the fat one, silently undoing all of it. If you would rather not carry
this dance, ship arm64-only and say so in the release notes. Shipping arm64-only by accident, while
the appcast quietly tells every Intel user there is no update, is the outcome this paragraph exists
to prevent.

Sparkle's own framework is already universal, so nothing else needs doing.

**Cutting a release from CI.** Do not. The private key would have to live there, which defeats §1.

**Assuming Gatekeeper protects anything here.** It does not. There is no Developer ID. `spctl` will
not say "Notarized Developer ID" and users will see the unidentified-developer dialog on first
launch. The EdDSA signature is what protects updates; say so in the release notes rather than letting
people assume Apple is checking.

---

## 6. If the private key is lost or stolen

This is the scenario the whole design has a single point of failure for, and pretending otherwise
would be worse than writing it down.

**If it is lost** (machine died, no backup): you can never ship an update that any installed copy
will accept. Every existing install is permanently frozen at its current version. The only path is
generating a new key pair, shipping a build with the new `SUPublicEDKey`, and telling people to
download and replace the app by hand. Section 2.4 exists so that this never happens.

**If it is stolen:** whoever has it can sign updates that every installed copy will accept, and
rotating the key does not reach them — they verify against the public key inside the build they
already have. Do all of these, in this order:

1. Publish a security advisory on the repository. Loudly. Before anything else.
2. Generate a new key pair (§2.3, after deleting the compromised keychain item).
3. Ship a new release carrying the new `SUPublicEDKey`, distributed **by hand**: GitHub release,
   Homebrew cask, and the website. Not through the in-app updater, which the attacker can also
   reach.
4. Get the Homebrew cask updated, since `brew upgrade` is the route most likely to reach people who
   are not reading advisories.
5. Take the old appcast down, so the compromised feed URL serves nothing rather than serving what the
   attacker put there.

Note what is *not* on that list: revoking anything. There is no certificate authority in this design
and nothing to revoke. That is the cost of not depending on one.

---

## 7. Sparkle itself

Pinned with `exact: "2.10.0"` in `app/Package.swift`, deliberately not a range. Upgrading it is a
normal, reviewable commit:

```sh
cd app
# edit Package.swift, change the exact version
swift package resolve
make build && make test && make verify
```

`make verify` reads the shipped version out of the embedded framework's own `Info.plist` and prints
it, so the release output records what actually went out rather than what `Package.resolved` intended.

The Sparkle command-line tools ship inside the resolved artifact and are not vendored into this
repository:

```
app/.build/artifacts/sparkle/Sparkle/bin/
├── generate_keys      create, export, import and print the EdDSA key pair
├── sign_update        sign one archive, or print an existing signature
├── generate_appcast   sign every archive in a directory and write appcast.xml
└── BinaryDelta        build delta updates (not used yet)
```

They are rebuilt by `swift package resolve`, so `make clean` costs you nothing but a re-download.
