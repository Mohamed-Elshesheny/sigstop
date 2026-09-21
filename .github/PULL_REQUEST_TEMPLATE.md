<!--
Short on purpose. CONTRIBUTING.md has the long version; this is the part a reviewer
needs in front of them.
-->

## What changes, and why

<!-- The why is the part the diff cannot say. One paragraph. -->

## How you know it works

<!-- The command you ran and what it printed. "Tests pass" is not that. -->

## Checklist

- [ ] One concern. A change that spans several is several pull requests.
- [ ] `make test`, `make verify` and `swift run -c release Scenarios` all pass locally.
- [ ] `docs/` updated in this PR if behaviour changed. Design docs are normative.
- [ ] No invariant in `CLAUDE.md` §4 is weakened. If one has to change, that is its own
      PR with the argument written out, landing before the code.
- [ ] Commit messages are Conventional Commits, imperative, and short.
