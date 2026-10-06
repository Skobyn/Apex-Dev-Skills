#!/usr/bin/env bash
# apex-dispatch report.sh — summarise a dispatch ledger.
#
# Usage:
#   report.sh --state DIR [--plan PLAN] [--json]
#   report.sh --plan PLAN [--json]        resolve the plan's state dir through apex-scope-loop
#
# Prints REPORT_* lines (or one JSON object with --json): chain status, routes by
# class/tier/provider/mode, spawns, verdicts, escalations, tokens, estimated USD
# (real usage x the policy tier prices) and the unverified-model bucket, which is
# excluded from USD. Exit 0 ok (a broken chain is reported, not fatal), 2 usage.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "report: python3 is required" >&2; exit 1; }
usage() { sed -n '4,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

STATE=""; PLAN=""; JSON=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --state) STATE="${2:?--state needs a value}"; shift 2 ;;
    --plan) PLAN="${2:?--plan needs a value}"; shift 2 ;;
    --json) JSON=(--json); shift ;;
    -h|--help) usage ;;
    *) echo "report: unknown argument $1" >&2; usage ;;
  esac
done
[[ -n "$STATE" || -n "$PLAN" ]] || usage

if [[ -z "$STATE" ]]; then
  [[ -f "$PLAN" ]] || { echo "report: plan not found: $PLAN" >&2; exit 1; }
  EX=""
  for c in "${APEX_SCOPE_LOOP_ROOT:-}" "$PLUGIN_ROOT/../apex-scope-loop"; do
    [[ -n "$c" && -f "$c/skills/apex-execute/scripts/_lib.sh" ]] && { EX="$c/skills/apex-execute/scripts"; break; }
  done
  [[ -n "$EX" ]] || { echo "report: --plan needs apex-scope-loop beside apex-dispatch (or pass --state)" >&2; exit 1; }
  # shellcheck source=/dev/null
  source "$EX/_lib.sh"
  APEX_RESOLVE_MODE=read
  apex_resolve "$PLAN"
fi
[[ -n "$STATE" ]] || STATE="$STATE_DIR"
ARGS=(--state "$STATE")
[[ -n "$PLAN" ]] && ARGS+=(--plan "$PLAN")
exec python3 -B "$PLUGIN_ROOT/scripts/lib/report.py" "$PLUGIN_ROOT" "${ARGS[@]}" ${JSON[@]+"${JSON[@]}"}
