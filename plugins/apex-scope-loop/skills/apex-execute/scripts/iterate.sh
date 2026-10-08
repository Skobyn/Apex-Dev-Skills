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
#   HEAD_SHA: <worktree HEAD at brief time — NOT a diff base; the reviewer's
#             HEAD_SHA is the head after the build commit>
#   TASK_BASE: <the task's diff base: the chain floor (ADR-0003); "none" when
#              no fork point is recorded — risk-tier and complete then refuse>
#   SINCE: <TASK_BASE again: the value for risk-tier.sh --since and round 1's SINCE>
#   HARNESS: gibson | off                # APEX_GIBSON=0 turns the harness off
#   LESSONS: <n> matching ...           # ratchet entries for this task's tags
#   CONSECUTIVE_FAILURES: <n>
#   THREAT_MODEL: source task|plan|default, then the text as "  > " lines
#                 (ADR-0004: every reviewer gets it verbatim)
#   LAST_REVIEWED: <sha>|none   # last reviewed SHA in this attempt and epoch
#   REVIEW_ROUND: <n>           # round of the next review (1 = full review)
#   REVIEW_MODE: full | verify  # round >= 2 re-reviews only the fixes since LAST_REVIEWED;
#                 full again when the tier rose above every tier reviewed in the
#                 attempt, or a Tier C attempt has no adversarial review yet
#   REVIEW_SINCE: <sha>         # SINCE for the next review (TASK_BASE when full)
#   TIER_REASONS: the recorded tier's reasons ("  ! " an overridden Tier C signal)
#   ADVERSARY_BUDGET: <n>       # max [blocking] findings per review (APEX_ADVERSARY_BUDGET, default 3)
#   BACKLOG: <n> open ...       # hardening backlog items for this plan (backlog.sh)
#   REVIEW_CAP / REVIEW_DIRECTIVE / FROZEN / THREATS: the task's review cap
#                 (blocking rounds), Review: directive, freeze and Threats: list
#   FINDINGS: <path> (<open> open, <residual> residual, <closed> closed)
#   KNOWN_DEFECT_CLASSES: lessons matching the tags + closed finding classes
#   LESSON_SUGGESTED: lessons.sh ... add ...  # a finding class seen in two tasks
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
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"; PLAN="$(apex_locate_plan "$PLAN")"   # ADR-0004 H
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

HEAD_SHA="$(apex_git "${WORKTREE:-$REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
# The task's diff base is the chain floor (ADR-0003): the head the last
# reviewed `complete` verified, else the run's fork point. A 0.2.x run has no
# fork point recorded: it is fixed once, here, at the worktree's fork from the
# base branch (never in an APEX_NO_WORKTREE run, where that would be HEAD).
if [[ -z "$(read_field fork_sha)" && -n "$WT_BRANCH" ]]; then
  FORK="$(apex_git "$WORKTREE" merge-base HEAD "$(apex_base_sha "$WORKTREE" "$(read_field base_branch)")" 2>/dev/null || true)"
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
# A briefed task means the run is active again (a reopened plan): it is no
# longer retired, so the restart guard covers its commits.
python3 - "$CHECKPOINT" "$STATE_DIR/.checkpoint.lock" <<'PY' || true
import fcntl, json, os, sys
path, lock = sys.argv[1:]
fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)          # checkpoint.sh's state lock
s = json.load(open(path))
if s.get("retired"):
    s["retired"] = False
    tmp = path + ".tmp"
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o644), "w") as f:
        json.dump(s, f, indent=2)
    os.replace(tmp, path)
PY
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
echo "SINCE: $TASK_BASE"
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
# Review-loop calibration (ADR-0004): the threat model every reviewer gets
# verbatim, the review round this task is in, and the adversary budget.
THREAT_OUT="$(python3 "$APEX_EXECUTE_SCRIPTS/planlib.py" threat "$PLAN_ABS" "$LINE_NO" 2>/dev/null)" \
  || THREAT_OUT="$(printf 'SOURCE: default\n%s' "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import planlib; print(planlib.DEFAULT_THREAT_MODEL)' "$APEX_EXECUTE_SCRIPTS")")"
THREAT_SRC="${THREAT_OUT%%$'\n'*}"
echo "THREAT_MODEL: source ${THREAT_SRC#SOURCE: }"
printf '%s\n' "$THREAT_OUT" | sed '1d; s/^/  > /'
python3 - "$CHECKPOINT" "$LINE_NO" "$HEAD_SHA" "$TASK_BASE" <<'PY' || { echo "LAST_REVIEWED: none"; echo "REVIEW_ROUND: 1"; echo "REVIEW_MODE: full"; echo "REVIEW_SINCE: $TASK_BASE"; }
import json, sys
path, line_no, head, task_base = sys.argv[1:]
s = json.load(open(path))
r = (s.get("reviews") or {}).get(line_no) or {}
attempt, epoch = r.get("attempt", 1), s.get("epoch", 0)
recs = [x for x in r.get("records") or [] if x.get("attempt", 1) == attempt and x.get("epoch", 0) == epoch]
rounds = r.get("rounds") or []
last = recs[-1]["sha"] if recs else "none"
# The next review's round: the head's own round while its reviews are still
# coming in and none requested changes; otherwise the next new commit's round.
if head in rounds and not any(x.get("sha") == head and x.get("verdict") != "APPROVE" for x in recs):
    n = rounds.index(head) + 1
else:
    n = len(rounds) + 1
order = {"A": 0, "B": 1, "C": 2}
trec = (s.get("tiers") or {}).get(line_no) or {}
tier = trec.get("tier") if trec.get("epoch", 0) == epoch else None
full = [x for x in recs if x.get("mode", "full") == "full"]
reviewed_at = max([order.get(x.get("tier") or "A", 0) for x in full] or [-1])
why = ""
if n == 1 or last == "none":
    mode = "full"
elif tier in order and order[tier] > reviewed_at:
    mode, why = "full", "the tier rose to %s after reviews at %s in this attempt" % (tier, "ABC"[max(reviewed_at, 0)])
elif tier == "C" and not any(x.get("role") == "adversarial" and x.get("tier") == "C" for x in full):
    mode, why = "full", "a Tier C attempt with no full-mode adversarial review at Tier C yet"
else:
    mode = "verify"
print("LAST_REVIEWED: " + last)
print("REVIEW_ROUND: %d" % n)
print("REVIEW_MODE: " + mode + (" (" + why + ")" if why else ""))
print("REVIEW_SINCE: " + (task_base if mode == "full" else last))
# The classifier's reasons reach every reviewer (ADR-0004 §8): the recorded
# tier's REASON lines, an overridden Tier C signal first.
if tier:
    print("TIER_REASONS: Tier %s at %s (risk-tier.sh; pass these to every reviewer)" % (tier, str(trec.get("head") or "?")[:12]))
    ov = trec.get("overridden_c") or []
    for x in ([ov] if isinstance(ov, str) else ov):
        print("  ! " + x)
    for x in trec.get("reasons") or []:
        print("  - " + x)
PY
AB="${APEX_ADVERSARY_BUDGET:-3}"; [[ "$AB" =~ ^[1-9][0-9]{0,2}$ ]] || AB=3
echo "ADVERSARY_BUDGET: $AB"
# Review directive, cap and freeze (ADR-0004 addendum B, C).
python3 - "$CHECKPOINT" "$LINE_NO" "$SEL" "${APEX_REVIEW_CAP:-3}" <<'PY' || true
import json, sys
path, line_no, sel, envcap = sys.argv[1:]
t = json.loads(sel)["task"]
raw = t.get("review_raw") or ""
print("REVIEW_CAP: %s (blocking rounds per attempt%s)" % ((t.get("review") or {}).get("cap") or envcap, "; Review: directive" if (t.get("review") or {}).get("cap") else ""))
if raw:
    print("REVIEW_DIRECTIVE: " + raw)
fz = (json.load(open(path)).get("freezes") or {}).get(line_no)
if fz:
    print("FROZEN: %s (%s/%s verdicts in; review of any other SHA is refused until the round is in or unfreeze)"
          % (fz.get("sha"), fz.get("recorded", 0), fz.get("reviewers", 1)))
for i, th in enumerate(t.get("threats") or [], 1):
    print(("THREATS: %d\n" % len(t["threats"]) if i == 1 else "") + "  %d. %s" % (i, th))
PY
# Carried findings (addendum A) and known defect classes (addendum G).
FSUM="$("$APEX_EXECUTE_SCRIPTS/findings.sh" "$PLAN_ABS" summary "$LINE_NO" 2>/dev/null || echo "? ? ?")"
read -r F_OPEN F_RES F_CLOSED <<<"$FSUM"
echo "FINDINGS: $("$APEX_EXECUTE_SCRIPTS/findings.sh" "$PLAN_ABS" path "$LINE_NO" 2>/dev/null) ($F_OPEN open, $F_RES residual, $F_CLOSED closed)"
python3 - "$PLAN" "$TAGS" "$LESSONS_LEDGER" "$("$APEX_EXECUTE_SCRIPTS/findings.sh" "$PLAN_ABS" classes 2>/dev/null || true)" <<'PY' || true
import os, re, sys
plan, tags, ledger, closed = sys.argv[1:]
want = {t.strip().lower() for t in tags.split(",") if t.strip()}
lesson_classes, all_slugs = [], set()
if os.path.isfile(ledger):
    for b in re.split(r"\n(?=## L-\d+)", open(ledger, encoding="utf-8", errors="replace").read()):
        m = re.match(r"## (L-\d+) · [^·]* · (\S+)", b)
        if not m:
            continue
        all_slugs.add(m.group(2))
        tm = re.search(r"^\*\*Tags:\*\*(.*)$", b, re.M)
        have = {x.lstrip("#").lower() for x in (tm.group(1).split() if tm else [])}
        if not want or want & have:
            lesson_classes.append("%s:%s" % (m.group(1), m.group(2)))
by_class = {}
for row in closed.splitlines():
    if "\t" in row:
        ln, c = row.split("\t", 1)
        by_class.setdefault(c, set()).add(ln)
classes = lesson_classes + sorted(by_class)
print("KNOWN_DEFECT_CLASSES: " + (", ".join(classes) if classes else "none"))
for c, lines in sorted(by_class.items()):
    if len(lines) >= 2 and c not in all_slugs and not any(c in s for s in all_slugs):
        ls = sorted(lines, key=int)
        print("LESSON_SUGGESTED: lessons.sh \"%s\" add \"%s\" \"finding class %s recurred in the tasks at lines %s\" \"<root cause>\" \"<harness fix>\" \"%s\""
              % (plan, c, c, ", ".join(ls), tags or c))
PY
echo "BACKLOG: $("$APEX_EXECUTE_SCRIPTS/backlog.sh" "$PLAN_ABS" count 2>/dev/null || echo "?") open for this plan — read with: backlog.sh $PLAN list"

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
    BUSY)       echo "STATUS: BUSY"; exit 0 ;;   # another ACTIVE owner: fail closed, never READY
  esac
else
  echo "ROUTE: none"
fi
echo "STATUS: READY"
