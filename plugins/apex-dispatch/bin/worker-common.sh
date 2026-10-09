#!/usr/bin/env bash
# shellcheck shell=bash
# worker-common.sh — the shared library of apex-dispatch's provider shims
# (bin/worker-claude-p.sh, -codex, -grok, -opencode, -aider, -openai-sdk) and scripts/apply.sh. Sourced,
# never executed. Spec §5.4 (uniform worker contract), §5.3 H/I.
#
# It resolves the plugin root, the sibling apex-scope-loop and the run's state
# base exactly as the hooks do (apex_state_base: APEX_STATE_ROOT, else
# `git rev-parse --git-common-dir`, so the base checkout, the plan worktree and
# shim worktrees see one ACTIVE lock), checks the tools the engine needs, and
# hands over to scripts/lib/worker.py, which does the policy checks, builds the
# provider command from the merged policy only, confines and times the run,
# writes result.json and appends the ledger rows in-process.
#
#   apex_worker_main PROVIDER "$@"   — the shims
#   apex_worker_apply "$@"           — scripts/apply.sh
#
# Exit codes are worker.py's: 0 ok, 1 the run failed (result.json written),
# 2 usage, 3 refused (policy, route, stage, budget, no run), 4 provider
# unavailable (doctor.json, binary, auth), 5 confinement could not be set up.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "worker-common.sh is a library sourced by bin/worker-<provider>.sh and scripts/apply.sh; run those" >&2
  exit 2
fi

apex_worker_root() { (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); }

apex_worker_scope_loop_scripts() {
  # The highest installed version wins (scripts/lib/sibling.bash), never the first glob match.
  # shellcheck source=/dev/null
  source "$1/scripts/lib/sibling.bash"
  apex_scope_loop_scripts "$1"
}

# apex_worker_env — sets APEX_W_ROOT, APEX_W_SCRIPTS, APEX_W_STATE_BASE, APEX_W_REPO or exits.
apex_worker_env() {
  local t
  for t in python3 git timeout tar; do
    command -v "$t" >/dev/null 2>&1 || { echo "DISPATCH-REFUSED: unavailable: $t is required" >&2; exit 4; }
  done
  [[ "${APEX_DISPATCH_MODE:-}" != off ]] || { echo "DISPATCH-REFUSED: refused: APEX_DISPATCH_MODE=off (apex-dispatch is off; no worker runs)" >&2; exit 3; }
  APEX_W_ROOT="$(apex_worker_root)"
  APEX_W_SCRIPTS="$(apex_worker_scope_loop_scripts "$APEX_W_ROOT")"
  [[ -n "$APEX_W_SCRIPTS" ]] || { echo "DISPATCH-REFUSED: refused: apex-scope-loop >= 0.3.0 is not installed beside apex-dispatch (APEX_SCOPE_LOOP_ROOT)" >&2; exit 3; }
  # shellcheck source=/dev/null
  source "$APEX_W_SCRIPTS/_lib.sh" || { echo "DISPATCH-REFUSED: refused: cannot load apex-scope-loop's _lib.sh" >&2; exit 3; }
  REPO_ROOT="$PWD"                                  # apex_state_base's fallback outside git
  APEX_W_STATE_BASE="$(apex_state_base "$PWD" 2>/dev/null)" || APEX_W_STATE_BASE=""
  [[ -n "$APEX_W_STATE_BASE" && -d "$APEX_W_STATE_BASE/ACTIVE" ]] \
    || { echo "DISPATCH-REFUSED: refused: no ACTIVE run in this repository (route a task first: iterate.sh or route.sh)" >&2; exit 3; }
  APEX_W_REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
}

apex_worker_main() {
  local provider="$1"; shift
  apex_worker_env
  python3 -B "$APEX_W_ROOT/scripts/lib/worker.py" run "$provider" "$APEX_W_ROOT" "$APEX_W_STATE_BASE" "$APEX_W_SCRIPTS" "$APEX_W_REPO" -- "$@"
}

apex_worker_apply() {
  apex_worker_env
  python3 -B "$APEX_W_ROOT/scripts/lib/worker.py" apply "$APEX_W_ROOT" "$APEX_W_STATE_BASE" "$APEX_W_SCRIPTS" "$APEX_W_REPO" -- "$@"
}
