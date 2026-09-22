#!/usr/bin/env bash
#
# Sign the built disk image and write the update feed.
#
# This step is why "Check for updates" was broken in 0.1.0. RELEASING.md described it,
# release.sh did not do it, GitHub Pages was never enabled, and the URL compiled into
# every copy of the app returned 404. A documented step that no script runs is a step
# that does not happen, so it is a script now and release.sh calls it.
#
# The feed carries the current release and nothing older. A Sparkle client compares its
# own version against the newest item, so one item is all it needs; keeping a history
# here would mean keeping every past archive on this machine to re-sign it, and a feed
# that silently loses items because a file was not on somebody's laptop is worse than a
# feed that never claimed to have them.
#
# The key is in the login keychain under the account `sigstop`, NOT the `ed25519` that
# Sparkle's tools default to, which is why --account is passed. Without it the tools say
# "Private key for account ed25519 not found in the Keychain" and exit, and that reads
# like the key is missing when it is only named something else.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="sigstop"
KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-sigstop}"
REPO="Mohamed-Elshesheny/sigstop"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
FEED="../updater/appcast.xml"

BIN="$(find .build/artifacts -type f -name generate_appcast -perm +111 2>/dev/null | head -1)"
[ -n "${BIN}" ] || {
  echo "error: generate_appcast not found. Run 'swift build -c release' first so" >&2
  echo "       SwiftPM fetches Sparkle's binary artifact." >&2
  exit 1
}

# Exactly one, or stop. `head -1` was picking the alphabetically first of whatever matched,
# and the versioned filename carries the codename slug, so renaming SGReleaseName without
# changing VERSION leaves two files for one version. The feed would then be signed over the
# stale one while `gh release create` uploaded both, and the URL the appcast points at would
# resolve to a different build than the signature covers. `dist/` is never cleaned, so the
# glob has plenty to choose from: it currently holds eight images.
MATCHES="$(ls dist/${APP_NAME}-${VERSION}*.dmg 2>/dev/null | wc -l | tr -d ' ')"
if [ "${MATCHES}" -eq 0 ]; then
  echo "error: no dist/${APP_NAME}-${VERSION}*.dmg, run 'make dmg' first" >&2
  exit 1
fi
if [ "${MATCHES}" -gt 1 ]; then
  echo "error: ${MATCHES} images match ${APP_NAME}-${VERSION}*.dmg, so signing one would be a guess:" >&2
  ls dist/${APP_NAME}-${VERSION}*.dmg | sed 's/^/       /' >&2
  echo "       Remove the ones that are not this build, or run 'make dmg' again after clearing them." >&2
  exit 1
fi
DMG="$(ls dist/${APP_NAME}-${VERSION}*.dmg)"

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
cp "${DMG}" "${STAGE}/"

echo "==> signing $(basename "${DMG}") and writing the feed"
"${BIN}" --account "${KEY_ACCOUNT}" \
  --download-url-prefix "https://github.com/${REPO}/releases/download/v${VERSION}/" \
  --link "https://github.com/${REPO}" \
  -o "${STAGE}/appcast.xml" "${STAGE}" 2>&1 | grep -v "deprecated" || true

[ -s "${STAGE}/appcast.xml" ] || { echo "error: no appcast was produced" >&2; exit 1; }

# Refuse to publish a feed whose enclosure is not signed. An unsigned item is not a
# smaller problem than a missing feed: the app refuses it, so the update silently never
# arrives, and the failure looks like "there is no update" rather than like a mistake.
grep -q 'sparkle:edSignature="' "${STAGE}/appcast.xml" || {
  echo "error: the generated feed has no EdDSA signature on its enclosure." >&2
  echo "       The key is expected in the login keychain under account '${KEY_ACCOUNT}'." >&2
  exit 1
}

mkdir -p "$(dirname "${FEED}")"
cp "${STAGE}/appcast.xml" "${FEED}"

echo
echo "wrote updater/appcast.xml for ${VERSION}"
grep -oE 'sparkle:shortVersionString>[^<]*|url="[^"]*"' "${FEED}" | sed 's/^/  /'
echo
echo "  Commit and push it. .github/workflows/pages.yml deploys updater/ to"
echo "  https://mohamed-elshesheny.github.io/sigstop/appcast.xml, which is SUFeedURL."
