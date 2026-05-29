#!/usr/bin/env bash
# status.sh — Print a snapshot of a decide-plan-loop initiative.
#
# Usage:
#   ./status.sh <slug>
#
# Reports:
#   - ADR path + status (Proposed / Accepted / Implemented / Superseded)
#   - Plan path + completion % (checked tasks / total tasks)
#   - Current phase (next unchecked task)
#   - Next gate (if any pending)
#   - dev-plan-loop checkpoint state (if initialized)

set -euo pipefail

SLUG="${1:-}"
if [[ -z "$SLUG" ]]; then
  echo "Usage: $0 <slug>" >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ADR="$REPO_ROOT/.claude/tasks/${SLUG}-adr.md"
PLAN="$REPO_ROOT/.claude/plans/${SLUG}-plan.md"

print_line() { printf '  %-20s %s\n' "$1" "$2"; }

echo "=== decide-plan-loop status: $SLUG ==="
echo

# ADR
if [[ -f "$ADR" ]]; then
  STATUS="$(grep -E '^\*\*Status\*\*:' "$ADR" | head -1 | sed 's/^\*\*Status\*\*: //')"
  print_line "ADR:" "$ADR"
  print_line "Status:" "${STATUS:-unknown}"
else
  print_line "ADR:" "(not found — run start.sh)"
fi

# Plan
if [[ -f "$PLAN" ]]; then
  TOTAL="$({ grep -cE '^- \[[ x]\]' "$PLAN" || true; })"
  DONE="$({ grep -cE '^- \[x\]' "$PLAN" || true; })"
  TOTAL="${TOTAL:-0}"
  DONE="${DONE:-0}"
  PCT=0
  if [[ "$TOTAL" -gt 0 ]]; then
    PCT=$(( DONE * 100 / TOTAL ))
  fi
  print_line "Plan:" "$PLAN"
  print_line "Progress:" "$DONE / $TOTAL tasks ($PCT%)"

  NEXT="$(grep -nE '^- \[ \]' "$PLAN" | head -1 || true)"
  if [[ -n "$NEXT" ]]; then
    NEXT_LINE="${NEXT#*:}"
    print_line "Next task:" "$(echo "$NEXT_LINE" | sed 's/^- \[ \] //' | cut -c1-80)"
  else
    print_line "Next task:" "(none — all checked OR no tasks)"
  fi

  NEXT_GATE="$(grep -nE '^- \[ \] \*\*Gate' "$PLAN" | head -1 || true)"
  if [[ -n "$NEXT_GATE" ]]; then
    GATE_LINE="${NEXT_GATE#*:}"
    print_line "Next gate:" "$(echo "$GATE_LINE" | sed 's/^- \[ \] //' | cut -c1-80)"
  fi
else
  print_line "Plan:" "(not found — run start.sh)"
fi

# dev-plan-loop checkpoint
if [[ -f "$PLAN" ]]; then
  PLAN_ABS="$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")"
  PLAN_HASH="$(printf '%s' "$PLAN_ABS" | shasum -a 256 | cut -c1-12)"
  STATE_DIR="$REPO_ROOT/.dev-plan-state/$PLAN_HASH"
  CHECKPOINT="$STATE_DIR/checkpoint.json"

  echo
  if [[ -f "$CHECKPOINT" ]]; then
    print_line "Checkpoint:" "$CHECKPOINT"
    HALTED="$(python3 -c "import json; print(json.load(open('$CHECKPOINT')).get('halted', False))" 2>/dev/null || echo unknown)"
    HALT_REASON="$(python3 -c "import json; print(json.load(open('$CHECKPOINT')).get('halt_reason') or '')" 2>/dev/null || echo "")"
    print_line "Halted:" "$HALTED"
    [[ -n "$HALT_REASON" ]] && print_line "Halt reason:" "$HALT_REASON"
    if [[ -f "$STATE_DIR/COMPLETE" ]]; then
      print_line "Marker:" "COMPLETE — plan finished"
    fi
  else
    print_line "Checkpoint:" "(not initialized — run promote-to-loop.sh)"
  fi
fi

echo
