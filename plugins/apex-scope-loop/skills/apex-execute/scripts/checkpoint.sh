#!/usr/bin/env bash
# checkpoint.sh — Mark a phase complete (or rewind) and update state.
# Usage:
#   ./checkpoint.sh PLAN.md complete LINE_NO VERDICT_REASON [--skip-review "why"]
#   ./checkpoint.sh PLAN.md fail     LINE_NO REASON
#   ./checkpoint.sh PLAN.md review   LINE_NO SHA APPROVE|REQUEST_CHANGES [REVIEWER]
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
# Error budget on `fail`: after APEX_ESCALATE_AFTER consecutive failures
# (default 2) the brief says ESCALATE (buy a second opinion from a different
# agent); at APEX_ERROR_BUDGET (default 3) the plan halts.
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

case "$ACTION" in
  complete)
    LINE_NO="${3:?line_no required}"
    VERDICT="${4:-passed}"
    SKIP_REVIEW=""
    [[ "${5:-}" == "--skip-review" ]] && SKIP_REVIEW="${6:?--skip-review needs a reason}"
    TASK_LINE="$(sed -n "${LINE_NO}p" "$PLAN")"
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
    r = s.get("reviews", {}).get(line_no)
    if not r:
        problems.append("no independent review recorded — dispatch the gibson-reviewer agent, then: checkpoint.sh PLAN review LINE SHA VERDICT")
    elif r.get("sha") != head:
        problems.append(f"review covers {r.get('sha','?')[:12]}, worktree head is {head[:12]} — stale review; re-review the exact head")
    elif r.get("verdict") != "APPROVE":
        problems.append(f"review verdict is {r.get('verdict')} — address findings and re-review")
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
json.dump(s, open(path, "w"), indent=2)
PY
    ;;

  review)
    LINE_NO="${3:?line_no required}"
    SHA="${4:?sha required}"
    VERDICT="${5:?verdict: APPROVE|REQUEST_CHANGES}"
    REVIEWER="${6:-gibson-reviewer}"
    case "$VERDICT" in APPROVE|REQUEST_CHANGES) ;; *) echo "ERROR: verdict must be APPROVE or REQUEST_CHANGES" >&2; exit 1 ;; esac
    python3 - "$CHECKPOINT" "$NOW" "$LINE_NO" "$SHA" "$VERDICT" "$REVIEWER" <<'PY'
import json, sys
path, now, line_no, sha, verdict, reviewer = sys.argv[1:]
s = json.load(open(path))
rounds = (s.get("reviews", {}).get(line_no) or {}).get("round", 0) + 1
s.setdefault("reviews", {})[line_no] = {"sha": sha, "verdict": verdict, "reviewer": reviewer, "round": rounds, "at": now}
json.dump(s, open(path, "w"), indent=2)
print(f"[checkpoint] review @ line {line_no}: {verdict} on {sha[:12]} (round {rounds}, by {reviewer})")
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
    sed -i.bak "${LINE_NO}s/^- \[x\]/- [ ]/" "$PLAN" && rm -f "${PLAN}.bak"
    python3 - "$CHECKPOINT" <<PY
import json
with open("$CHECKPOINT") as f: s = json.load(f)
s["completed_tasks"] = max(0, s.get("completed_tasks", 0) - 1)
s["halted"] = False
s["halt_reason"] = None
s["consecutive_failures"] = 0
with open("$CHECKPOINT", "w") as f: json.dump(s, f, indent=2)
PY
    echo "[checkpoint] rewound line $LINE_NO"
    ;;

  *) echo "ERROR: unknown action $ACTION" >&2; exit 1 ;;
esac
