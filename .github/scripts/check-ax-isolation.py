#!/usr/bin/env python3
"""Keep the Accessibility API inside the two files that are allowed to touch it.

docs/PRIVACY.md printed a script called `verify-ax-isolation.sh` in full, said it ran on
every pull request as a required check, and named the one file permitted to use AX. None
of that existed: no script, no workflow, and the file it named has never been in the tree.
A reader who followed the instructions found nothing, which is worse for the claim than
never having made it.

The claim itself turned out to be nearly true, so it is enforced here rather than deleted.
Measured: every AX symbol in the repository that is not inside a comment lives in
SigstopSensors, in exactly two files. AccessibilityCollector.swift does the reading;
PermissionBroker.swift asks whether the grant exists and nothing else.

That the reading is isolated is what lets PRIVACY.md say the window title is classified and
released in one place: a reader has one file to check rather than a tree to search.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCES = ROOT / "app/Sources"

AX = re.compile(r"\bAX[A-Za-z]\w*")

# The reader, and the file that only ever asks whether the grant exists.
READER = "SigstopSensors/Collectors/AccessibilityCollector.swift"
TRUST = "SigstopSensors/PermissionBroker.swift"

# What the trust file is allowed to name. Anything beyond this is reading, not asking.
TRUST_ONLY = {"AXIsProcessTrusted"}

# The notifications the reader subscribes to. These say WHEN to read again; they do not
# widen WHAT is read, which is why they are listed apart from the attributes below. An
# earlier version of this check conflated the two and flagged both as new attributes.
NOTIFICATIONS_ALLOWED = {
    "kAXFocusedWindowChangedNotification",
    "kAXTitleChangedNotification",
}

# The attributes the reader may ask an element for. PRIVACY.md 1.5 turns on this list:
# a title and a document path are a workflow, and the next attribute added is a decision
# rather than a detail.
ATTRIBUTES_ALLOWED = {
    "kAXFocusedWindowAttribute",
    "kAXTitleAttribute",
    "kAXDocumentAttribute",
}
ATTRIBUTE = re.compile(r"\bkAX[A-Za-z]\w*")

BLOCK = re.compile(r"/\*.*?\*/", re.S)
STRING = re.compile(r'"(?:[^"\\]|\\.)*"')
# Types this repository defines itself with an AX prefix. `AXWindowInfo` is our own struct
# carrying a title and a document path, and a file that passes one around is not a file
# that talks to Accessibility. Read from the source rather than listed, so a rename cannot
# turn this check into a liar.
# "AXValue" as CFString reads the same attribute as kAXValueAttribute, and would pass the
# allowlist unseen because the literal is stripped below. So an attribute or option named
# in a string is refused outright: write the constant, and the check can read it.
NAMED_IN_A_STRING = re.compile(r'"(AX[A-Za-z]\w*)"')

DEFINES = re.compile(r"\b(?:struct|class|enum|actor|protocol|typealias)\s+(AX\w+)")


def code_only(text: str) -> str:
    """The source with comments and string literals removed.

    Comments, because a doc comment explaining what AX is used for is not a use of it.
    String literals, because a sentence that mentions AX is not a call. The one string that
    is a call, an attribute name written out instead of its kAX constant, is caught by
    NAMED_IN_A_STRING before this runs.
    """
    text = BLOCK.sub("", text)
    text = "\n".join(
        "" if line.lstrip().startswith("//") else line.split("//")[0]
        for line in text.splitlines()
    )
    return STRING.sub('""', text)


def main() -> int:
    failures: list[str] = []
    reader_seen = trust_seen = False

    ours: set[str] = set()
    for path in SOURCES.rglob("*.swift"):
        ours.update(DEFINES.findall(path.read_text()))

    for path in sorted(SOURCES.rglob("*.swift")):
        rel = str(path.relative_to(SOURCES))
        raw = path.read_text()
        for name in sorted(set(NAMED_IN_A_STRING.findall(raw))):
            failures.append(
                f"{rel}: names {name} in a string literal.\n"
                "       Use its kAX constant, so this check can see which attribute it is."
            )
        body = code_only(raw)
        symbols = set(AX.findall(body)) - ours
        if not symbols:
            continue

        if rel == READER:
            reader_seen = True
            extra = set(ATTRIBUTE.findall(body)) - ATTRIBUTES_ALLOWED - NOTIFICATIONS_ALLOWED
            for a in sorted(extra):
                failures.append(
                    f"{rel}: reads a new attribute, {a}.\n"
                    "       Adding one widens what the app can see. Argue for it in "
                    "docs/PRIVACY.md §1.5 and add it to ATTRIBUTES_ALLOWED in the same PR."
                )
        elif rel == TRUST:
            trust_seen = True
            for s in sorted(symbols - TRUST_ONLY):
                failures.append(
                    f"{rel}: uses {s}, which is reading rather than asking whether the "
                    f"grant exists.\n       Reading belongs in {READER}."
                )
        else:
            for s in sorted(symbols):
                failures.append(
                    f"{rel}: uses {s} outside the two files allowed to.\n"
                    f"       docs/PRIVACY.md tells a suspicious reader that Accessibility "
                    f"lives in {READER}. Keep that true."
                )

    # A check that passes because the thing it guards has been renamed away is not a check.
    if not reader_seen:
        failures.append(f"{READER} has no AX code, so this check is guarding nothing. "
                        "If the reader moved, move this check with it.")
    if not trust_seen:
        failures.append(f"{TRUST} no longer asks for the grant. If that moved, move this "
                        "check with it.")

    if failures:
        print("::error::Accessibility is used outside the files PRIVACY.md names")
        for f in failures:
            print(f"  {f}")
        return 1

    print(f"accessibility isolation: AX code in {READER} and the trust check in {TRUST}, "
          f"and nowhere else. Types this repo defines itself and ignores: "
          f"{', '.join(sorted(ours)) or 'none'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
