#!/usr/bin/env bash
# audit.sh — Nightly progress audit (called by /schedule).
# Diffs current plan state vs. previous run and emits a brief for the model
# to write into the apex-execute memory namespace and MEMORY.md.
#
# Usage: ./audit.sh path/to/plan.md
set -euo pipefail

# Tier routing guard (ADR-0002): a /schedule env that sets this would flatten
# tier routing for any session spawned off this briefing.
if [ -n "${CLAUDE_CODE_SUBAGENT_MODEL:-}" ]; then
  echo "FATAL: CLAUDE_CODE_SUBAGENT_MODEL set; tier routing void" >&2
  exit 1
fi

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

# Cost attribution (ADR-0002): the orchestrator writes one JSON per finished
# phase to $STATE_DIR/outcomes/<phase>.json ({"phase","tier","verdict","tokens"}),
# mirroring the apex-scope-loop:outcomes/<slug>/<phase> memory key. Aggregate
# tokens per tier so tier assignments can be judged against real spend.
COST_JSON=$(python3 - "$STATE_DIR/outcomes" <<'PY'
import json, pathlib, sys
outdir = pathlib.Path(sys.argv[1])
phases, tiers = [], {}
for f in sorted(outdir.glob("*.json")) if outdir.is_dir() else []:
    try:
        o = json.loads(f.read_text())
    except (ValueError, OSError):
        continue
    tier, tokens = o.get("tier", "unknown"), int(o.get("tokens", 0) or 0)
    phases.append({"phase": o.get("phase", f.stem), "tier": tier, "tokens": tokens})
    tiers[tier] = tiers.get(tier, 0) + tokens
print(json.dumps({"per_phase": phases, "per_tier": tiers}))
PY
)

cat > "$THIS_AUDIT" <<EOF
{
  "audited_at": "$NOW",
  "completed": $DONE,
  "total": $TOTAL,
  "remaining": $((TOTAL - DONE)),
  "recent_commits": $(echo "$RECENT_COMMITS" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip().splitlines()))'),
  "cost": $COST_JSON
}
EOF

# Diff vs. previous
DELTA=0
if [[ -f "$PREV_AUDIT" ]]; then
  PREV_DONE=$(python3 -c "import json; print(json.load(open('$PREV_AUDIT'))['completed'])" 2>/dev/null || echo 0)
  DELTA=$((DONE - PREV_DONE))
fi
cp "$THIS_AUDIT" "$PREV_AUDIT"

COST_LINE=$(echo "$COST_JSON" | python3 -c 'import sys,json; t=json.load(sys.stdin)["per_tier"]; print(", ".join(f"{k}={v}" for k,v in sorted(t.items())) or "no outcome files yet")')

cat <<EOF
==== nightly audit ($TODAY) ====
Plan       : $PLAN
Progress   : $DONE / $TOTAL  (delta vs. last audit: +$DELTA)
Recent     : $(echo "$RECENT_COMMITS" | wc -l | xargs) commits in last 24h
Cost       : tokens per tier — $COST_LINE

Briefing for memory store (namespace=apex-execute, key=audit-$TODAY):
- $DELTA tasks completed since last audit
- $((TOTAL - DONE)) tasks remaining
- Recent commits touching plan: see $THIS_AUDIT
- Tokens per phase per tier: see "cost" in $THIS_AUDIT — also mirror to
  apex-scope-loop:outcomes/<slug> so tier assignments can be audited against
  real spend when writing the next ADR's rationale lines
EOF
