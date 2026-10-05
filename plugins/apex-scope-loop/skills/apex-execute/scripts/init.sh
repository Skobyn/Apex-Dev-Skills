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

# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
apex_resolve "$PLAN"
NAMESPACE="apex-execute"

if ! git rev-parse --git-dir >/dev/null 2>&1 && [[ "${APEX_NO_WORKTREE:-0}" != "1" ]]; then
  echo "ERROR: apex-execute runs the plan in a git worktree, but this is not a git repository." >&2
  echo "       Run inside a git repo, or set APEX_NO_WORKTREE=1 to opt out (not recommended)." >&2
  exit 1
fi

# The caller's checkout and the plan must belong to one repository: state is
# keyed on the plan's repo, git operations run in the caller's.
CALLER_COMMON="$(apex_common_dir "$REPO_ROOT")"
PLAN_COMMON="$( [[ -n "$PLAN_TOP" ]] && apex_common_dir "$PLAN_TOP" || true)"
if [[ -n "$CALLER_COMMON" && -n "$PLAN_COMMON" && "$CALLER_COMMON" != "$PLAN_COMMON" ]]; then
  echo "ERROR: the plan lives in a different repository than this checkout." >&2
  echo "       plan repo: $PLAN_COMMON   this checkout: $CALLER_COMMON" >&2
  echo "       Run init.sh from a checkout of the plan's repository." >&2
  exit 1
fi

mkdir -p "$STATE_DIR"

# --- Resolve worktree branch + base branch -----------------------------------
SLUG="$(basename "$PLAN" .md)"; SLUG="${SLUG%-plan}"
WT_BRANCH="apex-scope-loop/${SLUG}"
WT_PATH="$STATE_DIR/worktree"

BASE_BRANCH="${APEX_BASE_BRANCH:-}"
if [[ -z "$BASE_BRANCH" ]]; then
  if git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/main 2>/dev/null; then
    BASE_BRANCH="main"
  elif git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/master 2>/dev/null; then
    BASE_BRANCH="master"
  else
    BASE_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  fi
fi

# --- An existing plan run is never silently taken over -----------------------
# State is shared by every checkout of the repository, so a second init for the
# same plan from another checkout would otherwise retarget the run (and reset
# its reviews, approvals and error budget). Same base and repository: re-init
# keeps the run's reviews, approvals and counters (and recreates a missing
# worktree). Different base or repository: refuse. A landed run, or
# APEX_INIT_FORCE=1, starts over.
KEEP_RUN=0
if [[ -f "$CHECKPOINT" && "${APEX_INIT_FORCE:-0}" != "1" && "$(read_field landed)" != "True" ]]; then
  PREV_BASE="$(read_field base_branch)"
  PREV_COMMON="$(read_field git_common_dir)"
  if [[ "$PREV_BASE" != "$BASE_BRANCH" || ( -n "$PREV_COMMON" && "$PREV_COMMON" != "$CALLER_COMMON" ) ]]; then
    echo "ERROR: this plan is already initialized against base '$PREV_BASE'${PREV_COMMON:+ in $PREV_COMMON}." >&2
    echo "       Refusing to retarget it to '$BASE_BRANCH'${CALLER_COMMON:+ in $CALLER_COMMON}." >&2
    echo "       Land or abandon that run first, or set APEX_INIT_FORCE=1 to start over (discards its reviews and approvals)." >&2
    exit 1
  fi
  KEEP_RUN=1
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

# Written with json.dump so paths containing quotes or backslashes stay valid.
python3 - "$CHECKPOINT" "$PLAN_ABS" "$PLAN_HASH" "$NAMESPACE" "$TOTAL" "$DONE" "$WT_PATH" "$WT_BRANCH" "$BASE_BRANCH" \
  "$([[ "${APEX_GIBSON:-1}" == "0" ]] && echo off || echo gibson)" "$CALLER_COMMON" "$KEEP_RUN" <<'PY'
import datetime, json, os, sys
path, plan, h, ns, total, done, wt, br, base, harness, common, keep = sys.argv[1:]
prev = {}
if keep == "1" and os.path.isfile(path):
    prev = json.load(open(path))
fresh = {
    "plan_path": plan, "plan_hash": h, "namespace": ns,
    "initialized_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "total_tasks": int(total), "completed_tasks": int(done), "current_phase": None,
    "worktree_path": wt, "worktree_branch": br, "base_branch": base, "git_common_dir": common, "landed": False,
    "harness": harness, "consecutive_failures": 0, "tiers": {}, "reviews": {}, "approvals": {},
    "last_verdict": None, "last_iteration_at": None, "halted": False, "halt_reason": None,
}
# Structural fields always come from this init; run history survives a re-init.
structural = ("plan_path", "plan_hash", "namespace", "total_tasks", "completed_tasks",
              "worktree_path", "worktree_branch", "base_branch", "git_common_dir", "harness")
out = dict(fresh)
for k, v in prev.items():
    if k not in structural:
        out[k] = v
json.dump(out, open(path, "w"), indent=2)
PY

echo "[init] state -> $STATE_DIR/checkpoint.json"
echo "[init] plan: $TOTAL tasks ($DONE complete, $((TOTAL - DONE)) remaining)"
echo "[init] namespace: $NAMESPACE"
if [[ -n "$WT_PATH" ]]; then
  echo "[init] worktree: $WT_PATH (branch $WT_BRANCH, base $BASE_BRANCH)"
  echo "[init] ALL phase work must happen inside the worktree above."
fi

# Record the green-gate baseline at the fork point (Gibson Law 4: zero NEW
# failures vs. the branch point). Pre-existing red is recorded, never inherited.
if [[ "${APEX_GIBSON:-1}" != "0" ]]; then
  if [[ -f "$STATE_DIR/gate/baseline.json" ]]; then
    echo "[init] green-gate baseline already recorded (kept) -> $STATE_DIR/gate/baseline.json"
  else
    echo "[init] recording green-gate baseline (generate → typecheck → lint → test → build) ..."
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/green-gate.sh" "$PLAN" baseline | sed 's/^/[init]   /' \
      || echo "[init] WARNING: baseline capture failed — the gate will run in strict mode (any red step fails)"
  fi
fi

# Seed the memory namespace — optional (ADR-0003). APEX_MEMORY_CMD is any
# command that stores one record; it receives APEX_MEMORY_NAMESPACE,
# APEX_MEMORY_KEY and APEX_MEMORY_VALUE in its environment. Unset = skip
# quietly. ruflo example:
#   APEX_MEMORY_CMD='npx -y @claude-flow/cli@latest memory store --namespace "$APEX_MEMORY_NAMESPACE" --key "$APEX_MEMORY_KEY" --value "$APEX_MEMORY_VALUE"'
if [[ -n "${APEX_MEMORY_CMD:-}" ]]; then
  APEX_MEMORY_NAMESPACE="$NAMESPACE" \
  APEX_MEMORY_KEY="plan-meta-$PLAN_HASH" \
  APEX_MEMORY_VALUE="Plan: $(basename "$PLAN") | Tasks: $TOTAL | Worktree: ${WT_BRANCH:-none} | Initialized: $(date -u +%FT%TZ)" \
    bash -c "$APEX_MEMORY_CMD" >/dev/null 2>&1 || echo "[init] (memory seed failed — APEX_MEMORY_CMD returned non-zero; continuing)"
fi

[[ "${APEX_GIBSON:-1}" != "0" ]] && echo "[init] harness: gibson (green gate · independent review · Tier-C G12 · kill switch · ratchet). APEX_GIBSON=0 to disable."
echo "[init] ready. next: /loop iterate the next phase of $PLAN"
