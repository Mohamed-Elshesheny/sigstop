#!/usr/bin/env bash
#
# Somebody has to run the x86_64 slice before it ships. This Mac, under Rosetta, when it can.
# When it cannot (no Rosetta, or a macOS that no longer has it), CI's run on this exact commit,
# and only if its Intel step passed. Anything else refuses.
#
#   BUNDLE=dist/sigstop.app ./Scripts/intel-slice.sh [commit]
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="Mohamed-Elshesheny/sigstop"
STEP="The Intel slice runs too"
SHA="$(git rev-parse "${1:-HEAD}")"
BUNDLE="${BUNDLE:-dist/sigstop.app}"

if arch -x86_64 /usr/bin/true 2>/dev/null; then
  if ! OUT="$(BUNDLE="${BUNDLE}" REQUIRE_X86=1 ./Scripts/smoke.sh 2>&1)"; then
    printf '%s\n' "${OUT}" >&2
    exit 1
  fi
  echo "x86_64 slice run on this Mac, under Rosetta"
  exit 0
fi

RUN="$(gh run list -R "${REPO}" --workflow ci.yml --commit "${SHA}" \
  --json databaseId,conclusion -q '[.[] | select(.conclusion == "success")][0].databaseId // empty')"
if [ -z "${RUN}" ]; then
  echo "error: no Rosetta on this Mac, and CI has not passed on ${SHA:0:7}." >&2
  echo "       Push it, wait for CI to go green, then release." >&2
  exit 1
fi

RESULT="$(gh run view "${RUN}" -R "${REPO}" --json jobs \
  -q "[.jobs[].steps[] | select(.name == \"${STEP}\") | .conclusion][0] // empty")"
if [ "${RESULT}" != "success" ]; then
  echo "error: CI run ${RUN} passed on ${SHA:0:7} but did not run the Intel slice (step: ${RESULT:-missing})." >&2
  exit 1
fi
echo "x86_64 slice run by CI, run ${RUN} on ${SHA:0:7}"
