---
name: done
description: Close the active apex-dispatch task — verify the ledger chain (and, under enforcement, the route evidence), then checkpoint.sh complete for a plan task (gate, review, tier and G12 all bound to HEAD), or close an ad-hoc route and release its ACTIVE lock. Pass `<plan.md> [verdict summary]` or `adhoc <ROUTE_ID>` as $ARGUMENTS.
argument-hint: "<path-to-plan.md> [\"<verdict summary>\"] | adhoc <ROUTE_ID>"
---

You are closing the active routed task for `$ARGUMENTS`. Closing is a check, not a formality: if any step refuses, quote the refusal verbatim and stop. Never mark done what a sensor did not verify.

`$D` = `${CLAUDE_PLUGIN_ROOT}/scripts`; `$S` = the sibling apex-scope-loop's scripts, resolved as in `/apex-dispatch:run`.

## Plan task

1. Find the task: `LINE_NO`, `WORKTREE` and the route from the last iterate brief, or from `<state>/dispatch*/active-route.json` (`route_id`, `line`). `<state>` is `.dev-plan-state/<plan-hash>/` (`$D/report.sh --plan <plan>` prints it as `REPORT_STATE`). `HEAD=$(git -C <WORKTREE> rev-parse HEAD)`.
2. **Ledger.** `$D/ledger.sh verify --state <state>` must say the chain is intact. What else applies depends on `ROUTE_ENFORCED`:
   - **`yes`** (`<state>/dispatch/`, the default): `$D/ledger.sh evidence --state <state> --line <LINE_NO> --head <HEAD> --plan-hash <plan-hash>` (`--plan-hash` defaults to the state dir's name, which is the plan hash). It exits 0 only when the chain verifies, a READY route row `r-<plan-hash>-L<LINE_NO>-k` is on HEAD's history, and a hook- or shim-written `spawn_request`, `spawn` or `worker_run` row carries that route's id (`pre-agent.sh`, `subagent-start.sh` and `post-agent.sh` write them for every routed spawn). Exit 1 means the work was done inline or the chain is broken: do not complete; report the missing condition. Every verdict must have been recorded from its hook-written record (`checkpoint.sh review … --agent-id <id>`). Never write provenance rows yourself; `ledger.sh append` refuses them.
   - **`no`** (`dispatch-shadow/`: the human opted out with `APEX_DISPATCH_ENFORCE=0`): the hooks enforced and recorded the route in `dispatch-shadow/`, but `checkpoint.sh complete` does not ask for `ledger.sh evidence` and accepts typed verdicts. Say in your report that the run was recorded in the shadow ledger only.
3. **Complete.** Run the task's Acceptance command in the worktree once more, then `$S/checkpoint.sh <plan> complete <LINE_NO> "<verdict summary>"`. It refuses unless the green gate, an APPROVE, the risk tier and (Tier C) the G12 approval are all bound to HEAD, and — when `<state>/dispatch/` exists — the ledger evidence above. It flips the checkbox and sets the `ACTIVE` lock to stage DONE, which makes it reclaimable. Under enforcement a Tier C task (or a class whose review shape is `fanout6+adversarial`) also needs six distinct lens approvals, an adversarial approval and, when a second reviewer family is available (`doctor.json`), an approval from it; without one it completes with a diversity warning that is ledgered.
4. **Report.** `$D/report.sh --plan <plan>` and summarise: the route (class, tier, model, provider), spawns, review rounds, verdict, estimated USD (the unverified bucket separate). If the plan has no unchecked tasks left, say the next step is `land.sh` via `/apex-scope-loop:iterate`.

## Ad-hoc route (`adhoc <ROUTE_ID>`)

There is no plan line, so `checkpoint.sh` and `ledger.sh evidence` (which takes a plan line and plan hash) do not apply; a scripted ad-hoc close is not built yet. Close it by hand, in this order:

1. `<state>` = `.dev-plan-state/adhoc/<id>` (the `<id>` of `a-<id>-<n>`). `$D/ledger.sh verify --state <state>` must pass.
2. Report delegation honestly: state which roles you spawned; the hooks recorded each allowed spawn (`spawn_request`, `spawn`, `worker_run`) and each reviewer verdict (`verdict`, with a raw record under `reviews-raw/`) in the ad-hoc state's ledger, but nothing checks them at close yet.
3. The Acceptance command passed on the current HEAD and a reviewer returned `VERDICT: APPROVE` for it in this session (its record is `<state>/dispatch/reviews-raw/<agent_id>.json`; reviewer spawns needed a committed, clean HEAD). If any reviewer at that HEAD did not approve, or its record was refused, do not close.
4. Release the lock (only the owner's id releases it):
   ```bash
   bash -c 'set -euo pipefail; source "$1/_lib.sh"; STATE_BASE="$(apex_state_base "$PWD")"; apex_lock_release "$2"; apex_lock_owner' _ "$S" <id>
   ```
   It prints `none` when the lock is free.
5. Report as in step 4 above, with `--state <state>`.
