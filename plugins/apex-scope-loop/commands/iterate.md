---
name: iterate
description: Iterate the next phase of a promoted plan via /loop — dispatches a swarm, runs acceptance, advances the checkbox. Pass plan path as $ARGUMENTS.
argument-hint: "<path-to-plan.md>"
---

You are iterating one phase of the apex-execute for `$ARGUMENTS`.

Invoke the `apex-execute` skill and execute one iteration:

1. Read `.dev-plan-state/<plan-hash>/checkpoint.json` to find the next unchecked, unblocked task in `$ARGUMENTS`, and note the `worktree_path` / `worktree_branch`.
2. Parse the task's tags (`[backend]`, `[security]`, etc.) and `Swarm:` directive.
3. **Execution is worktree-bound.** The whole plan runs inside the worktree from the brief's `WORKTREE:` line (branch `BRANCH:`). Every agent must `cd` into that worktree and make ALL code edits there — never in the base checkout. Pass the worktree path explicitly in each Agent prompt. If `WORKTREE:` is empty, init.sh was run with `APEX_NO_WORKTREE=1`; only then operate in the base checkout.
4. Dispatch the appropriate swarm — Agent tool, all spawns in **one message**, `run_in_background: true` where applicable, each scoped to the worktree path.
5. Wait for verdicts; never poll. The harness notifies on completion.
6. Run the task's `Acceptance:` check inside the worktree (a runnable command, file-exists test, regex match, or — for `[gate:human]` — wait for the user's literal approval phrase).
7. On pass: check the box in `$ARGUMENTS`, write a one-paragraph summary to memory namespace `apex-execute`, advance.
8. On fail: store the failure pattern, surface to the user with the blocking reason, halt.
9. If the plan is complete (no unchecked tasks), the final gate has passed: write `COMPLETE`, then **land the worktree** by running `.claude/skills/apex-execute/scripts/land.sh $ARGUMENTS` — this merges `worktree_branch` into the base branch and removes the worktree. Exit, and do **not** call `ScheduleWakeup`.
10. Otherwise, use `ScheduleWakeup` with delay matched to the next task's expected wait (1200–1800s for non-urgent work; 270s when actively polling external state).

Respect the gates:
- `[gate:auto]` — run the Acceptance check, advance on pass.
- `[gate:human]` — set `halted: true` with `halt_reason: "awaiting human gate <id>"`, print "Reply 'approve <gate-id>' to continue," exit the loop.
- `[gate:partner:<email>]` — write a durable inbox item, halt with `halt_reason: "awaiting partner gate <id>"`.

Bounded reasoning: one task per iteration, one verdict gate, 30-minute timeout. Don't make this a "make progress" loop — make it a "check this box" loop.

If `$ARGUMENTS` is empty, scan `.claude/plans/*-plan.md` for the most recently-modified plan and confirm with the user before iterating.
