#!/usr/bin/env bash
# status.sh — Print current plan/state summary.
# Usage: ./status.sh path/to/plan.md [--review-metrics]
#   --review-metrics  per task: review rounds, rounds that requested changes
#                     (blocking rounds), attempts, and minutes per round (the
#                     mean gap between consecutive rounds' first verdicts) from
#                     the checkpoint's review timestamps (ADR-0004: before/after
#                     measurement is how the calibration is judged)
set -euo pipefail

PLAN="${1:?usage: status.sh PLAN.md}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"; PLAN="$(apex_locate_plan "$PLAN")"   # ADR-0004 H
[[ -f "$PLAN" ]] || { echo "ERROR: plan not found"; exit 1; }

APEX_RESOLVE_MODE=read  # reporting only: a repository mismatch warns
# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
apex_resolve "$PLAN"

if [[ "${2:-}" == "--review-metrics" ]]; then
  [[ -f "$CHECKPOINT" ]] || { echo "ERROR: not initialized — run init.sh first" >&2; exit 1; }
  python3 - "$CHECKPOINT" <<'PY'
import datetime, json, sys
s = json.load(open(sys.argv[1]))
def ts(x):
    try:
        return datetime.datetime.strptime(x, "%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        return None
print("REVIEW_METRICS: line rounds blocking_rounds attempts minutes_per_round waived")
tot_r = tot_b = 0
waived = {str(c.get("line")) for c in s.get("completes") or [] if c.get("review") == "waived"}
for line, r in sorted((s.get("reviews") or {}).items(), key=lambda kv: int(kv[0]) if kv[0].isdigit() else 0):
    recs = r.get("records") or []
    first = {}
    for x in recs:
        k = (x.get("attempt", 1), x.get("sha"))
        t = ts(x.get("at") or "")
        if k not in first or (t and first[k] and t < first[k]):
            first[k] = t
    rounds = list(first)
    blocking = {(x.get("attempt", 1), x.get("sha")) for x in recs if x.get("verdict") == "REQUEST_CHANGES"}
    times = sorted(t for t in first.values() if t)
    mpr = "%.1f" % ((times[-1] - times[0]).total_seconds() / 60 / (len(times) - 1)) if len(times) >= 2 else "-"
    attempts = max([x.get("attempt", 1) for x in recs] or [1])
    tot_r += len(rounds); tot_b += len(blocking)
    print("REVIEW_METRIC: %s %d %d %d %s %s" % (line, len(rounds), len(blocking), attempts, mpr, "yes" if line in waived else "no"))
print("REVIEW_TOTAL: rounds=%d blocking_rounds=%d tasks=%d" % (tot_r, tot_b, len(s.get("reviews") or {})))
PY
  exit 0
fi

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
