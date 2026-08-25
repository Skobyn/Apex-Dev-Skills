---
name: apex-done-gate
description: Use before claiming any apex-app task or phase complete. Triggers - "is this done", "mark complete", "ready to commit", "finished the feature", "before I open a PR". Runs the done-gate and enforces its verdict instead of prose.
---

# Apex done-gate

Never claim a task or phase is done from feel. Run the gate first:

```bash
apex gate --message "<your completion report>"
```

## The verdict is not advisory

`NOT DONE` means the work is not done, full stop. Fix every unmet obligation
— manifest regeneration, guard suite, style generator, import guard,
whatever it names — and run the gate again. Do not report completion, open
a PR, or hand off a phase on a `NOT DONE` verdict.

## A guard failure is real drift

Treat a failing guard as a genuine boundary violation, not a flaky test.
Add the missing resolver, view, or branch; regenerate the stale manifest;
or register a reason-stringed exception in the documented allowlist. Do not
retry it hoping it passes, and do not silence it without a recorded reason.

## Watchlist hits are BOUND-006 prompts

A watchlist hit is not a pass/fail signal by itself — it is a prompt to
verify the work underneath is sound. Either confirm it and say why it's
fine, or say plainly what is incomplete and why. Silence is not a valid
response to a watchlist hit.

## Enumerate the parity surfaces

Before declaring done, enumerate every parity surface the router named for
this change and confirm each one explicitly, or state clearly why a
particular surface diverges. An unmentioned parity surface is an
unfinished one.
