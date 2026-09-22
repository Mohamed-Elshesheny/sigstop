#!/usr/bin/env bash
#
# Does the thing we ship actually run on a machine that is not this one?
#
# This exists because the answer was no for every release up to v0.1.5 and nothing here
# could tell: the app resolved its own resources through the maintainer's build directory,
# so it worked perfectly on the only computer it had ever been run on and died before
# main() on every other. `make test` passed. `make verify` passed. A human opening the app
# saw it work. The bug reached real users and the report was "nothing happens at all".
#
# So this does not test the code. It tests the ARTIFACT, under the conditions that made the
# bug invisible:
#
#   1. a copy of the .app somewhere with no relationship to the source tree
#   2. .build moved aside, so a baked build path resolves to nothing
#   3. a pristine HOME, so no settings, no counters, no badges, no defaults
#   4. launched as the GUI, not as --doctor, because --doctor never touched the corpus and
#      that is exactly why the first version of this check passed while the bug was live
#
# It then asks the running app what it can actually see, rather than trusting that a
# process exists: a process that is alive with an empty corpus is the failure being
# checked for.

set -euo pipefail
cd "$(dirname "$0")/.."

APP="${BUNDLE:-dist/sigstop.app}"
BIN="${APP}/Contents/MacOS/sigstop"
BUILD_DIR="$(pwd)/.build"

[ -d "${APP}" ] || { echo "error: ${APP} not found, run make bundle first" >&2; exit 1; }

STAGE="$(mktemp -d)"
PROBE_HOME="$(mktemp -d)"
HIDDEN=0
X86_HOME=""
FAILURES=0

cleanup() {
  pkill -f "${STAGE}/sigstop.app" 2>/dev/null || true
  if [ "${HIDDEN}" -eq 1 ]; then
    if [ -e "${BUILD_DIR}" ]; then
      echo "warning: ${BUILD_DIR} was recreated while hidden; the original is still at ${BUILD_DIR}-smoke-hidden" >&2
    else
      mv "${BUILD_DIR}-smoke-hidden" "${BUILD_DIR}" 2>/dev/null || true
    fi
  fi
  rm -rf "${STAGE}" "${PROBE_HOME}" ${X86_HOME:+"${X86_HOME}"}
}
trap cleanup EXIT

pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

echo "==> staging a copy with no relationship to this tree"
cp -R "${APP}" "${STAGE}/sigstop.app"
mkdir -p "${PROBE_HOME}/Library/Application Support"

if [ -d "${BUILD_DIR}" ]; then
  if [ -e "${BUILD_DIR}-smoke-hidden" ]; then
    echo "error: ${BUILD_DIR}-smoke-hidden already exists, left by an interrupted run." >&2
    echo "       Move it back to ${BUILD_DIR} (or delete it) before running smoke again." >&2
    exit 1
  fi
  mv "${BUILD_DIR}" "${BUILD_DIR}-smoke-hidden"
  HIDDEN=1
  pass "build directory hidden, so a baked path resolves to nothing"
else
  pass "no build directory to hide"
fi

echo "==> asking it what it sees before it has ever run"
FIRST="$(CFFIXED_USER_HOME="${PROBE_HOME}" HOME="${PROBE_HOME}" \
  "${STAGE}/sigstop.app/Contents/MacOS/sigstop" --doctor 2>&1 || true)"
if [ -d "${PROBE_HOME}/Library/Application Support/dev.sigstop.app" ]; then
  fail "--doctor created the data directory, so a diagnostic wrote to disk"
else
  pass "--doctor read without writing anything"
fi
if printf '%s' "${FIRST}" | grep -q "the app has not run here"; then
  pass "--doctor says the app has not run here, which is true"
else
  fail "--doctor did not notice that nothing has been stored yet"
fi

echo "==> launching it the way a person does"
set +m   # so terminating it at the end does not print a job notice over the result
CFFIXED_USER_HOME="${PROBE_HOME}" HOME="${PROBE_HOME}" \
  "${STAGE}/sigstop.app/Contents/MacOS/sigstop" >"${STAGE}/run.log" 2>&1 &
LAUNCHED=$!
sleep 6

if kill -0 "${LAUNCHED}" 2>/dev/null; then
  pass "still running after six seconds"
else
  fail "died on launch"
  sed -n '1,8p' "${STAGE}/run.log" | sed 's/^/        /'
fi

if grep -qiE "fatal error|could not load|precondition failed" "${STAGE}/run.log"; then
  fail "printed a fatal error while starting"
  grep -iE "fatal error|could not load|precondition failed" "${STAGE}/run.log" | head -3 | sed 's/^/        /'
else
  pass "no fatal error on the way up"
fi

echo "==> asking it what it can see"
DOCTOR="$(CFFIXED_USER_HOME="${PROBE_HOME}" HOME="${PROBE_HOME}" \
  "${STAGE}/sigstop.app/Contents/MacOS/sigstop" --doctor 2>&1 || true)"

CORPUS_N="$(printf '%s' "${DOCTOR}" | grep -oE '[0-9]+ messages loaded' | head -1 | cut -d' ' -f1 || true)"
if [ -n "${CORPUS_N}" ] && [ "${CORPUS_N}" -gt 0 ] 2>/dev/null; then
  pass "reads its own message corpus (${CORPUS_N} messages)"
else
  fail "corpus did not load, so every prompt would come from the emergency pool"
fi

# Tier 0 is the promise that the app works with nothing granted. On a pristine home with no
# permissions this is the line that proves it rather than asserting it.
if grep -qE '^ +0 +input idle +[0-9]+\.[0-9]s via ' <<<"${DOCTOR}"; then
  pass "tier 0 reads a real idle time with no permissions and no settings"
else
  fail "could not read the signals that need no permission"
fi

if printf '%s' "${DOCTOR}" | grep -qiE "^\s+bundle\s+dev\.sigstop\.app"; then
  pass "identifies itself as the shipped bundle"
else
  fail "did not report its own bundle identifier"
fi

echo "==> checking it left nothing behind it could not create"
if [ -d "${PROBE_HOME}/Library/Application Support/dev.sigstop.app" ]; then
  pass "created its own data directory from nothing"
else
  fail "no data directory, so a first run cannot persist anything"
fi

echo "==> the Intel slice"
BIN="${STAGE}/sigstop.app/Contents/MacOS/sigstop"
kill "${LAUNCHED}" 2>/dev/null || true
wait "${LAUNCHED}" 2>/dev/null || true
if ! lipo -archs "${BIN}" | grep -qw x86_64; then
  if [ "${REQUIRE_X86:-0}" = "1" ]; then
    fail "the bundle has no x86_64 slice, so Intel Macs get nothing"
  else
    printf '  skip  native-only bundle, there is no x86_64 slice to run\n'
  fi
elif ! arch -x86_64 /usr/bin/true 2>/dev/null; then
  if [ "${REQUIRE_X86:-0}" = "1" ]; then
    fail "the x86_64 slice cannot run here without Rosetta. Install it once: softwareupdate --install-rosetta"
  else
    printf '  skip  the x86_64 slice was not run: no Rosetta on this Mac\n'
  fi
else
  X86_HOME="$(mktemp -d)"
  mkdir -p "${X86_HOME}/Library/Application Support"
  CFFIXED_USER_HOME="${X86_HOME}" HOME="${X86_HOME}" arch -x86_64 "${BIN}" >"${STAGE}/run-x86.log" 2>&1 &
  X86_PID=$!
  sleep 6
  if kill -0 "${X86_PID}" 2>/dev/null; then
    pass "the x86_64 slice is still running after six seconds"
  else
    fail "the x86_64 slice died on launch"
    sed -n '1,8p' "${STAGE}/run-x86.log" | sed 's/^/        /'
  fi
  kill "${X86_PID}" 2>/dev/null || true
  wait "${X86_PID}" 2>/dev/null || true
  X86_DOCTOR="$(CFFIXED_USER_HOME="${X86_HOME}" HOME="${X86_HOME}" arch -x86_64 "${BIN}" --doctor 2>&1 || true)"
  if printf '%s' "${X86_DOCTOR}" | grep -qE '^  slice +x86_64'; then
    pass "--doctor confirms it was the x86_64 slice that ran"
  else
    fail "asked for x86_64, but --doctor says: $(printf '%s' "${X86_DOCTOR}" | grep -E '^  slice' | sed 's/^ *//')"
  fi
  X86_N="$(printf '%s' "${X86_DOCTOR}" | grep -oE '[0-9]+ messages loaded' | head -1 | cut -d' ' -f1 || true)"
  if [ -n "${X86_N}" ] && [ "${X86_N}" -gt 0 ] 2>/dev/null; then
    pass "the x86_64 slice reads its message corpus (${X86_N} messages)"
  else
    fail "the x86_64 slice did not load the corpus"
  fi
  rm -rf "${X86_HOME}"
fi

printf '\n'
if [ "${FAILURES}" -eq 0 ]; then
  echo "smoke: the shipped app works on a machine that is not this one"
  exit 0
fi
echo "smoke: ${FAILURES} check(s) FAILED"
exit 1
