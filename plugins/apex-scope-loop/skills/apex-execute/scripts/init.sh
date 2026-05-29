#!/usr/bin/env bash
# init.sh — Initialize state, an isolated execution worktree, and the memory
# namespace for a dev plan.
#
# Execution is worktree-bound by contract: the WHOLE plan runs inside a single
# git worktree on a dedicated branch. Code never touches the base branch's
# working tree until the final gate passes and `land.sh` merges it back.
#
# Usage: ./init.sh path/to/plan.md
#
# Env:
#   APEX_BASE_BRANCH   Branch the worktree forks from and lands into.
#                      Default: main → master → current HEAD.
#   APEX_NO_WORKTREE=1 Escape hatch — skip worktree creation (NOT recommended;
#                      the orchestrator will then run in the base checkout).
set -euo pipefail

PLAN="${1:?usage: init.sh PATH_TO_PLAN.md}"
[[ -f "$PLAN" ]] || { echo "ERROR: plan not found: $PLAN" >&2; exit 1; }

PLAN_ABS="$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")"
PLAN_HASH="$(printf '%s' "$PLAN_ABS" | shasum -a 256 | cut -c1-12)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
NAMESPACE="apex-execute"

if [[ -z "$REPO_ROOT" ]]; then
  if [[ "${APEX_NO_WORKTREE:-0}" == "1" ]]; then
    REPO_ROOT="$(pwd)"
  else
    echo "ERROR: apex-execute runs the plan in a git worktree, but this is not a git repository." >&2
    echo "       Run inside a git repo, or set APEX_NO_WORKTREE=1 to opt out (not recommended)." >&2
    exit 1
  fi
fi

STATE_DIR="$REPO_ROOT/.dev-plan-state/$PLAN_HASH"
mkdir -p "$STATE_DIR"

# --- Resolve worktree branch + base branch -----------------------------------
SLUG="$(basename "$PLAN" .md)"; SLUG="${SLUG%-plan}"
WT_BRANCH="apex-scope-loop/${SLUG}"
WT_PATH="$STATE_DIR/worktree"

BASE_BRANCH="${APEX_BASE_BRANCH:-}"
if [[ -z "$BASE_BRANCH" ]]; then
  if git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/main; then
    BASE_BRANCH="main"
  elif git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/master; then
    BASE_BRANCH="master"
  else
    BASE_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  fi
fi

# --- Create (or reuse) the isolated execution worktree -----------------------
if [[ "${APEX_NO_WORKTREE:-0}" == "1" ]]; then
  WT_PATH=""
  WT_BRANCH=""
  echo "[init] WARNING: APEX_NO_WORKTREE=1 — execution will run in the base checkout."
elif git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $WT_PATH"; then
  echo "[init] reusing existing worktree: $WT_PATH (branch $WT_BRANCH)"
elif [[ -e "$WT_PATH" ]]; then
  echo "[init] reusing existing worktree dir: $WT_PATH"
elif git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$WT_BRANCH"; then
  git -C "$REPO_ROOT" worktree add "$WT_PATH" "$WT_BRANCH"
  echo "[init] worktree added on existing branch $WT_BRANCH -> $WT_PATH"
else
  git -C "$REPO_ROOT" worktree add -b "$WT_BRANCH" "$WT_PATH" "$BASE_BRANCH"
  echo "[init] worktree created: branch $WT_BRANCH (from $BASE_BRANCH) -> $WT_PATH"
fi

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
  "worktree_path": "$WT_PATH",
  "worktree_branch": "$WT_BRANCH",
  "base_branch": "$BASE_BRANCH",
  "landed": false,
  "last_verdict": null,
  "last_iteration_at": null,
  "halted": false,
  "halt_reason": null
}
EOF

echo "[init] state -> $STATE_DIR/checkpoint.json"
echo "[init] plan: $TOTAL tasks ($DONE complete, $((TOTAL - DONE)) remaining)"
echo "[init] namespace: $NAMESPACE"
if [[ -n "$WT_PATH" ]]; then
  echo "[init] worktree: $WT_PATH (branch $WT_BRANCH, base $BASE_BRANCH)"
  echo "[init] ALL phase work must happen inside the worktree above."
fi

# Seed memory namespace (best-effort; safe to fail if claude-flow not installed)
if command -v npx >/dev/null 2>&1; then
  npx -y @claude-flow/cli@latest memory store \
    --key "plan-meta-$PLAN_HASH" \
    --value "Plan: $(basename "$PLAN") | Tasks: $TOTAL | Worktree: ${WT_BRANCH:-none} | Initialized: $(date -u +%FT%TZ)" \
    --namespace "$NAMESPACE" 2>/dev/null || echo "[init] (memory seed skipped — claude-flow unavailable)"
fi

echo "[init] ready. next: /loop iterate the next phase of $PLAN"
