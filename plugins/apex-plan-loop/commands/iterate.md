---
name: iterate
description: Iterate the next phase of a promoted plan via /loop — dispatches a swarm, runs acceptance, advances the checkbox. Pass plan path as $ARGUMENTS.
argument-hint: "<path-to-plan.md>"
---

You are iterating one phase of the dev-plan-loop for `$ARGUMENTS`.

Invoke the `dev-plan-loop` skill and execute one iteration:

1. Read `.dev-plan-state/<plan-hash>/checkpoint.json` to find the next unchecked, unblocked task in `$ARGUMENTS`.
2. Parse the task's tags (`[backend]`, `[security]`, etc.) and `Swarm:` directive.
3. Dispatch the appropriate swarm — Agent tool, all spawns in **one message**, `run_in_background: true` where applicable.
4. Wait for verdicts; never poll. The harness notifies on completion.
5. Run the task's `Acceptance:` check (a runnable command, file-exists test, regex match, or — for `[gate:human]` — wait for the user's literal approval phrase).
6. On pass: check the box in `$ARGUMENTS`, write a one-paragraph summary to memory namespace `dev-plan-loop`, advance.
7. On fail: store the failure pattern, surface to the user with the blocking reason, halt.
8. If the plan is complete (no unchecked tasks), write `COMPLETE` marker, exit, and do **not** call `ScheduleWakeup`.
9. Otherwise, use `ScheduleWakeup` with delay matched to the next task's expected wait (1200–1800s for non-urgent work; 270s when actively polling external state).

Respect the gates:
- `[gate:auto]` — run the Acceptance check, advance on pass.
- `[gate:human]` — set `halted: true` with `halt_reason: "awaiting human gate <id>"`, print "Reply 'approve <gate-id>' to continue," exit the loop.
- `[gate:partner:<email>]` — write a durable inbox item, halt with `halt_reason: "awaiting partner gate <id>"`.

Bounded reasoning: one task per iteration, one verdict gate, 30-minute timeout. Don't make this a "make progress" loop — make it a "check this box" loop.

If `$ARGUMENTS` is empty, scan `.claude/plans/*-plan.md` for the most recently-modified plan and confirm with the user before iterating.
