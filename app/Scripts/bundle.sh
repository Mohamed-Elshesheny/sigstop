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
if [ "${UNIVERSAL}" = "1" ]; then
  echo "==> swift build -c ${CONFIG} --triple x86_64-apple-macosx14.0"
  swift build -c "${CONFIG}" --triple x86_64-apple-macosx14.0
fi

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

if [ "${UNIVERSAL}" = "1" ]; then
  # This machine builds arm64; the x86_64 slice is cross-built (see dmg.sh). On an Intel
  # Mac `uname -m` is x86_64, so ARM and X86 would name the same file and `lipo -create`
  # would fail on two identical slices with a message about neither cause nor fix. A
  # universal release therefore has to be cut from Apple Silicon, and this says so instead
  # of failing obscurely.
  if [ "$(uname -m)" != "arm64" ]; then
    echo "error: UNIVERSAL=1 builds the arm64 slice natively and cross-builds x86_64, so it" >&2
    echo "       has to run on an Apple Silicon Mac. This is $(uname -m)." >&2
    echo "       For a local build without the second slice, drop UNIVERSAL=1." >&2
    exit 1
  fi
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
# best-effort copy. A universal build resolves the bundles under a per-arch directory, a
# native one under .build/<config> directly; check both, and refuse to assemble an app
# with no corpus rather than hand one to `make smoke` to reject later.
COPIED_CORPUS=0
for dir in ".build/${CONFIG}" ".build/arm64-apple-macosx/${CONFIG}" ".build/x86_64-apple-macosx/${CONFIG}"; do
  for b in "${dir}"/*.bundle; do
    [ -e "$b" ] || continue
    cp -R "$b" "${BUNDLE}/Contents/Resources/"
    case "$b" in *SigstopCore.bundle) COPIED_CORPUS=1 ;; esac
  done
done
if [ "${COPIED_CORPUS}" -ne 1 ] || [ ! -f "${BUNDLE}/Contents/Resources/${APP_NAME}_SigstopCore.bundle/corpus.json" ]; then
  echo "error: the SigstopCore resource bundle with corpus.json is not in the app." >&2
  echo "       Without it the app dies at launch on every machine (this was the v0.1.5 bug)." >&2
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

# Hardened runtime is now OPT-IN, and the reason is worth reading before you turn
# it back on by default.
#
# --options runtime enables Library Validation, which makes dyld refuse to load a
# library signed by a different Team ID than the main executable. Ad-hoc and
# self-signed certificates carry no Team ID, so two separately ad-hoc-signed
# Mach-Os are treated as different teams even when the same command signed both.
# With Sparkle.framework embedded, the result is an app that passes
# `codesign --verify --deep --strict` and then dies at launch with:
#
#   Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
#   ... mapping process and mapped file (non-platform) have different Team IDs
#
# Before this framework existed the bundle had nothing to load, so hardened
# runtime cost nothing and was on. It is not free any more. The honest options
# are a real Developer ID (both halves get the same Team ID, HARDENED=1 works),
# or no hardened runtime. Disabling library validation with
# com.apple.security.cs.disable-library-validation is NOT one of the options:
# docs/PRIVACY.md §2.8 names the absence of that entitlement as the thing that
# stops the app loading code nobody reviewed, and trading it away to keep a
# checkbox would be exactly backwards.
#
# What carries the guarantee in the meantime is Sparkle's EdDSA signature, which
# is checked against a key compiled into the app and does not depend on Apple
# issuing anybody a certificate. See docs/RELEASING.md.
HARDENED="${HARDENED:-0}"
RUNTIME_FLAGS=()
if [ "${HARDENED}" = "1" ]; then
  RUNTIME_FLAGS=(--options runtime)
  echo "    (hardened runtime requested, needs a Developer ID or the app will not launch)"
fi

codesign --force --sign "${SIGN_IDENTITY}" \
         --entitlements Resources/sigstop.entitlements \
         ${RUNTIME_FLAGS[@]+"${RUNTIME_FLAGS[@]}"} \
         "${BUNDLE}" 2>&1 | sed 's/^/    /'

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
