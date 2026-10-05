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
# other than the plan file, the dispatch ledger (when apex-dispatch state
# exists), and the green gate. Only then: flush (harness off
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
#    Same rules as iterate.sh: an invalid plan is never landed, and "done" is
#    planlib's count. Anything unexpected refuses (fail closed); --force does
#    not bypass an invalid plan.
if ! PLAN_ERRORS="$(python3 "$APEX_EXECUTE_SCRIPTS/planlib.py" validate "$PLAN_ABS" 2>&1)"; then
  echo "ERROR: plan is invalid — refusing to land:" >&2
  printf '%s\n' "$PLAN_ERRORS" | head -10 | sed 's/^/         /' >&2
  exit 1
fi
REMAINING="$(python3 "$APEX_EXECUTE_SCRIPTS/planlib.py" remaining "$PLAN_ABS" 2>/dev/null || true)"
[[ "$REMAINING" =~ ^[0-9]+$ ]] || { echo "ERROR: could not count the plan's remaining tasks — refusing to land." >&2; exit 1; }
if [[ "$REMAINING" -gt 0 ]] && [[ "$FORCE" != "--force" ]]; then
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
# Only a ledger inside the plugin's own directory may ride along (an
# APEX_LESSONS_FILE pointing at a source file is not exempted).
[[ "$LEDGER_REL" == .claude/apex-scope-loop/* ]] || LEDGER_REL=""
DIRTY=()
exempt() { [[ -n "$1" && ( "$1" == "$PLAN_REL" || "$1" == "$LEDGER_REL" ) ]]; }
while IFS= read -r -d '' entry; do
  xy="${entry:0:2}"; path="${entry:3}"; src=""
  # A rename/copy (either column) is followed by its source path as its own record.
  [[ "$xy" == *[RC]* ]] && { IFS= read -r -d '' src || true; }
  # A rename is exempt only if both ends are exempt and it is the same file.
  if exempt "$path" && { [[ -z "$src" ]] || [[ "$src" == "$path" ]]; }; then continue; fi
  DIRTY+=("$path${src:+ (from $src)}")
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

# 5b. apex-dispatch: with dispatch state, the ledger's hash chain must verify
#     (ledger.sh verify). Per-task route evidence was already required when each
#     task was checked off (checkpoint.sh complete → ledger.sh evidence, which
#     neither APEX_GIBSON=0 nor --skip-review waives); a verified chain means
#     those rows were not rewritten since.
DISPATCH_STATE="$STATE_DIR/dispatch"
DISPATCH="$(apex_dispatch_root)"
if [[ -d "$DISPATCH_STATE" ]]; then   # --force does not bypass the ledger
  [[ -n "$DISPATCH" ]] || { echo "ERROR: dispatch state exists ($DISPATCH_STATE) but apex-dispatch is not installed beside apex-scope-loop — refusing to land." >&2; exit 1; }
  "$DISPATCH/scripts/ledger.sh" verify --state "$STATE_DIR" \
    || { echo "ERROR: the dispatch ledger does not verify (ledger.sh verify) — refusing to land." >&2; exit 1; }
fi

# 6. Harness: unreviewed code never reaches the base branch.
if [[ "${APEX_GIBSON:-1}" != "0" && "$FORCE" != "--force" ]]; then
  if [[ -d "$WT_PATH" ]] && [[ -n "$(git -C "$WT_PATH" status --porcelain)" ]]; then
    echo "ERROR: worktree has uncommitted changes that no reviewer has seen — commit, gate, and review them first." >&2
    exit 1
  fi
  # Every landed commit was verified by a reviewed `complete` (the chain):
  # nothing may follow the last completion's head.
  LAND_FLOOR="$(apex_floor "$REPO_ROOT" "$LAND_SHA" || true)"
  if [[ -z "$LAND_FLOOR" ]]; then
    echo "ERROR: this run predates the review chain (no fork point recorded) — land.sh cannot show every commit was reviewed." >&2
    echo "       Re-run iterate.sh once (it records the fork point), or after checking the branch yourself: land.sh $PLAN --force" >&2
    exit 1
  fi
  if ! git -C "$REPO_ROOT" diff --quiet --no-renames --ignore-submodules=none "$LAND_FLOOR" "$LAND_SHA" 2>/dev/null; then
    echo "ERROR: ${WT_BRANCH} has commits after the last reviewed completion (${LAND_FLOOR:0:12}..${LAND_SHA:0:12}) — review and complete them as a task first." >&2
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
    # A surviving worktree must not be adopted by a later run as if it were
    # new, so the run is not marked landed until it is gone.
    echo "ERROR: merged, but could not remove the worktree $WT_PATH (locked, or it has submodules)." >&2
    echo "       Remove it (git worktree remove --force '$WT_PATH'), then re-run land.sh to finish." >&2
    exit 1
  fi
fi
git -C "$REPO_ROOT" branch -d "$WT_BRANCH" 2>/dev/null \
  || echo "[land] WARNING: branch $WT_BRANCH not deleted (not fully merged, or still checked out)" >&2

# 11. Mark landed in checkpoint.
python3 - "$CHECKPOINT" "$STATE_DIR/.checkpoint.lock" <<'PY'
import fcntl, json, os, sys
p, lock = sys.argv[1:]
fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)          # checkpoint.sh's state lock
with open(p) as f: s = json.load(f)
s["landed"] = True
tmp = p + ".tmp"
try:
    os.unlink(tmp)
except FileNotFoundError:
    pass
with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o644), "w") as f:
    json.dump(s, f, indent=2)
os.replace(tmp, p)
PY

apex_lock_release "$PLAN_HASH"
if [[ -d "$DISPATCH_STATE" && -n "$DISPATCH" ]]; then
  "$DISPATCH/scripts/ledger.sh" export --state "$STATE_DIR" --plan "$PLAN_ABS" \
    || echo "[land] WARNING: ledger export failed (the landing itself succeeded)" >&2
  [[ -x "$DISPATCH/scripts/report.sh" ]] && { "$DISPATCH/scripts/report.sh" --plan "$PLAN_ABS" --state "$STATE_DIR" || true; }
fi
echo "[land] DONE — $WT_BRANCH merged into $BASE_BRANCH and worktree removed."
