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
#   ./checkpoint.sh PLAN.md rewind   LINE_NO
#
# Harness enforcement on `complete` (adapted from The Gibson — see
# docs/GIBSON_HARNESS.md; disable with APEX_GIBSON=0):
#   - green gate (green-gate.sh check) must be PASS or SKIPPED on the worktree's
#     current head SHA                                         (Law 4)
#   - an independent review verdict APPROVE must be recorded for that exact
#     head SHA, unless --skip-review names why review does not apply  (Law 5)
#   - a Tier C task needs a recorded human approval (G12) for that exact head
#     SHA; --skip-review never waives it                       (Law 7)
#   Gate tasks ([gate:auto] / [gate:human] / [gate:partner:*]) carry no code
#   and are exempt from the gate/review checks.
#
# Reviews (ADR-0003): every verdict is a record; a round is a distinct head
# SHA reviewed in the current attempt, and a fourth round is refused
# (APEX_REVIEW_CAP, default 3) — record `fail` and retry instead. `complete`
# needs an APPROVE at the exact head and no REQUEST_CHANGES there; Tier C also
# needs an APPROVE recorded with --role adversarial. When apex-dispatch state
# exists (<state>/dispatch/), a verdict is accepted only with provenance: a
# hook-written reviews-raw record (--agent-id) or a worker result.json
# (--worker) carrying the same verdict at the same SHA; `complete` also needs
# ledger evidence (route + spawn/worker rows, hash chain intact).
#
# Error budget on `fail`: after APEX_ESCALATE_AFTER consecutive failures
# (default 2) the brief says ESCALATE (buy a second opinion from a different
# agent); at APEX_ERROR_BUDGET (default 3) the plan halts. A failure starts a
# new review attempt for the line. With apex-dispatch, ESCALATE_ROUTE: lines
# come from `route.sh escalate`.
set -euo pipefail

PLAN="${1:?usage: checkpoint.sh PLAN.md ACTION [...]}"
ACTION="${2:?action: complete|fail|review|approve|halt|rewind}"
[[ -f "$PLAN" ]] || { echo "ERROR: plan not found"; exit 1; }

APEX_RESOLVE_MODE=act  # this script acts: a repository mismatch is fatal (never inherited from the env)
# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
apex_resolve "$PLAN"
NOW="$(date -u +%FT%TZ)"
[[ -f "$CHECKPOINT" ]] || { echo "ERROR: not initialized — run init.sh first"; exit 1; }

WT="$(read_field worktree_path)"; WT="${WT:-$REPO_ROOT}"
head_sha() { git -C "$WT" rev-parse HEAD 2>/dev/null || echo unknown; }
DISPATCH_STATE="$STATE_DIR/dispatch"
DISPATCH="$(apex_dispatch_root)"

case "$ACTION" in
  complete)
    LINE_NO="${3:?line_no required}"
    VERDICT="${4:-passed}"
    SKIP_REVIEW=""
    [[ "${5:-}" == "--skip-review" ]] && SKIP_REVIEW="${6:?--skip-review needs a reason}"
    TASK_LINE="$(sed -n "${LINE_NO}p" "$PLAN")"
    [[ "$TASK_LINE" =~ ^-\ \[\ \][[:space:]] ]] || { echo "[checkpoint] REFUSED complete: line $LINE_NO is not an unchecked task: $TASK_LINE" >&2; exit 1; }
    if [[ "${APEX_GIBSON:-1}" != "0" ]] && ! printf '%s' "$TASK_LINE" | grep -q '\[gate:'; then
      python3 - "$CHECKPOINT" "$STATE_DIR/gate/last.json" "$LINE_NO" "$(head_sha)" "$SKIP_REVIEW" <<'PY'
import json, os, sys
cp, gate_path, line_no, head, skip = sys.argv[1:]
s = json.load(open(cp))
problems = []
g = json.load(open(gate_path)) if os.path.isfile(gate_path) else None
if not g:
    problems.append("no green-gate result — run: green-gate.sh PLAN check")
elif g.get("head_sha") != head:
    problems.append(f"green gate ran on {g.get('head_sha','?')[:12]}, worktree head is {head[:12]} — re-run green-gate.sh check")
elif g.get("result") not in ("PASS", "SKIPPED"):
    problems.append(f"green gate is {g.get('result')} — zero new failures vs. baseline required")
tier = (s.get("tiers", {}).get(line_no) or {}).get("tier")
if not skip:
    r = s.get("reviews", {}).get(line_no) or {}
    attempt = r.get("attempt", 1)
    recs = [x for x in r.get("records", []) if x.get("attempt", 1) == attempt and x.get("sha") == head]
    if not recs and r.get("sha") == head and "records" not in r:      # 0.2.0 record
        recs = [{"verdict": r.get("verdict"), "role": "reviewer"}]
    if not recs:
        problems.append("no independent review recorded for the worktree head "
                        f"{head[:12]} — dispatch the reviewer, then: checkpoint.sh PLAN review LINE SHA VERDICT")
    elif any(x.get("verdict") != "APPROVE" for x in recs):
        problems.append("a review of the head requested changes — address the findings and re-review")
    elif tier == "C" and not any(x.get("role") == "adversarial" for x in recs):
        problems.append("Tier C: an adversarial review (--role adversarial) approving this exact head is required")
if tier is None and not skip:
    problems.append("no risk tier recorded — run: risk-tier.sh PLAN LINE --since <brief HEAD_SHA>")
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
      # With apex-dispatch state, the ledger must back the completion.
      if [[ -d "$DISPATCH_STATE" ]]; then
        [[ -n "$DISPATCH" ]] || { echo "[checkpoint] REFUSED complete: dispatch state exists ($DISPATCH_STATE) but apex-dispatch is not installed beside apex-scope-loop (APEX_DISPATCH_ROOT)" >&2; exit 1; }
        "$DISPATCH/scripts/ledger.sh" evidence --state "$STATE_DIR" --line "$LINE_NO" --head "$(head_sha)" \
          || { echo "[checkpoint] REFUSED complete: ledger evidence missing or the hash chain is broken (ledger.sh evidence)" >&2; exit 1; }
      fi
    fi
    # Flip "- [ ]" to "- [x]" on that line (BSD/macOS sed)
    sed -i.bak "${LINE_NO}s/^- \[ \]/- [x]/" "$PLAN" && rm -f "${PLAN}.bak"
    python3 - "$CHECKPOINT" "$NOW" "$VERDICT" "$LINE_NO" "$SKIP_REVIEW" <<'PY'
import json, sys
path, now, verdict, line_no, skip = sys.argv[1:]
with open(path) as f: s = json.load(f)
s["completed_tasks"] = s.get("completed_tasks", 0) + 1
s["last_verdict"] = {"line_no": int(line_no), "result": "pass", "reason": verdict, "at": now}
if skip:
    s.setdefault("skipped_reviews", {})[line_no] = {"reason": skip, "at": now}
s["last_iteration_at"] = now
s["current_phase"] = None
s["consecutive_failures"] = 0
with open(path, "w") as f: json.dump(s, f, indent=2)
PY
    apex_lock_stage "$PLAN_HASH" DONE   # this plan's lock becomes reclaimable until its next iterate
    echo "[checkpoint] complete @ line $LINE_NO ($VERDICT)"
    ;;

  fail)
    LINE_NO="${3:?line_no required}"
    REASON="${4:-unspecified}"
    python3 - "$CHECKPOINT" "$NOW" "$REASON" "$LINE_NO" "${APEX_ESCALATE_AFTER:-2}" "${APEX_ERROR_BUDGET:-3}" <<'PY'
import json, sys
path, now, reason, line_no, esc, budget = sys.argv[1:]
s = json.load(open(path))
n = s.get("consecutive_failures", 0) + 1
s["consecutive_failures"] = n
s["last_verdict"] = {"line_no": int(line_no), "result": "fail", "reason": reason, "at": now}
s["last_iteration_at"] = now
print(f"[checkpoint] FAIL @ line {line_no} ({n} consecutive): {reason}")
if n >= int(budget):
    s["halted"] = True
    s["halt_reason"] = f"error budget exhausted: {n} consecutive failures (last: {reason})"
    print(f"[checkpoint] HALTED: {s['halt_reason']}")
elif n >= int(esc):
    print("ESCALATE: second-opinion — dispatch a different agent (fresh context, different model if available) to diagnose before retrying")
# A failure ends the line's review attempt: the next attempt gets fresh rounds.
r = s.setdefault("reviews", {}).setdefault(line_no, {})
r["attempt"] = r.get("attempt", 1) + 1
r["rounds"] = []
json.dump(s, open(path, "w"), indent=2)
PY
    # apex-dispatch decides the next rung (effort+1, model+1, diagnoser, HALT).
    ROUTE_FILE="$DISPATCH_STATE/active-route.json"
    if [[ -n "$DISPATCH" && -f "$ROUTE_FILE" ]]; then
      RID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("route_id",""))' "$ROUTE_FILE" 2>/dev/null || true)"
      if [[ -n "$RID" ]]; then
        "$DISPATCH/scripts/route.sh" escalate "$RID" 2>&1 | sed 's/^/ESCALATE_ROUTE: /' || echo "ESCALATE_ROUTE: error route.sh escalate $RID failed"
      fi
    fi
    ;;

  review)
    LINE_NO="${3:?line_no required}"
    SHA="${4:?sha required}"
    VERDICT="${5:?verdict: APPROVE|REQUEST_CHANGES}"
    shift 5
    REVIEWER="gibson-reviewer"
    if [[ $# -gt 0 && "$1" != --* ]]; then REVIEWER="$1"; shift; fi
    ROLE="reviewer"; AGENT_ID=""; WORKER=""; PROVIDER=""; MODEL=""; ROUTE_ID=""
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
    case "$VERDICT" in APPROVE|REQUEST_CHANGES) ;; *) echo "ERROR: verdict must be APPROVE or REQUEST_CHANGES" >&2; exit 1 ;; esac
    [[ "$ROLE" =~ ^(reviewer|adversarial|lens:[a-z/-]+)$ ]] || { echo "ERROR: --role must be reviewer, adversarial or lens:<name>" >&2; exit 1; }
    python3 - "$CHECKPOINT" "$NOW" "$LINE_NO" "$SHA" "$VERDICT" "$REVIEWER" "$ROLE" "$AGENT_ID" "$WORKER" \
      "$PROVIDER" "$MODEL" "$ROUTE_ID" "$DISPATCH_STATE" "${APEX_REVIEW_CAP:-3}" <<'PY'
import json, os, re, sys
(path, now, line_no, sha, verdict, reviewer, role, agent_id, worker,
 provider, model, route_id, dstate, cap) = sys.argv[1:]
def die(msg):
    print(f"[checkpoint] REFUSED review @ line {line_no}: {msg}", file=sys.stderr)
    sys.exit(1)
if not re.fullmatch(r"[0-9a-f]{40}", sha):
    die(f"'{sha}' is not a full 40-character commit SHA")
provenance = "declared"
if os.path.isdir(dstate):
    # Provenance (spec §5.3 G): the verdict must come from a record the
    # orchestrator did not type — a hook-written reviews-raw record or a worker
    # result.json — with the same verdict at the same SHA.
    if agent_id:
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", agent_id):
            die("--agent-id has unexpected characters")
        rec_path = os.path.join(dstate, "reviews-raw", f"{agent_id}.json")
    elif worker:
        rec_path = os.path.join(worker, "result.json")
    else:
        die("apex-dispatch state exists, so a verdict needs provenance: --agent-id (hook-written reviews-raw record) "
            "or --worker DIR (worker result.json); a typed verdict is not accepted")
    try:
        rec = json.load(open(rec_path))
    except Exception:
        die(f"no readable provenance record at {rec_path}")
    if rec.get("head_sha") != sha:
        die(f"the provenance record reviewed {str(rec.get('head_sha'))[:12]}, not {sha[:12]}")
    if rec.get("verdict") != verdict:
        die(f"the provenance record says {rec.get('verdict')}, not {verdict}")
    if worker and not str(rec.get("role", "")).startswith(("reviewer", "adversarial")):
        die(f"the worker result has role {rec.get('role')!r}, not a reviewer role")
    provider = provider or rec.get("provider", "")
    model = model or rec.get("model", "")
    provenance = "reviews-raw" if agent_id else "worker"
s = json.load(open(path))
r = s.setdefault("reviews", {}).setdefault(line_no, {})
if "records" not in r and r.get("sha"):          # 0.2.0 single record
    r["records"] = [{"attempt": 1, "sha": r["sha"], "verdict": r.get("verdict"), "reviewer": r.get("reviewer"),
                     "role": "reviewer", "provenance": "declared", "at": r.get("at")}]
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
    "provenance": provenance, "at": now})
r.update({"sha": sha, "verdict": verdict, "reviewer": reviewer, "round": rounds.index(sha) + 1, "at": now})
json.dump(s, open(path, "w"), indent=2)
print(f"[checkpoint] review @ line {line_no}: {verdict} on {sha[:12]} (attempt {attempt}, round {rounds.index(sha) + 1}/{cap}, "
      f"{role} by {reviewer}, provenance {provenance})")
PY
    ;;

  approve)
    LINE_NO="${3:?line_no required}"
    SHA="${4:?sha required}"
    PHRASE="${5:?literal approval reply from the human is required}"
    python3 - "$CHECKPOINT" "$NOW" "$LINE_NO" "$SHA" "$PHRASE" <<'PY'
import json, sys
path, now, line_no, sha, phrase = sys.argv[1:]
s = json.load(open(path))
s.setdefault("approvals", {})[line_no] = {"gate": "G12", "sha": sha, "phrase": phrase, "at": now}
if s.get("halted") and str(s.get("halt_reason", "")).startswith("awaiting human gate G12"):
    s["halted"] = False
    s["halt_reason"] = None
json.dump(s, open(path, "w"), indent=2)
print(f"[checkpoint] G12 approval recorded @ line {line_no} for {sha[:12]}")
PY
    ;;

  halt)
    REASON="${3:-unspecified}"
    python3 - "$CHECKPOINT" "$NOW" "$REASON" <<'PY'
import json, sys
path, now, reason = sys.argv[1:]
with open(path) as f: s = json.load(f)
s["halted"] = True
s["halt_reason"] = reason
s["last_iteration_at"] = now
with open(path, "w") as f: json.dump(s, f, indent=2)
PY
    echo "[checkpoint] HALTED: $REASON"
    ;;

  rewind)
    LINE_NO="${3:?line_no required}"
    WAS_CHECKED=0
    [[ "$(sed -n "${LINE_NO}p" "$PLAN")" =~ ^-\ \[[xX]\] ]] && WAS_CHECKED=1
    sed -i.bak "${LINE_NO}s/^- \[[xX]\]/- [ ]/" "$PLAN" && rm -f "${PLAN}.bak"
    python3 - "$CHECKPOINT" "$WAS_CHECKED" <<'PY'
import json, sys
path, was_checked = sys.argv[1:]
with open(path) as f: s = json.load(f)
if was_checked == "1":
    s["completed_tasks"] = max(0, s.get("completed_tasks", 0) - 1)
s["halted"] = False
s["halt_reason"] = None
s["consecutive_failures"] = 0
with open(path, "w") as f: json.dump(s, f, indent=2)
PY
    echo "[checkpoint] rewound line $LINE_NO"
    ;;

  *) echo "ERROR: unknown action $ACTION" >&2; exit 1 ;;
esac
