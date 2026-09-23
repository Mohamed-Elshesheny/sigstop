#!/usr/bin/env bash
#
# Cut a release: build, tag, publish, upload.
#
# The name is not generated. The reference this was modelled on, boring.notch, looks like
# it has a bot inventing "Flying Rabbit 🐇🪽"; read its workflow and the title comes from
# a pull request a person wrote. That is the right split and it is the one here: a human
# chooses the name, and everything after it is a script so no step gets skipped at two in
# the morning.
#
#   make release VERSION=0.2.0 NAME="Wood Frog 🐸"
#
# The naming convention is in docs/RELEASING.md. Animals that suspend completely and
# resume with nothing lost, because that is the entire product in one image, and the
# codename stays the same across every patch of a minor version the way theirs does.

set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?set VERSION, for example VERSION=0.2.0}"
: "${NAME:?set NAME, for example NAME=\"Wood Frog 🐸\"}"

REPO="Mohamed-Elshesheny/sigstop"
TAG="v${VERSION}"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
PLIST_NAME="$(/usr/libexec/PlistBuddy -c 'Print SGReleaseName' Resources/Info.plist 2>/dev/null || true)"

# The subject of the commit that carries the signed feed. The checks below look for it.
FEED_SUBJECT="build: publish the appcast for"

# The one command that takes a single commit out of main and keeps everything around it.
drop_cmd() {
  if [ "$(git rev-parse HEAD)" = "$1" ]; then
    echo "git reset --keep $(git rev-parse "$1^")"
  else
    echo "git rebase --onto $1^ $1"
  fi
}

quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# What is checked out, for the messages that say it moved off main.
on_main() { [ "$(git symbolic-ref -q HEAD || true)" = refs/heads/main ]; }
branch_name() { git symbolic-ref -q --short HEAD || echo HEAD; }
head_is() {
  if git symbolic-ref -q HEAD >/dev/null; then echo "$(branch_name) is checked out"; else echo "HEAD is detached"; fi
}

# A feed commit that never reached origin is what a release leaves behind when it stops after
# signing. Pushing it is the obvious next move and the wrong one when its release does not exist:
# every installed copy would be offered a download that 404s.
unpushed_feed() {
  git log --format='%H %s' --grep="^${FEED_SUBJECT} " origin/main..HEAD 2>/dev/null || true
}
warn_unpushed_feed() {
  local left sha subject
  left="$(unpushed_feed)"
  [ -n "${left}" ] || return 0
  while read -r sha subject; do
    echo "       main holds ${sha}, \"${subject}\", which never reached origin." >&2
    echo "       See whether its release exists: gh release view ${subject##* } -R ${REPO}" >&2
    echo "       If it does, with both images, push main: that is the last step of that release." >&2
    echo "       If it does not, do NOT push main. Drop the commit: $(drop_cmd "${sha}")" >&2
  done <<<"${left}"
}

if [ "${PLIST_VERSION}" != "${VERSION}" ]; then
  echo "error: Info.plist says ${PLIST_VERSION}, you asked for ${VERSION}." >&2
  echo "       Bump CFBundleShortVersionString first so the app and the tag agree." >&2
  exit 1
fi

if [ "${PLIST_NAME}" != "${NAME}" ]; then
  echo "error: Info.plist says \"${PLIST_NAME}\", you asked for \"${NAME}\"." >&2
  echo "       The app shows the codename in About, so the two have to agree." >&2
  exit 1
fi

# Fetched first, so a tag that exists only on origin counts as existing.
git fetch -q origin

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  echo "error: ${TAG} already exists." >&2
  if [ -n "$(unpushed_feed)" ]; then
    warn_unpushed_feed
    echo "       To cut ${TAG} again once the commit is gone, delete the tag here, and on origin" >&2
    echo "       if it got there: git tag -d ${TAG}, then git push origin :refs/tags/${TAG}" >&2
  fi
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is dirty. A release has to be a commit somebody can check out." >&2
  exit 1
fi

# What gets signed has to be what everybody else can see: pushed, on main, and green in CI.
RELEASED_SHA="$(git rev-parse HEAD)"
if [ "$(git rev-parse --abbrev-ref HEAD)" != "main" ] || [ "${RELEASED_SHA}" != "$(git rev-parse origin/main)" ]; then
  if [ -n "$(unpushed_feed)" ]; then
    echo "error: HEAD is not origin/main, because a release stopped after signing its feed." >&2
    warn_unpushed_feed
  else
    echo "error: HEAD is not origin/main. Push main and let CI finish, then release from it." >&2
  fi
  exit 1
fi

LOGS="$(mktemp -d)"
# The run's status as well as its conclusion: a run still going has no conclusion yet, and that
# used to read as "not run". gh's own error is shown, not swallowed into the same words.
if ! CI_RUN="$(gh run list -R "${REPO}" --commit "${RELEASED_SHA}" --workflow CI --json status,conclusion \
    --jq '.[0] | if . == null then "none" else "\(.status) \(.conclusion)" end' 2>"${LOGS}/gh-run.err")"; then
  echo "error: gh could not say how CI went on ${RELEASED_SHA}:" >&2
  sed 's/^/       /' "${LOGS}/gh-run.err" >&2
  exit 1
fi
case "${CI_RUN}" in
  "completed success") ;;
  none|"")
    echo "error: CI has no run for ${RELEASED_SHA} yet. Let it run and pass, then release." >&2
    exit 1 ;;
  completed\ *)
    echo "error: CI on ${RELEASED_SHA} finished '${CI_RUN#completed }', not success." >&2
    exit 1 ;;
  *)
    echo "error: CI on ${RELEASED_SHA} is still running (${CI_RUN%% *}). Let it finish, then release." >&2
    exit 1 ;;
esac

# Publishing has to be possible before anything is built. `gh run list` only reads, so an account
# that could not publish got past the check above, built, signed the feed, pushed the tag, and only
# then failed at `gh release create`. This is the permission GitHub reports for the account gh is
# signed in as, and a dry run of the tag push, which reaches the remote and sends nothing.
if ! CAN_PUSH="$(gh api "repos/${REPO}" --jq '.permissions.push' 2>"${LOGS}/gh-api.err")"; then
  echo "error: gh could not read ${REPO}, so it could not publish to it either:" >&2
  sed 's/^/       /' "${LOGS}/gh-api.err" >&2
  exit 1
fi
if [ "${CAN_PUSH}" != "true" ]; then
  echo "error: gh is signed in as an account that cannot push to ${REPO}, so" >&2
  echo "       'gh release create' would fail after the feed was signed. 'gh auth status' says which." >&2
  exit 1
fi
if ! git push -q --dry-run origin "${RELEASED_SHA}:refs/tags/${TAG}" 2>"${LOGS}/git-push.err"; then
  echo "error: git cannot push ${TAG} to origin, so the release would stop after signing:" >&2
  sed 's/^/       /' "${LOGS}/git-push.err" >&2
  exit 1
fi

# Sparkle orders updates by CFBundleVersion, not by the version people read. An unbumped build
# number would tell every installed copy it is already up to date.
LAST_TAG="$(git describe --tags --abbrev=0 HEAD 2>/dev/null || true)"
PREVIOUS_BUILD=0
if [ -n "${LAST_TAG}" ]; then
  PREVIOUS_BUILD="$(git show "${LAST_TAG}:app/Resources/Info.plist" 2>/dev/null \
    | plutil -extract CFBundleVersion raw - 2>/dev/null || echo 0)"
fi
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Resources/Info.plist)"
# `[ -le ]` compares integers only. Handed "9.1" it printed an error, the `if` read that as false,
# and the release went ahead unchecked.
is_integer() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
if ! is_integer "${BUILD}" || ! is_integer "${PREVIOUS_BUILD}"; then
  echo "error: CFBundleVersion has to be a plain integer. It is '${BUILD}' now, and was" >&2
  echo "       '${PREVIOUS_BUILD}' at ${LAST_TAG:-the last release}." >&2
  exit 1
fi
if [ "${BUILD}" -le "${PREVIOUS_BUILD}" ]; then
  echo "error: CFBundleVersion is ${BUILD}, the last release was ${PREVIOUS_BUILD}. Bump it." >&2
  exit 1
fi

# An update is installed only if it matches what the installed copy trusts. A self-signed
# identity would make every later build signed with it inherit the users' Accessibility grants.
case "${SIGN_IDENTITY:--}" in
  -|"Developer ID Application"*) ;;
  *) echo "error: SIGN_IDENTITY is '${SIGN_IDENTITY}'. Release ad-hoc, or with a Developer ID." >&2; exit 1 ;;
esac
export SIGN_IDENTITY="${SIGN_IDENTITY:--}"

PREVIOUS_TAG="$(git describe --tags --abbrev=0 HEAD 2>/dev/null || true)"
NOTES="$(python3 Scripts/changelog.py "${PREVIOUS_TAG}" HEAD "${TAG} ${NAME}")"
STRAY="$(grep -vE '^(## |### |- |$)' <<<"${NOTES}" || true)"
if [ -n "${STRAY}" ]; then
  echo "error: the release notes may only hold headings and bullets. Found:" >&2
  sed 's/^/       /' <<<"${STRAY}" >&2
  exit 1
fi
# No em dash in anything a user reads, and the notes are read. Nothing earlier than this checks a
# subject for one, and by now every subject is on origin/main and cannot be reworded.
DASHED="$(grep -F "$(printf '\342\200\224')" <<<"${NOTES}" || true)"
if [ -n "${DASHED}" ]; then
  echo "error: the release notes carry an em dash, and nothing a user reads may:" >&2
  sed 's/^/       /' <<<"${DASHED}" >&2
  echo "       A bullet is a commit subject, and a pushed one cannot be reworded. Scripts/changelog.py" >&2
  echo "       writes the notes, so that is where one is changed." >&2
  exit 1
fi
if ! grep -q '^- ' <<<"${NOTES}"; then
  echo "error: nothing that ships changed since ${PREVIOUS_TAG}, so there is nothing to release." >&2
  exit 1
fi

# Kept on disk so that a release which stops after signing can be finished by hand with the
# same notes.
NOTES_FILE="${LOGS}/notes.md"
printf '%s\n' "${NOTES}" > "${NOTES_FILE}"
quiet() {
  local log="${LOGS}/$(printf '%s' "$*" | tr -c 'A-Za-z0-9' '_' | cut -c1-60).log"
  if ! "$@" >"${log}" 2>&1; then
    echo "error: '$*' failed. The last 40 lines:" >&2
    tail -40 "${log}" >&2
    echo "       Full log: ${log}" >&2
    exit 1
  fi
  rm -f "${log}"
}

echo "==> proving the claims before publishing them"
quiet make test
quiet make verify-shipped
# The artifact, not the code. Everything above this line passed for every release that
# shipped broken, because all of it runs on the machine that built the thing.
quiet env BUNDLE=dist/sigstop.app ./Scripts/smoke.sh
X86_BY="$(BUNDLE=dist/sigstop.app ./Scripts/intel-slice.sh)"
quiet swift run -c release Scenarios
echo "    tests, verify, smoke and scenarios all pass"
echo "    ${X86_BY}"

SIGNATURE="$(codesign -dv dist/sigstop.app 2>&1 | sed -n 's/^Signature=//p')"
if [ "${SIGN_IDENTITY}" = "-" ] && [ "${SIGNATURE}" != "adhoc" ]; then
  echo "error: the tested bundle is signed '${SIGNATURE}', not ad-hoc." >&2
  exit 1
fi

echo "==> packing the bundle just tested into the image"
quiet env STRICT_LAYOUT=1 ./Scripts/dmg.sh
SHA="$(shasum -a 256 dist/sigstop.dmg | cut -d' ' -f1)"

# The step 0.1.0 shipped without. Doing it before the tag means a release that cannot be
# signed fails here, with nothing published, rather than after the announcement.
# Checked before anything is signed: a signature cannot be withdrawn, and a feed commit left
# behind by a failed run would publish an update whose download does not exist yet.
if ! on_main; then
  echo "error: HEAD left main while the release was building: $(head_is) now." >&2
  echo "       Nothing was signed or tagged." >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "${RELEASED_SHA}" ]; then
  echo "error: the tree changed while the release was building. Nothing was signed or tagged." >&2
  exit 1
fi

echo "==> signing the update feed"
SIGSTOP_RELEASING="${RELEASED_SHA}" ./Scripts/appcast.sh >/dev/null
# The feed and nothing else: with the path named, a change somebody staged meanwhile stays staged
# instead of riding along in this commit and being thrown away with it.
FEED_SHA=""
if [ -n "$(cd .. && git status --porcelain updater/)" ]; then
  (cd .. && git add updater/appcast.xml && git commit -q -m "${FEED_SUBJECT} v${VERSION}" -- updater/appcast.xml)
  FEED_SHA="$(git rev-parse HEAD)"
  echo "    committed updater/appcast.xml"
fi

# appcast.sh signed exactly one versioned image, and these are the files the feed names.
shopt -s nullglob
ASSETS=(dist/sigstop.dmg dist/sigstop-"${VERSION}"*.dmg)
shopt -u nullglob
FEED_URL="$(sed -n '/url="[^"]*\.dmg"/{s/.*url="\([^"]*\.dmg\)".*/\1/p;q;}' ../updater/appcast.xml)"

# Takes the feed commit back off and nothing with it. `git reset --keep` does that too, but it resets
# the whole index, so a change somebody staged meanwhile came back unstaged. This puts the feed file
# alone back, in the index and the tree, then moves HEAD back one, and like --keep it refuses when
# the feed file holds changes the commit does not.
undo_feed() {
  [ "$(git rev-parse HEAD)" = "${FEED_SHA}" ] || return 1
  git diff --quiet "${FEED_SHA}" -- ':(top)updater/appcast.xml' || return 1
  git diff --cached --quiet "${FEED_SHA}" -- ':(top)updater/appcast.xml' || return 1
  git restore -q --source="${FEED_SHA}^" --staged --worktree -- ':(top)updater/appcast.xml' || return 1
  git reset -q --soft "${FEED_SHA}^"
}

# Nothing may have changed while the feed was signed but the feed commit this script made, and that
# commit has to be HEAD of main, directly on the released commit. Comparing files is not enough: a
# branch switch, an amend or an empty commit changes none, and each leaves the feed where the
# printed `git push` does not publish it, or publishes more than the release with it.
if [ -n "${FEED_SHA}" ]; then UNDER_FEED="$(git rev-parse "${FEED_SHA}^")"; else UNDER_FEED="${RELEASED_SHA}"; fi
MOVED=""
if ! on_main; then
  MOVED="HEAD left main while the feed was being signed: $(head_is) now."
elif [ "$(git rev-parse HEAD)" != "${FEED_SHA:-${RELEASED_SHA}}" ] || [ "${UNDER_FEED}" != "${RELEASED_SHA}" ]; then
  MOVED="main moved while the feed was being signed."
elif [ -n "$(git status --porcelain)" ] || [ -n "$(git diff --name-only "${RELEASED_SHA}" HEAD -- ':(top)' ':(top,exclude)updater/appcast.xml')" ]; then
  MOVED="the tree changed while the feed was being signed."
fi
if [ -n "${MOVED}" ]; then
  echo "error: ${MOVED} Nothing was tagged." >&2
  if on_main && ! git merge-base --is-ancestor "${RELEASED_SHA}" HEAD; then
    echo "       main no longer holds ${RELEASED_SHA}, the commit this release built." >&2
  fi
  # Only the feed commit is this script's to undo. A commit somebody made meanwhile is theirs,
  # and resetting main to the released commit would take it with the feed.
  OTHERS="$(git log --format='%H %s' "${RELEASED_SHA}..HEAD" | grep -v "^${FEED_SHA:-none} " || true)"
  if [ -z "${FEED_SHA}" ]; then
    echo "       There was no feed commit to undo." >&2
  elif [ -n "${OTHERS}" ]; then
    echo "       $(branch_name) also holds commits this release did not make, so it was left as it is:" >&2
    sed -n '1,20s/^/         /p' <<<"${OTHERS}" >&2
    echo "       Before pushing, drop only the feed commit ${FEED_SHA}, which names a" >&2
    echo "       download that does not exist: $(drop_cmd "${FEED_SHA}")" >&2
  elif undo_feed; then
    echo "       The feed commit was undone. Do not push main until a release succeeds." >&2
  else
    echo "       Before pushing, drop the feed commit ${FEED_SHA} by hand, it names a" >&2
    echo "       download that does not exist: $(drop_cmd "${FEED_SHA}")" >&2
  fi
  exit 1
fi

# From here on a failure leaves the signed feed committed on main with no release behind it, and
# the obvious next move, pushing main, would offer every installed copy a download that does not
# exist. So whatever stops the script says where it stopped and prints both ways out.
REACHED=""
stopped_after_signing() {
  [ "${REACHED}" = "released" ] && return 0
  {
    echo
    echo "error: ${TAG} stopped after its feed was signed, before GitHub had the release."
    if [ -n "${FEED_SHA}" ]; then
      echo "       The feed commit ${FEED_SHA} on main points every installed"
      echo "       copy at ${FEED_URL:-the new image},"
      echo "       which does not exist yet. Do NOT push main."
    fi
    if [ "${REACHED}" = "pushed" ]; then
      echo "       See what GitHub has first: gh release view ${TAG} -R ${REPO}"
      echo "       A draft left by a failed upload goes with: gh release delete ${TAG} -R ${REPO} --yes"
    fi
    echo
    echo "       To finish it, from $(pwd):"
    [ -n "${REACHED}" ] || echo "         git tag -a ${TAG} -m $(quote "${TAG} ${NAME}") ${RELEASED_SHA}"
    [ "${REACHED}" = "pushed" ] || echo "         git push origin ${TAG}"
    echo "         gh release create ${TAG} ${ASSETS[*]} -R ${REPO} --title $(quote "${TAG} ${NAME}") --notes-file $(quote "${NOTES_FILE}")"
    echo "         git push"
    echo
    echo "       To abandon it instead:"
    [ -z "${FEED_SHA}" ] || echo "         $(drop_cmd "${FEED_SHA}")"
    [ -z "${REACHED}" ] || echo "         git tag -d ${TAG}"
    [ "${REACHED}" != "pushed" ] || echo "         git push origin :refs/tags/${TAG}"
  } >&2
}
trap stopped_after_signing EXIT

echo "==> tagging ${TAG}"
git tag -a "${TAG}" -m "${TAG} ${NAME}" "${RELEASED_SHA}"
REACHED="tagged"
git push -q origin "${TAG}"
REACHED="pushed"

echo "==> publishing"
gh release create "${TAG}" "${ASSETS[@]}" \
  -R "${REPO}" \
  --title "${TAG} ${NAME}" \
  --notes-file "${NOTES_FILE}"
REACHED="released"

echo
echo "released ${TAG} ${NAME}"
echo "  sha256: ${SHA}"
echo "  https://github.com/${REPO}/releases/tag/${TAG}"
echo
echo "  The site links to the asset by name, so nothing there needs changing."
echo
# A 200 from the feed URL proves nothing: the last release's feed is already there and answers
# 200 before the push, and still does if the deploy fails. The version in it is the check.
echo "  Push main, which is what publishes the feed, then wait for its Pages deploy to finish:"
echo "    git push"
echo "    gh run watch --exit-status -R ${REPO} \\"
echo "      \"\$(gh run list -R ${REPO} --workflow Pages --commit \"\$(git rev-parse HEAD)\" --json databaseId --jq '.[0].databaseId')\""
echo "  Then the feed it serves has to be this release, not the last one. This has to end in ${VERSION}:"
echo "    curl -s https://mohamed-elshesheny.github.io/sigstop/appcast.xml | grep -o '<sparkle:shortVersionString>[^<]*'"
echo "  docs/RELEASING.md 3.5 has the rest of the check."
