#!/usr/bin/env bash
# land.sh — Merge the plan's execution worktree into the base branch after the
# final gate has passed, then tear the worktree down.
#
# This is the ONLY step that touches the base branch. Until every task in the
# plan is checked (the final gate), code stays isolated on the worktree branch.
#
# Usage:
#   ./land.sh path/to/plan.md            # land only if the plan is complete
#   ./land.sh path/to/plan.md --force    # land even with unchecked tasks
#
# Exit codes:
#   0  — Landed; worktree branch merged into base and removed
#   1  — Not ready / merge precondition failed (message explains why)
#   2  — Bad args / not initialized
set -euo pipefail

PLAN="${1:?usage: land.sh PATH_TO_PLAN.md [--force]}"
FORCE="${2:-}"
[[ -f "$PLAN" ]] || { echo "ERROR: plan not found: $PLAN" >&2; exit 2; }

PLAN_ABS="$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")"
PLAN_HASH="$(printf '%s' "$PLAN_ABS" | shasum -a 256 | cut -c1-12)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="$REPO_ROOT/.dev-plan-state/$PLAN_HASH"
CHECKPOINT="$STATE_DIR/checkpoint.json"

[[ -f "$CHECKPOINT" ]] || { echo "ERROR: not initialized — run init.sh first" >&2; exit 2; }

read_field() { grep -o "\"$1\": \"[^\"]*\"" "$CHECKPOINT" | head -1 | sed 's/.*: "//; s/"$//'; }
WT_PATH="$(read_field worktree_path)"
WT_BRANCH="$(read_field worktree_branch)"
BASE_BRANCH="$(read_field base_branch)"

[[ -n "$WT_BRANCH" ]] || { echo "ERROR: no worktree branch recorded (APEX_NO_WORKTREE run?) — nothing to land." >&2; exit 1; }

# 1. Final-gate guard: the plan must be fully checked unless --force.
if grep -qE '^- \[ \]' "$PLAN" && [[ "$FORCE" != "--force" ]]; then
  REMAINING=$(grep -cE '^- \[ \]' "$PLAN" || true)
  echo "ERROR: plan has $REMAINING unchecked task(s) — final gate not passed. Refusing to land." >&2
  echo "       Override (advanced): land.sh $PLAN --force" >&2
  exit 1
fi

# 2. Flush any uncommitted code in the worktree onto the worktree branch.
if [[ -d "$WT_PATH" ]] && [[ -n "$(git -C "$WT_PATH" status --porcelain)" ]]; then
  git -C "$WT_PATH" add -A
  git -C "$WT_PATH" commit -m "apex-scope-loop: flush working changes before landing $WT_BRANCH"
  echo "[land] committed pending worktree changes."
fi

# 3. Base checkout must be on the base branch.
CURRENT="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
if [[ "$CURRENT" != "$BASE_BRANCH" ]]; then
  echo "ERROR: base checkout is on '$CURRENT', expected '$BASE_BRANCH'." >&2
  echo "       Switch with: git -C $REPO_ROOT checkout $BASE_BRANCH" >&2
  exit 1
fi

# 4. Record plan/ADR progress on the base branch (best-effort) so the merge is clean.
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]]; then
  git -C "$REPO_ROOT" commit -am "apex-scope-loop: record plan completion for $WT_BRANCH" || true
fi

# 5. Merge the worktree branch into the base branch.
echo "[land] merging $WT_BRANCH into $BASE_BRANCH ..."
if ! git -C "$REPO_ROOT" merge --no-ff "$WT_BRANCH" -m "apex-scope-loop: merge $WT_BRANCH into $BASE_BRANCH (final gate passed)"; then
  echo "ERROR: merge hit conflicts. Resolve in $REPO_ROOT, commit, then re-run land.sh." >&2
  exit 1
fi

# 6. Tear down the worktree and delete the now-merged branch.
if [[ -d "$WT_PATH" ]]; then
  git -C "$REPO_ROOT" worktree remove "$WT_PATH" --force
  echo "[land] removed worktree $WT_PATH"
fi
git -C "$REPO_ROOT" branch -d "$WT_BRANCH" 2>/dev/null \
  || git -C "$REPO_ROOT" branch -D "$WT_BRANCH" 2>/dev/null || true

# 7. Mark landed in checkpoint.
python3 - "$CHECKPOINT" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f: s = json.load(f)
s["landed"] = True
with open(p, "w") as f: json.dump(s, f, indent=2)
PY

echo "[land] DONE — $WT_BRANCH merged into $BASE_BRANCH and worktree removed."
