---
name: report
description: Print apex-dispatch's ledger report for a plan or a state directory — chain status, routes by class/tier/provider/mode, spawns, verdicts, escalations, tokens, estimated USD and the unverified-usage bucket. Pass a plan path (or --state DIR, optionally --json) as $ARGUMENTS.
argument-hint: "<plan.md> | --state <dir> [--json]"
---

You are reporting on apex-dispatch routing for `$ARGUMENTS`.

1. If `$ARGUMENTS` starts with `--`, run `${CLAUDE_PLUGIN_ROOT}/scripts/report.sh $ARGUMENTS`. Otherwise treat it as a plan path and run `${CLAUDE_PLUGIN_ROOT}/scripts/report.sh --plan $ARGUMENTS`. If `$ARGUMENTS` is empty, use the most recently modified `.claude/plans/*-plan.md` and say which plan you chose. For an ad-hoc ask, pass `--state .dev-plan-state/adhoc/<id>`.
2. Print the `REPORT_*` lines verbatim, then summarise in a few plain sentences:
   - `REPORT_CHAIN` first: if it is not `OK`, the ledger was edited, truncated or torn; say so before any number, because every figure below is then untrustworthy.
   - Cost: `REPORT_USD_ESTIMATED` covers only rows with a resolved model of a known family. `REPORT_UNVERIFIED` rows carry usage without a resolved model; they are listed separately and are **not** in the USD figure. Do not add them in.
   - Routes, spawns, verdicts and escalations as counts. Under enforcement, a route with no spawn row means the work was done inline.
3. If the state is `dispatch-shadow/`, say that the human opted out of enforcement (`APEX_DISPATCH_ENFORCE=0`) or the run predates it: the hooks record the same rows there (`spawn_request`, `spawn`, `worker_run` from `post-agent.sh`, `verdict`, `model_mismatch`, `policy_violation`), but `checkpoint.sh` did not require them. Shim `worker_run` rows wait for the Phase 4 shims. A route with no spawn row recorded before Phase 3.1 is expected, not evidence of inline work. Name any `model_mismatch` or `policy_violation` rows.

Exit codes: 0 ok, 1 error, 2 usage (no `--state` or `--plan`). Quote errors verbatim.
