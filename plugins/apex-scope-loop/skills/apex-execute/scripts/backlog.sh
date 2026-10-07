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
#   ./backlog.sh PLAN.md done ID --line LINE --sha SHA
#       A task closed item ID (B-NNN) in commit SHA: the item is pending-close
#       until that task's `checkpoint.sh complete` confirms it (SHA must be in
#       the completed head's history); `fail` or `rewind` of the task reopens it.
#   ./backlog.sh PLAN.md done ID --now
#       Mark an item done at once (a human decision outside any task).
#   ./backlog.sh PLAN.md confirm LINE HEAD   (checkpoint.sh complete)
#   ./backlog.sh PLAN.md reopen LINE         (checkpoint.sh fail / rewind)
#   ./backlog.sh PLAN.md count
#       The number of open items for this plan.
set -euo pipefail

PLAN="${1:?usage: backlog.sh PLAN.md add|list|done|count|confirm|reopen ...}"
ACTION="${2:?action: add|list|done|count|confirm|reopen}"
shift 2
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"; PLAN="$(apex_locate_plan "$PLAN")"   # ADR-0004 H
[[ -f "$PLAN" ]] || { echo "ERROR: plan not found: $PLAN" >&2; exit 2; }

APEX_RESOLVE_MODE=act  # this script acts: a repository mismatch is fatal (never inherited from the env)
# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
apex_resolve "$PLAN"
PLAN_KEY="${PLAN_ABS#"${PLAN_TOP:-/nonexistent}"/}"

FROM="reviewer"; ALL=0; ARGS=(); D_LINE=""; D_SHA=""; NOW_DONE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --line) D_LINE="${2:?}"; shift 2 ;;
    --sha) D_SHA="${2:?}"; shift 2 ;;
    --now) NOW_DONE=1; shift ;;
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
  done) ID="${ARGS[0]:?ID required (B-NNN)}"; [[ "$ID" =~ ^B-[0-9]{3,}$ ]] || { echo "ERROR: ID must look like B-001" >&2; exit 2; }
    if [[ "$NOW_DONE" != 1 ]]; then
      [[ "$D_LINE" =~ ^[1-9][0-9]{0,8}$ && "$D_SHA" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] \
        || { echo "ERROR: done needs --line LINE --sha <full SHA of the closing commit> (pending until that task completes), or --now" >&2; exit 2; }
    fi ;;
  confirm) D_LINE="${ARGS[0]:?LINE}"; D_SHA="${ARGS[1]:?HEAD}" ;;
  reopen) D_LINE="${ARGS[0]:?LINE}" ;;
  list|count) ;;
  *) echo "ERROR: unknown action $ACTION" >&2; exit 2 ;;
esac

mkdir -p "$STATE_BASE"
WT="$(read_field worktree_path)"; WT="${WT:-$REPO_ROOT}"
python3 - "$BACKLOG_LEDGER" "$STATE_BASE/.backlog.lock" "$PLAN_KEY" "$ACTION" "$ALL" "${LINE_NO:-}" "${TID:-}" "${TEXT:-}" "$FROM" "${ID:-}" "$(date -u +%F)" \
  "$STATE_DIR/backlog-pending.json" "$D_LINE" "$D_SHA" "$NOW_DONE" "$WT" <<'PY'
import fcntl, json, os, re, subprocess, sys
path, lock, plan, action, show_all, line_no, tid, text, src, item, today, pend_path, d_line, d_sha, now_done, wt = sys.argv[1:]
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
try:
    pending = json.load(open(pend_path))
    pending = pending if isinstance(pending, dict) else {}
except Exception:
    pending = {}
def save_pending():
    if os.path.isdir(os.path.dirname(pend_path)):
        tmp = pend_path + ".tmp"
        json.dump(pending, open(tmp, "w"), indent=2)
        os.replace(tmp, pend_path)
def mark_done(i, note):
    lines[i] = "- [x]" + lines[i][5:] + f" (done {today}{note})"
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
        m = ITEM_RE.match(l)
        p = pending.get(m.group(2)) if m else None
        print(l + (f"  [pending close: line {p['line']} @ {p['sha'][:12]}]" if p and l.startswith("- [ ]") else ""))
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
    elif now_done == "1":
        mark_done(i, "")
        save(lines)
        pending.pop(item, None); save_pending()
        print(f"BACKLOG: {item} done")
    else:
        pending[item] = {"line": int(d_line), "sha": d_sha, "plan": plan, "at": today}
        save_pending()
        print(f"BACKLOG: {item} pending close — confirmed when the task at line {d_line} completes with {d_sha[:12]} in its history")
elif action == "confirm":
    done = []
    for iid, p in list(pending.items()):
        if str(p.get("line")) != d_line or p.get("plan") != plan:
            continue
        ok = subprocess.run(["git", "-C", wt, "merge-base", "--is-ancestor", p.get("sha", ""), d_sha],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        hit = [i for i in range(sec[0], sec[1]) if (m := ITEM_RE.match(lines[i])) and m.group(2) == iid] if sec else []
        if ok and hit and lines[hit[0]].startswith("- [ ]"):
            mark_done(hit[0], f" at {d_sha[:12]}, line {d_line}")
            done.append(iid)
        if ok or not hit:
            pending.pop(iid, None)
    if done:
        save(lines)
    save_pending()
    print("BACKLOG: confirmed " + (", ".join(done) if done else "nothing"))
elif action == "reopen":
    back = [iid for iid, p in pending.items() if str(p.get("line")) == d_line and p.get("plan") == plan]
    for iid in back:
        pending.pop(iid, None)
    save_pending()
    print("BACKLOG: reopened " + (", ".join(back) if back else "nothing"))
PY
