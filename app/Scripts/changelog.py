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
SHIPS = re.compile(
    r"^app/(Sources/(?!Scenarios/)|Resources/(Info\.plist|sigstop\.icns|sigstop\.entitlements)$"
    r"|Package\.swift$|Scripts/(bundle|dmg)\.sh$)"
)
UI = re.compile(r"^app/(Sources/SigstopApp/Views/|Scripts/dmg\.sh$)")

# The one change a subject gets on its way into the notes. Nothing a user reads carries an em dash,
# and release.sh refuses notes that do, but a subject is already on origin/main by then and cannot
# be reworded, so a refusal alone would block the release with no way on. With or without spaces
# around it, an em dash becomes a comma and a space; one at either end is dropped.
EM_DASH = "\u2014"
AROUND_EM_DASH = re.compile("[\\s,]*\u2014[\\s,\u2014]*")


def without_em_dash(subject):
    if EM_DASH not in subject:
        return subject
    return AROUND_EM_DASH.sub(", ", subject).strip(", ")


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=True).stdout


def commits(previous, head):
    span = f"{previous}..{head}" if previous else head
    out = git("log", "--no-merges", "--reverse", "--pretty=format:%H\t%s", span)
    for line in out.splitlines():
        if "\t" in line:
            yield line.split("\t", 1)


def shipped_files(sha):
    files = git("show", "--name-only", "--pretty=format:", sha).split()
    return [f for f in files if SHIPS.match(f)]


def section_for(kind, scope, breaking, files, first):
    if first:
        return "feat" if kind == "feat" else None
    if breaking:
        return "breaking"
    if kind not in {"feat", "fix", "perf"}:
        return None
    if scope == "ui" or all(UI.match(f) for f in files):
        return "ui"
    return kind


def main():
    previous = sys.argv[1] if len(sys.argv) > 1 else ""
    head = sys.argv[2] if len(sys.argv) > 2 else "HEAD"
    title = sys.argv[3] if len(sys.argv) > 3 else ""

    rows = {key: [] for key, _ in SECTIONS}
    for sha, line in commits(previous, head):
        m = SUBJECT.match(line)
        if not m:
            continue
        files = shipped_files(sha)
        if not files:
            continue
        key = section_for(m.group("type"), m.group("scope"), bool(m.group("breaking")), files, not previous)
        if key:
            subject = without_em_dash(m.group("subject"))
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
