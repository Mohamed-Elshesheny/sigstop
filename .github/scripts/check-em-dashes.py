#!/usr/bin/env python3
"""Fail if an em dash reaches a user.

The repo-wide rule is about strings a person reads, not about the source. A doc comment
explaining a decision may contain one; a `Text("...")`, a settings detail or a line in the
message corpus may not. Grepping the whole tree conflates the two and cries wolf, which is
how a real hit gets waved through.
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
# The em dash only. An en dash between two times is a range and is correct, and the
# window-title separator list is parser input rather than prose: an earlier version of
# this flagged both and neither was a bug.
DASH = "—"
failures: list[str] = []

corpus = ROOT / "app/Sources/SigstopCore/Message/corpus.json"
for message in json.loads(corpus.read_text())["messages"]:
    for field in ("text", "title", "altText"):
        value = message.get(field)
        if value and DASH in value:
            failures.append(f"{corpus.relative_to(ROOT)}: {message['id']} ({field})")

STRING = re.compile(r'"([^"\\]*(?:\\.[^"\\]*)*)"')

# The one escape hatch, keyed to the declaration by name rather than to a comment, because
# the source no longer carries comments to key it to. It is for a literal the app MATCHES
# AGAINST: `separators` has to contain the exact character VS Code puts in its window title,
# and a rule about prose has no business reaching it.
ALLOWED_NAMES = ("separators",)

for path in sorted((ROOT / "app/Sources").rglob("*.swift")):
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if line.lstrip().startswith("//"):
            continue
        if any(name in line for name in ALLOWED_NAMES) and ("let " in line or "var " in line):
            continue
        for literal in STRING.findall(line):
            if DASH in literal:
                failures.append(f"{path.relative_to(ROOT)}:{number}")
                break

if failures:
    print("::error::em dash in a user-visible string, see CLAUDE.md")
    for f in failures:
        print(f"  {f}")
    sys.exit(1)

print("no em dashes in any user-visible string")
