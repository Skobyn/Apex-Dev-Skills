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

# Counts, the next task and blocked tasks come from planlib.py, the parser
# iterate.sh and land.sh use, so status never disagrees with them.
SUMMARY="$(python3 - "$APEX_EXECUTE_SCRIPTS" "$PLAN_ABS" <<'PY'
import json, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1]); import planlib
errs = planlib.cmd_validate(sys.argv[2])
if errs:
    print(json.dumps({"invalid": errs[:3]}))
    sys.exit(0)
ts = planlib.parse(sys.argv[2])
d = planlib.cmd_next(sys.argv[2], 3)
print(json.dumps({"total": len(ts), "done": sum(t["checked"] for t in ts),
                  "next": (d.get("task") or {}).get("line_no"), "next_line": (d.get("task") or {}).get("line"),
                  "blocked": len(d.get("blocked", []))}))
PY
)"
sfield() { python3 -c 'import json,sys; v=json.loads(sys.argv[1]).get(sys.argv[2]); print("" if v is None else v)' "$SUMMARY" "$1"; }
TOTAL="$(sfield total)"; DONE="$(sfield done)"; TOTAL="${TOTAL:-0}"; DONE="${DONE:-0}"
TODO=$((TOTAL - DONE))

echo "==== apex-execute status ===="
echo "Plan       : $PLAN"
echo "Hash       : $PLAN_HASH"
echo "State      : $STATE_DIR"
echo "Tasks      : $DONE / $TOTAL  ($TODO remaining)"

if [[ -f "$CHECKPOINT" ]]; then
  echo "Checkpoint :"
  sed 's/^/  /' "$CHECKPOINT"; echo
else
  echo "Checkpoint : (uninitialized — run init.sh)"
fi

INVALID="$(sfield invalid)"
if [[ -n "$INVALID" ]]; then
  echo "Plan       : INVALID — iterate.sh will refuse it; run planlib.py validate $PLAN_ABS"
fi
# Next task preview (the task iterate.sh would select)
NEXT="$(sfield next)"
[[ -n "$NEXT" ]] && echo "Next task  : $NEXT:$(sfield next_line)"

# Tasks waiting on unchecked Blocked-by targets
BLOCKED="$(sfield blocked)"
[[ "${BLOCKED:-0}" -gt 0 ]] && echo "Blocked    : $BLOCKED task(s) waiting on unchecked Blocked-by targets"

# Marker files
[[ -f "$STATE_DIR/COMPLETE" ]] && echo "Marker     : COMPLETE"
