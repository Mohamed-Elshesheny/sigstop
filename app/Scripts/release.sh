#!/usr/bin/env bash
#
# Cut a release: build, tag, publish, upload.
#
# The name is not generated. The reference this was modelled on, boring.notch, looks like
# it has a bot inventing "Flying Rabbit 🐇🪽"; read its workflow and the title comes from
# a pull request a person wrote. That is the right split and it is the one here: a human
# chooses the name, and everything after it is a script so no step gets skipped at two in
# the morning.
#
#   make release VERSION=0.2.0 NAME="Wood Frog 🐸"
#
# The naming convention is in docs/RELEASING.md. Animals that suspend completely and
# resume with nothing lost, because that is the entire product in one image, and the
# codename stays the same across every patch of a minor version the way theirs does.

set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?set VERSION, for example VERSION=0.2.0}"
: "${NAME:?set NAME, for example NAME=\"Wood Frog 🐸\"}"

REPO="Mohamed-Elshesheny/sigstop"
TAG="v${VERSION}"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
PLIST_NAME="$(/usr/libexec/PlistBuddy -c 'Print SGReleaseName' Resources/Info.plist 2>/dev/null || true)"

if [ "${PLIST_VERSION}" != "${VERSION}" ]; then
  echo "error: Info.plist says ${PLIST_VERSION}, you asked for ${VERSION}." >&2
  echo "       Bump CFBundleShortVersionString first so the app and the tag agree." >&2
  exit 1
fi

if [ "${PLIST_NAME}" != "${NAME}" ]; then
  echo "error: Info.plist says \"${PLIST_NAME}\", you asked for \"${NAME}\"." >&2
  echo "       The app shows the codename in About, so the two have to agree." >&2
  exit 1
fi

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  echo "error: ${TAG} already exists." >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is dirty. A release has to be a commit somebody can check out." >&2
  exit 1
fi

echo "==> proving the claims before publishing them"
make test >/dev/null
make verify-shipped >/dev/null
swift run -c release Scenarios >/dev/null
echo "    tests, verify and scenarios all pass"

echo "==> building the image"
make dmg >/dev/null
SHA="$(shasum -a 256 dist/sigstop.dmg | cut -d' ' -f1)"

# The step 0.1.0 shipped without. Doing it before the tag means a release that cannot be
# signed fails here, with nothing published, rather than after the announcement.
echo "==> signing the update feed"
./Scripts/appcast.sh >/dev/null
if [ -n "$(cd .. && git status --porcelain updater/)" ]; then
  (cd .. && git add updater/appcast.xml && git commit -q -m "build: publish the appcast for v${VERSION}")
  echo "    committed updater/appcast.xml"
fi

# What changed, from the log, above the instructions. The install steps are the same on
# every release and were the ONLY thing these notes said, so the one question a reader has
# was the one the page did not answer. CLAUDE.md 8 makes every commit a Conventional
# Commit, so the answer is already written and cannot drift from a hand-kept file.
# HEAD, not "${TAG}^": the tag does not exist yet at this point in the script, and the
# newest tag reachable from HEAD is exactly the previous release.
PREVIOUS_TAG="$(git describe --tags --abbrev=0 HEAD 2>/dev/null || true)"
CHANGES="$(python3 Scripts/changelog.py "${PREVIOUS_TAG}" HEAD "${TAG} ${NAME}")"
if [ -n "${PREVIOUS_TAG}" ]; then
  CHANGES="${CHANGES}

[Every commit since ${PREVIOUS_TAG}](https://github.com/${REPO}/compare/${PREVIOUS_TAG}...${TAG})"
fi

# Only what is different about THIS build. The install steps are the same on every
# release and are already in the README, which is where somebody looks for them; printing
# them again on each tag made the page mostly boilerplate and buried the changelog under
# it. The checksum stays because it is the one line here that is per-build and the one a
# careful reader actually uses.
# The highlights belong to the release that shipped them, so the file is emptied once the
# notes have been built FROM it. It was cleared a few lines earlier at first, before the
# generator ran, which meant the one release it was written for was the one release that
# did not print it.
if [ -s Resources/RELEASE_HIGHLIGHTS.md ]; then
  : > Resources/RELEASE_HIGHLIGHTS.md
  (cd .. && git add app/Resources/RELEASE_HIGHLIGHTS.md)
  echo "    highlights used and cleared"
fi

# The notes are what changed and nothing else.
#
# They used to end with the filename, the platforms, the checksum and a link to the install
# steps, on every tag. GitHub already prints the asset and its size under the notes, the
# platforms have not changed since the first release, and the install steps are in the
# README where somebody looks for them. None of it answered the question a release page is
# opened to answer, and all of it pushed the answer further up the scrollbar.
#
# The checksum is still published, in `dist/` and in this script's own output, for anyone
# cutting or auditing a build. It is not a line a downloader reads.
NOTES="${CHANGES}"

echo "==> tagging ${TAG}"
git tag -a "${TAG}" -m "${TAG} ${NAME}"
git push -q origin "${TAG}"

echo "==> publishing"
gh release create "${TAG}" dist/sigstop.dmg dist/sigstop-${VERSION}*.dmg \
  -R "${REPO}" \
  --title "${TAG} ${NAME}" \
  --notes "${NOTES}"

echo
echo "released ${TAG} ${NAME}"
echo "  sha256: ${SHA}"
echo "  https://github.com/${REPO}/releases/tag/${TAG}"
echo
echo "  The site links to the asset by name, so nothing there needs changing."
echo
echo "  Push main so Pages deploys the feed, then check it as a user would:"
echo "    git push && curl -sSI https://mohamed-elshesheny.github.io/sigstop/appcast.xml | head -1"
