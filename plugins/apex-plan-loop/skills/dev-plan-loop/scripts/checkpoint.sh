#!/usr/bin/env bash
# checkpoint.sh — Mark a phase complete (or rewind) and update state.
# Usage:
#   ./checkpoint.sh PLAN.md complete LINE_NO VERDICT_REASON
#   ./checkpoint.sh PLAN.md halt    REASON
#   ./checkpoint.sh PLAN.md rewind  LINE_NO
set -euo pipefail

PLAN="${1:?usage: checkpoint.sh PLAN.md ACTION [...]}"
ACTION="${2:?action: complete|halt|rewind}"
[[ -f "$PLAN" ]] || { echo "ERROR: plan not found"; exit 1; }

PLAN_ABS="$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")"
PLAN_HASH="$(printf '%s' "$PLAN_ABS" | shasum -a 256 | cut -c1-12)"
STATE_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.dev-plan-state/$PLAN_HASH"
CHECKPOINT="$STATE_DIR/checkpoint.json"
NOW="$(date -u +%FT%TZ)"

case "$ACTION" in
  complete)
    LINE_NO="${3:?line_no required}"
    VERDICT="${4:-passed}"
    # Flip "- [ ]" to "- [x]" on that line (BSD/macOS sed)
    sed -i.bak "${LINE_NO}s/^- \[ \]/- [x]/" "$PLAN" && rm -f "${PLAN}.bak"
    # Update checkpoint
    python3 - "$CHECKPOINT" "$NOW" "$VERDICT" "$LINE_NO" <<'PY'
import json, sys
path, now, verdict, line_no = sys.argv[1:]
with open(path) as f: s = json.load(f)
s["completed_tasks"] = s.get("completed_tasks", 0) + 1
s["last_verdict"] = {"line_no": int(line_no), "result": "pass", "reason": verdict, "at": now}
s["last_iteration_at"] = now
s["current_phase"] = None
with open(path, "w") as f: json.dump(s, f, indent=2)
PY
    echo "[checkpoint] complete @ line $LINE_NO ($VERDICT)"
    ;;

  halt)
    REASON="${3:-unspecified}"
    python3 - "$CHECKPOINT" "$NOW" "$REASON" <<'PY'
import json, sys
path, now, reason = sys.argv[1:]
with open(path) as f: s = json.load(f)
s["halted"] = True
s["halt_reason"] = reason
s["last_iteration_at"] = now
with open(path, "w") as f: json.dump(s, f, indent=2)
PY
    echo "[checkpoint] HALTED: $REASON"
    ;;

  rewind)
    LINE_NO="${3:?line_no required}"
    sed -i.bak "${LINE_NO}s/^- \[x\]/- [ ]/" "$PLAN" && rm -f "${PLAN}.bak"
    python3 - "$CHECKPOINT" <<PY
import json
with open("$CHECKPOINT") as f: s = json.load(f)
s["completed_tasks"] = max(0, s.get("completed_tasks", 0) - 1)
s["halted"] = False
s["halt_reason"] = None
with open("$CHECKPOINT", "w") as f: json.dump(s, f, indent=2)
PY
    echo "[checkpoint] rewound line $LINE_NO"
    ;;

  *) echo "ERROR: unknown action $ACTION" >&2; exit 1 ;;
esac
