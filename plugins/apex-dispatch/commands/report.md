---
name: report
description: Print apex-dispatch's ledger report for a plan or a state directory — chain status, routes by class/tier/provider/mode, spawns, verdicts, escalations, tokens, estimated USD and the unverified-usage bucket; --compare for routed vs baseline, --decision for the decision layer vs routing. Pass a plan path (or --state DIR) plus any of --compare, --decision, --json as $ARGUMENTS.
argument-hint: "<plan.md> | --state <dir> [--compare [--baseline-state <dir>]] [--decision] [--json]"
---

You are reporting on apex-dispatch routing for `$ARGUMENTS`.

1. If `$ARGUMENTS` starts with `--`, run `${CLAUDE_PLUGIN_ROOT}/scripts/report.sh $ARGUMENTS`. Otherwise treat its first word as a plan path and run `${CLAUDE_PLUGIN_ROOT}/scripts/report.sh --plan <plan> <the remaining words>`. If `$ARGUMENTS` is empty, use the most recently modified `.claude/plans/*-plan.md` and say which plan you chose. For an ad-hoc ask, pass `--state <state>`, where `<state>` is two levels above the route's `ROUTE_FILE` (`<state>/dispatch*/active-route.json`), or `<apex_state_base>/adhoc/<id>` as `/apex-dispatch:done` derives it; never assume a fixed path under the current directory. If the report shows no rows at all, say the state path is probably wrong (`${CLAUDE_PLUGIN_ROOT}/scripts/ledger.sh verify --state <state>` prints `EMPTY` and exits 3 there) rather than reporting an empty but healthy ledger.
2. Print the `REPORT_*` lines verbatim, then summarise in a few plain sentences:
   - `REPORT_CHAIN` first: if it is not `OK`, the ledger was edited, truncated or torn; say so before any number, because every figure below is then untrustworthy.
   - Cost: `REPORT_USD_ESTIMATED` covers only rows with a resolved model of a known family. `REPORT_UNVERIFIED` rows carry usage without a resolved model; they are listed separately and are **not** in the USD figure. Do not add them in.
   - Routes, spawns, verdicts and escalations as counts. Under enforcement, a route with no spawn row means the work was done inline.
3. If the state is `dispatch-shadow/`, say that the human opted out of enforcement (`APEX_DISPATCH_ENFORCE=0`) or the run predates it: the hooks record the same rows there (`spawn_request`, `spawn`, `worker_run` from `post-agent.sh`, `verdict`, `model_mismatch`, `policy_violation`), but `checkpoint.sh` did not require them. Shim rows (`worker_run`, `verdict`, `worker_applied` with source `shim`) come from `bin/worker-*.sh` and `apply.sh`. A route with no spawn row recorded before Phase 3.1 is expected, not evidence of inline work. Name any `model_mismatch` or `policy_violation` rows.

4. With `--compare`: print the `REPORT_COMPARE*` lines verbatim, then say, per arm, tasks, USD per solved task, approval and first-round approval rates and review rounds, and the deltas. Lead with the status: `insufficient n` (fewer than the pre-registered 20 tasks in an arm) means no conclusion may be drawn yet; `no baseline data` means the ledger holds no `baseline`/`shadow` routes (run with `APEX_DISPATCH_MODE=shadow` or pass `--baseline-state <dir>` of a baseline run). USD figures are estimates and exclude the unverified bucket.
5. With `--decision`: print the `REPORT_DECISION*` lines verbatim and summarise agreement (overall, calibrated vs uncalibrated, by confidence bucket) and whether the decision moved any route. `no decision data` means `${APEX_DECIDE_CMD}` was unset, absent or timed out (routing was table-only); say that, it is not an error.

Exit codes: 0 ok, 1 error, 2 usage (no `--state` or `--plan`; `--baseline-state` without `--compare`). Quote errors verbatim.
