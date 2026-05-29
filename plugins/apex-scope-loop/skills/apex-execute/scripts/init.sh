#!/usr/bin/env bash
# init.sh — Initialize state and memory namespace for a dev plan
# Usage: ./init.sh path/to/plan.md
set -euo pipefail

PLAN="${1:?usage: init.sh PATH_TO_PLAN.md}"
[[ -f "$PLAN" ]] || { echo "ERROR: plan not found: $PLAN" >&2; exit 1; }

PLAN_ABS="$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")"
PLAN_HASH="$(printf '%s' "$PLAN_ABS" | shasum -a 256 | cut -c1-12)"
STATE_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.dev-plan-state/$PLAN_HASH"
NAMESPACE="apex-execute"

mkdir -p "$STATE_DIR"

# Count tasks (lines starting with "- [ ]" or "- [x]")
TOTAL=$(awk '/^- \[[ x]\]/{c++} END{print c+0}' "$PLAN")
DONE=$(awk '/^- \[x\]/{c++} END{print c+0}' "$PLAN")

cat > "$STATE_DIR/checkpoint.json" <<EOF
{
  "plan_path": "$PLAN_ABS",
  "plan_hash": "$PLAN_HASH",
  "namespace": "$NAMESPACE",
  "initialized_at": "$(date -u +%FT%TZ)",
  "total_tasks": $TOTAL,
  "completed_tasks": $DONE,
  "current_phase": null,
  "last_verdict": null,
  "last_iteration_at": null,
  "halted": false,
  "halt_reason": null
}
EOF

echo "[init] state -> $STATE_DIR/checkpoint.json"
echo "[init] plan: $TOTAL tasks ($DONE complete, $((TOTAL - DONE)) remaining)"
echo "[init] namespace: $NAMESPACE"

# Seed memory namespace (best-effort; safe to fail if claude-flow not installed)
if command -v npx >/dev/null 2>&1; then
  npx -y @claude-flow/cli@latest memory store \
    --key "plan-meta-$PLAN_HASH" \
    --value "Plan: $(basename "$PLAN") | Tasks: $TOTAL | Initialized: $(date -u +%FT%TZ)" \
    --namespace "$NAMESPACE" 2>/dev/null || echo "[init] (memory seed skipped — claude-flow unavailable)"
fi

echo "[init] ready. next: /loop iterate the next phase of $PLAN"
