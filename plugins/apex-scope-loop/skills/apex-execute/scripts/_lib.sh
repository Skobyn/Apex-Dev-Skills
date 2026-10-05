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
# PLAN_HASH, STATE_DIR and CHECKPOINT, then run apex_guard (fatal on a
# repository mismatch unless the caller declared APEX_RESOLVE_MODE=read).
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
    # Never adopt a state dir from the caller's checkout for another repo's plan.
    [[ "$(apex_common_dir "$REPO_ROOT")" == "$(apex_common_dir "$plan_dir")" ]] || legacy_dir="/nonexistent"
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
  apex_guard
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

# apex_die MSG — fail with MSG. Scripts that speak the iterate.sh brief
# protocol set APEX_STATUS_PROTOCOL=1 to also get a STATUS: ERROR line.
apex_die() {
  [[ "${APEX_STATUS_PROTOCOL:-0}" == "1" ]] && echo "STATUS: ERROR $1"
  echo "ERROR: $1" >&2
  exit 3
}

# apex_guard — one repository, proven (ADR-0003). State is keyed on the
# plan's repository; git actions run in the caller's checkout and in the
# checkpoint's worktree. Before any script acts, all four must name the same
# repository (physical common git dirs):
#   C  the caller's checkout            P  the plan's checkout
#   K  checkpoint git_common_dir        W  the recorded worktree, if present
# (a 0.2.0 checkpoint has no K; W stands in for it). The recorded worktree
# must also have the recorded branch checked out, and a recorded branch with
# no recorded worktree path is corruption. APEX_RESOLVE_MODE=read (status,
# audit, architecture review) turns a failure into a warning; nothing
# overrides it in act mode, APEX_INIT_FORCE included.
apex_guard() {
  local mode="${APEX_RESOLVE_MODE:-act}" c p k="" w="" wt="" br="" problems=() head
  c="$(apex_common_dir "$REPO_ROOT")"
  p="$( [[ -n "$PLAN_TOP" ]] && apex_common_dir "$PLAN_TOP" || true)"
  if [[ -f "$CHECKPOINT" ]]; then
    k="$(read_field git_common_dir)"
    wt="$(read_field worktree_path)"
    br="$(read_field worktree_branch)"
    [[ -n "$wt" && -d "$wt" ]] && w="$(apex_common_dir "$wt")"
  fi
  if [[ -n "$p" && -z "$c" && "$mode" == "act" ]]; then
    problems+=("the plan is in a git repository but this directory is not; run from a checkout of $p")
  fi
  local name val ref=""
  for name in c p k w; do
    val="${!name}"
    [[ -z "$val" ]] && continue
    if [[ -z "$ref" ]]; then ref="$val"; continue; fi
    if [[ "$val" != "$ref" ]]; then
      problems+=("repository mismatch: caller=${c:--} plan=${p:--} checkpoint=${k:--} worktree=${w:--}")
      break
    fi
  done
  if [[ -n "$br" && -z "$wt" ]]; then
    problems+=("checkpoint records branch '$br' but no worktree path (corrupt checkpoint)")
  elif [[ -n "$br" && -n "$w" ]]; then
    head="$(git -C "$wt" symbolic-ref -q HEAD 2>/dev/null || true)"
    [[ "$head" == "refs/heads/$br" ]] || problems+=("worktree $wt has '${head:-detached HEAD}' checked out, expected refs/heads/$br")
  fi
  [[ ${#problems[@]} -eq 0 ]] && return 0
  if [[ "$mode" == "read" ]]; then
    printf 'WARNING: %s\n' "${problems[@]}" >&2
    return 0
  fi
  apex_die "$(printf '%s; ' "${problems[@]}")refusing to act"
}
