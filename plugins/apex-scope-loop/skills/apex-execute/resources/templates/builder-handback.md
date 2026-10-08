# Builder handback — {{TASK_ID}} @ {{HEAD_SHA}}

> Fill this in before you hand the task back (ADR-0004, addendum F). The orchestrator passes it to
> the reviewers with the brief's `THREATS:` list. One row per threat item; no row may be blank.

## Threat → failing-first test → mutant

| # | Threat (from the brief's `THREATS:`) | Failing-first test (file::name) — real files / real gate / real seal, not a fake | Mutant that turns it red (the one-line change to the code under test) | Red before the fix? |
|---|---|---|---|---|
| 1 | {{threat 1}} | {{tests/...::test_...}} | {{e.g. drop the fsync; skip the check at path:line}} | yes / no |
| 2 | {{threat 2}} | | | |

## Tests that use real files rather than fakes

- {{tests/...::test_...}} — {{what is real: a real worktree / the real green gate / the real seal}}

## One line per threat item

1. {{threat 1}}: {{covered by test X; mutant Y turns it red}} | {{not covered: why, and the backlog id}}
2. {{threat 2}}: ...

## Working agreement

- If a hook or filter rejects text, stop and report the exact message. Never obfuscate around it.
- A task that hand-parses a language names its fallback in Acceptance (drop the feature) and uses it
  rather than growing the parser round by round.
- Anything you could not cover is listed above with its reason; it is never left implicit.
