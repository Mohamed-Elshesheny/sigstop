#!/usr/bin/env python3
"""What changed since the last tag, grouped, from the commit log.

The release notes used to be the install instructions and nothing else, on every release,
so the one question a reader actually has — what is different — was the one thing the page
did not answer. CLAUDE.md §8 makes every commit a Conventional Commit, which means the
answer is already in the log and does not need a hand-written file that drifts.

Merges and the appcast commit are dropped: the first is noise and the second is the release
publishing itself, which nobody downloads a build to read about.
"""
import pathlib
import re
import subprocess
import sys
from collections import OrderedDict, defaultdict

HEADINGS = OrderedDict([
    ("feat", "New"),
    ("fix", "Fixes"),
    ("perf", "Faster"),
    ("refactor", "Changed"),
    ("docs", "Documentation"),
    ("ci", "CI"),
    ("build", "Build"),
    ("test", "Tests"),
    ("chore", "Housekeeping"),
])
# Real work for a reader, versus work on the release machinery itself.
QUIET = {"ci", "build", "test", "chore"}
SUBJECT = re.compile(r"^(?P<type>\w+)(?:\((?P<scope>[^)]*)\))?(?P<breaking>!)?: (?P<subject>.+)$")


def commits(previous: str, head: str) -> list[str]:
    span = f"{previous}..{head}" if previous else head
    out = subprocess.run(
        ["git", "log", "--no-merges", "--pretty=format:%s", span],
        capture_output=True, text=True, check=True,
    ).stdout
    return [line for line in out.splitlines() if line.strip()]


def main() -> int:
    previous = sys.argv[1] if len(sys.argv) > 1 else ""
    head = sys.argv[2] if len(sys.argv) > 2 else "HEAD"
    # The title line, when the caller knows the version and the codename.
    title = sys.argv[3] if len(sys.argv) > 3 else ""

    # Hand-written highlights, when a release has something worth saying in a sentence a
    # commit subject cannot carry. Optional: most patch releases do not need one, and an
    # empty file is the same as no file.
    highlights = ""
    notes_file = pathlib.Path("Resources/RELEASE_HIGHLIGHTS.md")
    if notes_file.exists():
        highlights = notes_file.read_text().strip()

    buckets: dict[str, list[tuple[str, str, bool]]] = defaultdict(list)
    breaking: list[str] = []
    for line in commits(previous, head):
        m = SUBJECT.match(line)
        if not m:
            continue
        kind, scope, subject = m.group("type"), m.group("scope"), m.group("subject")
        # The release's own bookkeeping. A version bump and the appcast commit are the
        # act of releasing, not something that changed in the build somebody downloads.
        if kind == "build" and (
            subject.startswith("publish the appcast") or re.match(r"^bump to [\d.]+$", subject)
        ):
            continue
        if m.group("breaking"):
            breaking.append(subject)
        buckets[kind].append((scope or "", subject, bool(m.group("breaking"))))

    if not any(buckets.values()):
        return 0

    parts: list[str] = []
    if title:
        parts.append(f"## {title}\n")
    if highlights:
        parts.append(highlights)
        parts.append("")
    if breaking:
        parts.append("### Breaking\n")
        parts += [f"- {s}" for s in breaking]
        parts.append("")

    for kind, heading in HEADINGS.items():
        rows = buckets.get(kind) or []
        if not rows:
            continue
        if kind in QUIET:
            continue
        parts.append(f"### {heading}\n")
        for scope, subject, _ in rows:
            parts.append(f"- {f'**{scope}** ' if scope else ''}{subject}")
        parts.append("")

    # Everything that did not change the app itself, counted rather than listed: somebody
    # downloading a build is not shopping for a workflow tweak, and a page that lists them
    # buries the three lines they came for.
    quiet_total = sum(len(buckets.get(k) or []) for k in QUIET)
    if quiet_total:
        noun = "commit" if quiet_total == 1 else "commits"
        kinds = ", ".join(HEADINGS[k].lower() for k in QUIET if buckets.get(k))
        parts.append(f"_And {quiet_total} more {noun} to {kinds}._\n")

    print("\n".join(parts).rstrip())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
