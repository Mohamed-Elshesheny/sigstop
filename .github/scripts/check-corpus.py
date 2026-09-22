#!/usr/bin/env python3
"""The corpus lint that docs/MESSAGE-ENGINE.md said existed.

It did not. Section 4.4 described a `swift package corpus-lint` plugin, twelve hard
checks, four warnings and a `Lint/banned-lexicon.json`, run on every pull request
touching `docs/corpus-*.json` or `Resources/packs/**`. There was no plugin, no lexicon,
no schema, no packs directory and no CI step, and the corpus lives at neither of those
paths. The humour rails named that section as the thing enforcing them, so the project's
stated safety net for the one part of it that can hurt somebody was a paragraph.

This is the real one, against the corpus that actually ships. It is smaller than the
paragraph: the checks that assume a field the corpus does not have are not here, and
MESSAGE-ENGINE.md now says which those are instead of implying they run.

Hard failures exit 1. Warnings print and do not, because each has a false-positive mode
that a person has to judge.
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
# A path can be passed in so the checks can be tested against a deliberately broken
# copy. A lint nobody has seen fail is a lint nobody should trust.
CORPUS = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "app/Sources/SigstopCore/Message/corpus.json"
LEXICON = ROOT / ".github/lint/banned-lexicon.json"

ID = re.compile(r"^[a-z0-9]+(\.[a-z0-9-]+){2,}$")
SLOT = re.compile(r"\{([a-zA-Z][a-zA-Z0-9]*)\}")
TRAIT = re.compile(r"\byou(?:'re| are)\s+(?:a|an|so|such|just)\b", re.I)
SHOUT = re.compile(r"\b[A-Z]{2,}\b(?:\s+\b[A-Z]{2,}\b)+")
STOP = {"the","a","an","you","your","and","is","are","it","that","this","to","of",
        "for","in","on","have","has","been","not","one","be","at","with","was"}

fails: list[str] = []
warns: list[str] = []


def text_of(m: dict) -> str:
    return " ".join(str(m.get(k, "")) for k in ("text", "altText") if m.get(k))


def main() -> int:
    corpus = json.loads(CORPUS.read_text())
    messages = corpus["messages"]
    lexicon = json.loads(LEXICON.read_text())

    # L2  ids are unique and shaped like ids
    seen: dict[str, int] = {}
    for i, m in enumerate(messages):
        mid = m.get("id", "")
        if mid in seen:
            fails.append(f"L2 duplicate id: {mid}")
        seen[mid] = i
        if not ID.match(mid):
            fails.append(f"L2 id does not match ^[a-z0-9]+(\\.[a-z0-9-]+){{2,}}$: {mid!r}")

    for m in messages:
        mid = m.get("id", "<no id>")
        body = text_of(m)

        # L3  every slot used is declared, every slot declared is used
        used = set(SLOT.findall(body))
        declared = set(m.get("requiredSlots", [])) | set(m.get("optionalSlots", []))
        for s in sorted(used - declared):
            fails.append(f"L3 {mid}: {{{s}}} is used and not declared")
        for s in sorted(declared - used):
            fails.append(f"L3 {mid}: {s!r} is declared and never used")

        # L4  escalation is a range inside the four rungs
        esc = m.get("escalation", {})
        lo, hi = esc.get("min"), esc.get("max")
        if not (isinstance(lo, int) and isinstance(hi, int)):
            fails.append(f"L4 {mid}: escalation.min/max must both be integers")
        else:
            if not (1 <= lo <= 4 and 1 <= hi <= 4):
                fails.append(f"L4 {mid}: escalation {lo}..{hi} outside 1...4")
            if lo > hi:
                fails.append(f"L4 {mid}: escalation.min {lo} > max {hi}")

        # L5  tone and escalation have to agree
        tone = m.get("tone")
        if tone == "nuclear" and isinstance(lo, int) and lo < 3:
            fails.append(f"L5 {mid}: nuclear at escalation {lo}, needs min >= 3")
        if tone == "friendly" and hi == 4 and not m.get("isFallback"):
            fails.append(f"L5 {mid}: friendly reaches rung 4 without isFallback")

        # L6  a line that names the activity has to be confident about it
        conf = m.get("minConfidence")
        if not isinstance(conf, (int, float)) or not (0 <= conf <= 1):
            fails.append(f"L6 {mid}: minConfidence {conf!r} outside 0...1")
        elif m.get("claimsActivity"):
            if conf < 0.75:
                fails.append(f"L6 {mid}: claimsActivity with minConfidence {conf} < 0.75")
            preds = {w.get("p") for w in m.get("when", [])}
            if not ({"app", "activity"} & preds):
                fails.append(f"L6 {mid}: claimsActivity with no app or activity predicate")

        # L7  the banned lexicon, which is the rail that can actually hurt somebody
        for fam in lexicon["families"]:
            for pat in fam["patterns"]:
                hit = re.search(pat, body, re.I)
                if hit:
                    fails.append(
                        f"L7 {mid}: {hit.group(0)!r} is in the {fam['family']} family\n"
                        f"       {fam['rationale']}"
                    )

        # L9  length
        if len(m.get("text", "")) > 240:
            fails.append(f"L9 {mid}: text is {len(m['text'])} chars, limit 240")

        # W1  a label attached to the person rather than to the behaviour
        hit = TRAIT.search(body)
        if hit:
            warns.append(f"W1 {mid}: {hit.group(0)!r} usually attaches a label to the person")

        # W2  a nuclear line with no impossibility in it is just mean.
        #
        # MESSAGE-ENGINE.md offered `"theatrical": true` as an alternative "with a named
        # reviewer". There is no reviewer field in the format, so that clause was a free
        # opt-out: all eleven nuclear lines set the flag, and the check could not fire on
        # anything. It is the shouted run or nothing. All eleven pass on merit.
        if tone == "nuclear" and not SHOUT.search(body):
            warns.append(f"W2 {mid}: nuclear with no shouted run, so it may just be mean")

    # W3  near-duplicates
    toks = {m["id"]: {w for w in re.findall(r"[a-z']+", text_of(m).lower()) if w not in STOP}
            for m in messages}
    ids = list(toks)
    for i, a in enumerate(ids):
        for b in ids[i + 1:]:
            ta, tb = toks[a], toks[b]
            if not ta or not tb:
                continue
            j = len(ta & tb) / len(ta | tb)
            if j >= 0.6:
                warns.append(f"W3 {a} and {b} overlap {j:.0%}")

    for w in warns:
        print(f"::warning::{w}")
    if fails:
        print(f"::error::corpus lint: {len(fails)} hard failure(s)")
        for f in fails:
            print(f"  {f}")
        return 1
    print(f"corpus lint: {len(messages)} messages, {len(warns)} warning(s), no hard failures")
    return 0


if __name__ == "__main__":
    sys.exit(main())
