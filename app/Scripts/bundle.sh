#!/usr/bin/env bash
# Assemble sigstop.app from the SwiftPM build product.
#
# There is no .xcodeproj in this repo on purpose (see CONTRIBUTING.md), so the app
# bundle is assembled by hand. This is ~30 lines and works with Command Line
# Tools alone, which means CI needs no Xcode install.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP_NAME="sigstop"
BUNDLE="dist/${APP_NAME}.app"
# Explicit, not `.build/${CONFIG}/`, which is a symlink to the last triple built and
# can therefore be the Intel one.
BIN=".build/$(uname -m)-apple-macosx/${CONFIG}/${APP_NAME}"
[ -f "${BIN}" ] || BIN=".build/${CONFIG}/${APP_NAME}"

# A STABLE signing identity matters more than it looks. macOS keys the
# Accessibility (TCC) grant to the binary's cdhash. Ad-hoc signing produces a new
# cdhash on every build, so the grant silently evaporates after each rebuild and
# System Settings fills with stale entries. `make dev-cert` creates a persistent
# self-signed identity; set SIGN_IDENTITY to use it.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# UNIVERSAL=1 builds for both architectures and lipos them together.
#
# Off by default because the second slice costs a full extra compile and nobody
# developing on this machine runs the Intel one. On for anything that ships: the
# 0.1.0 disk image went out arm64-only under release notes that said "Apple
# Silicon and Intel", which an Intel user discovers by the app not opening.
# `dmg.sh` sets it, so the artifact people download cannot be built any other way.
#
# A full Xcode is NOT needed. `swift build --arch arm64 --arch x86_64` is, because
# it goes through xcbuild, but `--triple` does not, and Sparkle's binary artifact
# is already universal. Measured on Command Line Tools 27.0.
UNIVERSAL="${UNIVERSAL:-0}"

# The cross build runs FIRST and the native one last, and the order is the fix for a
# real bug rather than a preference. SwiftPM repoints `.build/release` at whichever
# triple it built most recently, so building x86_64 last leaves that path holding an
# Intel binary. Anything that then RUNS it on this machine dies with "Bad CPU type in
# executable", which is how `make dmg` failed: it renders its backdrop by running the
# app. Explicit per-triple paths below, native last, so the convenience symlink is
# never the Intel one.
# UNIVERSAL=1 builds arm64 natively and cross-builds x86_64, and the arm64 path below is
# fixed, so it only works on an Apple Silicon Mac. Refuse before spending two release builds
# on finding that out.
if [ "${UNIVERSAL}" = "1" ] && [ "$(uname -m)" != "arm64" ]; then
  echo "error: UNIVERSAL=1 has to run on an Apple Silicon Mac. This is $(uname -m)." >&2
  echo "       For a local build without the second slice, drop UNIVERSAL=1." >&2
  exit 1
fi

if [ "${UNIVERSAL}" = "1" ]; then
  echo "==> swift build -c ${CONFIG} --triple x86_64-apple-macosx14.0"
  swift build -c "${CONFIG}" --triple x86_64-apple-macosx14.0
fi

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

if [ "${UNIVERSAL}" = "1" ]; then
  ARM=".build/arm64-apple-macosx/${CONFIG}/${APP_NAME}"
  X86=".build/x86_64-apple-macosx/${CONFIG}/${APP_NAME}"
  [ -f "${ARM}" ] && [ -f "${X86}" ] || {
    echo "error: expected both slices, found:" >&2
    ls -la "${ARM}" "${X86}" 2>&1 >&2
    exit 1
  }
  BIN=".build/${APP_NAME}-universal"
  lipo -create "${ARM}" "${X86}" -output "${BIN}"
  echo "    universal: $(lipo -archs "${BIN}")"
fi

[ -f "${BIN}" ] || { echo "error: ${BIN} not found" >&2; exit 1; }

echo "==> assembling ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "${BIN}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${BUNDLE}/Contents/"
cp Resources/sigstop.icns "${BUNDLE}/Contents/Resources/"

# SwiftPM emits resource bundles next to the binary; the app expects them inside
# Contents/Resources, so copy any that exist.
#
# The message corpus lives in one of these, and the app dies at launch without it. That is
# not hypothetical: it is exactly what shipped through v0.1.5. So this is a guard, not a
# best-effort copy. Both a native and a universal build leave the bundles under this
# machine's per-arch directory, which is the one place read. Refuse to assemble an app with
# no corpus rather than hand one to `make smoke` to reject later.
COPIED_CORPUS=0
RESOURCES_FROM=".build/$(uname -m)-apple-macosx/${CONFIG}"
for b in "${RESOURCES_FROM}"/*.bundle; do
  [ -e "$b" ] || continue
  cp -R "$b" "${BUNDLE}/Contents/Resources/"
  case "$b" in *SigstopCore.bundle) COPIED_CORPUS=1 ;; esac
done
if [ "${COPIED_CORPUS}" -ne 1 ] || [ ! -f "${BUNDLE}/Contents/Resources/${APP_NAME}_SigstopCore.bundle/corpus.json" ]; then
  echo "error: the SigstopCore resource bundle with corpus.json is not in the app." >&2
  echo "       Without it the app dies at launch on every machine (this was the v0.1.5 bug)." >&2
  exit 1
fi
# SwiftPM never deletes a file it did not put in a resource bundle, so anything left there by
# hand (an mv into it, a copy) would be copied above and shipped. The bundle holds one file.
EXTRA="$(cd "${BUNDLE}/Contents/Resources/${APP_NAME}_SigstopCore.bundle" && find . -mindepth 1 ! -name corpus.json)"
if [ -n "${EXTRA}" ]; then
  echo "error: the SigstopCore resource bundle holds more than corpus.json:" >&2
  echo "${EXTRA}" | sed 's/^/         /' >&2
  echo "       Remove it from ${RESOURCES_FROM}/${APP_NAME}_SigstopCore.bundle, or run make clean." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Sparkle
#
# SwiftPM links Sparkle as @rpath/Sparkle.framework/... and drops the framework
# next to the build product, which is why `swift run` works. A .app has to carry
# its own copy in Contents/Frameworks, and the executable needs an rpath that
# points there, without it the app launches fine from .build and dies with a
# dyld "Library not loaded" the moment you double-click the bundle.
#
# The framework is copied WHOLE, symlinks and all (`cp -a`, not `cp -RL`).
# Inside it are the XPC services and the Autoupdate helper that actually perform
# the install; flattening the Versions/B symlink farm produces a bundle that
# codesign accepts and that macOS then refuses to load.
FRAMEWORK=".build/${CONFIG}/Sparkle.framework"
if [ -d "${FRAMEWORK}" ]; then
  echo "==> embedding Sparkle.framework"
  mkdir -p "${BUNDLE}/Contents/Frameworks"
  cp -a "${FRAMEWORK}" "${BUNDLE}/Contents/Frameworks/"
  # dSYMs are build output, not runtime. Shipping them doubles the bundle.
  rm -rf "${BUNDLE}/Contents/Frameworks/Sparkle.framework/Versions/B/dSYMs" 2>/dev/null || true
  install_name_tool -add_rpath "@executable_path/../Frameworks" \
                    "${BUNDLE}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
  # SwiftPM also leaves @loader_path, which is Contents/MacOS. dyld tries rpaths in order, so
  # an empty folder there came first: a Sparkle.framework dropped into it would load in place
  # of the real one, without changing the executable the Accessibility grant is tied to.
  install_name_tool -delete_rpath "@loader_path" "${BUNDLE}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
  RPATHS="$(otool -l "${BUNDLE}/Contents/MacOS/${APP_NAME}" | awk '/LC_RPATH/ { getline; getline; print $2 }' | sort -u)"
  if [ "${RPATHS}" != "@executable_path/../Frameworks" ]; then
    echo "error: the executable's rpaths are not exactly @executable_path/../Frameworks:" >&2
    echo "${RPATHS}" | sed 's/^/         /' >&2
    exit 1
  fi
else
  echo "==> WARNING: ${FRAMEWORK} missing, the bundle will not launch" >&2
fi

# ---------------------------------------------------------------------------
# Signing
#
# Order matters and is not negotiable: nested code first, outermost last. A
# framework that contains its own XPC services and helper app has to be sealed
# from the inside out, because signing the outer bundle computes a hash over the
# inner signatures. Signing the .app first and the framework second produces a
# bundle that fails Gatekeeper with a vague "code has been modified".
#
# `codesign --deep` would do this in one line and is explicitly discouraged by
# Apple: it re-signs vendor code with our entitlements, which for Sparkle's
# installer XPC service is exactly the wrong thing.
echo "==> codesign (identity: ${SIGN_IDENTITY})"

sign() {  # sign <path> [extra args...]
  local target="$1"; shift
  codesign --force --sign "${SIGN_IDENTITY}" --timestamp=none "$@" "${target}" 2>&1 \
    | sed 's/^/    /' || return 1
}

SPARKLE_IN_BUNDLE="${BUNDLE}/Contents/Frameworks/Sparkle.framework"
if [ -d "${SPARKLE_IN_BUNDLE}" ]; then
  # Deepest first. These paths are Sparkle 2's layout; if a future version moves
  # them the loop below simply signs nothing extra and the framework signature
  # still covers them.
  for nested in \
    "${SPARKLE_IN_BUNDLE}/Versions/B/XPCServices/Installer.xpc" \
    "${SPARKLE_IN_BUNDLE}/Versions/B/XPCServices/Downloader.xpc" \
    "${SPARKLE_IN_BUNDLE}/Versions/B/Autoupdate" \
    "${SPARKLE_IN_BUNDLE}/Versions/B/Updater.app"
  do
    # `|| true` guarded only the "path absent" case and swallowed a real signing
    # failure with it. A nested piece that will not sign produces a framework whose
    # outer signature seals a broken inner one, and the app dies at launch on a
    # machine stricter than the one that built it. If the path is there, it has to sign.
    if [ -e "${nested}" ]; then sign "${nested}"; fi
  done
  sign "${SPARKLE_IN_BUNDLE}"
fi

# Hardened runtime is on. Without it dyld honours DYLD_INSERT_LIBRARIES, so any process
# running as the user could start this binary with its own code inside and borrow the
# Accessibility grant, which macOS ties to this executable and not to what it loads. That
# was measured with a harmless probe: injected without the runtime, refused with it.
#
# The runtime also turns on Library Validation, which refuses a library signed by a different
# Team ID. An ad-hoc or self-signed build has no Team ID, so the app and the embedded
# Sparkle.framework count as different teams and the app dies at launch with "mapping process
# and mapped file (non-platform) have different Team IDs". So a build without a Team ID adds
# com.apple.security.cs.disable-library-validation. That gives up nothing: without the runtime
# Library Validation was never enforced at all, whatever the entitlements said. A Developer ID
# build has a Team ID, needs neither, and keeps Library Validation on.
#
# What proves an update came from the maintainer is Sparkle's EdDSA signature, checked against
# a key compiled into the app, before the image is unpacked. See docs/RELEASING.md.
HARDENED="${HARDENED:-1}"
RUNTIME_FLAGS=()
ENTITLEMENTS="Resources/sigstop.entitlements"
SIGNING_ENTITLEMENTS="${ENTITLEMENTS}"
if [ "${HARDENED}" = "1" ]; then
  RUNTIME_FLAGS=(--options runtime)
  case "${SIGN_IDENTITY}" in
    "Developer ID Application"*) ;;
    *)
      SIGNING_ENTITLEMENTS="$(mktemp -d)/sigstop.entitlements"
      cp "${ENTITLEMENTS}" "${SIGNING_ENTITLEMENTS}"
      /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" \
        "${SIGNING_ENTITLEMENTS}" >/dev/null
      echo "    hardened runtime; no Team ID, so library validation is off and DYLD_* is still refused"
      ;;
  esac
fi

codesign --force --sign "${SIGN_IDENTITY}" \
         --entitlements "${SIGNING_ENTITLEMENTS}" \
         ${RUNTIME_FLAGS[@]+"${RUNTIME_FLAGS[@]}"} \
         "${BUNDLE}" 2>&1 | sed 's/^/    /'
[ "${SIGNING_ENTITLEMENTS}" = "${ENTITLEMENTS}" ] || rm -rf "$(dirname "${SIGNING_ENTITLEMENTS}")"

# The seal, checked. Every failure above this point was either swallowed or trusted, and
# nothing ever asked codesign whether the finished bundle actually verifies. --deep --strict
# walks the nested code the same way Gatekeeper does on a strict machine, which is the one
# this build has never run on.
echo "==> verifying the signature"
if codesign --verify --deep --strict --verbose=1 "${BUNDLE}" 2>&1 | sed 's/^/    /'; then
  echo "    valid on disk, seal intact through the nested code"
else
  echo "error: the assembled bundle does not verify, so it would be refused where it counts" >&2
  exit 1
fi

echo
echo "built ${BUNDLE}"
echo "  size:   $(du -sh "${BUNDLE}" | cut -f1)"
echo "  linked: $(otool -L "${BUNDLE}/Contents/MacOS/${APP_NAME}" | grep -c dylib) dylibs"
echo "  cdhash: $(codesign -dvvv "${BUNDLE}" 2>&1 | awk -F= '/^CDHash=/{print $2}')"

# An ad-hoc bundle's designated requirement is its cdhash alone, and the cdhash
# is new on every build, so in principle every rebuild invalidates the
# Accessibility grant. In practice that was NOT observed on macOS 27.0 here: the
# grant survived repeated rebuilds and AXIsProcessTrusted kept returning true.
# So this prints the hash and the remedy without claiming the grant is dead,
# because a warning that cries wolf is how the real one gets ignored. Check with
# `--doctor`, which reports the window title as readable only when the process
# is genuinely trusted.
if [ "${SIGN_IDENTITY}" = "-" ]; then
  echo
  echo "  note: ad-hoc signed, so the cdhash above is new."
  echo "        An Accessibility grant is recorded against it, so a rebuild can"
  echo "        cost you the grant. If --doctor stops saying the window title is"
  echo "        readable, that is what happened. Fix it once:  make dev-cert"
  echo "        then build:   SIGN_IDENTITY=sigstop-dev make run"
fi
