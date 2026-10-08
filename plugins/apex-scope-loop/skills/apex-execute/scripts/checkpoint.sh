#!/usr/bin/env bash
# checkpoint.sh — Mark a phase complete (or rewind) and update state.
# Usage:
#   ./checkpoint.sh PLAN.md complete LINE_NO VERDICT_REASON [--skip-review "why"]
#   ./checkpoint.sh PLAN.md fail     LINE_NO REASON [--progress "what this attempt closed"]
#   ./checkpoint.sh PLAN.md review   LINE_NO SHA APPROVE|REQUEST_CHANGES [REVIEWER]
#                     [--role reviewer|adversarial|lens:<name>] [--agent-id ID | --worker DIR]
#                     [--provider P] [--model M] [--route ROUTE_ID] [--mode full|verify]
#   ./checkpoint.sh PLAN.md approve  LINE_NO SHA "<the human's literal approval reply>"
#   ./checkpoint.sh PLAN.md waive    LINE_NO SHA "<the human's literal reply>" "<the residual risk accepted>"
#   ./checkpoint.sh PLAN.md freeze   LINE_NO SHA [--reviewers N] [--mode full|verify]   # hold the head during a review round
#   ./checkpoint.sh PLAN.md unfreeze LINE_NO
#   ./checkpoint.sh PLAN.md review-mode LINE_NO   # read-only: REVIEW_MODE / REVIEW_SINCE for the next round
#   ./checkpoint.sh PLAN.md halt     REASON
#   ./checkpoint.sh PLAN.md resume   REASON       # human: clear a halt and the error budget
#   ./checkpoint.sh PLAN.md refork   REASON       # after merging a moved base: re-review against it
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
# SHA reviewed in the current attempt. A new round is refused once
# APEX_REVIEW_CAP (default 3; a plan's `Review: cap=<n>` overrides it) rounds
# of the attempt requested changes — record `fail` and retry instead; rounds
# that approved do not count (ADR-0004). `complete`
# needs an APPROVE at the exact head in the current attempt, and no
# REQUEST_CHANGES at that head in any attempt (a new attempt needs a new
# commit, not a new reviewer). Tier C also needs an APPROVE recorded with
# --role adversarial and can never use --skip-review.
# After REQUEST_CHANGES in APEX_ASK_HUMAN_AFTER rounds (default 2) of the
# attempt, `review` prints ASK_HUMAN: (ADR-0004). `waive` records the human's
# acceptance of the residual risk at one SHA in operator_overrides[]; it lifts
# only REQUEST_CHANGES verdicts at that SHA, line, epoch and attempt (see the
# waive action), and the completion is recorded as waived.
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
# Error budget on `fail` (progress-aware, ADR-0004): after
# APEX_ESCALATE_AFTER consecutive failures (default 2) it prints ESCALATE (buy
# a second opinion from a different agent). A failure is a stall unless
# --progress says what the attempt closed AND the worktree head moved since
# the previous failure on that line (else since the task base); the plan
# halts at APEX_ERROR_BUDGET stalls (default 3) in the failure streak, or at
# APEX_ATTEMPT_CAP consecutive failures (default 6) whatever their kind; the
# HALTED line names the counter that fired. A failure starts a new review
# attempt for the line. With apex-dispatch, ESCALATE_ROUTE: lines
# come from `route.sh escalate`.
set -euo pipefail

PLAN="${1:?usage: checkpoint.sh PLAN.md ACTION [...]}"
ACTION="${2:?action: complete|fail|review|review-mode|approve|waive|freeze|unfreeze|halt|resume|refork|rewind}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"; PLAN="$(apex_locate_plan "$PLAN")"   # ADR-0004 H
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
# apex-dispatch records dispatch_enforced when it first creates <state>/dispatch/;
# removing the directory afterwards must not drop the run out of provenance mode.
if [[ ( "$ACTION" == review || "$ACTION" == complete ) && ! -d "$DISPATCH_STATE" && "$(read_field dispatch_enforced)" == "True" ]]; then
  echo "[checkpoint] REFUSED $ACTION: this run was dispatch-enforced (checkpoint dispatch_enforced) but $DISPATCH_STATE is gone" >&2
  exit 1
fi

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
# the lessons and backlog ledgers (edited in place) are left out — as exact regular files,
# the plan only as a .md file, the ledgers only at .claude/apex-scope-loop/{LESSONS,BACKLOG}.md.
dirty_paths() {
  { apex_git "$WT" status --porcelain=v1 -z --untracked-files=all --ignore-submodules=none 2>/dev/null || printf '?? ?\0'; } | python3 -c '
import os, sys
wt, has_wt, plan, ledger, backlog = sys.argv[1:]
keep = set()
if has_wt != "1":
    for p in (plan, ledger, backlog):
        if p and os.path.isfile(p) and not os.path.islink(p):
            rel = os.path.relpath(os.path.abspath(p), os.path.abspath(wt))
            if (p == plan and not rel.endswith(".md")) or (p != plan and rel not in (
                    ".claude/apex-scope-loop/LESSONS.md", ".claude/apex-scope-loop/BACKLOG.md")):
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
        print(path)' "$WT" "$([[ -n "$(read_field worktree_branch)" ]] && echo 1 || echo 0)" "$PLAN_ABS" "${LESSONS_LEDGER:-}" "${BACKLOG_LEDGER:-}"
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
    SKIP_REVIEW=""; WAIVED_IDX=""; DIRECTIVE_REC=""
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
      CK_OUT="$(python3 - "$CHECKPOINT" "$STATE_DIR/gate/last.json" "$LINE_NO" "$HEAD_V" "$SKIP_REVIEW" "$COMPUTED" "$FLOOR" "$DISPATCH_STATE" "$DISPATCH" "$PLAN_HASH" "$PLAN" "$TASK_JSON" "$(sed -n '/^SIGNAL_LENSES: /{s///p;q;}' <<<"$RT_OUT")" <<'PY'
import json, os, sys
cp, gate_path, line_no, head, skip, computed, floor, dstate, droot, plan_hash, plan_arg, task_json, signal_lenses = sys.argv[1:]
s = json.load(open(cp))
problems = []
order = {"A": 0, "B": 1, "C": 2}
g = json.load(open(gate_path)) if os.path.isfile(gate_path) else None
if not g:
    problems.append(f"no green-gate result for line {line_no} — run: green-gate.sh {plan_arg} check")
elif g.get("head_sha") != head:
    problems.append(f"green gate ran on {g.get('head_sha','?')[:12]}, worktree head is {head[:12]} — re-run: green-gate.sh {plan_arg} check")
elif g.get("result") not in ("PASS", "SKIPPED"):
    problems.append(f"green gate is {g.get('result')} — zero new failures vs. baseline required")
epoch = s.get("epoch", 0)           # bumped by refork: earlier tiers and reviews saw a narrower diff
trec = s.get("tiers", {}).get(line_no) or {}
if trec and trec.get("epoch", 0) != epoch:
    trec = {}
recorded = trec.get("tier")
if recorded is None:
    problems.append(f"no risk tier recorded for line {line_no} — run risk-tier.sh for line {line_no} first: risk-tier.sh {plan_arg} {line_no} --since {floor} (TASK_BASE)")
elif trec.get("head") != head:
    problems.append(f"the risk tier was recorded for {str(trec.get('head') or 'an older version')[:12]}, not the head {head[:12]} "
                    f"— re-run: risk-tier.sh {plan_arg} {line_no} --since {floor} (TASK_BASE)")
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
# A human review waiver (ADR-0004, checkpoint.sh waive) for exactly this line,
# head, epoch and attempt accepts the REQUEST_CHANGES verdicts at this head as
# residual risk. It covers review findings only: the gate, the tier, G12,
# --skip-review rules, refused/unparsed records and Acceptance still apply,
# and a reviewer who never reviewed this head is never counted.
# Only the REQUEST_CHANGES records the waiver listed when it was written are
# covered (by index, verdict, SHA and source; the count must match
# waived_verdicts): a verdict recorded after the waiver is not.
waiver, waived_ids, covered_rids = None, set(), set()
for i, w in enumerate(s.get("operator_overrides") or []):
    if isinstance(w, dict) and w.get("kind") == "review_waiver" and str(w.get("line")) == line_no and w.get("sha") == head \
            and w.get("epoch", 0) == epoch and w.get("attempt") == attempt and str(w.get("reply") or "").strip():
        cov = w.get("covered") if isinstance(w.get("covered"), list) else []
        ids, rids = set(), set()
        for c in cov:
            j = c.get("index") if isinstance(c, dict) else None
            if isinstance(j, int) and 0 <= j < len(records):
                x = records[j]
                if x.get("sha") == head and x.get("verdict") == "REQUEST_CHANGES" and (x.get("source") or "") == (c.get("source") or ""):
                    ids.add(id(x))
                    if str(x.get("source") or "").startswith("record:"):
                        rids.add(x["source"][7:])
        if ids and len(ids) == w.get("waived_verdicts"):
            waiver = (i, w)
            waived_ids |= ids
            covered_rids |= rids
def waived(x):
    return id(x) in waived_ids
used_waiver = any(waived(x) for x in at_head)
if any(x.get("verdict") != "APPROVE" and not waived(x) for x in at_head):
    # Any attempt: a failure starts a new attempt, it does not launder a verdict.
    problems.append(f"a review of the head {head[:12]} requested changes — address the findings in a new commit and re-review "
                    f"(or, after the human accepts the residual risk: checkpoint.sh PLAN waive {line_no} {head} \"<reply>\" \"<risk>\")")
if skip and tier == "C":
    problems.append("Tier C: --skip-review cannot waive the review and adversarial pass")
elif not skip:
    recs = [x for x in at_head if x.get("attempt", 1) == attempt and x.get("epoch", 0) == epoch]
    if not recs:
        problems.append(f"no independent review recorded for line {line_no} at the worktree head "
                        f"{head[:12]} in this attempt — dispatch the reviewer, then: checkpoint.sh {plan_arg} review {line_no} {head} APPROVE|REQUEST_CHANGES")
    elif tier == "C" and not any(x.get("role") == "adversarial" and (x.get("verdict") == "APPROVE" or waived(x)) for x in recs):
        problems.append("Tier C: an adversarial review (--role adversarial) approving this exact head is required")
    # Review mode (ADR-0004 §3): some round of this attempt must have been a
    # full review at the effective tier, and for Tier C a full-mode
    # adversarial pass at Tier C; verify-only rounds never stand in for them.
    att = [x for x in records if x.get("attempt", 1) == attempt and x.get("epoch", 0) == epoch]
    full = [x for x in att if x.get("mode", "full") == "full"]
    if not full or max(order.get(x.get("tier") or "A", 0) for x in full) < order[tier]:
        problems.append(f"no full review at Tier {tier} in this attempt (the tier rose after the full round, or every round was verify-only) "
                        f"— run a full round: SINCE = TASK_BASE, checkpoint.sh {plan_arg} freeze {line_no} <sha> --mode full, review … --mode full")
    elif tier == "C" and not any(x.get("role") == "adversarial" and x.get("tier") == "C" for x in full):
        problems.append("Tier C: a full-mode adversarial review at Tier C in this attempt is required (risk-tier.sh before it; --mode full)")
# The plan's Review: directive (ADR-0004 addendum B). Tier A/B: it may drop
# the adversarial pass and choose the lenses. Tier C (and, without dispatch
# state, a task tagged security/auth/money/billing/payment/pii/consent/
# migration): it may narrow the lens fan-out to no fewer than 3 DISTINCT
# lenses, which must include the lens of each triggering signal (money,
# security, consent-pii); the adversarial pass and G12 stay. With dispatch
# state it never goes below the active route's review shape.
tj = json.loads(task_json)
rdir = tj.get("review") or {}
dir_applied, dir_ignored = [], []
need_adversarial_override = None          # None = shape decides
want_lenses = None
SENSITIVE_TAGS = {"security", "tier:c", "tier-c", "auth", "money", "billing", "payment", "payments", "pii", "consent", "migration"}
strict = tier == "C" or (not os.path.isdir(dstate) and bool(set(tj.get("tags") or []) & SENSITIVE_TAGS))
signal = {x for x in signal_lenses.split(",") if x}
for x in (trec.get("signal_lenses") or []):
    signal.add(x)
route_floor = None
if os.path.isdir(dstate):
    try:
        ar = json.load(open(os.path.join(dstate, "active-route.json")))
        if isinstance(ar, dict) and str(ar.get("line")) == line_no and isinstance(ar.get("router"), dict):
            route_floor = ar["router"].get("review_shape")
    except Exception:
        pass
if rdir:
    lz = rdir.get("lenses")
    if lz and lz != "all":
        ls = sorted({x for x in lz.split(",") if x})
        if route_floor == "fanout6+adversarial":
            dir_ignored.append(f"lenses={lz} (the active route's review shape {route_floor} needs all six)")
        elif strict and len(ls) < 3:
            dir_ignored.append(f"lenses={lz} (Tier C keeps at least 3 distinct lenses: all six required)")
        else:
            want_lenses = set(ls) | (signal if strict else set())
            extra = sorted(want_lenses - set(ls))
            dir_applied.append(f"lenses={','.join(ls)}" + (f" (+{','.join(extra)} required by the tier signals)" if extra else ""))
    if rdir.get("adversarial") == "no":
        if strict:
            dir_ignored.append("adversarial=no (mandatory for Tier C / sensitive tasks)")
        elif route_floor == "fanout6+adversarial":
            dir_ignored.append(f"adversarial=no (the active route's review shape {route_floor} requires it)")
        else:
            need_adversarial_override = False
            dir_applied.append("adversarial=no")
    if rdir.get("cap"):
        dir_applied.append(f"cap={rdir['cap']}" + (" (may only lower the cap here)" if strict else ""))
if tier == "C":
    a = s.get("approvals", {}).get(line_no)
    if not a or a.get("sha") != head or a.get("epoch", 0) != epoch:
        problems.append(f"Tier C: human approval (G12) for this exact head SHA in this epoch ({head[:12]}) is required — halt and ask with the Ask Contract, then: checkpoint.sh {plan_arg} approve {line_no} {head} \"<reply>\"")
# Provenance mode (apex-dispatch, spec §5.2 step 7 / §5.3 G): the review shape
# and reviewer family diversity of the stricter of the route (its class) and the
# effective tier. fanout6+adversarial needs six distinct lens approvals and an
# adversarial approval at the head; diversity "block" needs an approval from a
# provider other than the in-session one (claude-session), degraded to a warning
# (and a ledger row) when doctor.json shows no second family is available.
if os.path.isdir(dstate) and not skip:
    SHAPES = ["none", "solo", "six-lens", "fanout6+adversarial"]
    DIV = ["off", "warn", "block"]
    shape = {"A": "solo", "B": "six-lens", "C": "fanout6+adversarial"}[tier]
    div = {"A": "off", "B": "warn", "C": "block"}[tier]
    try:
        route = json.load(open(os.path.join(dstate, "active-route.json")))
    except Exception:
        route = {}
    route = route if isinstance(route, dict) else {}
    router = route.get("router") if isinstance(route.get("router"), dict) else {}
    if str(route.get("line")) == line_no:
        if router.get("review_shape") in SHAPES and SHAPES.index(router["review_shape"]) > SHAPES.index(shape):
            shape = router["review_shape"]
        if router.get("diversity") in DIV and DIV.index(router["diversity"]) > DIV.index(div):
            div = router["diversity"]
    # Only verdicts with provenance count here (a typed "declared" record does not).
    approved = [x for x in at_head if x.get("attempt", 1) == attempt and x.get("epoch", 0) == epoch
                and (x.get("verdict") == "APPROVE" or waived(x)) and x.get("provenance") != "declared"]
    # An unfavourable review at this head cannot be discarded by re-spawning
    # reviewers at the same SHA: any hook/shim verdict row or raw record for this
    # line at HEAD that is not APPROVE (an audit-refused record included) blocks
    # complete; only a new commit supersedes it.
    prefix = "r-%s-L%s-" % (plan_hash, line_no)
    def for_line(x):
        return str(x.get("line")) == line_no or str(x.get("route_id") or x.get("route") or "").startswith(prefix)
    bad = []
    rdir = os.path.join(dstate, "reviews-raw")
    for f in sorted(os.listdir(rdir)) if os.path.isdir(rdir) else []:
        try:
            rec = json.load(open(os.path.join(rdir, f)))
        except Exception:
            continue
        if isinstance(rec, dict) and rec.get("head_sha") == head and for_line(rec) and (rec.get("refused") or rec.get("verdict") != "APPROVE") \
                and not (not rec.get("refused") and rec.get("verdict") == "REQUEST_CHANGES" and str(rec.get("record_id") or "") in covered_rids):
            bad.append("%s (%s)" % (f[:-5], "refused by the transcript audit" if rec.get("refused") else rec.get("verdict")))
    try:
        for ln in open(os.path.join(dstate, "ledger.jsonl"), encoding="utf-8"):
            try:
                row = json.loads(ln)
            except ValueError:
                continue
            if row.get("event") == "verdict" and row.get("source") in ("hook", "shim") and row.get("head_sha") == head \
                    and for_line(row) and row.get("verdict") != "APPROVE" \
                    and not (row.get("verdict") == "REQUEST_CHANGES" and str(row.get("record_id") or "") in covered_rids):
                bad.append("ledger seq %s (%s by %s)" % (row.get("seq"), row.get("verdict"), row.get("agent_id") or row.get("role")))
    except OSError:
        pass
    if bad:
        problems.append(f"a review of the head {head[:12]} did not approve ({'; '.join(bad[:4])}) — address it in a new commit "
                        "and re-review; another reviewer at the same SHA does not supersede it")
    LENSES = {"correctness", "security", "consent-pii", "money", "performance", "maintainability"}
    if shape == "fanout6+adversarial":
        need = (want_lenses & LENSES) if want_lenses else LENSES
        lenses = sorted({x["role"][5:] for x in approved if str(x.get("role", "")).startswith("lens:")} & need)
        if len(lenses) < len(need):
            problems.append(f"review shape {shape}: {'six' if len(need) == 6 else len(need)} distinct lens approvals are required at {head[:12]} "
                            f"(have {len(lenses)}: {', '.join(lenses) or 'none'}) — one reviewer per lens "
                            f"({', '.join(sorted(need))}), each ending LENS: <lens>")
        if need_adversarial_override is not False and not any(x.get("role") == "adversarial" for x in approved):
            problems.append(f"review shape {shape}: an adversarial approval at {head[:12]} is required")
    if div != "off" and approved and not any(x.get("provider") not in (None, "", "claude-session") for x in approved):
        try:
            doc = json.load(open(os.path.join(dstate, "doctor.json")))
        except Exception:
            doc = {}
        # One rule with doctor.sh: apex-dispatch's ledger.second_families (an
        # available, verified provider whose bin/worker-*.sh shim ships and that
        # may review this route's class).
        second = []
        if droot:
            try:
                sys.path.insert(0, os.path.join(droot, "scripts", "lib"))
                import ledger
                try:
                    second = ledger.second_families(doc, droot, cls=(router.get("class") if str(route.get("line")) == line_no else None) or None)
                except TypeError:                     # an apex-dispatch before 0.3.0
                    second = ledger.second_families(doc, droot)
            except Exception as e:
                print(f"[checkpoint] warning: could not evaluate reviewer families ({e})", file=sys.stderr)
        msg = ("reviewer family diversity (%s): every approval at %s is from the in-session Claude family" % (div, head[:12]))
        if div == "block" and second:
            problems.append(msg + " — add a review from a second family (%s: bin/worker-<provider>.sh --role reviewer)" % ", ".join(second))
        else:
            why = ("no second family is available (doctor.json shows no enabled provider with a shipped bin/worker-*.sh shim, "
                   "working auth and accepted forced flags)"
                   if div == "block" else "advisory for this shape")
            print("DIVERSITY_WARN: " + msg + "; " + why)
if not problems and used_waiver:
    print("WAIVED: %d" % waiver[0])
if rdir:
    drec = json.dumps({"directive": tj.get("review_raw"), "tier": tier, "applied": dir_applied, "ignored": dir_ignored})
    if problems:
        print("[checkpoint] Review: directive at line " + line_no + ": " + drec, file=sys.stderr)
    else:
        print("DIRECTIVE: " + drec)
if problems:
    print("[checkpoint] REFUSED complete @ line " + line_no + ":", file=sys.stderr)
    for p in problems:
        print("  - " + p, file=sys.stderr)
    sys.exit(1)
PY
)"
      WAIVED_IDX="$(sed -n 's/^WAIVED: //p' <<<"$CK_OUT" | head -1)"
      DIRECTIVE_REC="$(sed -n 's/^DIRECTIVE: //p' <<<"$CK_OUT" | head -1)"
      [[ -n "$DIRECTIVE_REC" ]] && echo "[checkpoint] Review: directive at line $LINE_NO: $DIRECTIVE_REC"
      while IFS= read -r ln; do
        [[ "$ln" == DIVERSITY_WARN:* ]] || continue
        echo "[checkpoint] warning: ${ln#DIVERSITY_WARN: }"
        if [[ -n "$DISPATCH" ]]; then
          "$DISPATCH/scripts/ledger.sh" append hook_advisory \
            "$(python3 -c 'import json,sys; print(json.dumps({"hook": "checkpoint.sh complete", "advisory": sys.argv[1], "line": int(sys.argv[2])}))' "${ln#DIVERSITY_WARN: }" "$LINE_NO")" \
            --state "$STATE_DIR" --source cli 9>&- >/dev/null || echo "[checkpoint] warning: the diversity degrade was not ledgered" >&2
        fi
      done <<<"$CK_OUT"
    fi
    # With apex-dispatch state, the ledger must back the completion (not
    # waived by APEX_GIBSON=0).
    if [[ -d "$DISPATCH_STATE" && "$EXEMPT" == "0" ]]; then
      [[ -n "$DISPATCH" ]] || { echo "[checkpoint] REFUSED complete: dispatch state exists ($DISPATCH_STATE) but apex-dispatch is not installed beside apex-scope-loop (APEX_DISPATCH_ROOT)" >&2; exit 1; }
      "$DISPATCH/scripts/ledger.sh" evidence --state "$STATE_DIR" --plan-hash "$PLAN_HASH" --line "$LINE_NO" --head "$HEAD_V" 9>&- \
        || { echo "[checkpoint] REFUSED complete: ledger evidence missing or the hash chain is broken (ledger.sh evidence)" >&2; exit 1; }
    fi
    # Flip "- [ ]" to "- [x]" on that line (BSD/macOS sed)
    sed -i.bak "${LINE_NO}s/^- \[ \]/- [x]/" "$PLAN" && rm -f "${PLAN}.bak"
    python3 -c "$PY_SAVE"'
import sys
path, now, verdict, line_no, skip, head, harness, remaining, task_id, waived_idx, directive = sys.argv[1:]
with open(path) as f: s = json.load(f)
s["completed_tasks"] = s.get("completed_tasks", 0) + 1
# Retired: a reviewed completion left no task. Only a completion sets it;
# rewind and the next brief (iterate.sh) clear it. apex_unreviewed_runs skips
# a retired run (unless its plan, when present, has a task again).
s["retired"] = harness == "1" and remaining == "0"
# The chain advances only past code the harness verified (APEX_GIBSON=0
# completions leave their code in the diff of the next task).
if harness == "1" and head != "unknown":
    c = {"line": int(line_no), "id": task_id, "head": head, "at": now}
    if waived_idx:
        c["review"] = "waived"            # never recorded as an APPROVE
        c["waiver"] = int(waived_idx)     # index into operator_overrides
    if directive:
        c["review_directive"] = json.loads(directive)   # what the Review: directive of the plan changed
    s.setdefault("completes", []).append(c)
s["last_verdict"] = {"line_no": int(line_no), "result": "pass", "reason": verdict, "at": now}
if waived_idx:
    s["last_verdict"]["review"] = "waived"
if skip:
    s.setdefault("skipped_reviews", {})[line_no] = {"reason": skip, "at": now}
s["last_iteration_at"] = now
s["current_phase"] = None
s["consecutive_failures"] = 0
s["consecutive_stalls"] = 0
s.pop("fail_heads", None)
(s.get("freezes") or {}).pop(line_no, None)
save(path, s)' "$CHECKPOINT" "$NOW" "$VERDICT" "$LINE_NO" "$SKIP_REVIEW" "$HEAD_V" "$([[ "${APEX_GIBSON:-1}" != "0" ]] && echo 1 || echo 0)" \
      "$(python3 "$APEX_EXECUTE_SCRIPTS/planlib.py" remaining "$PLAN" 2>/dev/null || echo "?")" \
      "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("id") or "")' "$TASK_JSON")" "$WAIVED_IDX" "$DIRECTIVE_REC"
    apex_lock_stage "$PLAN_HASH" DONE   # this plan's lock becomes reclaimable until its next iterate
    "$APEX_EXECUTE_SCRIPTS/snapshot.sh" "$PLAN" prune 9>&- >/dev/null 2>&1 || true   # review snapshots are per head
    "$APEX_EXECUTE_SCRIPTS/backlog.sh" "$PLAN" confirm "$LINE_NO" "$HEAD_V" 9>&- 2>/dev/null | grep -v 'confirmed nothing' || true
    echo "[checkpoint] complete @ line $LINE_NO ($VERDICT)${WAIVED_IDX:+ — review findings at ${HEAD_V:0:12} accepted by human waiver (operator_overrides[$WAIVED_IDX]); recorded as waived, not approved}"
    ;;

  fail)
    LINE_NO="${3:?line_no required}"
    REASON="${4:-unspecified}"
    PROGRESS=""
    if [[ $# -ge 5 ]]; then
      [[ "$5" == "--progress" ]] || { echo "ERROR: unknown fail option $5 (usage: fail LINE REASON [--progress \"what this attempt closed\"])" >&2; exit 1; }
      PROGRESS="${6:?--progress needs a description of what this attempt closed}"
    fi
    need_line "$LINE_NO"
    # Progress-aware halts (ADR-0004): a failure is a stall unless --progress
    # says what it closed AND the worktree head moved since the previous
    # failure on this line (else since the task's diff base).
    HEAD_F="$(head_sha)"
    FLOOR_F="$(apex_floor "$WT" 2>/dev/null || true)"
    python3 -c "$PY_SAVE"'
import sys
path, now, reason, line_no, esc, budget, cap, progress, head, floor = sys.argv[1:]
s = json.load(open(path))
n = s.get("consecutive_failures", 0) + 1
s["consecutive_failures"] = n
fh = s.setdefault("fail_heads", {})
prev = fh.get(line_no) or floor or ""
moved = head not in ("", "unknown") and head != prev
stall = not (progress.strip() and moved)
stalls = s.get("consecutive_stalls", 0) + (1 if stall else 0)
s["consecutive_stalls"] = stalls
fh[line_no] = head
kind = "stall" if stall else "progress"
why_kind = ("" if not stall else
            " (no --progress given)" if not progress.strip() else
            " (--progress given but the head did not move since " + (prev[:12] or "the task base") + ")")
s["last_verdict"] = {"line_no": int(line_no), "result": "fail", "reason": reason, "kind": kind,
                     "progress": progress or None, "head": head, "at": now}
s["last_iteration_at"] = now
print(f"[checkpoint] FAIL @ line {line_no} ({n} consecutive, {stalls} stalls; this one: {kind}{why_kind}): {reason}")
halt = None
if stalls >= int(budget):
    halt = f"error budget exhausted: {stalls} stalled failures (APEX_ERROR_BUDGET={budget}) in {n} consecutive (last: {reason})"
elif n >= int(cap):
    halt = f"attempt cap reached: {n} consecutive failures (APEX_ATTEMPT_CAP={cap}), {stalls} of them stalls (last: {reason})"
if halt:
    s["halted"] = True
    s["halt_reason"] = halt
    print(f"[checkpoint] HALTED: {halt}")
elif n >= int(esc):
    print("ESCALATE: second-opinion — dispatch a different agent (fresh context, different model if available) to diagnose before retrying")
# A failure ends the review attempt for the line: the next attempt gets fresh rounds.
r = s.setdefault("reviews", {}).setdefault(line_no, {})
r["attempt"] = r.get("attempt", 1) + 1
r["rounds"] = []
(s.get("freezes") or {}).pop(line_no, None)     # a new attempt is never frozen
save(path, s)' "$CHECKPOINT" "$NOW" "$REASON" "$LINE_NO" "${APEX_ESCALATE_AFTER:-2}" "${APEX_ERROR_BUDGET:-3}" "${APEX_ATTEMPT_CAP:-6}" \
      "$PROGRESS" "$HEAD_F" "$FLOOR_F"
    "$APEX_EXECUTE_SCRIPTS/backlog.sh" "$PLAN" reopen "$LINE_NO" 9>&- >/dev/null 2>&1 || true   # pending closes of a failed attempt
    # apex-dispatch decides the next rung (effort+1, model+1, diagnoser, HALT).
    # (<state>/dispatch-shadow/ holds the route while apex-dispatch is not enforcing.)
    ROUTE_FILE="$DISPATCH_STATE/active-route.json"
    [[ -f "$ROUTE_FILE" ]] || ROUTE_FILE="$STATE_DIR/dispatch-shadow/active-route.json"
    if [[ -f "$ROUTE_FILE" ]]; then
      RID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("route_id",""))' "$ROUTE_FILE" 2>/dev/null || true)"
      if [[ -z "$DISPATCH" ]]; then
        echo "ESCALATE_ROUTE: error apex-dispatch is not installed beside apex-scope-loop (APEX_DISPATCH_ROOT); no escalation rung for ${RID:-the active route}"
      elif [[ -z "$RID" ]]; then
        echo "ESCALATE_ROUTE: error $ROUTE_FILE has no route_id"
      else
        "$DISPATCH/scripts/route.sh" escalate "$RID" --state "$STATE_DIR" 9>&- 2>&1 | sed 's/^/ESCALATE_ROUTE: /' || echo "ESCALATE_ROUTE: error route.sh escalate $RID failed"
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
    ROLE=""; AGENT_ID=""; WORKER=""; PROVIDER=""; MODEL=""; ROUTE_ID=""; RMODE=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --mode) RMODE="${2:?}"; shift 2 ;;
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
    # A plan's Review: cap=<n> sets this task's cap (ADR-0004 addendum B).
    REVIEW_CAP="${APEX_REVIEW_CAP:-3}"
    DCAP="$(python3 -c 'import json,sys; print((json.loads(sys.argv[1]).get("review") or {}).get("cap") or "")' "$TASK_JSON")"
    case "$VERDICT" in APPROVE|REQUEST_CHANGES) ;; *) echo "ERROR: verdict must be APPROVE or REQUEST_CHANGES" >&2; exit 1 ;; esac
    [[ -z "$ROLE" || "$ROLE" =~ ^(reviewer|adversarial|lens:[a-z/-]+)$ ]] || { echo "ERROR: --role must be reviewer, adversarial or lens:<name>" >&2; exit 1; }
    [[ -n "$AGENT_ID" && -n "$WORKER" ]] && { echo "ERROR: --agent-id and --worker are exclusive" >&2; exit 1; }
    ASK_AFTER="${APEX_ASK_HUMAN_AFTER:-2}"; [[ "$ASK_AFTER" =~ ^[1-9][0-9]{0,2}$ ]] || ASK_AFTER=2
    [[ -z "$RMODE" || "$RMODE" == full || "$RMODE" == verify ]] || { echo "ERROR: --mode must be full or verify" >&2; exit 1; }
    python3 - "$CHECKPOINT" "$NOW" "$LINE_NO" "$SHA" "$VERDICT" "$REVIEWER" "$REVIEWER_NAMED" "$ROLE" "$AGENT_ID" "$WORKER" \
      "$PROVIDER" "$MODEL" "$ROUTE_ID" "$DISPATCH_STATE" "${PLAN_TOP:-$REPO_ROOT}" "$REVIEW_CAP" "$(head_sha)" "$ASK_AFTER" "$DCAP" "$TASK_JSON" "$RMODE" <<'PY'
import json, os, re, sys
(path, now, line_no, sha, verdict, reviewer, reviewer_named, role, agent_id, worker,
 provider, model, route_id, dstate, top, cap, wt_head, ask_after, dcap, task_json, rmode) = sys.argv[1:]
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
SENSITIVE_TAGS = {"security", "tier:c", "tier-c", "auth", "money", "billing", "payment", "payments", "pii", "consent", "migration"}
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
    if rec.get("refused"):
        die(f"the review record was refused by apex-dispatch's transcript audit: {str(rec['refused'])[:300]}")
    if rec.get("stale"):
        die(f"the review record is stale ({str(rec['stale'])[:200]}): it reviewed {str(rec.get('head_sha'))[:12]}, re-review the current head")
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
    if worker:
        # A shim result (apex-dispatch bin/worker-<provider>.sh): a finished run of a
        # provider other than the in-session one, reviewing the worktree's current
        # HEAD, whose verdict the shim also wrote to the hash-chained ledger.
        if rec.get("source") != "shim" or str(rec.get("provider") or "") in ("", "claude-session"):
            die("the worker record is not a provider shim result (source shim, provider other than claude-session)")
        if rec.get("exit_code") != 0 or not rec.get("sentinel_seen"):
            die(f"the worker run did not finish cleanly (exit {rec.get('exit_code')}, sentinel {rec.get('sentinel_seen')})")
        if sha != wt_head:
            die(f"the worker reviewed {sha[:12]} but the worktree HEAD is {wt_head[:12]}: re-review the current head")
        found = False
        try:
            for ln in open(os.path.join(dstate, "ledger.jsonl"), encoding="utf-8"):
                try:
                    row = json.loads(ln)
                except ValueError:
                    continue
                if row.get("event") == "verdict" and row.get("source") == "shim" and row.get("record_id") == rid \
                        and row.get("verdict") == rec.get("verdict") and row.get("head_sha") == sha:
                    found = True
                    break
        except OSError:
            pass
        if not found:
            die("no shim verdict row in the ledger carries this record_id at that SHA (the result was not written by a shim run)")
    # Provider and family come from the record (what ran), never from the caller.
    provider = str(rec.get("provider") or "")
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
# The tier this review is done at (iterate.sh forces a full review when the
# tier rises above every tier reviewed in the attempt).
trec = (s.get("tiers") or {}).get(line_no) or {}
tier_at = trec.get("tier") if trec.get("epoch", 0) == s.get("epoch", 0) else None
# Review: cap=<n> sets the cap; for Tier C (or a sensitive-tagged task) it may
# only lower it (ADR-0004).
if dcap:
    tags = set(json.loads(task_json).get("tags") or [])
    sensitive = tier_at == "C" or bool(tags & SENSITIVE_TAGS)
    cap = str(min(int(dcap), int(cap))) if sensitive else dcap
# A head frozen for review (checkpoint.sh freeze) takes no verdict for another SHA.
fz = (s.get("freezes") or {}).get(line_no)
if fz and fz.get("sha") != sha:
    die(f"the head is frozen at {str(fz.get('sha'))[:12]} for a review round ({fz.get('recorded', 0)}/{fz.get('reviewers', 1)} verdicts in); "
        f"fixes wait and land as one batch after the round — record the round's verdicts, or: checkpoint.sh PLAN unfreeze {line_no}")
# The cap counts only rounds that requested changes (ADR-0004 addendum B):
# a round that approved, or had only non-blocking findings, does not use it.
blocking_rounds = [x for x in rounds if any(y.get("sha") == x and y.get("attempt", 1) == attempt and y.get("verdict") == "REQUEST_CHANGES"
                                             for y in r.get("records", []))]
if sha not in rounds:
    if len(blocking_rounds) >= int(cap):
        die(f"REVIEW_CAP: {len(blocking_rounds)} review rounds requested changes in this attempt ({', '.join(x[:12] for x in blocking_rounds)}; cap {cap}); "
            "record `checkpoint.sh PLAN fail LINE REASON` and retry, or ask the human (waive)")
    rounds.append(sha)
# The review's mode (ADR-0004 §3): --mode, else the freeze's, else full.
mode = rmode or (fz.get("mode") if fz and fz.get("sha") == sha else "") or "full"
r.setdefault("records", []).append({"attempt": attempt, "epoch": s.get("epoch", 0), "tier": tier_at, "mode": mode, "sha": sha, "verdict": verdict, "reviewer": reviewer,
    "role": role, "provider": provider, "model": model, "agent_id": agent_id, "route": route_id,
    "provenance": provenance, "source": source, "at": now})
r.update({"sha": sha, "verdict": verdict, "reviewer": reviewer, "round": rounds.index(sha) + 1, "at": now})
lifted = False
if fz:
    fz["recorded"] = fz.get("recorded", 0) + 1
    if fz["recorded"] >= int(fz.get("reviewers", 1)):
        s["freezes"].pop(line_no, None)
        lifted = True
save(s)
nb = len([x for x in rounds if any(y.get("sha") == x and y.get("attempt", 1) == attempt and y.get("verdict") == "REQUEST_CHANGES"
                                   for y in r.get("records", []))])
print(f"[checkpoint] review @ line {line_no}: {verdict} on {sha[:12]} (attempt {attempt}, round {rounds.index(sha) + 1}, "
      f"{nb}/{cap} blocking rounds, {role} by {reviewer}, provenance {provenance})")
if lifted:
    print(f"FREEZE: lifted at {sha[:12]} — all {fz['recorded']} verdicts of the round are in; fixes may land now")
# Earlier human escalation (ADR-0004): after REQUEST_CHANGES in ask_after
# rounds of this attempt, the orchestrator asks the human instead of looping.
rc_rounds = sorted({x["sha"] for x in r["records"] if x.get("attempt", 1) == attempt and x.get("verdict") == "REQUEST_CHANGES"},
                   key=lambda x: rounds.index(x) if x in rounds else 99)
prior_waivers = [w for w in s.get("operator_overrides") or [] if isinstance(w, dict) and w.get("kind") == "review_waiver"
                 and str(w.get("line")) == line_no and w.get("sha") == sha and w.get("attempt") == attempt and w.get("epoch", 0) == s.get("epoch", 0)]
outstanding = fz and not lifted
# When a frozen round completes, its REQUEST_CHANGES (any of its verdicts)
# trigger the final ASK_HUMAN now, even if the last verdict approved.
rc_now = verdict == "REQUEST_CHANGES" or (lifted and any(x.get("sha") == sha and x.get("attempt", 1) == attempt
                                                          and x.get("verdict") == "REQUEST_CHANGES" for x in r["records"]))
if verdict == "REQUEST_CHANGES" and outstanding and (prior_waivers or len(rc_rounds) >= int(ask_after)):
    print(f"ASK_HUMAN: pending — record the rest of this round's verdicts first ({fz.get('recorded', 0)}/{fz.get('reviewers', 1)} in), "
          "then ask the human about all of them (do not halt yet)")
elif rc_now and prior_waivers and any(i not in {c.get("index") for w in prior_waivers for c in (w.get("covered") or []) if isinstance(c, dict)}
                                     for i, x in enumerate(r["records"]) if x.get("sha") == sha and x.get("verdict") == "REQUEST_CHANGES"
                                     and x.get("attempt", 1) == attempt):
    print(f"ASK_HUMAN: new REQUEST_CHANGES at {sha[:12]} after the waiver — not covered by it; ask the human again "
          f"(a new waiver covers it: checkpoint.sh PLAN waive {line_no} {sha} \"<their literal reply>\" \"<the residual risk accepted>\")")
elif rc_now and not prior_waivers and len(rc_rounds) >= int(ask_after):
    print(f"ASK_HUMAN: line {line_no} has REQUEST_CHANGES in {len(rc_rounds)} review rounds of attempt {attempt} "
          f"(APEX_ASK_HUMAN_AFTER={ask_after}) — halt and ask the human with the Ask Contract: accept the residual risk "
          f"at {sha[:12]} (reply 'waive {line_no}', then: checkpoint.sh PLAN waive {line_no} {sha} \"<their literal reply>\" "
          f"\"<the residual risk accepted>\") or keep fixing?")
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
s.setdefault("approvals", {})[line_no] = {"gate": "G12", "sha": sha, "epoch": s.get("epoch", 0), "phrase": phrase, "at": now}
if s.get("halted") and str(s.get("halt_reason", "")).startswith("awaiting human gate G12"):
    s["halted"] = False
    s["halt_reason"] = None
save(path, s)
print(f"[checkpoint] G12 approval recorded @ line {line_no} for {sha[:12]}")' "$CHECKPOINT" "$NOW" "$LINE_NO" "$SHA" "$PHRASE"
    ;;

  waive)
    # A human accepts the residual risk of a task's review findings at one
    # head (ADR-0004 §5). Records into operator_overrides[] (the writer
    # ADR-0003 §5 named as missing), bound to LINE + SHA + epoch + attempt.
    # It unlocks only REQUEST_CHANGES verdicts at that SHA in `complete`
    # (and, in provenance mode, the "non-APPROVE at HEAD is final" block for
    # them). It never unlocks: the green gate, the risk tier record, G12 for
    # Tier C, refused or unparsed review records, a role that never reviewed
    # the head, Acceptance, another SHA, another epoch or a later attempt.
    LINE_NO="${3:?line_no required}"
    SHA="${4:?sha required}"
    REPLY="${5:-}"
    RISK="${6:-}"
    need_line "$LINE_NO"
    need_sha "$SHA"
    [[ -n "${REPLY//[[:space:]]/}" ]] || { echo "[checkpoint] REFUSED waive: the human's literal reply is required (it must contain 'waive $LINE_NO')" >&2; exit 1; }
    [[ -n "${RISK//[[:space:]]/}" ]] || { echo "[checkpoint] REFUSED waive: name the residual risk the human accepted (6th argument)" >&2; exit 1; }
    # Validate the reply and the checkpoint before anything is ledgered. The
    # waiver covers exactly the REQUEST_CHANGES records at SHA that exist now
    # (their indices, sources and times are stored); a verdict recorded later
    # is never covered.
    WV="$(python3 - "$CHECKPOINT" "$LINE_NO" "$SHA" "$REPLY" <<'PY'
import json, re, sys
path, line_no, sha, reply = sys.argv[1:]
def refuse(msg):
    print("[checkpoint] REFUSED waive: " + msg, file=sys.stderr)
    sys.exit(1)
# Strict form, no negation parsing: after trimming whitespace and optional
# surrounding quotes/backticks, the reply must START with "waive <LINE>"
# (any case), followed by the end or a separator; a remark may follow.
body = reply.strip().strip("\"'`\u2018\u2019\u201c\u201d").strip()
if not re.match(r"waive\s+%s(?:$|[\s.,:;\u2014\u2013-])" % re.escape(line_no), body, re.I):
    refuse(f"the reply does not start with 'waive {line_no}' — ask the human to reply plainly `waive {line_no}` (optionally followed by a remark)")
s = json.load(open(path))
fz = (s.get("freezes") or {}).get(line_no)
if fz and fz.get("recorded", 0) < int(fz.get("reviewers", 1)):
    refuse(f"the review round at {str(fz.get('sha'))[:12]} still has verdicts outstanding ({fz.get('recorded', 0)}/{fz.get('reviewers', 1)}) — "
           "record them (or unfreeze) and ask the human about all of them")
r = (s.get("reviews") or {}).get(line_no) or {}
attempt, epoch = r.get("attempt", 1), s.get("epoch", 0)
cov = [{"index": i, "source": x.get("source") or "", "role": x.get("role"), "at": x.get("at")}
       for i, x in enumerate(r.get("records") or []) if x.get("sha") == sha and x.get("verdict") == "REQUEST_CHANGES"
       and x.get("attempt", 1) == attempt and x.get("epoch", 0) == epoch]
if not cov:
    refuse(f"no review requested changes at {sha[:12]} in attempt {attempt} (epoch {epoch}) of line {line_no} — nothing to waive")
print(attempt, epoch, len(cov), json.dumps(cov, separators=(",", ":")))
PY
)" || exit 1
    read -r W_ATTEMPT W_EPOCH W_N W_COV <<<"$WV"
    # With apex-dispatch state, the waiver is ledgered first (a non-provenance
    # human_gate row); no ledger row, no waiver.
    if [[ -d "$DISPATCH_STATE" ]]; then
      [[ -n "$DISPATCH" ]] || { echo "[checkpoint] REFUSED waive: dispatch state exists but apex-dispatch is not installed beside apex-scope-loop (the waiver must be ledgered)" >&2; exit 1; }
      RID="$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r.get("route_id","") if str(r.get("line"))==sys.argv[2] else "")' "$DISPATCH_STATE/active-route.json" "$LINE_NO" 2>/dev/null || true)"
      "$DISPATCH/scripts/ledger.sh" append human_gate \
        "$(python3 -c 'import json,sys; print(json.dumps({"gate": "review-waiver", "decision": "approved", "line": int(sys.argv[1]), "sha": sys.argv[2], "attempt": int(sys.argv[3]), "epoch": int(sys.argv[4]), "reply": sys.argv[5], "residual_risk": sys.argv[6]}))' "$LINE_NO" "$SHA" "$W_ATTEMPT" "$W_EPOCH" "$REPLY" "$RISK")" \
        --state "$STATE_DIR" --source cli --head "$SHA" ${RID:+--route-id "$RID"} 9>&- >/dev/null \
        || { echo "[checkpoint] REFUSED waive: the waiver could not be ledgered (ledger.sh append human_gate)" >&2; exit 1; }
    fi
    python3 -c "$PY_SAVE"'
import sys
path, now, line_no, sha, reply, risk, attempt, epoch, n, cov = sys.argv[1:]
s = json.load(open(path))
o = s.setdefault("operator_overrides", [])
o.append({"kind": "review_waiver", "line": int(line_no), "sha": sha, "epoch": int(epoch), "attempt": int(attempt),
          "reply": reply, "residual_risk": risk, "waived_verdicts": int(n), "covered": json.loads(cov), "at": now})
import re
if s.get("halted") and re.fullmatch(r"awaiting human review waiver line %s\b.*" % line_no, str(s.get("halt_reason", "")), re.S):
    s["halted"] = False
    s["halt_reason"] = None
save(path, s)
print(f"[checkpoint] review waiver recorded @ line {line_no} for {sha[:12]} (attempt {attempt}, epoch {epoch}; "
      f"{n} REQUEST_CHANGES verdict(s) accepted as residual risk; gate, tier, G12 and Acceptance still apply)")' \
      "$CHECKPOINT" "$NOW" "$LINE_NO" "$SHA" "$REPLY" "$RISK" "$W_ATTEMPT" "$W_EPOCH" "$W_N" "$W_COV"
    ;;

  review-mode)
    # Read-only (ADR-0004 §3): the mode and SINCE of the next review round,
    # computed from the tier recorded NOW (run it after risk-tier.sh; it is
    # what iterate.sh prints, without re-routing or touching the lock).
    LINE_NO="${3:?line_no required}"
    need_line "$LINE_NO"
    python3 - "$CHECKPOINT" "$LINE_NO" "$(apex_floor "$WT" 2>/dev/null || echo none)" <<'PY'
import json, sys
path, line_no, base = sys.argv[1:]
s = json.load(open(path))
order = {"A": 0, "B": 1, "C": 2}
r = (s.get("reviews") or {}).get(line_no) or {}
attempt, epoch = r.get("attempt", 1), s.get("epoch", 0)
recs = [x for x in r.get("records") or [] if x.get("attempt", 1) == attempt and x.get("epoch", 0) == epoch]
full = [x for x in recs if x.get("mode", "full") == "full"]
trec = (s.get("tiers") or {}).get(line_no) or {}
tier = trec.get("tier") if trec.get("epoch", 0) == epoch else None
why = ""
if not full:
    mode, why = "full", "no full round in this attempt yet"
elif tier in order and order[tier] > max(order.get(x.get("tier") or "A", 0) for x in full):
    mode, why = "full", "the tier rose to %s above every full round of this attempt" % tier
elif tier == "C" and not any(x.get("role") == "adversarial" and x.get("tier") == "C" for x in full):
    mode, why = "full", "a Tier C attempt with no full-mode adversarial review at Tier C"
else:
    mode = "verify"
print("REVIEW_MODE: " + mode + (" (" + why + ")" if why else ""))
print("REVIEW_SINCE: " + (base if mode == "full" else recs[-1]["sha"]))
PY
    ;;

  freeze)
    # Freeze the head for one review round (ADR-0004 addendum C): `review` of
    # any other SHA for this line is refused until the round's verdicts are
    # all in (--reviewers N, default 1) or `unfreeze`. With apex-dispatch, the
    # ACTIVE lock moves GATE -> REVIEW, where its hooks refuse commits.
    LINE_NO="${3:?line_no required}"
    SHA="${4:?sha required}"
    NREV=1; FMODE=full; shift 4
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --reviewers) NREV="${2:?--reviewers needs a count}"; shift 2 ;;
        --mode) FMODE="${2:?--mode needs full or verify}"; shift 2 ;;
        *) echo "ERROR: unknown freeze option $1" >&2; exit 1 ;;
      esac
    done
    [[ "$NREV" =~ ^[1-9][0-9]?$ ]] || { echo "ERROR: --reviewers must be 1-99" >&2; exit 1; }
    [[ "$FMODE" == full || "$FMODE" == verify ]] || { echo "ERROR: --mode must be full or verify" >&2; exit 1; }
    need_line "$LINE_NO"
    need_sha "$SHA"
    refuse_if_halted
    [[ "$SHA" == "$(head_sha)" ]] || { echo "[checkpoint] REFUSED freeze: $SHA is not the worktree head ($(head_sha)) — freeze the head you dispatch reviewers for" >&2; exit 1; }
    python3 -c "$PY_SAVE"'
import sys
path, now, line_no, sha, n, mode = sys.argv[1:]
s = json.load(open(path))
order = {"A": 0, "B": 1, "C": 2}
r = (s.get("reviews") or {}).get(line_no) or {}
attempt, epoch = r.get("attempt", 1), s.get("epoch", 0)
recs = [x for x in r.get("records") or [] if x.get("attempt", 1) == attempt and x.get("epoch", 0) == epoch]
full = [x for x in recs if x.get("mode", "full") == "full"]
trec = (s.get("tiers") or {}).get(line_no) or {}
tier = trec.get("tier") if trec.get("epoch", 0) == epoch else None
since = recs[-1]["sha"] if recs else None
if mode == "verify":
    why = None
    if not full:
        why = "no full review in this attempt yet"
    elif tier in order and order[tier] > max(order.get(x.get("tier") or "A", 0) for x in full):
        why = f"the tier rose to {tier} above every full review of this attempt"
    elif tier == "C" and not any(x.get("role") == "adversarial" and x.get("tier") == "C" for x in full):
        why = "this Tier C attempt has no full-mode adversarial review at Tier C"
    if why:
        print(f"[checkpoint] REFUSED freeze: --mode verify, but {why} — run a full round (SINCE = TASK_BASE, --mode full)", file=sys.stderr)
        sys.exit(1)
s.setdefault("freezes", {})[line_no] = {"sha": sha, "reviewers": int(n), "recorded": 0, "mode": mode,
                                         "since": since if mode == "verify" else "TASK_BASE", "at": now}
save(path, s)
print(f"[checkpoint] FROZEN: line {line_no} at {sha[:12]} for a {mode} round until {n} verdict(s) are recorded (or: checkpoint.sh PLAN unfreeze {line_no})")' \
      "$CHECKPOINT" "$NOW" "$LINE_NO" "$SHA" "$NREV" "$FMODE"
    apex_lock_stage "$PLAN_HASH" REVIEW GATE
    ;;

  unfreeze)
    LINE_NO="${3:?line_no required}"
    need_line "$LINE_NO"
    python3 -c "$PY_SAVE"'
import sys
path, line_no = sys.argv[1:]
s = json.load(open(path))
fz = (s.get("freezes") or {}).pop(line_no, None)
save(path, s)
was = (" (was " + str(fz.get("sha"))[:12] + ")") if fz else " (was not frozen)"
print(f"[checkpoint] unfrozen: line {line_no}{was}")' "$CHECKPOINT" "$LINE_NO"
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
                                    "consecutive_failures": s.get("consecutive_failures", 0),
                                    "consecutive_stalls": s.get("consecutive_stalls", 0), "at": now})
s["halted"] = False
s["halt_reason"] = None
s["consecutive_failures"] = 0
s["consecutive_stalls"] = 0
save(path, s)' "$CHECKPOINT" "$NOW" "$REASON"
    echo "[checkpoint] resumed: $REASON"
    ;;

  refork)
    # The base moved and changed paths this run also changed: after the
    # operator merges the base into the run branch, the run's diff base
    # becomes the base tip, so the next completion reviews the run's whole
    # effect against the current base (land.sh 6b then has nothing to refuse).
    REASON="${3:?refork needs a reason (the operator decision)}"
    [[ "${APEX_GIBSON:-1}" != "0" ]] || { echo "[checkpoint] REFUSED refork: the harness is off" >&2; exit 1; }
    [[ -n "$(read_field worktree_branch)" ]] || { echo "[checkpoint] REFUSED refork: only a run with a worktree lands, so only it reforks" >&2; exit 1; }
    refuse_if_halted
    BASE_TIP="$(apex_base_sha "$WT" "$(read_field base_branch)")" \
      || { echo "[checkpoint] REFUSED refork: the base branch '$(read_field base_branch)' does not resolve" >&2; exit 1; }
    apex_git "$WT" merge-base --is-ancestor "$BASE_TIP" HEAD \
      || { echo "[checkpoint] REFUSED refork: merge $(read_field base_branch) (${BASE_TIP:0:12}) into the run branch first" >&2; exit 1; }
    # The wider review needs a task: with none left, the last completed one is
    # reopened.
    REOPEN=""
    if [[ "$(python3 "$APEX_EXECUTE_SCRIPTS/planlib.py" remaining "$PLAN" 2>/dev/null)" == "0" ]]; then
      # The last completed task, found by its id (plan edits move lines).
      REOPEN="$(python3 -c '
import json, sys
sys.path.insert(0, sys.argv[2])
import planlib
s = json.load(open(sys.argv[1]))
c = s.get("completes") or []
tid = c[-1].get("id") if c else None
lines = [t["line_no"] for t in planlib.parse(sys.argv[3]) if tid and t.get("id") == tid and t["checked"]]
print(lines[0] if len(lines) == 1 else "")' "$CHECKPOINT" "$APEX_EXECUTE_SCRIPTS" "$PLAN")"
      [[ "$REOPEN" =~ ^[1-9][0-9]*$ ]] || { echo "[checkpoint] REFUSED refork: no task is unchecked and the last completed task cannot be found by its id — rewind a task first" >&2; exit 1; }
      need_line "$REOPEN"
      [[ "$(task_field checked)" == "1" ]] || { echo "[checkpoint] REFUSED refork: line $REOPEN is not checked — rewind a task first" >&2; exit 1; }
      sed -i.bak "${REOPEN}s/^- \[[xX]\]/- [ ]/" "$PLAN" && rm -f "${PLAN}.bak"
    fi
    python3 -c "$PY_SAVE"'
import sys
path, now, reason, base_tip, reopen = sys.argv[1:]
with open(path) as f: s = json.load(f)
s.setdefault("reforks", []).append({"reason": reason, "old_fork": s.get("fork_sha"), "new_fork": base_tip,
                                    "completes": s.get("completes") or [], "reopened_line": reopen or None, "at": now})
s["fork_sha"] = base_tip
s["completes"] = []
s["epoch"] = s.get("epoch", 0) + 1   # tiers, reviews and G12 approvals recorded before this saw a narrower diff
s["retired"] = False
if reopen:
    s["completed_tasks"] = max(0, s.get("completed_tasks", 0) - 1)
save(path, s)' "$CHECKPOINT" "$NOW" "$REASON" "$BASE_TIP" "$REOPEN"
    echo "[checkpoint] reforked at ${BASE_TIP:0:12}${REOPEN:+ (reopened line $REOPEN)}: the next completion reviews the run against the current base"
    ;;

  rewind)
    LINE_NO="${3:?line_no required}"
    need_line "$LINE_NO"
    if [[ "$(task_field checked)" != "1" ]]; then
      # Still a rewind of the task's attempt state: a freeze never survives it.
      python3 -c "$PY_SAVE"'
import sys
path, line_no = sys.argv[1:]
s = json.load(open(path))
if (s.get("freezes") or {}).pop(line_no, None) is not None:
    save(path, s)' "$CHECKPOINT" "$LINE_NO"
      "$APEX_EXECUTE_SCRIPTS/backlog.sh" "$PLAN" reopen "$LINE_NO" 9>&- >/dev/null 2>&1 || true
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
(s.get("freezes") or {}).pop(line_no, None)
save(path, s)' "$CHECKPOINT" "$LINE_NO"
    "$APEX_EXECUTE_SCRIPTS/backlog.sh" "$PLAN" reopen "$LINE_NO" 9>&- >/dev/null 2>&1 || true
    echo "[checkpoint] rewound line $LINE_NO"
    ;;

  *) echo "ERROR: unknown action $ACTION" >&2; exit 1 ;;
esac
