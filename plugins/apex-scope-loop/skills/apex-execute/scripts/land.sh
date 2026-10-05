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
# Order (ADR-0003): every precondition is checked before anything changes —
# repository identity (apex_guard), final gate, kill switches, the caller's
# checkout is the base checkout on the base branch with no tracked changes
# other than the plan file, and the green gate. Only then: flush (harness off
# or --force), record the plan file, merge the worktree's exact head SHA,
# remove the worktree, delete the branch only if fully merged.
#
# Exit codes:
#   0  — Landed; worktree branch merged into base and removed
#   1  — Not ready / merge precondition failed (message explains why)
#   2  — Bad args / not initialized
#   3  — Repository mismatch (apex_guard)
set -euo pipefail

PLAN="${1:?usage: land.sh PATH_TO_PLAN.md [--force]}"
FORCE="${2:-}"
[[ -f "$PLAN" ]] || { echo "ERROR: plan not found: $PLAN" >&2; exit 2; }

APEX_RESOLVE_MODE=act  # this script acts: a repository mismatch is fatal (never inherited from the env)
# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
apex_resolve "$PLAN"

[[ -f "$CHECKPOINT" ]] || { echo "ERROR: not initialized — run init.sh first" >&2; exit 2; }

WT_PATH="$(read_field worktree_path)"
WT_BRANCH="$(read_field worktree_branch)"
BASE_BRANCH="$(read_field base_branch)"

[[ -n "$WT_BRANCH" ]] || { echo "ERROR: no worktree branch recorded (APEX_NO_WORKTREE run?) — nothing to land." >&2; exit 1; }

# --- Preconditions (nothing is modified until all pass) ----------------------

# 1. Final gate: the plan must be fully checked unless --force.
if grep -qE '^- \[ \]' "$PLAN" && [[ "$FORCE" != "--force" ]]; then
  REMAINING=$(grep -cE '^- \[ \]' "$PLAN" || true)
  echo "ERROR: plan has $REMAINING unchecked task(s) — final gate not passed. Refusing to land." >&2
  echo "       Override (advanced): land.sh $PLAN --force" >&2
  exit 1
fi

# 2. Kill switches (harness on, no --force).
if [[ "${APEX_GIBSON:-1}" != "0" && "$FORCE" != "--force" ]]; then
  while IFS= read -r f; do
    [[ -f "$f" ]] && { echo "ERROR: kill switch present ($f) — refusing to land." >&2; exit 1; }
  done < <(apex_halt_files)
fi

# 3. The caller's checkout must be the base checkout, on the base branch.
#    Never merge in a checkout the caller is not in.
CURRENT="$(git -C "$REPO_ROOT" symbolic-ref -q --short HEAD 2>/dev/null || echo '')"
if [[ "$CURRENT" != "$BASE_BRANCH" ]]; then
  HOLDER="$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null \
    | awk -v b="branch refs/heads/$BASE_BRANCH" '/^worktree /{p=substr($0,10)} $0==b{print p; exit}')"
  echo "ERROR: this checkout ($REPO_ROOT) is on '${CURRENT:-detached HEAD}', expected the base branch '$BASE_BRANCH'." >&2
  if [[ -n "$HOLDER" ]]; then
    echo "       '$BASE_BRANCH' is checked out at $HOLDER — run land.sh from there." >&2
  else
    echo "       Switch with: git -C '$REPO_ROOT' checkout '$BASE_BRANCH'" >&2
  fi
  exit 1
fi

# 4. No tracked changes in the base checkout other than the plan file itself
#    (its checkboxes are flipped there) and the lessons ledger (append-only).
#    Unrelated work is never swept in.
PLAN_REL=""
REPO_ROOT_P="$(cd "$REPO_ROOT" && pwd -P)"
[[ "$PLAN_ABS" == "$REPO_ROOT_P"/* ]] && PLAN_REL="${PLAN_ABS#"$REPO_ROOT_P"/}"
LEDGER_REL=""
[[ "$LESSONS_LEDGER" == "$REPO_ROOT_P"/* ]] && LEDGER_REL="${LESSONS_LEDGER#"$REPO_ROOT_P"/}"
DIRTY=()
while IFS= read -r -d '' entry; do
  path="${entry:3}"
  # A rename/copy entry is followed by its source path as a separate record.
  case "${entry:0:1}" in R|C) IFS= read -r -d '' _ || true ;; esac
  [[ -n "$PLAN_REL" && "$path" == "$PLAN_REL" ]] && continue
  [[ -n "$LEDGER_REL" && "$path" == "$LEDGER_REL" ]] && continue
  DIRTY+=("$path")
done < <(git -C "$REPO_ROOT" status --porcelain -z --untracked-files=no)
if [[ ${#DIRTY[@]} -gt 0 ]]; then
  echo "ERROR: the base checkout has uncommitted tracked changes unrelated to this plan — commit or stash them first:" >&2
  printf '         %s\n' "${DIRTY[@]}" >&2
  exit 1
fi

# 5. The branch to merge is exactly what the worktree holds.
if [[ -d "$WT_PATH" ]]; then
  LAND_SHA="$(git -C "$WT_PATH" rev-parse HEAD)"
  BR_SHA="$(git -C "$REPO_ROOT" rev-parse -q --verify "refs/heads/$WT_BRANCH" || true)"
  [[ "$BR_SHA" == "$LAND_SHA" ]] || { echo "ERROR: refs/heads/$WT_BRANCH ($BR_SHA) is not the worktree head ($LAND_SHA) — refusing to land." >&2; exit 1; }
else
  LAND_SHA="$(git -C "$REPO_ROOT" rev-parse -q --verify "refs/heads/$WT_BRANCH" || true)"
  [[ -n "$LAND_SHA" ]] || { echo "ERROR: neither the worktree ($WT_PATH) nor branch $WT_BRANCH exists — nothing to land." >&2; exit 1; }
fi

# 6. Harness: unreviewed code never reaches the base branch.
if [[ "${APEX_GIBSON:-1}" != "0" && "$FORCE" != "--force" ]]; then
  if [[ -d "$WT_PATH" ]] && [[ -n "$(git -C "$WT_PATH" status --porcelain)" ]]; then
    echo "ERROR: worktree has uncommitted changes that no reviewer has seen — commit, gate, and review them first." >&2
    exit 1
  fi
  if ! "$APEX_EXECUTE_SCRIPTS/green-gate.sh" "$PLAN" check; then
    echo "ERROR: final green gate failed on the branch head — refusing to land." >&2
    exit 1
  fi
fi

# --- Mutations ------------------------------------------------------------------

# 7. Flush uncommitted worktree changes (reachable only with the harness off or --force).
if [[ -d "$WT_PATH" ]] && [[ -n "$(git -C "$WT_PATH" status --porcelain)" ]]; then
  git -C "$WT_PATH" add -A
  git -C "$WT_PATH" commit -m "apex-scope-loop: flush working changes before landing $WT_BRANCH"
  LAND_SHA="$(git -C "$WT_PATH" rev-parse HEAD)"
  echo "[land] committed pending worktree changes."
fi

# 8. Record the plan's progress on the base branch (plan file and lessons ledger only).
RECORD=()
for rel in "$PLAN_REL" "$LEDGER_REL"; do
  [[ -n "$rel" ]] && [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no -- "$rel")" ]] && RECORD+=("$rel")
done
if [[ ${#RECORD[@]} -gt 0 ]]; then
  git -C "$REPO_ROOT" commit -m "apex-scope-loop: record plan completion for $WT_BRANCH" -- "${RECORD[@]}"
fi

# 9. Merge the worktree's exact head.
echo "[land] merging $WT_BRANCH (${LAND_SHA:0:12}) into $BASE_BRANCH ..."
if ! git -C "$REPO_ROOT" merge --no-ff "$LAND_SHA" -m "apex-scope-loop: merge $WT_BRANCH into $BASE_BRANCH (final gate passed)"; then
  echo "ERROR: merge hit conflicts. Resolve in $REPO_ROOT, commit, then re-run land.sh." >&2
  exit 1
fi

# 10. Tear down the worktree; delete the branch only if it is fully merged.
if [[ -d "$WT_PATH" ]]; then
  if git -C "$REPO_ROOT" worktree remove "$WT_PATH"; then
    echo "[land] removed worktree $WT_PATH"
  else
    echo "[land] WARNING: could not remove worktree $WT_PATH (left in place)" >&2
  fi
fi
git -C "$REPO_ROOT" branch -d "$WT_BRANCH" 2>/dev/null \
  || echo "[land] WARNING: branch $WT_BRANCH not deleted (not fully merged, or still checked out)" >&2

# 11. Mark landed in checkpoint.
python3 - "$CHECKPOINT" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f: s = json.load(f)
s["landed"] = True
with open(p, "w") as f: json.dump(s, f, indent=2)
PY

echo "[land] DONE — $WT_BRANCH merged into $BASE_BRANCH and worktree removed."
