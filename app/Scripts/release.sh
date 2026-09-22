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

PREVIOUS_TAG="$(git describe --tags --abbrev=0 HEAD 2>/dev/null || true)"
NOTES="$(python3 Scripts/changelog.py "${PREVIOUS_TAG}" HEAD "${TAG} ${NAME}")"
STRAY="$(grep -vE '^(## |### |- |$)' <<<"${NOTES}" || true)"
if [ -n "${STRAY}" ]; then
  echo "error: the release notes may only hold headings and bullets. Found:" >&2
  sed 's/^/       /' <<<"${STRAY}" >&2
  exit 1
fi
if ! grep -q '^- ' <<<"${NOTES}"; then
  echo "error: nothing that ships changed since ${PREVIOUS_TAG}, so there is nothing to release." >&2
  exit 1
fi

LOGS="$(mktemp -d)"
quiet() {
  local log="${LOGS}/$(printf '%s' "$*" | tr -c 'A-Za-z0-9' '_' | cut -c1-60).log"
  if ! "$@" >"${log}" 2>&1; then
    echo "error: '$*' failed. The last 40 lines:" >&2
    tail -40 "${log}" >&2
    echo "       Full log: ${log}" >&2
    exit 1
  fi
  rm -f "${log}"
}

echo "==> proving the claims before publishing them"
quiet make test
quiet make verify-shipped
# The artifact, not the code. Everything above this line passed for every release that
# shipped broken, because all of it runs on the machine that built the thing.
quiet env BUNDLE=dist/sigstop.app ./Scripts/smoke.sh
X86_BY="$(BUNDLE=dist/sigstop.app ./Scripts/intel-slice.sh)"
quiet swift run -c release Scenarios
echo "    tests, verify, smoke and scenarios all pass"
echo "    ${X86_BY}"

echo "==> packing the bundle just tested into the image"
quiet env STRICT_LAYOUT=1 ./Scripts/dmg.sh
SHA="$(shasum -a 256 dist/sigstop.dmg | cut -d' ' -f1)"

# The step 0.1.0 shipped without. Doing it before the tag means a release that cannot be
# signed fails here, with nothing published, rather than after the announcement.
echo "==> signing the update feed"
./Scripts/appcast.sh >/dev/null
if [ -n "$(cd .. && git status --porcelain updater/)" ]; then
  (cd .. && git add updater/appcast.xml && git commit -q -m "build: publish the appcast for v${VERSION}")
  echo "    committed updater/appcast.xml"
fi



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
