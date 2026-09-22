#!/usr/bin/env bash
#
# What sigstop costs a battery, measured from the kernel's own counters for the process
# (proc_pid_rusage), never from `top`, whose IDLEW column is a running total and reads like a
# rate. Two states: idle, which is most of a day, and the break screen.
#
# The copy under test runs from a temporary folder with an empty home. Quit any other sigstop
# first; the counters are per process, but one instance keeps the numbers easy to trust.
#
#   make bench            IDLE=180 BREAK=45 by default, in seconds
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${BUNDLE:-dist/sigstop.app}"
IDLE="${IDLE:-180}"
BREAK="${BREAK:-45}"
[ -d "${APP}" ] || { echo "error: ${APP} not found, run make bundle first" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'pkill -f "${WORK}/" 2>/dev/null || true; rm -rf "${WORK}"' EXIT
swiftc -O -o "${WORK}/rusage" Scripts/rusage.swift

run() {
  local label="$1" warm="$2" secs="$3"; shift 3
  local home="${WORK}/home-${label}"
  mkdir -p "${home}/Library/Application Support"
  cp -R "${APP}" "${WORK}/${label}.app"
  CFFIXED_USER_HOME="${home}" HOME="${home}" "${WORK}/${label}.app/Contents/MacOS/sigstop" "$@" >/dev/null 2>&1 &
  local pid=$!
  sleep "${warm}"
  local a b
  a="$("${WORK}/rusage" "${pid}")" || { echo "error: sigstop exited during the ${warm}s warm-up" >&2; exit 1; }
  sleep "${secs}"
  b="$("${WORK}/rusage" "${pid}")" || { echo "error: sigstop exited during the ${secs}s measurement" >&2; exit 1; }
  kill "${pid}" 2>/dev/null || true; wait "${pid}" 2>/dev/null || true
  python3 - "${label}" "${secs}" "${a}" "${b}" <<'PY'
import sys
label, secs = sys.argv[1], float(sys.argv[2])
a = [float(x) for x in sys.argv[3].split()]; b = [float(x) for x in sys.argv[4].split()]
print(f"  {label:<7} cpu {100*(b[0]-a[0])/1e9/secs:5.2f}%   wakeups {(b[1]-a[1])/secs:5.1f}/s   energy {(b[2]-a[2])/1e6/secs:5.2f} mW   memory {b[3]/1048576:3.0f} MB")
PY
}

echo "==> ${APP}, idle for ${IDLE}s after a minute to settle, then the break screen for ${BREAK}s"
run idle 60 "${IDLE}"
run break 12 "${BREAK}" --bench-break
