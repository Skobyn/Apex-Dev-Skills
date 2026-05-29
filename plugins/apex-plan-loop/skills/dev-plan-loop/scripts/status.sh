#!/usr/bin/env bash
# status.sh — Print current plan/state summary.
# Usage: ./status.sh path/to/plan.md
set -euo pipefail

PLAN="${1:?usage: status.sh PLAN.md}"
[[ -f "$PLAN" ]] || { echo "ERROR: plan not found"; exit 1; }

PLAN_ABS="$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")"
PLAN_HASH="$(printf '%s' "$PLAN_ABS" | shasum -a 256 | cut -c1-12)"
STATE_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.dev-plan-state/$PLAN_HASH"
CHECKPOINT="$STATE_DIR/checkpoint.json"

TOTAL=$(awk '/^- \[[ x]\]/{c++} END{print c+0}' "$PLAN")
DONE=$(awk '/^- \[x\]/{c++} END{print c+0}' "$PLAN")
TODO=$((TOTAL - DONE))

echo "==== dev-plan-loop status ===="
echo "Plan       : $PLAN"
echo "Hash       : $PLAN_HASH"
echo "State      : $STATE_DIR"
echo "Tasks      : $DONE / $TOTAL  ($TODO remaining)"

if [[ -f "$CHECKPOINT" ]]; then
  echo "Checkpoint :"
  cat "$CHECKPOINT" | sed 's/^/  /'
else
  echo "Checkpoint : (uninitialized — run init.sh)"
fi

# Next task preview
NEXT=$(grep -nE '^- \[ \]' "$PLAN" | head -1 || true)
if [[ -n "$NEXT" ]]; then
  echo "Next task  : $NEXT"
fi

# Blocked tasks
BLOCKED=$(grep -B1 'Blocked-by:' "$PLAN" 2>/dev/null | awk '/^- \[ \]/{c++} END{print c+0}')
[[ $BLOCKED -gt 0 ]] && echo "Blocked    : $BLOCKED unresolved blocked-by references"

# Marker files
[[ -f "$STATE_DIR/COMPLETE" ]] && echo "Marker     : COMPLETE"
