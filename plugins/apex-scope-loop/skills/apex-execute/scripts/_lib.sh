# shellcheck shell=bash
# _lib.sh — shared path and state resolution for apex-execute scripts.
# Sourced, never executed. Callers set PLAN before sourcing.
#
# State root (ADR-0003): every script, hook and worktree must agree on one
# .dev-plan-state/. `git rev-parse --show-toplevel` returns the worktree's own
# root inside a worktree, so state is anchored on the *common* git dir instead:
#   1. $APEX_STATE_ROOT                         (explicit override)
#   2. parent of `git rev-parse --git-common-dir` (the main checkout)
#   3. `git rev-parse --show-toplevel`
#   4. $PWD
# Plan identity: the plan's path relative to the main checkout, so the same
# plan referenced from the base checkout or from a worktree resolves to the
# same state dir. A state dir created by 0.2.0 (hash of the absolute path) is
# still honoured when it exists.

APEX_EXECUTE_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APEX_SCOPE_LOOP_PLUGIN_ROOT="$(cd "$APEX_EXECUTE_SCRIPTS/../../.." && pwd)"

apex_sha12() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -c1-12; }

apex_repo_root() {
  if [[ -n "${APEX_STATE_ROOT:-}" ]]; then printf '%s' "$APEX_STATE_ROOT"; return; fi
  local d="${1:-$PWD}" common
  common="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -n "$common" && "$(basename "$common")" == ".git" ]]; then
    dirname "$common"; return
  fi
  git -C "$d" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$d"
}

# apex_resolve PLAN — sets PLAN_ABS, REPO_ROOT, PLAN_HASH, STATE_DIR, CHECKPOINT.
apex_resolve() {
  local plan="$1" plan_dir rel wt_top legacy
  plan_dir="$(cd "$(dirname "$plan")" && pwd)"
  PLAN_ABS="$plan_dir/$(basename "$plan")"
  REPO_ROOT="$(apex_repo_root "$plan_dir")"
  # Path of the plan relative to whichever checkout holds it.
  wt_top="$(git -C "$plan_dir" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$REPO_ROOT")"
  rel="${PLAN_ABS#"$wt_top"/}"
  PLAN_HASH="$(printf '%s' "$rel" | apex_sha12)"
  legacy="$(printf '%s' "$PLAN_ABS" | apex_sha12)"
  if [[ ! -d "$REPO_ROOT/.dev-plan-state/$PLAN_HASH" && -d "$REPO_ROOT/.dev-plan-state/$legacy" ]]; then
    PLAN_HASH="$legacy"
  fi
  STATE_DIR="$REPO_ROOT/.dev-plan-state/$PLAN_HASH"
  CHECKPOINT="$STATE_DIR/checkpoint.json"
}

# read_field KEY — first string value of KEY in the checkpoint.
read_field() { python3 - "$CHECKPOINT" "$1" <<'PY' 2>/dev/null || true
import json, sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception:
    v = None
print("" if v is None else v, end="")
PY
}

# apex_dispatch_root — the sibling apex-dispatch plugin, or empty.
apex_dispatch_root() {
  local c
  for c in "${APEX_DISPATCH_ROOT:-}" "$APEX_SCOPE_LOOP_PLUGIN_ROOT/../apex-dispatch"; do
    [[ -n "$c" && -x "$c/scripts/route.sh" ]] && { (cd "$c" && pwd); return; }
  done
  # Plugin cache layout: <cache>/<marketplace>/<plugin>/<version>/
  for c in "$APEX_SCOPE_LOOP_PLUGIN_ROOT"/../../apex-dispatch/*/; do
    [[ -x "$c/scripts/route.sh" ]] && { (cd "$c" && pwd); return; }
  done
  return 0
}
