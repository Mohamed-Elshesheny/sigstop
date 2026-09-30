#!/usr/bin/env python3
"""Fail if the README's test-count badge disagrees with the suite.

A number on the front page of a repository whose whole pitch is "check this yourself" has
to be the number. It said 281 while the suite ran 288, which took one commit to happen and
would have taken another to happen again, so it is checked instead of remembered.

Reads the count from swift-testing's own summary line rather than counting @Test by hand,
because the run is the authority and a grep is a second implementation of it.

Usage:  make test | python3 .github/scripts/check-test-count.py
        (or pass a file:  python3 check-test-count.py run.log)
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
README = ROOT / "README.md"

log = pathlib.Path(sys.argv[1]).read_text() if len(sys.argv) > 1 else sys.stdin.read()

ran = re.search(r"Test run with (\d+) tests? (?:in \d+ suites? )?passed", log)
if not ran:
    print("::error::no 'Test run with N tests ... passed' line in the output: the run failed, "
          "or nothing was checked")
    sys.exit(1)
actual = int(ran.group(1))

# Both numbers in the badge: the alt text is what a screen reader and a broken image show,
# and it drifted to 481 while the URL said 520 because only the URL was checked.
badge = re.search(
    r"\[!\[(\d+) tests\]\(https://img\.shields\.io/badge/tests-(\d+)%20passing", README.read_text()
)
if not badge:
    print("::error::README.md has no test-count badge of the form [![N tests](...tests-N%20passing...)]")
    sys.exit(1)
alt, url = int(badge.group(1)), int(badge.group(2))

if alt != actual or url != actual:
    print(f"::error::README's badge says {alt} tests in its alt text and {url} in its URL, "
          f"the suite ran {actual}")
    print(f"  fix: [![{actual} tests](https://img.shields.io/badge/tests-{actual}%20passing-...)]")
    sys.exit(1)

print(f"README's test count matches the suite: {actual}")
