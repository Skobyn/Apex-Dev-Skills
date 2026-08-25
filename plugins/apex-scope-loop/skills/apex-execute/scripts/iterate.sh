#!/usr/bin/env bash
# iterate.sh — Find next task and emit a swarm dispatch brief for the model.
# This script is intentionally NON-EXECUTING — it produces a structured
# briefing the orchestrator (the model running /loop) reads, then spawns
# the swarm via the Agent tool in ONE message.
#
# Usage: ./iterate.sh path/to/plan.md
#
# Emits to stdout (machine-readable):
#   STATE: <state-dir>
#   WORKTREE: <abs-path>      # cwd the swarm MUST operate in (empty if opted out)
#   BRANCH: <worktree-branch>
#   PHASE: <phase-id>
#   TAGS: <comma-separated>
#   TASK: <task-line>
#   ACCEPTANCE: <criteria-line>
#   BLOCKED_BY: <phase-or-empty>
#   STATUS: READY | BLOCKED | COMPLETE | HALTED
set -euo pipefail

PLAN="${1:?usage: iterate.sh PATH_TO_PLAN.md}"
[[ -f "$PLAN" ]] || { echo "STATUS: ERROR plan not found"; exit 1; }

PLAN_ABS="$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")"
PLAN_HASH="$(printf '%s' "$PLAN_ABS" | shasum -a 256 | cut -c1-12)"
STATE_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.dev-plan-state/$PLAN_HASH"
CHECKPOINT="$STATE_DIR/checkpoint.json"

[[ -f "$CHECKPOINT" ]] || { echo "STATUS: ERROR not initialized — run init.sh first"; exit 1; }

# Worktree the plan is bound to (recorded by init.sh).
read_field() { grep -o "\"$1\": \"[^\"]*\"" "$CHECKPOINT" | head -1 | sed 's/.*: "//; s/"$//'; }
WORKTREE="$(read_field worktree_path)"
WT_BRANCH="$(read_field worktree_branch)"

# Enforce worktree-bound execution: if a worktree was recorded, it must exist.
if [[ -n "$WORKTREE" && ! -d "$WORKTREE" ]]; then
  echo "STATE: $STATE_DIR"
  echo "STATUS: ERROR worktree missing at $WORKTREE — re-run init.sh to recreate it"
  exit 1
fi

# Halted?
if grep -q '"halted": true' "$CHECKPOINT"; then
  echo "STATE: $STATE_DIR"
  echo "STATUS: HALTED"
  exit 0
fi

# Find first unchecked task
NEXT_LINE=$(grep -nE '^- \[ \]' "$PLAN" | head -1 || true)
if [[ -z "$NEXT_LINE" ]]; then
  echo "STATE: $STATE_DIR"
  echo "WORKTREE: $WORKTREE"
  echo "BRANCH: $WT_BRANCH"
  echo "STATUS: COMPLETE"
  echo "NEXT: final gate passed — land the worktree with land.sh $PLAN_ABS"
  touch "$STATE_DIR/COMPLETE"
  exit 0
fi

LINE_NO="${NEXT_LINE%%:*}"
TASK_LINE="${NEXT_LINE#*:}"

# Extract Phase id (e.g., "Phase 2.3")
PHASE_ID=$(echo "$TASK_LINE" | grep -oE 'Phase [0-9]+(\.[0-9]+)*' | head -1 || echo "phase-unknown")

# Extract tags ([backend][security] -> backend,security)
TAGS=$(echo "$TASK_LINE" | grep -oE '\[[a-z-]+\]' | tr -d '[]' | grep -vE '^(x| )$' | paste -sd, - 2>/dev/null || echo "")

# Look ahead for Acceptance: and Blocked-by: lines
ACCEPTANCE=""
BLOCKED_BY=""
NEXT=$((LINE_NO + 1))
END=$((LINE_NO + 6))
while [[ $NEXT -le $END ]]; do
  L=$(sed -n "${NEXT}p" "$PLAN" 2>/dev/null || echo "")
  [[ -z "$L" ]] && break
  case "$L" in
    *"Acceptance:"*) ACCEPTANCE="${L#*Acceptance:}"; ACCEPTANCE="${ACCEPTANCE# }" ;;
    *"Blocked-by:"*) BLOCKED_BY="${L#*Blocked-by:}"; BLOCKED_BY="${BLOCKED_BY# }" ;;
    "- ["*) break ;;  # next task
  esac
  NEXT=$((NEXT + 1))
done

# Resolve blocked-by against current plan state
if [[ -n "$BLOCKED_BY" ]]; then
  # Strip trailing ] or ) and whitespace
  BB_CLEAN=$(echo "$BLOCKED_BY" | sed 's/[])]*$//' | xargs)
  # Check if that phase line is checked
  if grep -qE "^- \[ \].*${BB_CLEAN}" "$PLAN"; then
    echo "STATE: $STATE_DIR"
    echo "PHASE: $PHASE_ID"
    echo "STATUS: BLOCKED"
    echo "BLOCKED_BY: $BB_CLEAN"
    exit 0
  fi
fi

echo "STATE: $STATE_DIR"
echo "WORKTREE: $WORKTREE"
echo "BRANCH: $WT_BRANCH"
echo "PHASE: $PHASE_ID"
echo "TAGS: $TAGS"
echo "TASK: $TASK_LINE"
echo "ACCEPTANCE: $ACCEPTANCE"
echo "BLOCKED_BY: $BLOCKED_BY"
echo "LINE_NO: $LINE_NO"
echo "STATUS: READY"
