---
name: run
description: Drive one routed task end to end with apex-dispatch and apex-scope-loop — iterate → route → dispatch exactly the route → gate → risk tier → review shape → review → complete (or fail and escalate). Pass a plan path as $ARGUMENTS (or `adhoc <ROUTE_ID>` for an ad-hoc route made with /apex-dispatch:route).
argument-hint: "<path-to-plan.md> | adhoc <ROUTE_ID>"
---

You are driving **one** routed task for `$ARGUMENTS`. One task per invocation; never more.

Script paths: `$D` = `${CLAUDE_PLUGIN_ROOT}/scripts` (this plugin). `$S` = the sibling apex-scope-loop's scripts; resolve it once, exactly as `route.sh` does, and stop if it is empty ("apex-scope-loop 0.3.0+ must be installed beside apex-dispatch, or set APEX_SCOPE_LOOP_ROOT"):

```bash
S=""; for c in "${APEX_SCOPE_LOOP_ROOT:-}" "${CLAUDE_PLUGIN_ROOT}/../apex-scope-loop" "${CLAUDE_PLUGIN_ROOT}"/../../apex-scope-loop/*/; do
  [ -n "$c" ] && [ -f "$c/skills/apex-execute/scripts/iterate.sh" ] && { S="$(cd "$c/skills/apex-execute/scripts" && pwd)"; break; }
done; echo "S=$S"
```

Use the `dispatch-route` skill for every dispatch decision below, and the `dispatch-worker` skill when `ROUTE_PROVIDER` is not `claude-session`.

## Plan task

1. **Iterate.** `$S/iterate.sh $ARGUMENTS`. It applies the kill switches, picks the next unblocked task, takes the `ACTIVE` lock, sets stage BUILD and calls `$D/route.sh plan` for you. Keep `WORKTREE`, `LINE_NO`, `HEAD_SHA`, `TASK_BASE`, `LESSONS` and the whole `ROUTE_*` block.
   - `STATUS: HALTED | NEEDS_SPEC | HUMAN_GATE | BUSY` → act as the `dispatch-route` skill says for that status and stop. Never work around a kill switch or a lock.
   - `ROUTE: none` → apex-dispatch is off (`APEX_DISPATCH_MODE=off`); hand over to `/apex-scope-loop:iterate $ARGUMENTS` and stop.
   - `ROUTE: error …` → quote it and stop; do not route by hand.
2. **Recall.** If `LESSONS` is non-zero: `$S/lessons.sh $ARGUMENTS recall <tags>`; the lessons go into every brief.
3. **Dispatch.** Spawn exactly the route: roster roles only, as `apex-dispatch:<role>`, `model: ROUTE_MODEL`, the routed fan-out and lanes, within the budgets, all builders in one message, in the worktree. You do not write spawn rows (only hooks and shims can): `pre-agent.sh`, `subagent-start.sh` and `post-agent.sh` record each spawn, its resolved model and its usage. While the lock is held, `pre-agent.sh` denies spawns off the roster, at another model, over the spawn, minute or USD budget, or builders during GATE/REVIEW; a denial is the route speaking, not an error to work around. Wait for every builder to finish, then commit the work on the worktree branch (`stop-gate.sh` refuses, once, to end your turn with uncommitted work or a builder still running).
4. **Gate.** Run the task's Acceptance command in the worktree, then `$S/green-gate.sh $ARGUMENTS check`. On FAIL go to step 8. A PASS at HEAD sets stage GATE: no more commits until a re-route.
5. **Tier.** `$S/risk-tier.sh $ARGUMENTS <LINE_NO> --since <TASK_BASE> --classify` (re-run after every fix commit).
6. **Review shape.** `$D/route.sh review-shape <ROUTE_ID> --tier <TIER>`. Dispatch it: A one reviewer; B one six-lens reviewer; C six lens reviewers + one adversarial reviewer in one message, the diversity requirement, then G12. Reviewers get the gate and Acceptance output in the brief (they have no Bash); a lens reviewer ends with `LENS: <lens>` above its verdict. Record each verdict from its hook-written record with `$S/checkpoint.sh $ARGUMENTS review <LINE_NO> <sha> <VERDICT> apex-dispatch:reviewer --agent-id <the reviewer's agent id>` (the role comes from the record). REQUEST_CHANGES → re-route with `$D/route.sh plan $ARGUMENTS --line <LINE_NO>` (it returns the lock to BUILD), builders fix and commit, back to step 4; three rounds max.
7. **G12 (Tier C).** `$S/checkpoint.sh $ARGUMENTS halt "awaiting human gate G12 line <LINE_NO>"`, ask with the Ask Contract (what I'm asking / what it does / why / risks, plus cost so far from `$D/report.sh --plan $ARGUMENTS`), and stop. When the user replies, `$S/checkpoint.sh $ARGUMENTS approve <LINE_NO> <sha> "<their literal reply>"`, then continue with `/apex-dispatch:done`.
8. **Failure.** `$S/checkpoint.sh $ARGUMENTS fail <LINE_NO> "<reason, verbatim>"` and `$S/lessons.sh $ARGUMENTS fail "<signature>"`. Relay its `ESCALATE_ROUTE:` lines (effort-up, model-up + diagnoser, or HALT) and stop; the next `/apex-dispatch:run` routes the new rung. `RATCHET: FILE_LESSON` → file the lesson. `HALTED` → surface the reason verbatim.
9. **Complete.** On an APPROVE at the current head (and G12 where required), run `/apex-dispatch:done $ARGUMENTS` (or its steps directly).

## Ad-hoc route (`adhoc <ROUTE_ID>`)

An ad-hoc ask has no plan line, so `green-gate.sh`, `risk-tier.sh` and `checkpoint.sh` (all plan-bound) do not apply yet. Read the route from `.dev-plan-state/adhoc/<id>/dispatch*/active-route.json` (the id is the middle of `a-<id>-<n>`), dispatch it the same way (step 3), run its Acceptance command, review at `ROUTE_RISK_TIER` via `$D/route.sh review-shape <ROUTE_ID> --tier <tier>`, and close with `/apex-dispatch:done adhoc <ROUTE_ID>`. If the change touches money, auth, PII, schema or security, stop and promote it to a plan task: an ad-hoc run has no G12 path.

## Rules

- One task, one route. Never dispatch a role, model, provider or fan-out the route did not name; if you cannot honour a field, stop and say which.
- `ROUTE_ENFORCED: yes` (the default) means `checkpoint.sh` takes only hook-written review records and `complete` needs ledger evidence. `ROUTE_ENFORCED: no` means the human opted out with `APEX_DISPATCH_ENFORCE=0`: the hooks still enforce and record the route in `dispatch-shadow/`, but the checkpoint accepts typed verdicts; say so in your summary. Never change that variable yourself.
- Report truthfully: quote failures verbatim, name skipped steps, never call a task done that a sensor did not verify.
