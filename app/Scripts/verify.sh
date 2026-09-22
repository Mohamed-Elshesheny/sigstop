#!/usr/bin/env bash
# Prove the app's privacy claims against the BUILT BUNDLE, not against the source.
#
# This script used to assert one thing, "no networking framework is linked", and
# fail the build if any appeared. That assertion is gone, because it is no longer
# true: the app embeds Sparkle so it can check for, verify and install updates.
#
# Deleting the check would have been the easy move and the wrong one. What
# replaces it is narrower and harder to pass by accident. The claim is no longer
# "this binary cannot open a socket." It is:
#
#   1. The app's OWN executable links no networking framework and references no
#      networking symbol. Every byte of network code in this bundle belongs to
#      Sparkle, in a framework you can name, version and diff.
#   2. Sparkle is the ONLY thing embedded. One framework, no second updater, no
#      vendored SDK that came along for the ride.
#   3. No analytics or telemetry SDK is linked or embedded, by name, from a list.
#   4. There is no network SERVER entitlement: nothing here listens.
#   5. Updates are signature-gated: SUPublicEDKey is present and is a real
#      32-byte Ed25519 key, so an update that is not signed by the maintainer's
#      private half cannot install.
#   6. Exactly one fetchable endpoint exists, it is HTTPS, and it is the feed.
#   7. Nothing checks on its own: automatic checks and system profiling are off
#      in the shipped Info.plist.
#   8. The entitlement that would let this process load unreviewed code is still
#      absent (docs/PRIVACY.md §2.8).
#
# Every one of these is a property of the artifact a user downloads, checkable
# with tools they already have. Run it yourself: `make verify`.
set -uo pipefail

cd "$(dirname "$0")/.."

SLICE_DIR=""
BUILD_DIR="$(pwd)/.build"
BUILD_HIDDEN="${BUILD_DIR}-verify-hidden"
HIDDEN=0
# An interrupt during section 8 would otherwise leave the build directory hidden.
cleanup() {
  [ -n "${SLICE_DIR}" ] && rm -rf "${SLICE_DIR}"
  if [ "${HIDDEN}" -eq 1 ] && [ -d "${BUILD_HIDDEN}" ] && [ ! -e "${BUILD_DIR}" ]; then
    mv "${BUILD_HIDDEN}" "${BUILD_DIR}"
  fi
}
trap cleanup EXIT

APP_NAME="sigstop"
BUNDLE="${BUNDLE:-dist/${APP_NAME}.app}"
BIN="${BUNDLE}/Contents/MacOS/${APP_NAME}"
PLIST="${BUNDLE}/Contents/Info.plist"

FAILURES=0

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
head2() { printf '\n== %s ==\n' "$1"; }

[ -x "${BIN}" ] || { echo "error: ${BIN} not found, run 'make bundle' first" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Every binary-level check below runs once per architecture, and this is new.
#
# It did not matter while the binary was arm64 only. The shipped image is universal
# now, and `nm` and `otool` read the NATIVE slice by default: on this machine a
# networking symbol present only in the Intel half returned nothing and the check
# said ok. That is a check that passes precisely when it should not, which is worse
# than not having it. `all_slices nm -u` runs the tool against each slice in turn.
ARCHS="$(lipo -archs "${BIN}" 2>/dev/null || echo "")"
SLICES=()
if [ "$(printf '%s ' ${ARCHS} | wc -w | tr -d ' ')" -gt 1 ]; then
  SLICE_DIR="$(mktemp -d)"
  for a in ${ARCHS}; do
    lipo -thin "${a}" "${BIN}" -output "${SLICE_DIR}/${a}" 2>/dev/null \
      || { echo "error: could not split ${a} out of ${BIN}" >&2; exit 1; }
    SLICES+=("${SLICE_DIR}/${a}")
  done
  echo "  note  universal binary, every check below runs on: ${ARCHS}"
else
  SLICES=("${BIN}")
fi

all_slices() { for s in "${SLICES[@]}"; do "$@" "${s}"; done; }

# ---------------------------------------------------------------------------
head2 "1. the app's own binary does no networking"

# Frameworks. CFNetwork and Network are the two that matter; Foundation is
# always linked and is where NSURLSession lives, which is why the symbol check
# below exists and this one is not sufficient on its own.
if all_slices otool -L | grep -Ei '(CFNetwork|/Network\.framework|libnetwork)' >/dev/null; then
  fail "a networking framework is linked into the app binary"
  all_slices otool -L | grep -Ei '(CFNetwork|/Network\.framework|libnetwork)' | sed 's/^/        /'
else
  pass "no networking framework linked into the app binary"
fi

# Symbols. This is the check that actually bites: it catches NSURLSession reached
# through Foundation, BSD sockets reached through libSystem, and the DNS and
# reachability paths that are the classic way to smuggle data into a hostname.
NET_SYMS=$(all_slices nm -u 2>/dev/null \
  | grep -E '(NSURLSession|NSURLConnection|NSURLDownload|NWConnection|NWBrowser|NWListener|CFHost|CFSocket|SCNetworkReachability|CFStream.*Socket)' \
  || true)
BSD_SYMS=$(all_slices nm -u 2>/dev/null \
  | grep -E '^ *_(socket|connect|bind|listen|accept|send|sendto|recvfrom|getaddrinfo|gethostbyname|res_9_init)$' \
  || true)
if [ -n "${NET_SYMS}${BSD_SYMS}" ]; then
  fail "the app binary references networking symbols directly"
  printf '%s\n%s\n' "${NET_SYMS}" "${BSD_SYMS}" | grep -v '^$' | sed 's/^/        /'
else
  pass "no networking symbol referenced by the app binary"
fi

# ---------------------------------------------------------------------------
head2 "2. the only networking in the bundle is Sparkle's"

FRAMEWORKS_DIR="${BUNDLE}/Contents/Frameworks"
EMBEDDED=$(ls "${FRAMEWORKS_DIR}" 2>/dev/null || true)
if [ "${EMBEDDED}" = "Sparkle.framework" ]; then
  pass "exactly one embedded framework, and it is Sparkle"
else
  fail "expected Sparkle.framework and nothing else, found: ${EMBEDDED:-(none)}"
fi

# The pinned version, read out of the framework itself rather than out of
# Package.resolved, so this checks what shipped and not what was intended.
SPARKLE_PLIST="${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B/Resources/Info.plist"
if [ -f "${SPARKLE_PLIST}" ]; then
  SPARKLE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${SPARKLE_PLIST}" 2>/dev/null || echo "?")
  pass "Sparkle ${SPARKLE_VERSION} (pinned exactly in Package.swift)"
else
  fail "Sparkle.framework has no readable Info.plist"
fi

# What is actually true about where the update runs, which is not what this said.
#
# It claimed "downloads run in Sparkle's out-of-process XPC service" and proved it by
# checking that Downloader.xpc exists in the framework. Sparkle ships that service inside
# the framework whether or not it is used, and it is used ONLY when the host app sets
# `SUEnableDownloaderService`, an opt-in for sandboxed apps with no network-client
# entitlement. This app is not sandboxed and does not set it, so the check was true, the
# claim was false, and the check could not have failed either way. A check that cannot fail
# is worse than no check: it is a reassurance nobody earned.
#
# The download runs in-process, inside Sparkle.framework. The INSTALL does not: Autoupdate
# is always a separate process. Both halves are asserted below, each by something that
# could come out the other way.
if plutil -extract SUEnableDownloaderService raw "${PLIST}" >/dev/null 2>&1; then
  fail "SUEnableDownloaderService is set; Sparkle warns against it on an unsandboxed app"
else
  pass "SUEnableDownloaderService is unset, so the download runs in-process inside Sparkle.framework"
fi

if [ -x "${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B/Autoupdate" ]; then
  pass "Sparkle's separate Autoupdate installer is present in the bundle"
else
  fail "Sparkle's Autoupdate is missing, so there is nothing to install an update out of process"
fi

# ---------------------------------------------------------------------------
head2 "3. no analytics or telemetry SDK"

# By name, because that is how these actually arrive: as a transitive dependency
# somebody added for one convenience function. Checked against the whole bundle,
# not just the executable, so a vendored copy inside a framework is caught too.
TELEMETRY='Firebase|GoogleAnalytics|GoogleAppMeasurement|Crashlytics|Fabric|Mixpanel|Amplitude|Segment|Analytics\.framework|Sentry|Bugsnag|AppCenter|Instabug|Countly|Matomo|Plausible|PostHog|Datadog|NewRelic|TelemetryDeck|Aptabase|Adjust|AppsFlyer|Branch|Intercom|Smartlook|Heap'
HITS=$( { all_slices otool -L 2>/dev/null; find "${BUNDLE}" -maxdepth 6 \( -name '*.framework' -o -name '*.dylib' -o -name '*.a' \) 2>/dev/null; } \
  | grep -Ei "${TELEMETRY}" || true)
if [ -n "${HITS}" ]; then
  fail "something that looks like an analytics SDK is in the bundle"
  printf '%s\n' "${HITS}" | sed 's/^/        /'
else
  pass "none of the known analytics or crash-reporting SDKs are present"
fi

# docs/PRIVACY.md §2 says the app never reads the clipboard, the screen or keystrokes, and never
# starts another process or scripts another app. These are the symbols each of those needs. An
# NSEvent monitor is an Objective-C method and invisible to nm; the source check in
# .github/scripts/check-forbidden-apis.py covers that one.
FORBIDDEN='^ *_(OBJC_CLASS_\$_(NSPasteboard|NSTask|NSAppleScript|OSAScript|SCStream|SCShareableContent|SCScreenshotManager|AVCaptureSession|AVAudioRecorder|AVAudioEngine)|posix_spawnp?|fork|vfork|execve|execv|execvp|system|popen|AESendMessage|CGEventTapCreate|CGEventTapCreateForPid|CGEventTapCreateForPSN|CGWindowListCreateImage|CGDisplayCreateImage|IOHIDManagerCreate|CGEventSourceKeyState)$'
FORBIDDEN_HITS=$(all_slices nm -u 2>/dev/null | grep -E "${FORBIDDEN}" | sort -u || true)
if [ -n "${FORBIDDEN_HITS}" ]; then
  fail "the app binary references an API that reads content or starts another process"
  printf '%s\n' "${FORBIDDEN_HITS}" | sed 's/^/        /'
else
  pass "no clipboard, screen capture, key reading, process spawning or AppleScript symbol"
fi

# ---------------------------------------------------------------------------
head2 "4. entitlements"

ENTS=$(codesign -d --entitlements - --xml "${BUNDLE}" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)

# The server entitlement is the one that has no defensible reason to exist here.
# A break timer does not listen for connections.
if printf '%s' "${ENTS}" | grep -q 'com.apple.security.network.server'; then
  fail "a network SERVER entitlement is present, this app must never listen"
else
  pass "no network server entitlement"
fi

# The hardened runtime is what makes dyld refuse DYLD_INSERT_LIBRARIES. Without it any process
# running as the user can start this binary with its own code inside, and that code inherits the
# Accessibility grant. This check used to pass on the absence of disable-library-validation,
# which proved nothing: without the runtime, library validation is not enforced at all.
SIG_INFO=$(codesign -dvv "${BUNDLE}" 2>&1 || true)
CS_FLAGS=$(printf '%s\n' "${SIG_INFO}" | sed -n 's/.*flags=0x\([0-9a-f]*\).*/\1/p' | head -1)
if [ -n "${CS_FLAGS}" ] && (( 16#${CS_FLAGS} & 16#10000 )); then
  pass "hardened runtime is on, so dyld refuses DYLD_* injection"
else
  fail "hardened runtime is off, so another process can inject code and borrow the Accessibility grant"
fi

REOPENS=""
for key in allow-dyld-environment-variables allow-unsigned-executable-memory allow-jit \
           disable-executable-page-protection get-task-allow; do
  if printf '%s' "${ENTS}" | grep -q "${key}"; then REOPENS="${REOPENS} ${key}"; fi
done
if [ -n "${REOPENS}" ]; then
  fail "entitlements reopen what the hardened runtime closes:${REOPENS}"
else
  pass "no entitlement reopens injection, JIT or debugging"
fi

# Library validation can only be on when the app and Sparkle share a Team ID. An ad-hoc build
# has none, so it carries disable-library-validation; a build with a Team ID must not.
TEAM=$(printf '%s\n' "${SIG_INFO}" | sed -n 's/^TeamIdentifier=//p' | head -1)
if printf '%s' "${ENTS}" | grep -q 'disable-library-validation'; then
  if [ -z "${TEAM}" ] || [ "${TEAM}" = "not set" ]; then
    pass "library validation is off because no Team ID exists to validate against"
  else
    fail "library validation is disabled on a build signed by team ${TEAM}, which does not need it"
  fi
else
  pass "library validation is on"
fi

# ---------------------------------------------------------------------------
head2 "5. updates are signature-gated"

ED_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "${PLIST}" 2>/dev/null || true)
if [ -z "${ED_KEY}" ]; then
  fail "SUPublicEDKey is missing, Sparkle would have nothing to verify against"
else
  # A base64 Ed25519 public key is 32 bytes, which is 44 base64 characters.
  DECODED_LEN=$(printf '%s' "${ED_KEY}" | base64 --decode 2>/dev/null | wc -c | tr -d ' ')
  if [ "${DECODED_LEN}" = "32" ]; then
    pass "SUPublicEDKey is a 32-byte Ed25519 public key"
  else
    fail "SUPublicEDKey does not decode to 32 bytes (got ${DECODED_LEN})"
  fi
fi

# The private half must never be anywhere near the tree. This is cheap and the
# failure it catches is unrecoverable.
# Searched over the whole repository, not just app/, and excluding this file ,
# which names the patterns and would otherwise always match itself.
KEY_HITS=$(grep -rIlE 'BEGIN [A-Z ]*PRIVATE KEY|SUPrivateEDKey' .. \
  --exclude-dir=.build --exclude-dir=dist --exclude-dir=.git \
  --exclude-dir=node_modules --exclude-dir=.next --exclude=verify.sh \
  2>/dev/null || true)
if [ -n "${KEY_HITS}" ]; then
  fail "something that looks like a private key is in the repository"
  printf '%s\n' "${KEY_HITS}" | sed 's/^/        /'
else
  pass "no private signing key anywhere in the repository"
fi

# Sparkle's `generate_keys -x` exports the key as bare base64 with no header, so the grep above
# cannot see it. A line that is nothing but a 32 or 64 byte base64 value, other than the public
# key, is treated as one.
PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "${PLIST}" 2>/dev/null || true)
BARE_KEYS=$(cd .. && python3 - "${PUBLIC_KEY}" <<'PY'
import base64, os, re, sys
public = sys.argv[1]
token = re.compile(r"^(?:[A-Za-z0-9+/]{43}=|[A-Za-z0-9+/]{86}==)$")
skip = {".build", "dist", ".git", "node_modules", ".next"}
for base, dirs, files in os.walk("."):
    dirs[:] = [d for d in dirs if d not in skip and not d.startswith(".build")]
    for name in files:
        path = os.path.join(base, name)
        try:
            if os.path.getsize(path) > 1_000_000:
                continue
            text = open(path, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        for line in text.splitlines():
            value = line.strip()
            if value and value != public and token.match(value):
                try:
                    if len(base64.b64decode(value)) in (32, 64):
                        print(path)
                        break
                except ValueError:
                    pass
PY
)
if [ -n "${BARE_KEYS}" ]; then
  fail "a line holding nothing but a key-sized base64 value is in the repository"
  printf '%s\n' "${BARE_KEYS}" | sed 's/^/        /'
else
  pass "no bare base64 key, the format Sparkle exports, anywhere in the repository"
fi

# ---------------------------------------------------------------------------
head2 "6. exactly one endpoint, and it is the feed"

FEED=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "${PLIST}" 2>/dev/null || true)
case "${FEED}" in
  https://*) pass "feed URL is HTTPS: ${FEED}" ;;
  "")        fail "SUFeedURL is missing" ;;
  *)         fail "feed URL is not HTTPS: ${FEED}" ;;
esac

# Every other URL compiled into the app is a link handed to the user's browser,
# which docs/PRIVACY.md §2.8 allowlists by call site. If a URL shows up here that
# is not on this list, someone added an endpoint.
ALLOWED='^https://github\.com/Mohamed-Elshesheny/sigstop'
UNEXPECTED=$(all_slices strings -a \
  | grep -oE 'https?://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+' \
  | sort -u \
  | grep -Ev "${ALLOWED}" || true)
if [ -n "${UNEXPECTED}" ]; then
  fail "URLs in the app binary that are not allowlisted browser links"
  printf '%s\n' "${UNEXPECTED}" | sed 's/^/        /'
else
  pass "every URL in the app binary is an allowlisted browser link"
fi

# ---------------------------------------------------------------------------
head2 "7. nothing checks on its own"

check_plist_false() {  # check_plist_false <key> <human description>
  local value
  value=$(/usr/libexec/PlistBuddy -c "Print :$1" "${PLIST}" 2>/dev/null || echo "missing")
  if [ "${value}" = "false" ]; then
    pass "$2"
  else
    fail "$1 is '${value}', expected false, $2"
  fi
}

check_plist_false SUEnableAutomaticChecks "no scheduled check, and the app also forces it off at launch"
check_plist_false SUAutomaticallyUpdate   "nothing downloads or installs without being asked"
# Sparkle decides whether to append a system profile from SUSendProfileInfo, not from
# SUEnableSystemProfiling, which only drives its stock permission prompt. The delegate in
# UpdateChecker.swift allows no profile keys either way; this keeps the plist from asking for one.
if /usr/libexec/PlistBuddy -c "Print :SUSendProfileInfo" "${PLIST}" >/dev/null 2>&1 \
   && [ "$(/usr/libexec/PlistBuddy -c "Print :SUSendProfileInfo" "${PLIST}")" != "false" ]; then
  fail "SUSendProfileInfo is set in Info.plist, which asks Sparkle to send a system profile"
else
  pass "no system profile is asked for in Info.plist"
fi
# Without this Sparkle unpacks a downloaded image first and checks it after, and accepts an app
# whose code signature matches the installed one in place of the EdDSA signature. With it, the
# archive's EdDSA signature is checked before anything is unpacked, and the only fallback Sparkle
# offers needs a Developer ID team this app does not have, so the key is the only way in.
if [ "$(/usr/libexec/PlistBuddy -c "Print :SUVerifyUpdateBeforeExtraction" "${PLIST}" 2>/dev/null)" = "true" ]; then
  pass "an update's EdDSA signature is checked before it is unpacked"
else
  fail "SUVerifyUpdateBeforeExtraction is not true, so an update is unpacked before it is verified"
fi
# The schedule key was removed with the toggle (§4.3). It is inert while automatic checks
# are off, but a leftover key is how a removed feature creeps back, so it must stay gone.
if plutil -extract SUScheduledCheckInterval raw "${PLIST}" >/dev/null 2>&1; then
  fail "SUScheduledCheckInterval is back in Info.plist; the schedule was removed"
else
  pass "no schedule interval key, so nothing describes a check that does not run"
fi

# ---------------------------------------------------------------------------
# 8. it runs on a machine that is not this one
# ---------------------------------------------------------------------------
#
# The check that would have caught the worst bug this project has shipped.
#
# SwiftPM's generated `Bundle.module` resolves a resource bundle from exactly two places:
# the top level of the app, where macOS does not allow one, and the absolute build
# directory of the machine that compiled it. So the corpus resolved through the
# maintainer's own `.build` and every published build died before `main()` on every other
# computer: no window, no Dock icon, no menu bar item, nothing to report. It cannot be
# caught by running the app on the machine that built it, which is the only machine it was
# ever run on.
#
# So run it with `.build` moved aside, which is the closest this machine can get to being
# somebody else's. A fresh HOME as well, so a launch here cannot touch real data.
head2 "8. it starts on a machine with no build directory"

PROBE_HOME="$(mktemp -d)"
PROBE_LOG="$(mktemp)"
if [ -e "${BUILD_HIDDEN}" ]; then
  echo "error: ${BUILD_HIDDEN} already exists, left by an interrupted run." >&2
  echo "       Move it back to ${BUILD_DIR} (or delete it) before running verify again." >&2
  exit 1
fi
if [ -d "${BUILD_DIR}" ]; then mv "${BUILD_DIR}" "${BUILD_HIDDEN}"; HIDDEN=1; fi

CFFIXED_USER_HOME="${PROBE_HOME}" HOME="${PROBE_HOME}" \
  "${BUNDLE}/Contents/MacOS/sigstop" --doctor >"${PROBE_LOG}" 2>&1
PROBE_STATUS=$?

if [ "${HIDDEN}" -eq 1 ]; then mv "${BUILD_HIDDEN}" "${BUILD_DIR}"; HIDDEN=0; fi

# The probe has to READ something, not merely start. The first version of this check
# asked `--doctor` for its output and passed while the bug was live, because `--doctor`
# did not touch the corpus. It prints the message count now, so a zero or a missing line
# is the failure.
CORPUS_LINE="$(grep -oE '[0-9]+ messages loaded from the bundled corpus' "${PROBE_LOG}" || true)"
CORPUS_N="${CORPUS_LINE%% *}"
if [ "${PROBE_STATUS}" -eq 0 ] \
   && ! grep -qi "could not load resource bundle\|Fatal error" "${PROBE_LOG}" \
   && [ -n "${CORPUS_N}" ] && [ "${CORPUS_N}" -gt 0 ] 2>/dev/null; then
  pass "starts and reads its own resources with the build directory gone (${CORPUS_N} messages)"
else
  fail "dies without the build directory, so it would die on every machine but this one"
  sed -n '1,6p' "${PROBE_LOG}" | sed 's/^/        /'
fi
rm -rf "${PROBE_HOME}" "${PROBE_LOG}"

# ---------------------------------------------------------------------------
printf '\n'
if [ "${FAILURES}" -eq 0 ]; then
  echo "verify: all checks passed"
  exit 0
fi
echo "verify: ${FAILURES} check(s) FAILED"
exit 1
