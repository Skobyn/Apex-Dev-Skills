#!/usr/bin/env bash
# checkpoint.sh — Mark a phase complete (or rewind) and update state.
# Usage:
#   ./checkpoint.sh PLAN.md complete LINE_NO VERDICT_REASON [--skip-review "why"]
#   ./checkpoint.sh PLAN.md fail     LINE_NO REASON
#   ./checkpoint.sh PLAN.md review   LINE_NO SHA APPROVE|REQUEST_CHANGES [REVIEWER]
#                     [--role reviewer|adversarial|lens:<name>] [--agent-id ID | --worker DIR]
#                     [--provider P] [--model M] [--route ROUTE_ID]
#   ./checkpoint.sh PLAN.md approve  LINE_NO SHA "<the human's literal approval reply>"
#   ./checkpoint.sh PLAN.md halt     REASON
#   ./checkpoint.sh PLAN.md resume   REASON       # human: clear a halt and the error budget
#   ./checkpoint.sh PLAN.md rewind   LINE_NO      # uncheck a completed task
#
# LINE_NO is always the line of a task in a valid plan (planlib); SHA is a
# full commit id (40 or 64 hex). Every action holds an exclusive lock on the
# plan's state, so parallel reviewers cannot lose each other's records.
# While the plan is halted, `review` and `complete` are refused.
#
# Harness enforcement on `complete` (adapted from The Gibson — see
# docs/GIBSON_HARNESS.md; disable with APEX_GIBSON=0):
#   - green gate (green-gate.sh check) must be PASS or SKIPPED on the worktree's
#     current head SHA                                         (Law 4)
#   - an independent review verdict APPROVE must be recorded for that exact
#     head SHA, unless --skip-review names why review does not apply  (Law 5)
#   - a Tier C task needs a recorded human approval (G12) for that exact head
#     SHA; --skip-review never waives it                       (Law 7)
#   - a risk tier must be recorded for the head; --skip-review never waives it
#   - the task diff is everything since the chain floor (ADR-0003; apex_floor:
#     the head the last reviewed `complete` verified, else the run's fork
#     point); `complete` re-classifies it (risk-tier.sh --no-record) and the
#     effective tier is the higher of that and the recorded tier
#   A gate task (its line opens with **Gate …** and carries a [gate:*] tag) is
#   exempt only when it adds no code since the floor (no commits, no dirty or
#   untracked files) and neither its tags nor its recorded tier say Tier C.
#   A reviewed completion records its verified head: the next task's floor.
#
# Reviews (ADR-0003): every verdict is a record; a round is a distinct head
# SHA reviewed in the current attempt, and a fourth round is refused
# (APEX_REVIEW_CAP, default 3) — record `fail` and retry instead. `complete`
# needs an APPROVE at the exact head in the current attempt, and no
# REQUEST_CHANGES at that head in any attempt (a new attempt needs a new
# commit, not a new reviewer). Tier C also needs an APPROVE recorded with
# --role adversarial and can never use --skip-review.
#
# apex-dispatch (when <state>/dispatch/ exists): a verdict is accepted only
# with provenance — a hook-written reviews-raw record (--agent-id) or a worker
# result.json one level inside <state>/dispatch/workers or the shim worktree
# root (--worker) — that carries the same verdict, SHA, role and task line, and
# a record_id unique to the review run. The role comes from the record; a
# record_id is used once.
# --skip-review and the default reviewer name are refused,
# and `complete` needs ledger evidence (ledger.sh evidence) even with
# APEX_GIBSON=0. APEX_DISPATCH_ROOT is trusted like APEX_GIBSON: whoever sets
# the environment owns the harness.
#
# Error budget on `fail`: after APEX_ESCALATE_AFTER consecutive failures
# (default 2) the brief says ESCALATE (buy a second opinion from a different
# agent); at APEX_ERROR_BUDGET (default 3) the plan halts. A failure starts a
# new review attempt for the line. With apex-dispatch, ESCALATE_ROUTE: lines
# come from `route.sh escalate`.
set -euo pipefail

PLAN="${1:?usage: checkpoint.sh PLAN.md ACTION [...]}"
ACTION="${2:?action: complete|fail|review|approve|halt|resume|rewind}"
[[ -f "$PLAN" ]] || { echo "ERROR: plan not found"; exit 1; }

APEX_RESOLVE_MODE=act  # this script acts: a repository mismatch is fatal (never inherited from the env)
# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
apex_resolve "$PLAN"
[[ -f "$CHECKPOINT" ]] || { echo "ERROR: not initialized — run init.sh first"; exit 1; }

# Serialise every action on this plan's state: an exclusive flock on fd 9,
# held by this shell until it exits (the lock belongs to the open file, which
# python locks and this shell keeps open). External tools get 9>&- so a
# background child of theirs never holds it.
exec 9>>"$STATE_DIR/.checkpoint.lock"
python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX)'

NOW="$(date -u +%FT%TZ)"
WT="$(read_field worktree_path)"; WT="${WT:-$REPO_ROOT}"
head_sha() { apex_git "$WT" rev-parse HEAD 2>/dev/null || echo unknown; }
DISPATCH_STATE="$STATE_DIR/dispatch"
DISPATCH="$(apex_dispatch_root)"

need_line() {
  [[ "$1" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "ERROR: LINE_NO must be a plan line number, got '$1'" >&2; exit 1; }
  local err
  err="$(python3 "$APEX_EXECUTE_SCRIPTS/planlib.py" validate "$PLAN" 2>&1)" \
    || { echo "[checkpoint] REFUSED $ACTION: the plan is invalid:" >&2; printf '%s\n' "$err" | head -5 | sed 's/^/  /' >&2; exit 1; }
  TASK_JSON="$(python3 "$APEX_EXECUTE_SCRIPTS/planlib.py" task "$PLAN" "$1" 2>/dev/null || true)"
  [[ "$TASK_JSON" == \{* ]] || { echo "[checkpoint] REFUSED $ACTION: line $1 is not a task in $PLAN" >&2; exit 1; }
}
# checked: the box is ticked. gate: the task line opens with **Gate …** and
# carries a [gate:*] tag (a tag or a **Gate** quoted in prose does not make a
# code task a gate).
task_field() {
  python3 -c '
import json, re, sys
t = json.loads(sys.argv[1])
gate = re.match(r"- \[[ xX]\] \*\*Gate ", t["line"]) is not None and any(x.startswith("gate:") for x in t["tags"])
forced_c = any(x in ("security", "tier:c", "tier-c") for x in t["tags"])
print("1" if {"checked": t["checked"], "gate": gate, "forced_c": forced_c}[sys.argv[2]] else "0")' "$TASK_JSON" "$1"
}
recorded_tier() {
  python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("tiers", {}).get(sys.argv[2]) or {}).get("tier") or "")' "$CHECKPOINT" "$1"
}
refuse_if_halted() {
  local why f
  why="$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(s.get("halt_reason") or "halted" if s.get("halted") else "")' "$CHECKPOINT")"
  [[ -z "$why" ]] || { echo "[checkpoint] REFUSED $ACTION: the plan is halted ($why) — a human clears it with: checkpoint.sh PLAN resume REASON" >&2; exit 1; }
  if [[ "${APEX_GIBSON:-1}" != "0" ]]; then
    [[ "${APEX_HALT:-0}" != "1" ]] || { echo "[checkpoint] REFUSED $ACTION: kill switch APEX_HALT=1" >&2; exit 1; }
    while IFS= read -r f; do
      [[ -f "$f" ]] && { echo "[checkpoint] REFUSED $ACTION: kill switch present ($f)" >&2; exit 1; }
    done < <(apex_halt_files)
  fi
  return 0
}
# dirty_paths — uncommitted and untracked (not ignored) paths in the
# worktree; "?" when git fails. In a run without a worktree the plan file and
# the lessons ledger (edited in place) are left out — as exact regular files,
# the plan only as a .md file, the ledger only at .claude/apex-scope-loop/LESSONS.md.
dirty_paths() {
  { apex_git "$WT" status --porcelain=v1 -z --untracked-files=all --ignore-submodules=none 2>/dev/null || printf '?? ?\0'; } | python3 -c '
import os, sys
wt, has_wt, plan, ledger = sys.argv[1:]
keep = set()
if has_wt != "1":
    for p in (plan, ledger):
        if p and os.path.isfile(p) and not os.path.islink(p):
            rel = os.path.relpath(os.path.abspath(p), os.path.abspath(wt))
            if (p == plan and not rel.endswith(".md")) or (p != plan and rel != ".claude/apex-scope-loop/LESSONS.md"):
                continue
            keep.add(os.path.abspath(p))
recs = sys.stdin.buffer.read().split(b"\0")
i = 0
while i < len(recs):
    r = recs[i].decode("utf-8", "replace"); i += 1
    if len(r) < 4:
        continue
    xy, path = r[:2], r[3:]
    if "R" in xy or "C" in xy:
        i += 1                                  # the source path record
    if path == "?" or os.path.abspath(os.path.join(wt, path)) not in keep:
        print(path)' "$WT" "$([[ -n "$(read_field worktree_branch)" ]] && echo 1 || echo 0)" "$PLAN_ABS" "${LESSONS_LEDGER:-}"
}
need_sha() {
  [[ "$1" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || { echo "[checkpoint] REFUSED $ACTION: '$1' is not a full commit SHA" >&2; exit 1; }
}
# Atomic JSON write shared by the python blocks below (never follows a
# planted .tmp symlink).
PY_SAVE='
import json, os
def save(path, s):
    tmp = path + ".tmp"
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o644)
    with os.fdopen(fd, "w") as f:
        json.dump(s, f, indent=2)
    os.replace(tmp, path)
'

case "$ACTION" in
  complete)
    LINE_NO="${3:?line_no required}"
    VERDICT="${4:-passed}"
    SKIP_REVIEW=""
    [[ "${5:-}" == "--skip-review" ]] && SKIP_REVIEW="${6:?--skip-review needs a reason}"
    need_line "$LINE_NO"
    [[ "$(task_field checked)" == "0" ]] || { echo "[checkpoint] REFUSED complete: line $LINE_NO is already checked" >&2; exit 1; }
    refuse_if_halted
    HEAD_V="$(head_sha)"   # the head this completion verifies (and records)
    # A run without a worktree verifies completions on its own branch only.
    if [[ -z "$(read_field worktree_branch)" && "${APEX_GIBSON:-1}" != "0" ]]; then
      RUN_BRANCH="$(read_field run_branch)"
      CUR_BRANCH="$(git -C "$WT" symbolic-ref -q --short HEAD 2>/dev/null || true)"
      [[ -n "$RUN_BRANCH" ]] || { echo "[checkpoint] REFUSED complete: this run has no recorded branch — re-run init.sh on the run's branch (it records it)" >&2; exit 1; }
      [[ "$CUR_BRANCH" == "$RUN_BRANCH" ]] || { echo "[checkpoint] REFUSED complete: this run is on '$RUN_BRANCH', the checkout is on '${CUR_BRANCH:-a detached HEAD}' — complete it on its own branch" >&2; exit 1; }
    fi
    # The task's code is everything since the chain floor (ADR-0003). A gate
    # line is exempt from the checks only when it adds no code at all and
    # nothing marks it Tier C.
    FLOOR="$(apex_floor "$WT" "$HEAD_V" || true)"
    EXEMPT=0
    if [[ "$(task_field gate)" == "1" && "$(task_field forced_c)" == "0" && "$(recorded_tier "$LINE_NO")" != "C" && -n "$FLOOR" ]] \
       && apex_git "$WT" diff --quiet --no-renames --ignore-submodules=none "$FLOOR" "$HEAD_V" 2>/dev/null && [[ -z "$(dirty_paths)" ]]; then
      EXEMPT=1
    fi
    if [[ -n "$SKIP_REVIEW" && -d "$DISPATCH_STATE" ]]; then
      echo "[checkpoint] REFUSED complete: apex-dispatch state exists ($DISPATCH_STATE); --skip-review is not accepted — record a reviewed verdict" >&2
      exit 1
    fi
    if [[ "${APEX_GIBSON:-1}" != "0" && "$EXEMPT" == "0" ]]; then
      [[ -n "$FLOOR" ]] || { echo "[checkpoint] REFUSED complete: no diff base (apex_floor reason above)" >&2; exit 1; }
      # Recompute the tier from the whole task diff: the recorded tier (which
      # keeps a decision-layer raise) never outranks what the code shows.
      RT_OUT="$("$APEX_EXECUTE_SCRIPTS/risk-tier.sh" "$PLAN" "$LINE_NO" --since "$FLOOR" --no-record 9>&- 2>&1)" \
        || { echo "[checkpoint] REFUSED complete: could not classify the task diff:" >&2; printf '%s\n' "$RT_OUT" | tail -3 | sed 's/^/  /' >&2; exit 1; }
      COMPUTED="$(sed -n '/^TIER: /{s///p;q;}' <<<"$RT_OUT")"
      [[ "$COMPUTED" =~ ^[ABC]$ && "$(sed -n '/^HEAD: /{s///p;q;}' <<<"$RT_OUT")" == "$HEAD_V" ]] \
        || { echo "[checkpoint] REFUSED complete: the task diff was not classified at the head ${HEAD_V:0:12} (did the head move?)" >&2; exit 1; }
      python3 - "$CHECKPOINT" "$STATE_DIR/gate/last.json" "$LINE_NO" "$HEAD_V" "$SKIP_REVIEW" "$COMPUTED" "$FLOOR" <<'PY'
import json, os, sys
cp, gate_path, line_no, head, skip, computed, floor = sys.argv[1:]
s = json.load(open(cp))
problems = []
order = {"A": 0, "B": 1, "C": 2}
g = json.load(open(gate_path)) if os.path.isfile(gate_path) else None
if not g:
    problems.append("no green-gate result — run: green-gate.sh PLAN check")
elif g.get("head_sha") != head:
    problems.append(f"green gate ran on {g.get('head_sha','?')[:12]}, worktree head is {head[:12]} — re-run green-gate.sh check")
elif g.get("result") not in ("PASS", "SKIPPED"):
    problems.append(f"green gate is {g.get('result')} — zero new failures vs. baseline required")
trec = s.get("tiers", {}).get(line_no) or {}
recorded = trec.get("tier")
if recorded is None:
    problems.append(f"no risk tier recorded — run: risk-tier.sh PLAN LINE --since {floor[:12]} (TASK_BASE)")
elif trec.get("head") != head:
    problems.append(f"the risk tier was recorded for {str(trec.get('head') or 'an older version')[:12]}, not the head {head[:12]} "
                    f"— re-run: risk-tier.sh PLAN LINE --since {floor[:12]} (TASK_BASE)")
# Effective tier: the higher of the recorded tier and the tier the task diff
# shows now (classified here from the chain floor, with the plan's tags).
tier = max([t for t in (recorded, computed) if t in order], key=order.get)
if recorded in order and order[computed] > order[recorded]:
    problems.append(f"the task diff since {floor[:12]} classifies as Tier {computed}, above the recorded Tier {recorded} "
                    "— re-run risk-tier.sh and give the task the Tier " + computed + " review")
r = s.get("reviews", {}).get(line_no) or {}
attempt = r.get("attempt", 1)
records = r.get("records")
if records is None:                                    # 0.2.0 single record = attempt 1
    records = [{"attempt": 1, "sha": r["sha"], "verdict": r.get("verdict"), "role": "reviewer"}] if r.get("sha") else []
at_head = [x for x in records if x.get("sha") == head]
if any(x.get("verdict") != "APPROVE" for x in at_head):
    # Any attempt: a failure starts a new attempt, it does not launder a verdict.
    problems.append(f"a review of the head {head[:12]} requested changes — address the findings in a new commit and re-review")
if skip and tier == "C":
    problems.append("Tier C: --skip-review cannot waive the review and adversarial pass")
elif not skip:
    recs = [x for x in at_head if x.get("attempt", 1) == attempt]
    if not recs:
        problems.append("no independent review recorded for the worktree head "
                        f"{head[:12]} in this attempt — dispatch the reviewer, then: checkpoint.sh PLAN review LINE SHA VERDICT")
    elif tier == "C" and not any(x.get("role") == "adversarial" and x.get("verdict") == "APPROVE" for x in recs):
        problems.append("Tier C: an adversarial review (--role adversarial) approving this exact head is required")
if tier == "C":
    a = s.get("approvals", {}).get(line_no)
    if not a or a.get("sha") != head:
        problems.append("Tier C: human approval (G12) for this exact head SHA is required — halt and ask with the Ask Contract")
if problems:
    print("[checkpoint] REFUSED complete @ line " + line_no + ":", file=sys.stderr)
    for p in problems:
        print("  - " + p, file=sys.stderr)
    sys.exit(1)
PY
    fi
    # With apex-dispatch state, the ledger must back the completion (not
    # waived by APEX_GIBSON=0).
    if [[ -d "$DISPATCH_STATE" && "$EXEMPT" == "0" ]]; then
      [[ -n "$DISPATCH" ]] || { echo "[checkpoint] REFUSED complete: dispatch state exists ($DISPATCH_STATE) but apex-dispatch is not installed beside apex-scope-loop (APEX_DISPATCH_ROOT)" >&2; exit 1; }
      "$DISPATCH/scripts/ledger.sh" evidence --state "$STATE_DIR" --line "$LINE_NO" --head "$HEAD_V" 9>&- \
        || { echo "[checkpoint] REFUSED complete: ledger evidence missing or the hash chain is broken (ledger.sh evidence)" >&2; exit 1; }
    fi
    # Flip "- [ ]" to "- [x]" on that line (BSD/macOS sed)
    sed -i.bak "${LINE_NO}s/^- \[ \]/- [x]/" "$PLAN" && rm -f "${PLAN}.bak"
    python3 -c "$PY_SAVE"'
import sys
path, now, verdict, line_no, skip, head, harness, remaining = sys.argv[1:]
with open(path) as f: s = json.load(f)
s["completed_tasks"] = s.get("completed_tasks", 0) + 1
# Retired: a reviewed completion left no task. Only a completion sets it;
# rewind and the next brief (iterate.sh) clear it. apex_unreviewed_runs skips
# a retired run (unless its plan, when present, has a task again).
s["retired"] = harness == "1" and remaining == "0"
# The chain advances only past code the harness verified (APEX_GIBSON=0
# completions leave their code in the diff of the next task).
if harness == "1" and head != "unknown":
    s.setdefault("completes", []).append({"line": int(line_no), "head": head, "at": now})
s["last_verdict"] = {"line_no": int(line_no), "result": "pass", "reason": verdict, "at": now}
if skip:
    s.setdefault("skipped_reviews", {})[line_no] = {"reason": skip, "at": now}
s["last_iteration_at"] = now
s["current_phase"] = None
s["consecutive_failures"] = 0
save(path, s)' "$CHECKPOINT" "$NOW" "$VERDICT" "$LINE_NO" "$SKIP_REVIEW" "$HEAD_V" "$([[ "${APEX_GIBSON:-1}" != "0" ]] && echo 1 || echo 0)" \
      "$(python3 "$APEX_EXECUTE_SCRIPTS/planlib.py" remaining "$PLAN" 2>/dev/null || echo "?")"
    apex_lock_stage "$PLAN_HASH" DONE   # this plan's lock becomes reclaimable until its next iterate
    echo "[checkpoint] complete @ line $LINE_NO ($VERDICT)"
    ;;

  fail)
    LINE_NO="${3:?line_no required}"
    REASON="${4:-unspecified}"
    need_line "$LINE_NO"
    python3 -c "$PY_SAVE"'
import sys
path, now, reason, line_no, esc, budget = sys.argv[1:]
s = json.load(open(path))
n = s.get("consecutive_failures", 0) + 1
s["consecutive_failures"] = n
s["last_verdict"] = {"line_no": int(line_no), "result": "fail", "reason": reason, "at": now}
s["last_iteration_at"] = now
print(f"[checkpoint] FAIL @ line {line_no} ({n} consecutive): {reason}")
if n >= int(budget):
    why = f"error budget exhausted: {n} consecutive failures (last: {reason})"
    s["halted"] = True
    s["halt_reason"] = why
    print(f"[checkpoint] HALTED: {why}")
elif n >= int(esc):
    print("ESCALATE: second-opinion — dispatch a different agent (fresh context, different model if available) to diagnose before retrying")
# A failure ends the review attempt for the line: the next attempt gets fresh rounds.
r = s.setdefault("reviews", {}).setdefault(line_no, {})
r["attempt"] = r.get("attempt", 1) + 1
r["rounds"] = []
save(path, s)' "$CHECKPOINT" "$NOW" "$REASON" "$LINE_NO" "${APEX_ESCALATE_AFTER:-2}" "${APEX_ERROR_BUDGET:-3}"
    # apex-dispatch decides the next rung (effort+1, model+1, diagnoser, HALT).
    ROUTE_FILE="$DISPATCH_STATE/active-route.json"
    if [[ -f "$ROUTE_FILE" ]]; then
      RID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("route_id",""))' "$ROUTE_FILE" 2>/dev/null || true)"
      if [[ -z "$DISPATCH" ]]; then
        echo "ESCALATE_ROUTE: error apex-dispatch is not installed beside apex-scope-loop (APEX_DISPATCH_ROOT); no escalation rung for ${RID:-the active route}"
      elif [[ -z "$RID" ]]; then
        echo "ESCALATE_ROUTE: error $ROUTE_FILE has no route_id"
      else
        "$DISPATCH/scripts/route.sh" escalate "$RID" 9>&- 2>&1 | sed 's/^/ESCALATE_ROUTE: /' || echo "ESCALATE_ROUTE: error route.sh escalate $RID failed"
      fi
    fi
    ;;

  review)
    LINE_NO="${3:?line_no required}"
    SHA="${4:?sha required}"
    VERDICT="${5:?verdict: APPROVE|REQUEST_CHANGES}"
    shift 5
    REVIEWER="gibson-reviewer"; REVIEWER_NAMED=0
    if [[ $# -gt 0 && "$1" != --* ]]; then REVIEWER="$1"; REVIEWER_NAMED=1; shift; fi
    ROLE=""; AGENT_ID=""; WORKER=""; PROVIDER=""; MODEL=""; ROUTE_ID=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --role) ROLE="${2:?}"; shift 2 ;;
        --agent-id) AGENT_ID="${2:?}"; shift 2 ;;
        --worker) WORKER="${2:?}"; shift 2 ;;
        --provider) PROVIDER="${2:?}"; shift 2 ;;
        --model) MODEL="${2:?}"; shift 2 ;;
        --route) ROUTE_ID="${2:?}"; shift 2 ;;
        *) echo "ERROR: unknown review option $1" >&2; exit 1 ;;
      esac
    done
    need_line "$LINE_NO"
    need_sha "$SHA"
    refuse_if_halted
    case "$VERDICT" in APPROVE|REQUEST_CHANGES) ;; *) echo "ERROR: verdict must be APPROVE or REQUEST_CHANGES" >&2; exit 1 ;; esac
    [[ -z "$ROLE" || "$ROLE" =~ ^(reviewer|adversarial|lens:[a-z/-]+)$ ]] || { echo "ERROR: --role must be reviewer, adversarial or lens:<name>" >&2; exit 1; }
    [[ -n "$AGENT_ID" && -n "$WORKER" ]] && { echo "ERROR: --agent-id and --worker are exclusive" >&2; exit 1; }
    python3 - "$CHECKPOINT" "$NOW" "$LINE_NO" "$SHA" "$VERDICT" "$REVIEWER" "$REVIEWER_NAMED" "$ROLE" "$AGENT_ID" "$WORKER" \
      "$PROVIDER" "$MODEL" "$ROUTE_ID" "$DISPATCH_STATE" "${PLAN_TOP:-$REPO_ROOT}" "${APEX_REVIEW_CAP:-3}" <<'PY'
import json, os, re, sys
(path, now, line_no, sha, verdict, reviewer, reviewer_named, role, agent_id, worker,
 provider, model, route_id, dstate, top, cap) = sys.argv[1:]
def die(msg):
    print(f"[checkpoint] REFUSED review @ line {line_no}: {msg}", file=sys.stderr)
    sys.exit(1)
def save(s):
    tmp = path + ".tmp"
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o644)
    with os.fdopen(fd, "w") as f:
        json.dump(s, f, indent=2)
    os.replace(tmp, path)
ROLE_RE = r"reviewer|adversarial|lens:[a-z/-]+"
provenance, source = "declared", ""
s = json.load(open(path))
if os.path.isdir(dstate):
    # Provenance (spec §5.3 G): the verdict must come from a record the
    # orchestrator did not type — a hook-written reviews-raw record or a shim
    # worker result.json — with the same verdict, SHA and role.
    if reviewer_named != "1" or reviewer == "gibson-reviewer":
        die("apex-dispatch state exists: name the reviewer (the default name is not accepted)")
    # A worker directory is exactly one level below <state>/dispatch/workers or
    # the shim worktree root, and the shim root itself is not a symlink.
    shim_root = os.path.join(os.path.realpath(top), ".claude", "apex-dispatch", "worktrees")
    roots = [os.path.realpath(os.path.join(dstate, "workers"))]
    if os.path.realpath(shim_root) == shim_root:
        roots.append(shim_root)
    if agent_id:
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", agent_id):
            die("--agent-id has unexpected characters")
        rec_path = os.path.join(dstate, "reviews-raw", f"{agent_id}.json")
    elif worker:
        real = os.path.realpath(worker)
        if os.path.dirname(real) not in roots:
            die(f"--worker {worker} is not a shim worker directory (one level inside {' or '.join(roots)})")
        rec_path = os.path.join(real, "result.json")
    else:
        die("apex-dispatch state exists, so a verdict needs provenance: --agent-id (hook-written reviews-raw record) "
            "or --worker DIR (worker result.json); a typed verdict is not accepted")
    try:
        rec = json.load(open(rec_path))
        assert isinstance(rec, dict)
    except Exception:
        die(f"no readable provenance record at {rec_path}")
    # A record's identity is the record_id its writer (hook or shim) gives each
    # review run: copies, links, aliases and re-serialisations of one run are
    # one record; a new run is a new record wherever its file lands.
    rid = str(rec.get("record_id", ""))
    if not re.fullmatch(r"[A-Za-z0-9_-]{8,128}", rid):
        die("the provenance record has no record_id (8-128 of [A-Za-z0-9_-], unique per review run)")
    source = "record:" + rid
    if rec.get("head_sha") != sha:
        die(f"the provenance record reviewed {str(rec.get('head_sha'))[:12]}, not {sha[:12]}")
    if rec.get("verdict") != verdict:
        die(f"the provenance record says {rec.get('verdict')}, not {verdict}")
    rrole = str(rec.get("role", ""))
    if not re.fullmatch(ROLE_RE, rrole):
        die(f"the provenance record has role {rec.get('role')!r}, not a reviewer role")
    if role and role != rrole:
        die(f"--role {role} does not match the provenance record's role {rrole}")
    role = rrole
    if str(rec.get("line", "")) != line_no:
        die(f"the provenance record is for line {rec.get('line')!r}, not {line_no} (records must name their task line)")
    if rec.get("route") and route_id and rec["route"] != route_id:
        die(f"the provenance record is for route {rec['route']}, not {route_id}")
    route_id = route_id or str(rec.get("route") or "")
    for ln, rv in (s.get("reviews") or {}).items():
        for x in rv.get("records", []):
            if x.get("source") == source:
                die(f"that provenance record is already recorded (line {ln}, {x.get('role')} on {str(x.get('sha'))[:12]})")
    provider = provider or rec.get("provider", "")
    model = model or rec.get("model", "")
    provenance = "reviews-raw" if agent_id else "worker"
role = role or "reviewer"
r = s.setdefault("reviews", {}).setdefault(line_no, {})
if "records" not in r and r.get("sha"):          # 0.2.0 single record = attempt 1
    r["records"] = [{"attempt": 1, "sha": r["sha"], "verdict": r.get("verdict"), "reviewer": r.get("reviewer"),
                     "role": "reviewer", "provenance": "declared", "at": r.get("at")}]
    if r.get("attempt", 1) == 1:
        r["rounds"] = [r["sha"]]
attempt = r.setdefault("attempt", 1)
rounds = r.setdefault("rounds", [])
if sha not in rounds:
    if len(rounds) >= int(cap):
        die(f"REVIEW_CAP: {len(rounds)} review rounds already in this attempt ({', '.join(x[:12] for x in rounds)}); "
            "record `checkpoint.sh PLAN fail LINE REASON` and retry")
    rounds.append(sha)
r.setdefault("records", []).append({"attempt": attempt, "sha": sha, "verdict": verdict, "reviewer": reviewer,
    "role": role, "provider": provider, "model": model, "agent_id": agent_id, "route": route_id,
    "provenance": provenance, "source": source, "at": now})
r.update({"sha": sha, "verdict": verdict, "reviewer": reviewer, "round": rounds.index(sha) + 1, "at": now})
save(s)
print(f"[checkpoint] review @ line {line_no}: {verdict} on {sha[:12]} (attempt {attempt}, round {rounds.index(sha) + 1}/{cap}, "
      f"{role} by {reviewer}, provenance {provenance})")
PY
    ;;

  approve)
    LINE_NO="${3:?line_no required}"
    SHA="${4:?sha required}"
    PHRASE="${5:?literal approval reply from the human is required}"
    need_line "$LINE_NO"
    need_sha "$SHA"
    python3 -c "$PY_SAVE"'
import sys
path, now, line_no, sha, phrase = sys.argv[1:]
s = json.load(open(path))
s.setdefault("approvals", {})[line_no] = {"gate": "G12", "sha": sha, "phrase": phrase, "at": now}
if s.get("halted") and str(s.get("halt_reason", "")).startswith("awaiting human gate G12"):
    s["halted"] = False
    s["halt_reason"] = None
save(path, s)
print(f"[checkpoint] G12 approval recorded @ line {line_no} for {sha[:12]}")' "$CHECKPOINT" "$NOW" "$LINE_NO" "$SHA" "$PHRASE"
    ;;

  halt)
    REASON="${3:-unspecified}"
    python3 -c "$PY_SAVE"'
import sys
path, now, reason = sys.argv[1:]
with open(path) as f: s = json.load(f)
s["halted"] = True
s["halt_reason"] = reason
s["last_iteration_at"] = now
save(path, s)' "$CHECKPOINT" "$NOW" "$REASON"
    echo "[checkpoint] HALTED: $REASON"
    ;;

  resume)
    REASON="${3:?resume needs a reason (the human decision that clears the halt)}"
    python3 -c "$PY_SAVE"'
import sys
path, now, reason = sys.argv[1:]
with open(path) as f: s = json.load(f)
s.setdefault("resumes", []).append({"reason": reason, "halt_reason": s.get("halt_reason"),
                                    "consecutive_failures": s.get("consecutive_failures", 0), "at": now})
s["halted"] = False
s["halt_reason"] = None
s["consecutive_failures"] = 0
save(path, s)' "$CHECKPOINT" "$NOW" "$REASON"
    echo "[checkpoint] resumed: $REASON"
    ;;

  rewind)
    LINE_NO="${3:?line_no required}"
    need_line "$LINE_NO"
    if [[ "$(task_field checked)" != "1" ]]; then
      echo "[checkpoint] line $LINE_NO is not checked — nothing to rewind"
      exit 0
    fi
    sed -i.bak "${LINE_NO}s/^- \[[xX]\]/- [ ]/" "$PLAN" && rm -f "${PLAN}.bak"
    python3 -c "$PY_SAVE"'
import sys
path, line_no = sys.argv[1:]
with open(path) as f: s = json.load(f)
s["completed_tasks"] = max(0, s.get("completed_tasks", 0) - 1)
s["retired"] = False
# The chain floor moves back to before this task: its code (and everything
# completed after it) is in the next task diff again.
c = s.get("completes") or []
idx = [i for i, e in enumerate(c) if e.get("line") == int(line_no)]
if idx:
    s["completes"] = c[:idx[-1]]
save(path, s)' "$CHECKPOINT" "$LINE_NO"
    echo "[checkpoint] rewound line $LINE_NO"
    ;;

  *) echo "ERROR: unknown action $ACTION" >&2; exit 1 ;;
esac
