---
description: Run the done-gate — compute what the current diff owes, run those checks, and report a verdict.
---

!`apex gate --message "$ARGUMENTS"`

A `NOT DONE` verdict is not advisory. Fix every unmet obligation, then run this again.

A guard failure is a real drift, not a flaky test: add the missing resolver, view, or branch, regenerate the manifest, or register a reason-stringed exception in the documented allowlist.

Watchlist hits are BOUND-006 prompts — verify the work underneath is sound, or say plainly what is incomplete and why.
