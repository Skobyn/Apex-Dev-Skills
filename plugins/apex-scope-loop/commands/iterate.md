---
name: iterate
description: Iterate the next phase of a promoted plan via /loop — dispatches a swarm, runs the green gate + independent review + acceptance, advances the checkbox. Pass plan path as $ARGUMENTS.
argument-hint: "<path-to-plan.md>"
---

You are iterating one phase of the apex-execute for `$ARGUMENTS`.

Invoke the `apex-execute` skill and execute one iteration:

In the steps below, `$S` stands for `${CLAUDE_PLUGIN_ROOT}/skills/apex-execute/scripts`, where the helper scripts ship with this plugin. Use that absolute path in every command; no repo-local `.claude/skills` copy is needed.

1. Run `$S/iterate.sh $ARGUMENTS` to get the brief. It returns the next unchecked, unblocked task along with `WORKTREE:`, `BRANCH:`, `LINE_NO:`, `HEAD_SHA:` (this task's diff base), `HARNESS:`, `LESSONS:`, and `CONSECUTIVE_FAILURES:`. If `STATUS: HALTED` comes back, report the `HALT_REASON:` and stop. Never work around a kill switch.
2. **Recall before you act.** If `LESSONS:` is non-zero, run `$S/lessons.sh $ARGUMENTS recall <tags>` and put the relevant lessons into every builder's prompt.
3. Parse the task's tags (`[backend]`, `[security]`, etc.) and its `Swarm:` directive.
4. **Execution is worktree-bound.** The whole plan runs inside the worktree on the brief's `WORKTREE:` line (branch `BRANCH:`). Every agent must `cd` into that worktree and make ALL code edits there, never in the base checkout. Pass the worktree path explicitly in each Agent prompt. If `WORKTREE:` is empty, init.sh was run with `APEX_NO_WORKTREE=1`, and only then do you operate in the base checkout.
5. **Build.** Dispatch the builder swarm with the Agent tool: all spawns in **one message**, `run_in_background: true` where it applies, each scoped to the worktree path. Wait for the verdicts and don't poll, because the harness notifies you on completion. Then commit the task's work on the worktree branch.

When `HARNESS: gibson` (the default), steps 6–9 apply. With `HARNESS: off`, skip them and go straight to step 10.

6. **Green gate.** Run `$S/green-gate.sh $ARGUMENTS check`. It needs a clean, committed worktree and fails on any step that is red now but was green at the fork point. A `PREEXISTING` red step isn't this task's failure, but report it anyway. On `GATE: FAIL`, go to step 11.
7. **Tier.** Run `$S/risk-tier.sh $ARGUMENTS <LINE_NO> --since <HEAD_SHA> --tags <TAGS>`.
8. **Independent review (never grade your own homework).** Dispatch the `gibson-reviewer` agent in a fresh context, separate from every builder, and pass it WORKTREE, the new head SHA (`git -C <WORKTREE> rev-parse HEAD`), SINCE=`<HEAD_SHA>`, TASK, ACCEPTANCE, and TIER.
   - Tier A: one reviewer. Tier B: one reviewer covering all six lenses.
   - Tier C: a **fan-out**, with one `gibson-reviewer` per lens (six, in one message), then one more with `ADVERSARIAL: true` to try to refute the approvals.
   - Record each outcome with `$S/checkpoint.sh $ARGUMENTS review <LINE_NO> <sha> APPROVE|REQUEST_CHANGES`. Any REQUEST_CHANGES means the builders fix, commit, and repeat from step 6. Cap it at 3 review rounds per task; after that, treat it as a failure (step 11).
   - If the reviewer can't run, the task **blocks**. Fail closed and never skip review silently. Only a task whose entry condition genuinely doesn't apply (for example, pure research notes) may use `--skip-review "<why>"` in step 10, and the reason is recorded.
9. **Tier C → human gate G12.** Halt with `$S/checkpoint.sh $ARGUMENTS halt "awaiting human gate G12 line <LINE_NO>"` and ask the user using the **Ask Contract**:
   - **What I'm asking:** approval to accept this change, in one sentence.
   - **What it does:** the behavior change in plain words, not the diff.
   - **Why:** how it serves the plan's goal.
   - **Risks:** what could go wrong, how likely it is, and how to undo it.
   End with "Reply `approve G12 <LINE_NO>` to continue." When the user replies with that, record their literal reply with `$S/checkpoint.sh $ARGUMENTS approve <LINE_NO> <sha> "<reply>"`. Never record an approval the user didn't give.
10. **Acceptance and check-off.** Run the task's `Acceptance:` check inside the worktree. It can be a runnable command, a file-exists test, or a regex match; for `[gate:human]`, wait for the user's literal approval phrase. On pass, run `$S/checkpoint.sh $ARGUMENTS complete <LINE_NO> "<verdict>"`. With the harness on, this **refuses** unless the gate, the review, and (for Tier C) the G12 approval all bind to the current head SHA. Write a one-paragraph summary to memory namespace `apex-execute` and advance.
11. **On failure:** run `$S/checkpoint.sh $ARGUMENTS fail <LINE_NO> "<reason, verbatim>"` and `$S/lessons.sh $ARGUMENTS fail "<stable failure signature>"`.
    - `ESCALATE:` means two failures in a row. Buy a second opinion from a *different* agent (fresh context, a different model if one is available) before retrying.
    - `RATCHET: FILE_LESSON` means this failure has happened before. File it with `$S/lessons.sh $ARGUMENTS add ...`, and where you can, add the guide or sensor that prevents it.
    - `HALTED` means the error budget is spent. Surface the blocking reason verbatim to the user and stop.
12. If the plan is complete (no unchecked tasks), the final gate has passed. Write `COMPLETE`, then **land the worktree** by running `$S/land.sh $ARGUMENTS`. With the harness on, land.sh re-runs the green gate on the final head and refuses to land any uncommitted, unreviewed code. Then exit, and do **not** call `ScheduleWakeup`.
13. Otherwise, call `ScheduleWakeup` with a delay matched to the next task's expected wait: 1200–1800s for non-urgent work, 270s when actively polling external state.

Respect the gates:
- `[gate:auto]` — run the Acceptance check, advance on pass.
- `[gate:human]` — set `halted: true` with `halt_reason: "awaiting human gate <id>"`, present the gate in Ask Contract form (what / what it does / why / risks), print "Reply 'approve <gate-id>' to continue," exit the loop.
- `[gate:partner:<email>]` — write a durable inbox item, halt with `halt_reason: "awaiting partner gate <id>"`.

Bounded reasoning: one task per iteration, one verdict gate, 30-minute timeout. Report truthfully: quote failures verbatim, name skipped steps, and never mark done what a sensor didn't verify. Don't make this a "make progress" loop — make it a "check this box" loop.

If `$ARGUMENTS` is empty, scan `.claude/plans/*-plan.md` for the most recently-modified plan and confirm with the user before iterating.
