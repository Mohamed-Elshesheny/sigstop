#!/usr/bin/env python3
import re
import subprocess
import sys

SECTIONS = [
    ("breaking", "⚠️ Breaking"),
    ("feat", "✨ New"),
    ("fix", "🐛 Bugs"),
    ("perf", "⚡ Perf"),
    ("ui", "🎨 UI"),
]
SUBJECT = re.compile(r"^(?P<type>\w+)(?:\((?P<scope>[^)]*)\))?(?P<breaking>!)?: (?P<subject>.+)$")


def commits(previous, head):
    span = f"{previous}..{head}" if previous else head
    out = subprocess.run(
        ["git", "log", "--no-merges", "--reverse", "--pretty=format:%s", span],
        capture_output=True, text=True, check=True,
    ).stdout
    return [line for line in out.splitlines() if line.strip()]


def section_for(kind, scope, breaking):
    if breaking:
        return "breaking"
    if scope == "ui" and kind in {"feat", "fix", "perf", "refactor"}:
        return "ui"
    if kind in {"feat", "fix", "perf"}:
        return kind
    return None


def main():
    previous = sys.argv[1] if len(sys.argv) > 1 else ""
    head = sys.argv[2] if len(sys.argv) > 2 else "HEAD"
    title = sys.argv[3] if len(sys.argv) > 3 else ""

    rows = {key: [] for key, _ in SECTIONS}
    for line in commits(previous, head):
        m = SUBJECT.match(line)
        if not m:
            continue
        key = section_for(m.group("type"), m.group("scope"), bool(m.group("breaking")))
        if key:
            subject = m.group("subject")
            rows[key].append(subject[:1].upper() + subject[1:])

    parts = [f"## {title}", ""] if title else []
    for key, heading in SECTIONS:
        if rows[key]:
            parts.append(f"### {heading}")
            parts += [f"- {s}" for s in rows[key]]
            parts.append("")
    print("\n".join(parts).rstrip())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
