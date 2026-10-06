#!/usr/bin/env bash
# apex-dispatch route.sh — the routing algorithm (spec §5.2), table-only plus
# the decision-layer seam. Prints a KEY: VALUE ROUTE block in iterate.sh style.
#
# Usage:
#   route.sh plan PLAN --line N [--base SHA] [--lanes L1,L2] [--dry-run]
#   route.sh adhoc --tags CSV [--paths GLOBS] [--acceptance CMD] [--dry-run]
#   route.sh escalate ROUTE_ID          next rung (checkpoint.sh fail prefixes ESCALATE_ROUTE:)
#   route.sh review-shape TIER          A solo | B six-lens | C six lenses + adversarial + G12
#   route.sh review-shape ROUTE_ID --tier TIER
#   route.sh --version                  == .claude-plugin/plugin.json version
#
# ROUTE_STATUS: READY | NEEDS_SPEC | HUMAN_GATE | HALTED | BUSY. Every status
# exits 0; an error (bad policy, unreadable plan) exits 1; usage exits 2.
# Without --dry-run a READY route is written to <state>/dispatch/active-route.json
# (atomic) and appended to <state>/dispatch/routes.jsonl (Phase 2.4's ledger.sh
# replaces that log). <state> is the plan's state dir, or <state-base>/adhoc/<id>.
#
# Environment:
#   APEX_DISPATCH_MODE=baseline  emit the 0.2.0 route; record what the table chose
#   APEX_DISPATCH_MODE=shadow    compute everything (decision layer included), log it, emit baseline
#   APEX_DISPATCH_MODE=off       print "ROUTE: none" and do nothing
#   APEX_DECIDE_CMD              decision CLI for fields still `auto` (absent: SEMANTIC_SOURCE=table)
#   APEX_HALT=1, HALT files      the same kill switches as apex-scope-loop (apex_halt_files)
#   APEX_SCOPE_LOOP_ROOT         the sibling apex-scope-loop (path resolution, ACTIVE lock, planlib)
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROUTE_PY="$PLUGIN_ROOT/scripts/lib/route.py"
usage() { sed -n '4,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "route: python3 is required" >&2; exit 1; }
py() { python3 -B "$ROUTE_PY" "$PLUGIN_ROOT" "$@"; }

[[ $# -ge 1 ]] || usage
SUB="$1"; shift
case "$SUB" in
  --version|version) py version; exit 0 ;;
  -h|--help) usage ;;
  plan|adhoc|escalate|review-shape) ;;
  *) echo "route: unknown subcommand $SUB" >&2; usage ;;
esac

if [[ "${APEX_DISPATCH_MODE:-}" == "off" && ( "$SUB" == plan || "$SUB" == adhoc ) ]]; then
  echo "ROUTE: none"
  echo "ROUTE_REASON: APEX_DISPATCH_MODE=off"
  exit 0
fi

# The sibling apex-scope-loop owns .dev-plan-state/, the kill switches and the
# ACTIVE lock (its ADR-0003); route.sh reuses its _lib.sh rather than a copy.
scope_loop_scripts() {
  local c
  for c in "${APEX_SCOPE_LOOP_ROOT:-}" "$PLUGIN_ROOT/../apex-scope-loop"; do
    [[ -n "$c" && -f "$c/skills/apex-execute/scripts/_lib.sh" ]] && { (cd "$c/skills/apex-execute/scripts" && pwd); return; }
  done
  for c in "$PLUGIN_ROOT"/../../apex-scope-loop/*/; do
    [[ -f "$c/skills/apex-execute/scripts/_lib.sh" ]] && { (cd "$c/skills/apex-execute/scripts" && pwd); return; }
  done
  return 0
}
EXEC_SCRIPTS="$(scope_loop_scripts)"
[[ -n "$EXEC_SCRIPTS" ]] || { echo "route: apex-scope-loop not found beside apex-dispatch (set APEX_SCOPE_LOOP_ROOT)" >&2; exit 1; }
# shellcheck source=/dev/null
source "$EXEC_SCRIPTS/_lib.sh"

# halt_reason — the first kill switch that is on, or nothing.
halt_reason() {
  local f
  if [[ "${APEX_HALT:-0}" == "1" ]]; then echo "APEX_HALT=1"; return; fi
  while IFS= read -r f; do
    [[ -f "$f" ]] && { echo "kill switch file present: $f"; return; }
  done < <(apex_halt_files)
  return 0
}

repo_state_base() {
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
  STATE_BASE="$(apex_state_base "$PWD")"
}

case "$SUB" in
  plan)
    PLAN="${1:-}"; [[ -n "$PLAN" && "$PLAN" != --* ]] || usage; shift
    LINE=""; BASE=""; LANES=""; DRY=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --line) LINE="${2:?--line needs a value}"; shift 2 ;;
        --base) BASE="${2:?--base needs a value}"; shift 2 ;;
        --lanes) LANES="${2:?--lanes needs a value}"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        *) echo "route: unknown argument $1" >&2; usage ;;
      esac
    done
    [[ "$LINE" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "route: --line must be a plan line number" >&2; exit 2; }
    [[ -f "$PLAN" ]] || { echo "route: plan not found: $PLAN" >&2; exit 1; }
    if [[ "$DRY" == 1 ]]; then APEX_RESOLVE_MODE=read; else APEX_RESOLVE_MODE=act; fi
    apex_resolve "$PLAN"
    HALTED="$(halt_reason)"
    if [[ -z "$HALTED" && -f "$CHECKPOINT" && "$(read_field halted)" == "True" ]]; then
      HALTED="checkpoint halted: $(read_field halt_reason)"
    fi
    BUSY=""
    if [[ -z "$HALTED" && "$DRY" == 0 ]]; then
      # iterate.sh already holds the lock for this plan; re-acquiring is a no-op
      # for the same plan and session, BUSY for anything else.
      RC=0; apex_lock_acquire "$PLAN_HASH" "$PLAN_ABS" "$LINE" BUILD plan || RC=$?
      if [[ "$RC" -eq 10 ]]; then BUSY="$(apex_lock_owner)"
      elif [[ "$RC" -ne 0 ]]; then echo "route: the ACTIVE lock under $STATE_BASE could not be used (exit $RC)" >&2; exit 1; fi
    fi
    WT="$( [[ -f "$CHECKPOINT" ]] && read_field worktree_path || true)"
    [[ -n "$WT" && -d "$WT" ]] || WT="${PLAN_TOP:-$REPO_ROOT}"
    ARGS=(--plan "$PLAN_ABS" --line "$LINE" --state "$STATE_DIR" --plan-hash "$PLAN_HASH" --exec-scripts "$EXEC_SCRIPTS"
          --checkpoint "$CHECKPOINT" --repo "$WT")
    [[ -n "$BASE" ]] && ARGS+=(--base "$BASE")
    [[ -n "$LANES" ]] && ARGS+=(--lanes "$LANES")
    [[ "$DRY" == 1 ]] && ARGS+=(--dry-run)
    [[ -n "$HALTED" ]] && ARGS+=(--halted "$HALTED")
    [[ -n "$BUSY" ]] && ARGS+=(--busy "$BUSY")
    py plan "${ARGS[@]}"
    ;;

  adhoc)
    TAGS=""; PATHS=""; ACC=""; DRY=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --tags) TAGS="${2:-}"; shift 2 || shift ;;
        --paths) PATHS="${2:?--paths needs a value}"; shift 2 ;;
        --acceptance) ACC="${2:?--acceptance needs a value}"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        *) echo "route: unknown argument $1 (ad-hoc asks take --tags, never free text)" >&2; exit 2 ;;
      esac
    done
    TAGS_N="$(printf '%s' "$TAGS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]' | grep -v '^$' | sort -u | paste -sd, - || true)"
    [[ -n "$TAGS_N" ]] || { echo "route: adhoc requires --tags <csv> (caller-supplied tags only, never free text)" >&2; exit 2; }
    for t in ${TAGS_N//,/ }; do
      [[ "$t" =~ ^[a-z0-9:@._+-]{1,40}$ ]] || { echo "route: adhoc --tags must be tag tokens [a-z0-9:@._+-], got '$t'" >&2; exit 2; }
    done
    repo_state_base
    ID="$(printf 'adhoc\n%s\n%s\n%s\n' "$TAGS_N" "$PATHS" "$ACC" | apex_sha12)"
    STATE_DIR="$STATE_BASE/adhoc/$ID"
    HALTED="$(halt_reason)"
    BUSY=""; LOCKED=0
    if [[ -z "$HALTED" && "$DRY" == 0 ]]; then
      RC=0; apex_lock_acquire "$ID" "adhoc:$TAGS_N" 0 BUILD adhoc || RC=$?
      if [[ "$RC" -eq 10 ]]; then BUSY="$(apex_lock_owner)"
      elif [[ "$RC" -ne 0 ]]; then echo "route: the ACTIVE lock under $STATE_BASE could not be used (exit $RC)" >&2; exit 1
      else LOCKED=1; fi
    fi
    ARGS=(--tags "$TAGS_N" --id "$ID" --state "$STATE_DIR" --repo "$REPO_ROOT" --exec-scripts "$EXEC_SCRIPTS")
    [[ -n "$PATHS" ]] && ARGS+=(--paths "$PATHS")
    [[ -n "$ACC" ]] && ARGS+=(--acceptance "$ACC")
    [[ "$DRY" == 1 ]] && ARGS+=(--dry-run)
    [[ -n "$HALTED" ]] && ARGS+=(--halted "$HALTED")
    [[ -n "$BUSY" ]] && ARGS+=(--busy "$BUSY")
    RC=0; OUT="$(py adhoc "${ARGS[@]}")" || RC=$?
    [[ -n "$OUT" ]] && printf '%s\n' "$OUT"
    # An ad-hoc ask that does not route (NEEDS_SPEC, HUMAN_GATE) does not keep the lock.
    if [[ "$LOCKED" == 1 ]] && ! grep -q '^ROUTE_STATUS: READY$' <<<"$OUT"; then apex_lock_release "$ID"; fi
    exit "$RC"
    ;;

  escalate)
    [[ $# -eq 1 ]] || usage
    repo_state_base
    py escalate "$1" --state-base "$STATE_BASE"
    ;;

  review-shape)
    [[ $# -ge 1 ]] || usage
    repo_state_base
    py review-shape "$@" --state-base "$STATE_BASE"
    ;;
esac
