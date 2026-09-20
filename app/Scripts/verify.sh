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
head2 "1. the app's own binary does no networking"

# Frameworks. CFNetwork and Network are the two that matter; Foundation is
# always linked and is where NSURLSession lives, which is why the symbol check
# below exists and this one is not sufficient on its own.
if otool -L "${BIN}" | grep -Ei '(CFNetwork|/Network\.framework|libnetwork)' >/dev/null; then
  fail "a networking framework is linked into the app binary"
  otool -L "${BIN}" | grep -Ei '(CFNetwork|/Network\.framework|libnetwork)' | sed 's/^/        /'
else
  pass "no networking framework linked into the app binary"
fi

# Symbols. This is the check that actually bites: it catches NSURLSession reached
# through Foundation, BSD sockets reached through libSystem, and the DNS and
# reachability paths that are the classic way to smuggle data into a hostname.
NET_SYMS=$(nm -u "${BIN}" 2>/dev/null \
  | grep -E '(NSURLSession|NSURLConnection|NSURLDownload|NWConnection|NWBrowser|NWListener|CFHost|CFSocket|SCNetworkReachability|CFStream.*Socket)' \
  || true)
BSD_SYMS=$(nm -u "${BIN}" 2>/dev/null \
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

# Sparkle performs the download in its own XPC service, out of process. That is
# not decoration: it keeps the half of the update that touches the network out of
# the process that holds an Accessibility grant.
if [ -d "${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" ]; then
  pass "downloads run in Sparkle's out-of-process XPC service"
else
  fail "Sparkle's Downloader.xpc is missing from the bundle"
fi

# ---------------------------------------------------------------------------
head2 "3. no analytics or telemetry SDK"

# By name, because that is how these actually arrive: as a transitive dependency
# somebody added for one convenience function. Checked against the whole bundle,
# not just the executable, so a vendored copy inside a framework is caught too.
TELEMETRY='Firebase|GoogleAnalytics|GoogleAppMeasurement|Crashlytics|Fabric|Mixpanel|Amplitude|Segment|Analytics\.framework|Sentry|Bugsnag|AppCenter|Instabug|Countly|Matomo|Plausible|PostHog|Datadog|NewRelic|TelemetryDeck|Aptabase|Adjust|AppsFlyer|Branch|Intercom|Smartlook|Heap'
HITS=$( { otool -L "${BIN}" 2>/dev/null; find "${BUNDLE}" -maxdepth 6 \( -name '*.framework' -o -name '*.dylib' -o -name '*.a' \) 2>/dev/null; } \
  | grep -Ei "${TELEMETRY}" || true)
if [ -n "${HITS}" ]; then
  fail "something that looks like an analytics SDK is in the bundle"
  printf '%s\n' "${HITS}" | sed 's/^/        /'
else
  pass "none of the known analytics or crash-reporting SDKs are present"
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

# Library validation. docs/PRIVACY.md §2.8 names the ABSENCE of this entitlement
# as the thing that stops the process loading code nobody reviewed. Embedding
# Sparkle made it tempting to add; it was not added.
if printf '%s' "${ENTS}" | grep -q 'disable-library-validation'; then
  fail "com.apple.security.cs.disable-library-validation is present"
else
  pass "library validation is not disabled"
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
UNEXPECTED=$(strings -a "${BIN}" \
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

check_plist_false SUEnableAutomaticChecks "no scheduled check unless the user turns it on"
check_plist_false SUAutomaticallyUpdate   "nothing downloads or installs without being asked"
check_plist_false SUEnableSystemProfiling "no system profile is appended to the request"

# ---------------------------------------------------------------------------
printf '\n'
if [ "${FAILURES}" -eq 0 ]; then
  echo "verify: all checks passed"
  exit 0
fi
echo "verify: ${FAILURES} check(s) FAILED"
exit 1
