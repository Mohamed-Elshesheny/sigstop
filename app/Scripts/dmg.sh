#!/usr/bin/env bash
#
# Build the disk image people download.
#
# The whole installer is a drag. There is no package, no wizard, no licence page and
# nothing that runs on the user's machine before the app does, which is the least this
# project can do given what it says about permissions everywhere else.
#
# THE IMAGE IS NOT SIGNED OR NOTARIZED, and that is a decision. Gatekeeper kills an
# ad-hoc signed app carrying the quarantine attribute, with SIGKILL, which this product's
# own vocabulary says nothing survives. Measured: with the attribute the binary exits 137
# before main() runs; with `xattr -dr com.apple.quarantine` it exits 0. README.md gives
# the command. Doing it properly needs an Apple Developer Program membership, and the two
# steps that would replace the README paragraph are written out below, unrun.
#
# The window is laid out by telling Finder where things go, which needs an Automation
# grant on THIS machine, the maintainer's. Nothing is asked of the person downloading it.
# If the grant is absent the layout step is skipped and a plain image is still produced,
# because a release that cannot be cut without a permission dialog is worse than an
# unstyled window.

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="sigstop"
BUNDLE="dist/${APP_NAME}.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
RELEASE_NAME="$(/usr/libexec/PlistBuddy -c 'Print SGReleaseName' Resources/Info.plist 2>/dev/null || true)"
# "Sleeping Dormouse 🐿️" becomes "sleeping-dormouse": lower case, no emoji, no spaces,
# because a filename with an emoji in it is a filename somebody has to quote forever.
SLUG="$(printf '%s' "${RELEASE_NAME}" | LC_ALL=C tr -cd 'A-Za-z0-9 ' | tr '[:upper:]' '[:lower:]' | xargs | tr ' ' '-')"
# HFS+ caps a volume name at 27 characters, so the codename does not go here: with it
# hdiutil fails with "Operation not permitted", which reads like a permissions problem
# and is a length problem. The codename is in the filename instead, where it is read.
VOLUME="${APP_NAME} ${VERSION}"
# Two names for one file, and the duplication is deliberate.
#
# The site's download button uses GitHub's /releases/latest/download/<name> redirect,
# which needs a filename that is identical in every release, so one asset has to be
# plain `sigstop.dmg`. But a file called that sitting in someone's Downloads folder says
# nothing about which build it is, so the other carries the version and the codename.
# Upload both: the button takes the stable one, a person browsing the release takes the
# one whose name they can read a year from now.
OUT="dist/${APP_NAME}-${VERSION}${SLUG:+-${SLUG}}.dmg"
STABLE="dist/${APP_NAME}.dmg"
RW="dist/.${APP_NAME}-rw.dmg"
MOUNT="/Volumes/${VOLUME}"

# Finder's coordinates for the two icons. InstallerBackdrop.swift draws the arrow
# between these exact points, so the two files have to agree and there is a check below.
ICON_X_APP=165
ICON_X_APPLICATIONS=435
ICON_Y=205
WINDOW_W=600
WINDOW_H=400

[ -d "${BUNDLE}" ] || { echo "error: ${BUNDLE} not found, run make bundle first" >&2; exit 1; }

# The image people download carries both architectures, and this is the check rather
# than the comment: 0.1.0 shipped arm64-only under release notes promising Intel too.
# `make dmg` builds with UNIVERSAL=1, so reaching here with one slice means somebody
# staged a bundle by hand.
ARCHS="$(lipo -archs "${BUNDLE}/Contents/MacOS/${APP_NAME}" 2>/dev/null || echo "none")"
case " ${ARCHS} " in
  *" arm64 "*) : ;;
  *) echo "error: ${BUNDLE} has no arm64 slice (${ARCHS})" >&2; exit 1 ;;
esac
case " ${ARCHS} " in
  *" x86_64 "*) : ;;
  *) echo "error: ${BUNDLE} is ${ARCHS} only. Build it with: UNIVERSAL=1 make bundle" >&2
     echo "       The release notes promise Intel, so a single-slice image is a lie." >&2
     exit 1 ;;
esac
echo "==> ${ARCHS}"

cleanup() {
  hdiutil detach "${MOUNT}" -quiet 2>/dev/null || true
  rm -f "${RW}"
}
trap cleanup EXIT

echo "==> backdrop"
mkdir -p dist/.dmg-background
./.build/release/${APP_NAME} --render-installer dist/.dmg-background/backdrop >/dev/null

echo "==> staging"
STAGE="$(mktemp -d)"
cp -R "${BUNDLE}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
mkdir -p "${STAGE}/.background"
# 1200x800 pixels stamped at 144 dpi is 600x400 points, which is the window, drawn at
# retina density. Without the stamp Finder reads it as a 1200 point image and scales it.
sips -s dpiWidth 144 -s dpiHeight 144 dist/.dmg-background/backdrop.png >/dev/null
cp dist/.dmg-background/backdrop.png "${STAGE}/.background/"

echo "==> read-write image"
hdiutil detach "${MOUNT}" -quiet 2>/dev/null || true
rm -f "${RW}" "${OUT}"
hdiutil create -volname "${VOLUME}" -srcfolder "${STAGE}" -ov -format UDRW -fs HFS+ "${RW}" >/dev/null
rm -rf "${STAGE}"
hdiutil attach "${RW}" -nobrowse -quiet

echo "==> window"
if osascript <<OSA >/dev/null 2>&1
tell application "Finder"
  tell disk "${VOLUME}"
    open
    -- The window has to exist before an item can be positioned in it. Without this
    -- the position lines fail with -10006 and the whole layout is skipped, which is
    -- how this shipped once as a plain window that looked like a permission problem.
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- bounds includes the title bar, so the content area is shorter than the number
    -- given here by exactly its height. Without the 28 the backdrop lost its last line.
    set the bounds of container window to {200, 140, ${WINDOW_W} + 200, ${WINDOW_H} + 140 + 28}
    set theOptions to the icon view options of container window
    set arrangement of theOptions to not arranged
    set icon size of theOptions to 92
    set background picture of theOptions to file ".background:backdrop.png"
    set position of item "${APP_NAME}.app" of container window to {${ICON_X_APP}, ${ICON_Y}}
    set position of item "Applications" of container window to {${ICON_X_APPLICATIONS}, ${ICON_Y}}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA
then
  echo "    laid out"
else
  echo "    skipped: Finder refused the layout. The image is still valid, it just"
  echo "    opens as a plain window. Run the script again before assuming a"
  echo "    permission problem: the first cause of this was a timing race, not TCC."
fi

sync
hdiutil detach "${MOUNT}" -quiet
echo "==> compressing"
hdiutil convert "${RW}" -format UDZO -imagekey zlib-level=9 -o "${OUT}" -quiet

# With a Developer ID, these two replace the README paragraph entirely:
#
#   codesign --force --sign "Developer ID Application: ..." --timestamp "${OUT}"
#   xcrun notarytool submit "${OUT}" --keychain-profile "..." --wait
#   xcrun stapler staple "${OUT}"

cp "${OUT}" "${STABLE}"

SIZE="$(du -h "${OUT}" | cut -f1 | tr -d ' \t')"
SHA="$(shasum -a 256 "${OUT}" | cut -d' ' -f1)"

echo
echo "built ${OUT}"
echo "  also:    ${STABLE}  (upload this one, the site links to it by name)"
echo "  size:    ${SIZE}"
echo "  sha256:  ${SHA}"
if codesign -dv "${BUNDLE}" 2>&1 | grep -q adhoc; then
  echo
  echo "  note: ad-hoc signed, so a downloader sees \"damaged and can't be opened\""
  echo "        until they run the command in README.md. Publish the sha256 above"
  echo "        beside the download so the file can be checked."
fi
