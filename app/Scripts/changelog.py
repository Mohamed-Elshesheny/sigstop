#!/usr/bin/env python3
"""What changed since the last tag, grouped, from the commit log.

The release notes used to be the install instructions and nothing else, on every release,
so the one question a reader actually has — what is different — was the one thing the page
did not answer. CLAUDE.md §8 makes every commit a Conventional Commit, which means the
answer is already in the log and does not need a hand-written file that drifts.

Merges and the appcast commit are dropped: the first is noise and the second is the release
publishing itself, which nobody downloads a build to read about.
"""
import re
import subprocess
import sys
from collections import OrderedDict, defaultdict

HEADINGS = OrderedDict([
    ("feat", "Added"),
    ("fix", "Fixed"),
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

    buckets: dict[str, list[tuple[str, str, bool]]] = defaultdict(list)
    breaking: list[str] = []
    for line in commits(previous, head):
        m = SUBJECT.match(line)
        if not m:
            continue
        kind, scope, subject = m.group("type"), m.group("scope"), m.group("subject")
        if kind == "build" and subject.startswith("publish the appcast"):
            continue
        if m.group("breaking"):
            breaking.append(subject)
        buckets[kind].append((scope or "", subject, bool(m.group("breaking"))))

    if not any(buckets.values()):
        return 0

    parts: list[str] = []
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

    quiet_total = sum(len(buckets.get(k) or []) for k in QUIET)
    if quiet_total:
        bits = [f"{len(buckets[k])} {HEADINGS[k].lower()}" for k in QUIET if buckets.get(k)]
        parts.append(f"Plus {', '.join(bits)}.\n")

    print("\n".join(parts).rstrip())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
