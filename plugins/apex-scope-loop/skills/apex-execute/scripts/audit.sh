#!/usr/bin/env bash
# audit.sh — Nightly progress audit (called by /schedule).
# Diffs current plan state vs. previous run and emits a brief for the model
# to write into the apex-execute memory namespace and MEMORY.md.
#
# Usage: ./audit.sh path/to/plan.md
set -euo pipefail

PLAN="${1:?usage: audit.sh PLAN.md}"
[[ -f "$PLAN" ]] || { echo "STATUS: ERROR plan not found"; exit 1; }

PLAN_ABS="$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")"
PLAN_HASH="$(printf '%s' "$PLAN_ABS" | shasum -a 256 | cut -c1-12)"
STATE_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.dev-plan-state/$PLAN_HASH"
CHECKPOINT="$STATE_DIR/checkpoint.json"
mkdir -p "$STATE_DIR/audits"

NOW="$(date -u +%FT%TZ)"
TODAY="$(date -u +%Y-%m-%d)"
PREV_AUDIT="$STATE_DIR/audits/last.json"
THIS_AUDIT="$STATE_DIR/audits/$TODAY.json"

DONE=$(awk '/^- \[x\]/{c++} END{print c+0}' "$PLAN")
TOTAL=$(awk '/^- \[[ x]\]/{c++} END{print c+0}' "$PLAN")

# Worktree the plan executes in (commits land on its branch, not the plan file).
WT_BRANCH=""
[[ -f "$CHECKPOINT" ]] && WT_BRANCH="$(grep -o '"worktree_branch": "[^"]*"' "$CHECKPOINT" | head -1 | sed 's/.*: "//; s/"$//')"

# Recently completed (last 24h). Prefer the worktree branch where code lands;
# fall back to the plan file's history if no worktree branch is recorded.
if [[ -n "$WT_BRANCH" ]] && git -C "$(dirname "$PLAN_ABS")" show-ref --verify --quiet "refs/heads/$WT_BRANCH"; then
  RECENT_COMMITS=$(git -C "$(dirname "$PLAN_ABS")" log "$WT_BRANCH" --since='24 hours ago' --pretty=format:'%h %s' 2>/dev/null | head -20 || echo "")
else
  RECENT_COMMITS=$(git -C "$(dirname "$PLAN_ABS")" log --since='24 hours ago' --pretty=format:'%h %s' -- "$PLAN_ABS" 2>/dev/null | head -20 || echo "")
fi

cat > "$THIS_AUDIT" <<EOF
{
  "audited_at": "$NOW",
  "completed": $DONE,
  "total": $TOTAL,
  "remaining": $((TOTAL - DONE)),
  "recent_commits": $(echo "$RECENT_COMMITS" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip().splitlines()))')
}
EOF

# Diff vs. previous
DELTA=0
if [[ -f "$PREV_AUDIT" ]]; then
  PREV_DONE=$(python3 -c "import json; print(json.load(open('$PREV_AUDIT'))['completed'])" 2>/dev/null || echo 0)
  DELTA=$((DONE - PREV_DONE))
fi
cp "$THIS_AUDIT" "$PREV_AUDIT"

cat <<EOF
==== nightly audit ($TODAY) ====
Plan       : $PLAN
Progress   : $DONE / $TOTAL  (delta vs. last audit: +$DELTA)
Recent     : $(echo "$RECENT_COMMITS" | wc -l | xargs) commits in last 24h

Briefing for memory store (namespace=apex-execute, key=audit-$TODAY):
- $DELTA tasks completed since last audit
- $((TOTAL - DONE)) tasks remaining
- Recent commits touching plan: see $THIS_AUDIT
EOF
