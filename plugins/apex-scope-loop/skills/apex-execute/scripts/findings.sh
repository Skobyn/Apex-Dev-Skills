#!/usr/bin/env bash
# findings.sh — Carried review findings per task (ADR-0004, addendum A).
#
# One JSON file per task line in the plan's state dir:
#   <state>/findings/L<LINE>.json   {"line": N, "items": [ {id, sha, severity, class,
#                                     at, mechanism, status, from, rounds, created, closed, reason} ]}
# The orchestrator records every reviewer finding here. A defect is counted
# once: an item with the same class and file:line is the same finding — its
# rounds grow, a new mechanism is added to its `mechanisms` list, and a
# blocking re-report re-opens it if it was closed; a non-blocking re-report
# never re-opens anything.
# Non-blocking findings are "residuals": status residual, copied to the
# hardening backlog (backlog.sh), and they never reopen a review round.
#
# Usage:
#   ./findings.sh PLAN.md add LINE --severity blocking|non-blocking --class CLASS
#                 --at FILE:LINE --sha SHA "<one-line mechanism>" [--from REVIEWER]
#   ./findings.sh PLAN.md list LINE [--open]          open = status open (blocking, unresolved)
#   ./findings.sh PLAN.md close LINE ID [--reason "how it was verified fixed"]
#   ./findings.sh PLAN.md path LINE                   the file's path
#   ./findings.sh PLAN.md summary LINE                "<open> <residual> <closed>"
#   ./findings.sh PLAN.md classes                     distinct classes of closed findings, per line ("LINE<TAB>CLASS")
set -euo pipefail

PLAN="${1:?usage: findings.sh PLAN.md add|list|close|path|summary|classes ...}"
ACTION="${2:?action: add|list|close|path|summary|classes}"
shift 2
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"; PLAN="$(apex_locate_plan "$PLAN")"   # ADR-0004 H
[[ -f "$PLAN" ]] || { echo "ERROR: plan not found: $PLAN" >&2; exit 2; }

APEX_RESOLVE_MODE=act  # this script acts: a repository mismatch is fatal (never inherited from the env)
# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
apex_resolve "$PLAN"
[[ -f "$CHECKPOINT" ]] || { echo "ERROR: not initialized — run init.sh first" >&2; exit 2; }
FDIR="$STATE_DIR/findings"

LINE_NO=""; SEV=""; CLASS=""; AT=""; SHA=""; FROM="reviewer"; OPEN=0; REASON=""; ARGS=()
if [[ "$ACTION" != classes ]]; then
  LINE_NO="${1:?LINE required}"; shift
  [[ "$LINE_NO" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "ERROR: LINE must be a plan line number, got '$LINE_NO'" >&2; exit 2; }
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --severity) SEV="${2:?}"; shift 2 ;;
    --class) CLASS="${2:?}"; shift 2 ;;
    --at) AT="${2:?}"; shift 2 ;;
    --sha) SHA="${2:?}"; shift 2 ;;
    --from) FROM="${2:?}"; shift 2 ;;
    --reason) REASON="${2:?}"; shift 2 ;;
    --open) OPEN=1; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

case "$ACTION" in
  add)
    MECH="${ARGS[0]:?the one-line mechanism is required}"
    [[ "$SEV" == blocking || "$SEV" == non-blocking ]] || { echo "ERROR: --severity must be blocking or non-blocking" >&2; exit 2; }
    [[ "$CLASS" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || { echo "ERROR: --class must be a short kebab-case defect class (e.g. path-traversal, stale-cache)" >&2; exit 2; }
    [[ -n "$AT" ]] || { echo "ERROR: --at FILE:LINE is required" >&2; exit 2; }
    [[ "$SHA" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || { echo "ERROR: --sha must be the full reviewed commit SHA" >&2; exit 2; }
    python3 "$APEX_EXECUTE_SCRIPTS/planlib.py" task "$PLAN_ABS" "$LINE_NO" >/dev/null 2>&1 \
      || { echo "ERROR: line $LINE_NO is not a task in a valid plan $PLAN" >&2; exit 2; }
    ;;
  close) ID="${ARGS[0]:?ID required (F-NNN)}" ;;
  list|path|summary|classes) ;;
  *) echo "ERROR: unknown action $ACTION" >&2; exit 2 ;;
esac

[[ "$ACTION" == path ]] && { printf '%s\n' "$FDIR/L$LINE_NO.json"; exit 0; }
mkdir -p "$FDIR"
OUT="$(python3 - "$FDIR" "$ACTION" "$LINE_NO" "$SEV" "$CLASS" "$AT" "$SHA" "$FROM" "$OPEN" "$REASON" "${ID:-}" "${MECH:-}" "$(date -u +%FT%TZ)" <<'PY'
import fcntl, glob, json, os, re, sys
fdir, action, line_no, sev, cls, at, sha, src, only_open, reason, item_id, mech, now = sys.argv[1:]
fd = os.open(os.path.join(fdir, ".lock"), os.O_CREAT | os.O_RDWR, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)

def load(path):
    try:
        d = json.load(open(path))
        return d if isinstance(d, dict) and isinstance(d.get("items"), list) else {"items": []}
    except FileNotFoundError:
        return {"items": []}

def save(path, d):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=2)
    os.replace(tmp, path)

if action == "classes":
    for p in sorted(glob.glob(os.path.join(fdir, "L*.json"))):
        d = load(p)
        ln = os.path.basename(p)[1:-5]
        for c in sorted({x.get("class") for x in d["items"] if x.get("status") == "closed" and x.get("class")}):
            print(f"{ln}\t{c}")
    sys.exit(0)

path = os.path.join(fdir, f"L{line_no}.json")
d = load(path)
d["line"] = int(line_no)
items = d["items"]

def show(x):
    return (f"{x['id']} [{x['severity']}] {x['status']} {x['class']} {x['at']} @ {x['sha'][:12]} "
            f"(rounds {len(x.get('rounds') or [])}) — {x['mechanism']}")

if action == "add":
    one = " ".join(mech.split())
    norm = lambda m: re.sub(r"[^a-z0-9]+", " ", m.lower()).strip()
    same = [x for x in items if x.get("class") == cls and x.get("at") == " ".join(at.split())]
    if same:
        x = same[0]
        if sha not in x.setdefault("rounds", []):
            x["rounds"].append(sha)
        if sev == "blocking" and x["severity"] == "non-blocking":
            x["severity"] = "blocking"                 # a promotion, never a demotion
        if sev == "blocking" and x["status"] == "closed":
            x["status"], x["reopened"] = "open", now   # the same defect again: one entry, re-opened
        elif sev == "blocking" and x["status"] == "residual":
            x["status"] = "open"                       # a non-blocking re-report never reopens anything
        save(path, d)
        mechs = x.setdefault("mechanisms", [x.get("mechanism", "")])
        added = not any(norm(m) == norm(one) for m in mechs)
        if added:
            mechs.append(one)                          # another mechanism of the same defect, on the same entry
        save(path, d)
        print(f"FINDING: {x['id']} DUPLICATE (same class and file:line; counted once{'; mechanism added' if added else ''}) -> {x['status']}")
    else:
        n = max([int(x["id"][2:]) for x in items if str(x.get("id", "")).startswith("F-")] or [0]) + 1
        x = {"id": "F-%03d" % n, "sha": sha, "severity": sev, "class": cls, "at": " ".join(at.split()),
             "mechanism": one, "mechanisms": [one], "status": "open" if sev == "blocking" else "residual", "from": " ".join(src.split()),
             "rounds": [sha], "created": now}
        items.append(x)
        save(path, d)
        print(f"FINDING: {x['id']} {x['status']}")
        if x["status"] == "residual":
            print("RESIDUAL: " + f"{cls} {x['at']} — {one}")
elif action == "close":
    hit = [x for x in items if x.get("id") == item_id]
    if not hit:
        print(f"ERROR: {item_id} is not a finding of line {line_no}", file=sys.stderr)
        sys.exit(1)
    hit[0].update(status="closed", closed=now, reason=" ".join(reason.split()) or None)
    save(path, d)
    print(f"FINDING: {item_id} closed")
elif action == "list":
    sel = [x for x in items if x.get("status") == "open"] if only_open == "1" else items
    print(f"FINDINGS: {path} ({sum(x.get('status') == 'open' for x in items)} open, "
          f"{sum(x.get('status') == 'residual' for x in items)} residual, {sum(x.get('status') == 'closed' for x in items)} closed)")
    for x in sel:
        print(show(x))
elif action == "summary":
    print(sum(x.get("status") == "open" for x in items), sum(x.get("status") == "residual" for x in items),
          sum(x.get("status") == "closed" for x in items))
PY
)"
sed '/^RESIDUAL: /d' <<<"$OUT"
# A residual goes to the hardening backlog (it never reopens a round).
if R="$(sed -n 's/^RESIDUAL: //p' <<<"$OUT")" && [[ -n "$R" ]]; then
  "$APEX_EXECUTE_SCRIPTS/backlog.sh" "$PLAN_ABS" add "$LINE_NO" "$R" --from "$FROM"
fi
