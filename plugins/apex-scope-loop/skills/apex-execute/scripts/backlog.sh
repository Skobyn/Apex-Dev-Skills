#!/usr/bin/env bash
# backlog.sh — The hardening backlog (ADR-0004). Non-blocking review findings
# (and findings outside the stated threat model) are written here instead of
# being carried in the orchestrator's memory; the plan's next [docs] or
# hygiene task consumes the open items.
#
# One tracked markdown file per plan repository, beside the lessons ledger,
# one section per plan, and treated exactly like the ledger (land.sh always
# takes the base checkout's copy):
#   default: <main checkout of the plan's repo>/.claude/apex-scope-loop/BACKLOG.md
#            (override: APEX_BACKLOG_FILE)
#
# Usage:
#   ./backlog.sh PLAN.md add LINE "<finding>" [--from reviewer]
#       Record one finding for the task at LINE. Prints "BACKLOG: B-NNN added".
#   ./backlog.sh PLAN.md list [--all]
#       "BACKLOG: <n> open for <plan>", then the open items (--all: done ones too).
#   ./backlog.sh PLAN.md done ID
#       Mark an item of this plan done (ID is B-NNN).
#   ./backlog.sh PLAN.md count
#       The number of open items for this plan.
set -euo pipefail

PLAN="${1:?usage: backlog.sh PLAN.md add|list|done|count ...}"
ACTION="${2:?action: add|list|done|count}"
shift 2
[[ -f "$PLAN" ]] || { echo "ERROR: plan not found: $PLAN" >&2; exit 2; }

APEX_RESOLVE_MODE=act  # this script acts: a repository mismatch is fatal (never inherited from the env)
# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
apex_resolve "$PLAN"
PLAN_KEY="${PLAN_ABS#"${PLAN_TOP:-/nonexistent}"/}"

FROM="reviewer"; ALL=0; ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="${2:?--from needs a name}"; shift 2 ;;
    --all) ALL=1; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

case "$ACTION" in
  add)
    LINE_NO="${ARGS[0]:?line required}"; TEXT="${ARGS[1]:?finding text required}"
    [[ "$LINE_NO" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "ERROR: LINE must be a plan line number, got '$LINE_NO'" >&2; exit 2; }
    python3 "$APEX_EXECUTE_SCRIPTS/planlib.py" task "$PLAN_ABS" "$LINE_NO" >/dev/null 2>&1 \
      || { echo "ERROR: line $LINE_NO is not a task in a valid plan $PLAN" >&2; exit 2; }
    TID="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("id") or "")' "$(python3 "$APEX_EXECUTE_SCRIPTS/planlib.py" task "$PLAN_ABS" "$LINE_NO")")"
    ;;
  done) ID="${ARGS[0]:?ID required (B-NNN)}"; [[ "$ID" =~ ^B-[0-9]{3,}$ ]] || { echo "ERROR: ID must look like B-001" >&2; exit 2; } ;;
  list|count) ;;
  *) echo "ERROR: unknown action $ACTION" >&2; exit 2 ;;
esac

mkdir -p "$STATE_BASE"
python3 - "$BACKLOG_LEDGER" "$STATE_BASE/.backlog.lock" "$PLAN_KEY" "$ACTION" "$ALL" "${LINE_NO:-}" "${TID:-}" "${TEXT:-}" "$FROM" "${ID:-}" "$(date -u +%F)" <<'PY'
import fcntl, os, re, sys
path, lock, plan, action, show_all, line_no, tid, text, src, item, today = sys.argv[1:]
HEADER = ("# apex-scope-loop Hardening Backlog\n\n"
          "Non-blocking review findings and findings outside a task's threat model\n"
          "(ADR-0004). One section per plan; the plan's next [docs] or hygiene task\n"
          "consumes the open items (backlog.sh PLAN list, then backlog.sh PLAN done ID).\n")
ITEM_RE = re.compile(r"^- \[( |x)\] (B-\d+) ")
fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)
lines = open(path, encoding="utf-8").read().split("\n") if os.path.isfile(path) else []
head = "## Plan: " + plan

def section(ls):
    """(start, end) of this plan's section (end exclusive), or None."""
    for i, l in enumerate(ls):
        if l == head:
            j = i + 1
            while j < len(ls) and not ls[j].startswith("## "):
                j += 1
            return i, j
    return None

sec = section(lines)
mine = [l for l in lines[sec[0]:sec[1]] if ITEM_RE.match(l)] if sec else []
opened = [l for l in mine if l.startswith("- [ ]")]

def save(ls):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(ls).rstrip("\n") + "\n")
    os.replace(tmp, path)

if action == "count":
    print(len(opened))
elif action == "list":
    print(f"BACKLOG: {len(opened)} open for {plan} ({path})")
    for l in (mine if show_all == "1" else opened):
        print(l)
elif action == "add":
    one = " ".join(text.split())                  # one line: a finding can never open a section
    src1 = " ".join(src.split())
    nums = [int(m.group(2)[2:]) for l in lines for m in [ITEM_RE.match(l)] if m]
    new_id = "B-%03d" % (max(nums, default=0) + 1)
    entry = f"- [ ] {new_id} · {today} · line {line_no}{' (' + tid + ')' if tid else ''} · from {src1} — {one}"
    if not lines:
        lines = HEADER.rstrip("\n").split("\n")
    if sec is None:
        while lines and lines[-1] == "":
            lines.pop()
        lines += ["", head, "", entry]
    else:
        end = sec[1]
        while end > sec[0] + 1 and lines[end - 1] == "":
            end -= 1
        lines.insert(end, entry)
    save(lines)
    print(f"BACKLOG: {new_id} added for {plan} -> {path}")
elif action == "done":
    hit = [i for i in range(sec[0], sec[1]) if (m := ITEM_RE.match(lines[i])) and m.group(2) == item] if sec else []
    if not hit:
        print(f"ERROR: {item} is not an item of {plan} in {path}", file=sys.stderr)
        sys.exit(1)
    i = hit[0]
    if lines[i].startswith("- [x]"):
        print(f"BACKLOG: {item} was already done")
    else:
        lines[i] = "- [x]" + lines[i][5:] + f" (done {today})"
        save(lines)
        print(f"BACKLOG: {item} done")
PY
