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
make verify >/dev/null
swift run -c release Scenarios >/dev/null
echo "    tests, verify and scenarios all pass"

echo "==> building the image"
make dmg >/dev/null
SHA="$(shasum -a 256 dist/sigstop.dmg | cut -d' ' -f1)"

NOTES="$(cat <<EOF
macOS 14 or later, Apple Silicon and Intel.

Open the disk image and drag sigstop to Applications.

**macOS will refuse to open it the first time.** It is not broken. This build is signed
with a certificate that belongs to nobody, because the one that would stop macOS saying
that costs ninety nine dollars a year. Open System Settings, go to Privacy and Security,
and press Open Anyway. If that button is not there, this clears it instead:

\`\`\`sh
xattr -dr com.apple.quarantine /Applications/sigstop.app
\`\`\`

Either way you only do it once.

Running it means trusting a binary somebody else built, so check the file first if you
would rather:

\`\`\`
shasum -a 256 sigstop.dmg
${SHA}
\`\`\`

Or build it yourself, which needs no trust at all: clone, \`cd app\`, \`make run\`. Command
Line Tools are enough and there is no Xcode requirement.
EOF
)"

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
