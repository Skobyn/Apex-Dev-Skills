#!/usr/bin/env bash
# status.sh — Print current plan/state summary.
# Usage: ./status.sh path/to/plan.md
set -euo pipefail

PLAN="${1:?usage: status.sh PLAN.md}"
[[ -f "$PLAN" ]] || { echo "ERROR: plan not found"; exit 1; }

APEX_RESOLVE_MODE=read  # reporting only: a repository mismatch warns
# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
apex_resolve "$PLAN"

TOTAL=$(awk '/^- \[[ x]\]/{c++} END{print c+0}' "$PLAN")
DONE=$(awk '/^- \[x\]/{c++} END{print c+0}' "$PLAN")
TODO=$((TOTAL - DONE))

echo "==== apex-execute status ===="
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
