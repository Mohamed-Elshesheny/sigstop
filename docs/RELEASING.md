# Releasing sigstop

How a build gets from this repository onto somebody's machine, and what makes that safe.

This is an operational document. It assumes you are the maintainer, on the machine that holds the
signing key. If you are reading it to audit the process rather than to run it, §1 and §6 are the
interesting parts.

Related: `docs/PRIVACY.md` §2.7 (what the network use is), §2.8 (why signatures carry the guarantee),
§5.3 (why the project changed its mind about in-app updates), and the *One network call* row of
[`CONTRIBUTING.md`](../CONTRIBUTING.md#the-rules-a-pr-cannot-break).

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

It refuses to run if `Info.plist` disagrees with the version or the name, if the tag exists,
if the working tree is dirty, if `HEAD` is not `main` and exactly `origin/main`, if CI on that
commit did not pass, if `CFBundleVersion` is not a plain integer higher than the last tag's, if
`SIGN_IDENTITY` is neither ad hoc nor a Developer ID, or if the notes hold anything but headings
and bullets or no bullet at all. Then it runs the tests, `make verify-shipped`, `Scripts/smoke.sh`,
`Scripts/intel-slice.sh` and the scenario suite before it publishes anything; §3.3 has the
order. A release that cannot prove its own claims does not go out.

## 0.4 When to cut one

**A release is a body of work, not a commit.** Four went out in one evening here, and two of
them existed only to fix something the one before had broken. That is not a changelog anybody
reads, it is a log of somebody debugging in public, and it teaches a watcher to ignore the
release feed.

The rule, written down because it was broken:

- **A fix does not earn a release.** It earns a commit on `main`. Releases collect.
- **Cut one when there is something a user would act on**: a crash they are hitting, a
  feature they asked for, a batch of fixes that together change how the app behaves.
- **Never cut one to fix the release you just cut.** If the tag is wrong, the answer is to
  finish the work and cut the next one when it is ready, not to chase it with a patch an
  hour later.
- **Finish the release machinery before using it.** v0.1.6 shipped with the old note format
  because the new one was wired up after the tag was already out. Get the shape right, prove
  it on a dry run, then release once.

An exception worth naming: a build that is broken for everybody, like v0.1.5, ships the
moment it is fixed. That is the whole list of exceptions.

## 0.5 What the notes say

Sections and bullets, generated from the log by `Scripts/changelog.py`. The format and the rules
are that script's; `release.sh` refuses to publish notes with any other kind of line in them. There
is no prose in them, so nothing can be said in the notes that is not a commit subject.

## 1. What makes this safe, in one paragraph

sigstop is distributed outside the App Store and is **ad-hoc signed: no Apple Developer ID, no Team
ID, no notarization.** Apple's code signature therefore proves nothing about who produced a build —
Gatekeeper would be checking a signature against nobody. What makes the update channel safe is
**EdDSA (Ed25519)**: every release archive is signed with a private key that exists only in the
maintainer's login keychain, and the app refuses to install anything whose signature does not verify
against the public key compiled into it. The consequence is worth stating plainly, because it is the
reason this design was chosen: **an attacker who completely owns GitHub, the CDN and the network can
stop users getting updates, and cannot make an installed copy run their code.** That protects people
who already have the app. Somebody downloading it for the first time is trusting whatever file the
release page serves, and an attacker with the account could replace it; the first install rests on
GitHub alone.

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
(umask 077; .build/artifacts/sparkle/Sparkle/bin/generate_keys --account sigstop -x /Volumes/<encrypted>/sigstop-ed25519.key)
```

Write it straight to an encrypted volume, or paste its one line into a password manager and write
it nowhere else. The `umask` matters: `generate_keys` writes with the default mode, which is
readable by every account on the Mac. Do not export it into your home folder or the repository;
`make verify` fails if a line that looks like an exported key is anywhere in the tree, and
`.gitignore` refuses `*.key`. There is no secure delete to fall back on: `rm -P` does nothing on
APFS, and a snapshot or Time Machine backup taken while the file existed keeps it.

To restore it on a new machine:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account sigstop -f /path/to/sigstop-ed25519.key
```

---

## 3. Cutting a release

### 3.0 Prerequisites, once per machine

```sh
cd app
swift package resolve              # fetches Sparkle's binary artifact, which carries the signing tools
softwareupdate --install-rosetta   # optional: lets this Mac run the x86_64 slice itself
```

Somebody has to run an x86_64 slice before a release goes out. `Scripts/intel-slice.sh` decides
who, and the two answers do not prove the same thing. Under Rosetta, this Mac launches the slice
in `dist/sigstop.app`, the bundle `dmg.sh` then packs, and asks `--doctor` which slice answered:
the slice that runs is the slice that ships. Without Rosetta it falls back to CI's run on the
exact commit being released, and only if its `The Intel slice runs too` step passed. That shows
an x86_64 build of the same commit ran, built by CI's own runner, not the bytes in the image
being released; two builds of the same commit are not byte-identical (§3.4). With neither, the
release refuses. macOS 28 removes Rosetta, so from then on a release waits for CI, and carries
only the weaker proof: push, let it go green, then release. Running
the slice under Rosetta on macOS 27 makes macOS show an "App Update Required" notice for
sigstop; that is the test, not a defect, and users on Apple Silicon run the arm64 slice.

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

Commit this on its own, as a `chore` or `build` commit, before anything is built. Then push
`main` and wait for CI to pass on that commit: `release.sh` releases only a pushed commit whose
CI run succeeded, so what is signed is what everybody else can see and what CI built.

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

A note on `make bundle`: it signs **with** the Hardened Runtime, so dyld refuses
`DYLD_INSERT_LIBRARIES`, and for an ad-hoc build it adds `disable-library-validation`, because
Library Validation refuses a framework whose Team ID differs from the executable's and ad-hoc
signatures have none. `docs/PRIVACY.md` §2.9 has the full explanation, and `make verify` checks
both halves. If you ever obtain a Developer ID, the entitlement is left out and Library Validation
stays on:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make bundle
```

### 3.3 Cut it

One command, and the order inside it matters more than the command does.

```sh
cd app
make release VERSION=0.2.0 NAME="Wood Frog 🐸"
```

In order, it:

1. builds the notes from the commit subjects since the last tag and checks them before anything
   is built: headings and bullets only, and at least one bullet, or there is nothing to release;
2. runs `make test`, then `make verify-shipped`, which builds the universal bundle and checks it,
   then `Scripts/smoke.sh` on that same bundle, then `Scripts/intel-slice.sh` (§3.0), then the
   `Scenarios` harness, and stops on any failure;
3. packs that same bundle with `Scripts/dmg.sh` and `STRICT_LAYOUT=1`. `dmg.sh` **refuses a
   single-slice bundle**, because 0.1.0 went out arm64 only under release notes promising Intel, and
   with `STRICT_LAYOUT=1` it refuses to ship an unstyled window when Finder will not lay it out;
4. runs `Scripts/appcast.sh`, which signs the image just built and writes `updater/appcast.xml`,
   then commits it. **This happens before the tag**, so a release whose feed cannot be signed fails
   with nothing published rather than after the announcement;
5. tags the commit it built and tested, the bump, not the feed commit on top of it, pushes the
   tag, and creates the GitHub release with both disk image names: the stable `sigstop.dmg` the
   site links to, and the versioned one a human can read a year later.

If anything changes in the tree while it runs, it stops before signing. If that happens after the
feed commit, it undoes the commit, because a pushed feed naming a download that does not exist
would offer every installed copy an update that 404s. It undoes that commit and nothing else: if
`main` picked up a commit of yours meanwhile, it leaves `main` alone, lists what it found, and
prints the one command that drops only the feed commit. The feed commit holds the feed file only,
so a change you staged while it ran stays staged.

**If `make release` fails after signing.** From the feed commit on, a failure in the tag, the tag
push or `gh release create` leaves that commit on local `main` with no release behind it.
`release.sh` says so as it exits, names the feed commit, and prints both ways out as commands for
the point it reached: finish it (the tag, the tag push, `gh release create` with the same two
images and the notes it saved, then `git push`), or abandon it (drop the feed commit, and delete
the tag here and on `origin` if it got that far). **Do not push `main` until one of them is
done.** A later run that finds a feed commit which never reached `origin` refuses and says the
same, rather than telling you to push.

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
Settings → About. Watch it go: *Asking the feed… → n.n.n is available → Downloading… → Checking the
signature, then unpacking… → verified and ready*. If it stops at an error, the message in the About pane is
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
- [ ] The bump commit pushed, and CI green on it
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
`release.sh` refuses a build number that is not a plain integer greater than the last tag's.

**Editing `appcast.xml` by hand after signing.** Each enclosure's signature covers its archive, so
a manual edit to the XML can point an item at an archive the signature does not match. The feed
itself is not signed yet (`SURequireSignedFeed` is not set), so its text is trusted as served.
Re-run `generate_appcast` rather than patching the XML.

**Before 0.1.8 the archive was unpacked before it was verified.** `SUVerifyUpdateBeforeExtraction`
is read from the installed copy, and releases up to 0.1.7 do not set it, so their next update is
mounted before its EdDSA signature is checked. It still will not install unsigned, and from the
first release that carries the key the check comes first.

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
Command Line Tools ([`CONTRIBUTING.md`](../CONTRIBUTING.md#setup)). It fails with *"xcbuild executable ... does not exist."*

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
native-only product back over the fat one, silently undoing all of it. There is no arm64-only
release to fall back on: `dmg.sh` refuses a single-slice bundle, and the notes hold no prose that
could say so. Shipping arm64-only by accident, while the appcast quietly tells every Intel user
there is no update, is the outcome this paragraph exists to prevent.

Sparkle's own framework is already universal, so nothing else needs doing.

**Cutting a release from CI.** Do not. The private key would have to live there, which defeats §1.

**Assuming Gatekeeper protects anything here.** It does not. There is no Developer ID. `spctl` will
not say "Notarized Developer ID" and users will see the unidentified-developer dialog on first
launch. The EdDSA signature is what protects updates. The notes carry only commit subjects, so that
is said in `docs/PRIVACY.md` §2.8, which is where a reader who wonders whether Apple is checking
should be sent.

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
   and the website. Not through the in-app updater, which the attacker can also reach.
4. Take the old appcast down, so the compromised feed URL serves nothing rather than serving what the
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
