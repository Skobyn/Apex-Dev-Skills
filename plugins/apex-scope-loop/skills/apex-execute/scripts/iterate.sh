#!/usr/bin/env bash
# iterate.sh — Find next task and emit a swarm dispatch brief for the model.
# This script is intentionally NON-EXECUTING — it produces a structured
# briefing the orchestrator (the model running /loop) reads, then spawns
# the swarm via the Agent tool in ONE message.
#
# Usage: ./iterate.sh path/to/plan.md
#
# Task selection (ADR-0003): the first unchecked task whose Blocked-by
# references are all checked (planlib.py is the one plan parser). A reference
# that names no task in the plan blocks (fail closed). One plan or ad-hoc
# route is active per repository (ACTIVE lock); another owner gives BUSY.
#
# Emits to stdout (machine-readable):
#   STATE: <state-dir>
#   WORKTREE: <abs-path>      # cwd the swarm MUST operate in (empty if opted out)
#   BRANCH: <worktree-branch>
#   PHASE: <phase-id>
#   TAGS: <comma-separated>
#   TASK: <task-line>
#   ACCEPTANCE: <criteria-line>
#   BLOCKED_BY: <phase-or-empty>
#   HEAD_SHA: <worktree HEAD at brief time>
#   TASK_BASE: <the task's diff base: the chain floor (ADR-0003); "none" when
#              no fork point is recorded — risk-tier and complete then refuse>
#   HARNESS: gibson | off                # APEX_GIBSON=0 turns the harness off
#   LESSONS: <n> matching ...           # ratchet entries for this task's tags
#   CONSECUTIVE_FAILURES: <n>
#   SWARM / ROUTE_DIRECTIVE / PATHS / BUDGET: the task's directives (0.3.0)
#   STAGE: BUILD                          # recorded in the ACTIVE lock
#   LANES: <line,line,...>                # optional; disjoint-Paths lane candidates
#   ROUTE_* block from apex-dispatch route.sh, or "ROUTE: none"
#   STATUS: READY | BLOCKED | COMPLETE | HALTED | BUSY | NEEDS_SPEC | HUMAN_GATE
#
# Kill switch (adapted from The Gibson): the loop halts immediately, before
# any dispatch, if APEX_HALT=1 or any of these files exist:
#   <checkout>/.dev-plan-state/HALT  and  <state-base>/HALT   (all plans)
#   <state-dir>/HALT                 (this plan)
#   <repo>/gibson/HALT               (a Gibson-wired repo's permanent stop)
set -euo pipefail

PLAN="${1:?usage: iterate.sh PATH_TO_PLAN.md}"
[[ -f "$PLAN" ]] || { echo "STATUS: ERROR plan not found"; exit 1; }

APEX_STATUS_PROTOCOL=1
APEX_RESOLVE_MODE=act  # this script acts: a repository mismatch is fatal (never inherited from the env)
# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
apex_resolve "$PLAN"

[[ -f "$CHECKPOINT" ]] || { echo "STATUS: ERROR not initialized — run init.sh first"; exit 1; }

# Worktree the plan is bound to (recorded by init.sh).
WORKTREE="$(read_field worktree_path)"
WT_BRANCH="$(read_field worktree_branch)"

# Kill switch — checked every iteration, before anything else is dispatched.
while IFS= read -r f; do
  if [[ -f "$f" ]]; then
    echo "STATE: $STATE_DIR"
    echo "STATUS: HALTED"
    echo "HALT_REASON: kill switch file present: $f (delete it to resume)"
    exit 0
  fi
done < <(apex_halt_files)
if [[ "${APEX_HALT:-0}" == "1" ]]; then
  echo "STATE: $STATE_DIR"
  echo "STATUS: HALTED"
  echo "HALT_REASON: APEX_HALT=1"
  exit 0
fi

# Enforce worktree-bound execution: if a worktree was recorded, it must exist.
if [[ -n "$WORKTREE" && ! -d "$WORKTREE" ]]; then
  echo "STATE: $STATE_DIR"
  echo "STATUS: ERROR worktree missing at $WORKTREE — re-run init.sh to recreate it"
  exit 1
fi

# Halted?
if [[ "$(read_field halted)" == "True" ]]; then
  echo "STATE: $STATE_DIR"
  echo "STATUS: HALTED"
  echo "HALT_REASON: $(read_field halt_reason)"
  exit 0
fi

# A plan that fails validation is never iterated (fail closed): a stray
# directive, an unclosed code fence or an unknown Blocked-by could otherwise
# change which task runs.
if ! PLAN_ERRORS="$(python3 "$APEX_EXECUTE_SCRIPTS/planlib.py" validate "$PLAN_ABS" 2>&1)"; then
  echo "STATE: $STATE_DIR"
  printf '%s\n' "$PLAN_ERRORS" | head -10 | sed 's/^/PLAN_ERROR: /'
  echo "STATUS: ERROR plan is invalid — fix the PLAN_ERROR lines (planlib.py validate) and re-run"
  exit 1
fi

# Next unchecked, unblocked task (planlib.py is the one plan parser).
SEL="$(python3 "$APEX_EXECUTE_SCRIPTS/planlib.py" next "$PLAN_ABS")" \
  || { echo "STATE: $STATE_DIR"; echo "STATUS: ERROR plan could not be parsed"; exit 1; }
field() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); exec("v="+sys.argv[2]); print("" if v is None else (",".join(map(str,v)) if isinstance(v,list) else v))' "$SEL" "$1"; }
SEL_STATUS="$(field 'd["status"]')"
if [[ "$SEL_STATUS" == "ERROR" ]]; then
  echo "STATE: $STATE_DIR"
  echo "STATUS: ERROR $(field 'd["error"]')"
  exit 1
fi

if [[ "$SEL_STATUS" == "COMPLETE" ]]; then
  echo "STATE: $STATE_DIR"
  echo "WORKTREE: $WORKTREE"
  echo "BRANCH: $WT_BRANCH"
  echo "STATUS: COMPLETE"
  echo "NEXT: final gate passed — land the worktree with land.sh $PLAN_ABS"
  touch "$STATE_DIR/COMPLETE"
  exit 0
fi

# Unreachable for a plan that passed validate (an all-blocked plan needs a
# cycle or an unknown reference); kept as a fail-closed guard.
if [[ "$SEL_STATUS" == "BLOCKED" ]]; then
  echo "STATE: $STATE_DIR"
  echo "STATUS: BLOCKED"
  python3 -c '
import json, sys
for b in json.loads(sys.argv[1])["blocked"]:
    why = ", ".join(b["open"]) or "-"
    unk = (" unknown: " + ", ".join(b["unknown"])) if b["unknown"] else ""
    print("BLOCKED_BY: line %s %s waits on %s%s" % (b["line_no"], b["id"] or "(no id)", why, unk))' "$SEL"
  exit 0
fi

LINE_NO="$(field 'd["task"]["line_no"]')"
TASK_LINE="$(field 'd["task"]["line"]')"
PHASE_ID="$(field 'd["task"]["id"] or "phase-unknown"')"
TAGS="$(field 'd["task"]["tags"]')"
ACCEPTANCE="$(field 'd["task"]["acceptance"]')"
BLOCKED_BY="$(field 'd["task"]["blocked_by"]')"
SWARM="$(field 'd["task"]["swarm"]')"
ROUTE_DIRECTIVE="$(field 'd["task"]["route_raw"]')"
PATHS="$(field 'd["task"]["paths"]')"
BUDGET="$(field 'd["task"]["budget_raw"]')"
LANES="$(field 'd["lanes"]')"

# One active plan (or ad-hoc route) per repository and session: the ACTIVE lock
# (every check-and-write under flock; see apex_lock in _lib.sh).
LOCK_RC=0; apex_lock_acquire "$PLAN_HASH" "$PLAN_ABS" "$LINE_NO" BUILD || LOCK_RC=$?
if [[ "$LOCK_RC" -ne 0 && "$LOCK_RC" -ne 10 ]]; then
  echo "STATE: $STATE_DIR"
  echo "STATUS: ERROR the ACTIVE lock could not be read or written under $STATE_BASE (exit $LOCK_RC)"
  exit 1
fi
if [[ "$LOCK_RC" -eq 10 ]]; then
  echo "STATE: $STATE_DIR"
  echo "STATUS: BUSY"
  echo "BUSY_WITH: $(apex_lock_owner)"
  echo "BUSY_HINT: finish or land that run; if it was abandoned, re-run with APEX_FORCE_UNLOCK=1"
  exit 0
fi

HEAD_SHA="$(git -C "${WORKTREE:-$REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
# The task's diff base is the chain floor (ADR-0003): the head the last
# reviewed `complete` verified, else the run's fork point. A 0.2.x run has no
# fork point recorded: it is fixed once, here, at the worktree's fork from the
# base branch (never in an APEX_NO_WORKTREE run, where that would be HEAD).
if [[ -z "$(read_field fork_sha)" && -n "$WT_BRANCH" ]]; then
  FORK="$(git -C "$WORKTREE" merge-base HEAD "$(read_field base_branch)" 2>/dev/null || true)"
  [[ -n "$FORK" ]] && python3 - "$CHECKPOINT" "$STATE_DIR/.checkpoint.lock" "$FORK" <<'PY' || true
import fcntl, json, os, sys
path, lock, fork = sys.argv[1:]
fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)          # checkpoint.sh's state lock
s = json.load(open(path))
if not s.get("fork_sha"):
    s["fork_sha"] = fork
    tmp = path + ".tmp"
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o644), "w") as f:
        json.dump(s, f, indent=2)
    os.replace(tmp, path)
PY
fi
TASK_BASE="$(apex_floor "${WORKTREE:-$REPO_ROOT}" || echo none)"
echo "STATE: $STATE_DIR"
echo "WORKTREE: $WORKTREE"
echo "BRANCH: $WT_BRANCH"
echo "PHASE: $PHASE_ID"
echo "TAGS: $TAGS"
echo "TASK: $TASK_LINE"
echo "ACCEPTANCE: $ACCEPTANCE"
echo "BLOCKED_BY: $BLOCKED_BY"
echo "SWARM: $SWARM"
echo "ROUTE_DIRECTIVE: $ROUTE_DIRECTIVE"
echo "PATHS: $PATHS"
echo "BUDGET: $BUDGET"
echo "LINE_NO: $LINE_NO"
echo "HEAD_SHA: $HEAD_SHA"
echo "TASK_BASE: $TASK_BASE"
echo "STAGE: BUILD"
[[ -n "$LANES" ]] && echo "LANES: $LANES"
if [[ "${APEX_GIBSON:-1}" != "0" ]]; then
  echo "HARNESS: gibson"
  "$APEX_EXECUTE_SCRIPTS/lessons.sh" "$PLAN" recall "$TAGS" 2>/dev/null | head -1 \
    | sed "s|\$| — read with: lessons.sh $PLAN recall $TAGS|" || true
else
  echo "HARNESS: off"
fi
echo "CONSECUTIVE_FAILURES: $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("consecutive_failures",0))' "$CHECKPOINT" 2>/dev/null || echo 0)"

# Routing (apex-dispatch, when installed beside this plugin). Its block sits
# between the task fields and STATUS; without it the orchestrator routes by
# the Swarm: directive exactly as in 0.2.0.
DISPATCH="$(apex_dispatch_root)"
if [[ -n "$DISPATCH" && "${APEX_DISPATCH_MODE:-}" != "off" ]]; then
  ROUTE_OUT="$("$DISPATCH/scripts/route.sh" plan "$PLAN_ABS" --line "$LINE_NO" --base "$TASK_BASE" ${LANES:+--lanes "$LANES"} 2>&1)" \
    || ROUTE_OUT="ROUTE: error route.sh exited non-zero: $(printf '%s' "$ROUTE_OUT" | tail -1)"
  printf '%s\n' "$ROUTE_OUT"
  # A route that refuses to dispatch decides the iteration's status.
  case "$(printf '%s\n' "$ROUTE_OUT" | sed -n 's/^ROUTE_STATUS: //p' | head -1)" in
    NEEDS_SPEC) echo "STATUS: NEEDS_SPEC"; exit 0 ;;
    HUMAN_GATE) echo "STATUS: HUMAN_GATE"; exit 0 ;;
    HALTED)     echo "STATUS: HALTED"; exit 0 ;;
  esac
else
  echo "ROUTE: none"
fi
echo "STATUS: READY"
