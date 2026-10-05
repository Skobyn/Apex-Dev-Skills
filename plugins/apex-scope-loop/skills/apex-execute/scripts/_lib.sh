# shellcheck shell=bash
# _lib.sh — shared path and state resolution for apex-execute scripts.
# Sourced, never executed.
#
# Two roots, never conflated (ADR-0003):
#   REPO_ROOT   the checkout the caller is working in: `git rev-parse
#               --show-toplevel` from $PWD, else $PWD. Every git operation
#               (worktree add, land's merge), the lessons ledger and the
#               checkout-local kill switches use it, exactly as in 0.2.0.
#   STATE_BASE  the directory holding plan state dirs, shared by the base
#               checkout, the plan worktree and every linked worktree:
#                 1. $APEX_STATE_ROOT/.dev-plan-state/<repo-id>  (explicit; moves
#                    state only; made absolute; <repo-id> keys the repository
#                    so one root can serve several repos without collisions)
#                 2. <main checkout>/.dev-plan-state    (common git dir is <repo>/.git)
#                 3. <git-common-dir>/apex-scope-loop-state (bare repos, submodules)
#                 4. $REPO_ROOT/.dev-plan-state         (not a git repository)
# Plan identity: in git, the plan's path relative to the toplevel of the
# checkout holding it (physical paths, symlinks resolved), so the same plan
# referenced from the base checkout, from the plan worktree or through a
# symlink resolves to one state dir. Outside git: the plan's absolute
# physical path. A 0.2.0 state dir (absolute-path hash under REPO_ROOT) is
# honoured when no 0.3.0 dir exists yet.

APEX_EXECUTE_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APEX_SCOPE_LOOP_PLUGIN_ROOT="$(cd "$APEX_EXECUTE_SCRIPTS/../../.." && pwd)"

apex_sha12() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -c1-12; }

# apex_state_base DIR — print the directory that holds plan state dirs for
# the repository containing DIR (the plan's directory).
apex_state_base() {
  local common root
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [[ -n "$common" ]] && common="$(cd "$common" && pwd -P)"
  if [[ -n "${APEX_STATE_ROOT:-}" ]]; then
    mkdir -p "$APEX_STATE_ROOT" && root="$(cd "$APEX_STATE_ROOT" && pwd -P)" || return 1
    printf '%s/.dev-plan-state/%s' "$root" "$(printf '%s' "${common:-$REPO_ROOT}" | apex_sha12)"
    return
  fi
  if [[ -z "$common" ]]; then
    printf '%s/.dev-plan-state' "$REPO_ROOT"
  elif [[ "$(basename "$common")" == ".git" ]]; then
    printf '%s/.dev-plan-state' "$(dirname "$common")"
  else
    printf '%s/apex-scope-loop-state' "$common"
  fi
}

# apex_resolve PLAN — set PLAN_ABS, PLAN_TOP, REPO_ROOT, STATE_BASE,
# PLAN_HASH, STATE_DIR and CHECKPOINT.
apex_resolve() {
  local plan="$1" plan_dir plan_top legacy legacy_dir main_root
  plan_dir="$(cd "$(dirname "$plan")" && pwd -P)"
  PLAN_ABS="$plan_dir/$(basename "$plan")"
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
  STATE_BASE="$(apex_state_base "$plan_dir")"
  plan_top="$(git -C "$plan_dir" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$plan_top" ]]; then
    plan_top="$(cd "$plan_top" && pwd -P)"
    PLAN_TOP="$plan_top"
    PLAN_HASH="$(printf '%s' "${PLAN_ABS#"$plan_top"/}" | apex_sha12)"
  else
    PLAN_TOP=""
    PLAN_HASH="$(printf '%s' "$PLAN_ABS" | apex_sha12)"
  fi
  STATE_DIR="$STATE_BASE/$PLAN_HASH"
  # 0.2.0 compatibility: a state dir keyed by the absolute (logical) plan path
  # under the caller's checkout, or, for the same plan referenced from a
  # worktree, the main checkout's copy of that path.
  if [[ ! -d "$STATE_DIR" ]]; then
    legacy="$(printf '%s' "$(cd "$(dirname "$plan")" && pwd)/$(basename "$plan")" | apex_sha12)"
    legacy_dir="$REPO_ROOT/.dev-plan-state/$legacy"
    if [[ ! -f "$legacy_dir/checkpoint.json" && -n "$plan_top" && "$(basename "$STATE_BASE")" == ".dev-plan-state" ]]; then
      main_root="$(dirname "$STATE_BASE")"
      legacy="$(printf '%s' "$main_root/${PLAN_ABS#"$plan_top"/}" | apex_sha12)"
      legacy_dir="$main_root/.dev-plan-state/$legacy"
    fi
    if [[ -f "$legacy_dir/checkpoint.json" ]]; then
      PLAN_HASH="$legacy"
      STATE_DIR="$legacy_dir"
    fi
  fi
  CHECKPOINT="$STATE_DIR/checkpoint.json"
}

# apex_halt_files — every kill-switch path: checkout-local and shared.
apex_halt_files() {
  printf '%s\n' "$REPO_ROOT/.dev-plan-state/HALT" "$STATE_BASE/HALT" "$STATE_DIR/HALT" "$REPO_ROOT/gibson/HALT" \
    | awk '!seen[$0]++'
}

# read_field KEY — a top-level checkpoint value as text ("" when absent or
# null). Callers read string fields only (worktree_path, worktree_branch,
# base_branch).
read_field() {
  python3 - "$CHECKPOINT" "$1" <<'PY' 2>/dev/null || true
import json, sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception:
    v = None
print("" if v is None else v, end="")
PY
}

# apex_common_dir DIR — the physical common git dir of DIR's repository ("" outside git).
apex_common_dir() {
  local c
  c="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [[ -n "$c" ]] && (cd "$c" && pwd -P)
  return 0
}
