#!/usr/bin/env bash
# apex-dispatch report.sh — summarise a dispatch ledger.
#
# Usage:
#   report.sh --state DIR [--plan PLAN] [--json]
#   report.sh --plan PLAN [--json]        resolve the plan's state dir through apex-scope-loop
#   report.sh ... --compare [baseline] [--baseline-state DIR]   routed vs baseline (spec §10)
#   report.sh ... --decision                                    decision layer vs routing (spec §4)
#   report.sh ... --per-task [--transcript PATH]...             delegated USD, tokens, spawns, rounds, outcome per task (alone),
#                                                               plus orchestrator (main-session) tokens and USD from session transcripts
#
# Prints REPORT_* lines (or one JSON object with --json): chain status, routes by
# class/tier/provider/mode, spawns, verdicts, escalations, tokens, estimated USD
# (real usage x the policy tier prices) and the unverified-model bucket, which is
# excluded from USD. --compare: per arm (routed = table/decision/escalated routes,
# baseline = baseline/shadow routes, or the --baseline-state ledger) tasks, spawns,
# USD per task and per solved task, tier mix, review rounds, approval and first-round
# approval rates, escalation rate, p50 wall-clock, per class, and the deltas; an arm
# under the pre-registered minimum n is "insufficient n". --decision: what
# ${APEX_DECIDE_CMD} said vs what routing did (agreement by calibration and
# confidence bucket), or "no decision data". --per-task (ADR-0002 R7): one REPORT_TASK
# line per routed task; unknown USD/tokens (unpriced rows, an unmeasured or background
# agent, nothing run) print n/a, never 0; malformed ledger lines are counted in a
# REPORT_TASK_WARNING and make every figure n/a; REPORT_TASKS_TOTAL reconciles the known,
# partial and unrouted USD with REPORT_USD_ESTIMATED; it cannot be combined with --compare
# or --decision (exit 2). Orchestrator (ADR-0002 R7b): --transcript PATH (repeatable; else auto-located
# by session id as <config>/projects/*/<session_id>.jsonl ($CLAUDE_CONFIG_DIR or ~/.claude), any project
# dir, for each UUID session_id on the ledger) gives orchestrator_tokens / orchestrator_usd per task (turns
# inside the task's route window; a lower bound, compaction and utility calls write no assistant line), an
# unattributed bucket (main-session turns in no single task window; not the same as usd_unrouted, which
# is delegated ledger rows outside any task), and n/a, never 0 or a partial figure, whenever a figure is not
# covered: no transcript, a task session id no transcript read covers (transcript_sessions_missing), a
# window with no main-session turn or an unusable turn, or transcripts with no main-session turn at all;
# sidechain (subagent) turns are excluded as delegated cost; unusable lines are counted as skipped, and one
# with no usable timestamp nulls every orchestrator figure. All print REPORT_* lines, or JSON with --json.
# Exit 0 ok (a broken chain is reported, not fatal), 2 usage.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "report: python3 is required" >&2; exit 1; }
usage() { sed -n '4,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

STATE=""; PLAN=""; JSON=(); EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --state) STATE="${2:?--state needs a value}"; shift 2 ;;
    --plan) PLAN="${2:?--plan needs a value}"; shift 2 ;;
    --json) JSON=(--json); shift ;;
    --compare) EXTRA+=(--compare); shift; if [[ "${1:-}" == baseline ]]; then shift; fi ;;
    --decision) EXTRA+=(--decision); shift ;;
    --per-task) EXTRA+=(--per-task); shift ;;
    --transcript) EXTRA+=(--transcript "${2:?--transcript needs a value}"); shift 2 ;;
    --baseline-state) EXTRA+=(--baseline-state "${2:?--baseline-state needs a value}"); shift 2 ;;
    -h|--help) usage ;;
    *) echo "report: unknown argument $1" >&2; usage ;;
  esac
done
[[ -n "$STATE" || -n "$PLAN" ]] || usage

if [[ -z "$STATE" ]]; then
  [[ -f "$PLAN" ]] || { echo "report: plan not found: $PLAN" >&2; exit 1; }
  # shellcheck source=lib/sibling.bash
  source "$PLUGIN_ROOT/scripts/lib/sibling.bash"
  EX="$(apex_scope_loop_scripts "$PLUGIN_ROOT")"
  [[ -n "$EX" ]] || { echo "report: --plan needs apex-scope-loop beside apex-dispatch (or pass --state)" >&2; exit 1; }
  # shellcheck source=/dev/null
  source "$EX/_lib.sh"
  APEX_RESOLVE_MODE=read
  apex_resolve "$PLAN"
fi
[[ -n "$STATE" ]] || STATE="$STATE_DIR"
ARGS=(--state "$STATE")
[[ -n "$PLAN" ]] && ARGS+=(--plan "$PLAN")
exec python3 -B "$PLUGIN_ROOT/scripts/lib/report.py" "$PLUGIN_ROOT" "${ARGS[@]}" ${JSON[@]+"${JSON[@]}"} ${EXTRA[@]+"${EXTRA[@]}"}
