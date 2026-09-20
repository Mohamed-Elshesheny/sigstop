#!/usr/bin/env bash
# Assemble sigstop.app from the SwiftPM build product.
#
# There is no .xcodeproj in this repo on purpose (see CLAUDE.md §2), so the app
# bundle is assembled by hand. This is ~30 lines and works with Command Line
# Tools alone, which means CI needs no Xcode install.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP_NAME="sigstop"
BUNDLE="dist/${APP_NAME}.app"
BIN=".build/${CONFIG}/${APP_NAME}"

# A STABLE signing identity matters more than it looks. macOS keys the
# Accessibility (TCC) grant to the binary's cdhash. Ad-hoc signing produces a new
# cdhash on every build, so the grant silently evaporates after each rebuild and
# System Settings fills with stale entries. `make dev-cert` creates a persistent
# self-signed identity; set SIGN_IDENTITY to use it.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

[ -f "${BIN}" ] || { echo "error: ${BIN} not found" >&2; exit 1; }

echo "==> assembling ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "${BIN}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${BUNDLE}/Contents/"

# SwiftPM emits resource bundles next to the binary; the app expects them inside
# Contents/Resources, so copy any that exist.
for b in .build/"${CONFIG}"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "${BUNDLE}/Contents/Resources/"
done

echo "==> codesign (identity: ${SIGN_IDENTITY})"
codesign --force --sign "${SIGN_IDENTITY}" \
         --entitlements Resources/sigstop.entitlements \
         --options runtime \
         "${BUNDLE}" 2>&1 | sed 's/^/    /' || {
  # --options runtime requires a real identity; fall back for ad-hoc local builds.
  echo "    (hardened runtime needs a real identity; signing ad-hoc instead)"
  codesign --force --sign "${SIGN_IDENTITY}" \
           --entitlements Resources/sigstop.entitlements "${BUNDLE}"
}

echo
echo "built ${BUNDLE}"
echo "  size:   $(du -sh "${BUNDLE}" | cut -f1)"
echo "  linked: $(otool -L "${BUNDLE}/Contents/MacOS/${APP_NAME}" | grep -c dylib) dylibs"
