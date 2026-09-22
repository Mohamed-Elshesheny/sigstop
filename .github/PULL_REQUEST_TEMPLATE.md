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
- [ ] No rule in the table in
      [`CONTRIBUTING.md`](https://github.com/Mohamed-Elshesheny/sigstop/blob/main/CONTRIBUTING.md#the-rules-a-pr-cannot-break)
      is weakened. If one has to change, that is its own PR with the argument written out,
      landing before the code.
- [ ] Commit messages are Conventional Commits, imperative, and short.

## If this touches the message corpus

CI runs the structural checks. These four are the ones only a person can answer, and
`docs/MESSAGE-ENGINE.md` §4.3 is where they come from. Delete this section if it does not
apply.

- [ ] **Target.** Name what the joke is about in one word. If the answer is a person or a
      trait rather than a behaviour or a tool, it does not ship.
- [ ] **Standup.** You could say this out loud to a colleague and have them laugh.
- [ ] **Bad day.** Read as somebody having the worst week of their career, it still reads
      as being on their side.
- [ ] **Specificity.** It could not be about any app, any activity, any hour.
