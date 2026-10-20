#!/usr/bin/env bash
# operate.sh — operate a landed plan (aidlc-borrowings ADR R5, R5b, R6, R8).
#
# Usage:
#   operate.sh PLAN deploy        run $APEX_DEPLOY_CMD for the landed plan after a
#                                 human types the ack at the controlling terminal
#   operate.sh PLAN status        deploy history, watch window and declared checks
#   operate.sh --all status       the same for every landed plan under the state base
# (monitor and ingest are Phase 3.4: the step dispatch below is their seam.)
#
# Deploy (the human-only step). Two layers:
#   1. apex-dispatch's pre-bash denies every agent Bash call that invokes
#      `operate.sh … deploy`, at every stage (with or without a run lock,
#      wrappers such as script/expect/unbuffer/python pty included). That is the
#      control: a terminal read alone is agent-satisfiable (a self-made pty).
#   2. Here: an Ask Contract is printed, then the ack is read from /dev/tty and
#      must equal `<slug>@<landed sha>` (the full 40-hex sha shown in the
#      contract). APEX_OPERATE_ACK never authorizes a deploy, and a process with
#      no controlling terminal is refused: a human must type the ack at their
#      own terminal. A wrong slug or sha is refused.
#   Residual: a script file written to disk that calls operate.sh defeats the
#   hook's text match; that is deliberate circumvention, out of the threat model.
#   The landed sha is the checkpoint's `landed_sha` when recorded, else the
#   commit land.sh made for this run on the base branch (the newest first-parent
#   merge whose subject is land.sh's message for the run's branch); never the
#   base tip, which unrelated commits move. $APEX_DEPLOY_CMD runs from the caller's checkout
#   with PLAN_SLUG and LANDED_SHA in its environment (APEX_OPERATE_ACK removed);
#   its output goes to the terminal and is never captured, logged or stored, and
#   operate.sh never reads its environment. Each run is recorded in
#   checkpoint.json `operate.deploys` ({ts, sha, head, exit, ack_source: "tty"}; head
#   is the caller's checkout HEAD); exit 0 opens the watch window (operate.window
#   {start, end, days}, days = the plan's Monitor window_days, default 14); a
#   non-zero exit is recorded, opens no window and exits 1. An interrupted deploy
#   (INT, TERM or HUP) is recorded with exit 128+n and operate.sh exits 128+n; a
#   deploy that cannot be recorded exits 6 and opens no window. With <state>/dispatch/ present an `operate_deploy` ledger
#   row is appended (ledger.sh append; route_id and route_mode explicitly null, never a stale
#   active-route.json's).
#
# Status: per landed plan, the last deploy, the window as "day N of M",
# "not opened" or "closed", and the declared checks; a landed `feature` plan
# with no ## Monitor section is warned about (R5b).
#
# Exit codes:
#   0  done
#   1  the deploy command exited non-zero (recorded, no window opened)
#   2  usage, a needed command unset (APEX_DEPLOY_CMD), an invalid ## Monitor section
#   3  the plan is not landed (or not initialized), or its repository does not match
#   4  a kill switch is set (HALT file or APEX_HALT=1)
#   5  the deploy ack was refused (no human terminal, wrong or missing ack)
#   6  the deploy ran but could not be recorded in checkpoint.json (no window opened)
#   128+n  the deploy was interrupted by signal n (INT 130, TERM 143, HUP 129); recorded
set -euo pipefail

usage() {
  echo "usage: operate.sh PLAN deploy|status | operate.sh --all status" >&2
  exit 2
}
[[ $# -eq 2 ]] || usage
TARGET="$1"; STEP="$2"
case "$STEP" in
  deploy|status) ;;
  monitor|ingest) echo "ERROR: operate.sh $STEP is not implemented yet (Phase 3.4)" >&2; exit 2 ;;
  *) usage ;;
esac
[[ "$TARGET" == "--all" && "$STEP" != status ]] && { echo "ERROR: --all supports status only" >&2; exit 2; }

# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

# The python half: Monitor validation, the checkpoint record and status lines.
IFS= read -r -d '' OPERATE_PY <<'PY' || true
import datetime, fcntl, json, os, re, sys
sys.dont_write_bytecode = True
mode, exec_dir = sys.argv[1], sys.argv[2]
sys.path.insert(0, exec_dir)
import monitorlib

def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)

def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")

def parse(ts):
    return datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)

def monitor(plan):
    """(cfg, problems); callers test problems (load_plan's contract), never cfg is None."""
    return monitorlib.load_plan(plan)

STRICT = re.compile(r"^(?:>[ \t]?)?\*\*Scope\*\*:[ \t]*(.*?)[ \t]*$")
def scope(plan):
    """The plan header's Scope (promote-to-loop.sh 7b header rule); absent means feature."""
    try:
        with open(plan, encoding="utf-8", errors="replace") as f:
            for n, line in enumerate(f, 1):
                line = line.rstrip("\r\n")
                if n > 1 and (line.strip() == "---" or line.startswith("## ")):
                    break
                m = STRICT.match(line)
                if m:
                    return m.group(1) or "feature"
    except OSError:
        pass
    return "feature"

if mode == "window-days":
    cfg, probs = monitor(sys.argv[3])
    if probs:
        for p in probs:
            print("  - " + p, file=sys.stderr)
        sys.exit(2)
    print((cfg or {}).get("window_days", 14))

elif mode == "record":
    cp, lock, sha, code, days, head = sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6]), int(sys.argv[7]), sys.argv[8]
    fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o644)
    fcntl.flock(fd, fcntl.LOCK_EX)          # checkpoint.sh's state lock
    with open(cp) as f:
        s = json.load(f)
    op = s.get("operate") if isinstance(s.get("operate"), dict) else {}
    deploys = op.get("deploys") if isinstance(op.get("deploys"), list) else []
    t = now()
    deploys.append({"ts": iso(t), "sha": sha, "head": head or None, "exit": code, "ack_source": "tty"})
    op["deploys"] = deploys
    if code == 0:                           # only a successful deploy opens (restarts) the window
        op["window"] = {"start": iso(t), "end": iso(t + datetime.timedelta(days=days)), "days": days}
    s["operate"] = op
    tmp = cp + ".tmp"
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o644), "w") as f:
        json.dump(s, f, indent=2)
    os.replace(tmp, cp)

elif mode == "status":
    cp, plan, slug = sys.argv[3], sys.argv[4], sys.argv[5]
    with open(cp) as f:
        s = json.load(f)
    op = s.get("operate") if isinstance(s.get("operate"), dict) else {}
    deploys = [d for d in (op.get("deploys") or []) if isinstance(d, dict)]
    print("plan %s (%s)" % (slug, plan))
    if deploys:
        d = deploys[-1]
        print("  last deploy: %s sha %s exit %s (ack: %s; %d deploy(s))"
              % (d.get("ts"), str(d.get("sha"))[:12], d.get("exit"), d.get("ack_source", "?"), len(deploys)))
    else:
        print("  last deploy: none")
    w = op.get("window") if isinstance(op.get("window"), dict) else None
    if not w:
        print("  window: not opened")
    else:
        try:
            start, end, days = parse(w["start"]), parse(w["end"]), int(w["days"])
        except (KeyError, ValueError, TypeError):
            print("  window: unreadable %r" % (w,))
            sys.exit(2)
        t = now()
        if w.get("outcome") or t >= end:
            extra = (", " + w["outcome"]) if w.get("outcome") else ""
            oac = w.get("open_at_close") or []
            if oac:
                extra += ", open-at-close: " + ", ".join(str(x) for x in oac)
            print("  window: closed (ended %s%s)" % (w["end"], extra))
        else:
            n = min(days, max(1, (t - start).days + 1))
            print("  window: day %d of %d (opened %s, ends %s)" % (n, days, w["start"], w["end"]))
    cfg, probs = monitor(plan)
    if probs:
        print("  monitor: INVALID ## Monitor section:")
        for p in probs:
            print("    - " + p)
        sys.exit(2)
    if cfg is None:
        print("  monitor: no ## Monitor section (not watched)")
        if scope(plan) == "feature":
            print("  WARNING: %s is a landed feature plan with no ## Monitor section: nothing will be measured after a deploy (ADR R5b; add the section with its checks)" % slug)
    elif not cfg.get("checks"):
        print("  monitor: checks: [] (not watched; window_days %s)" % cfg.get("window_days", 14))
    else:
        print("  monitor: window_days %s, %d check(s):" % (cfg.get("window_days", 14), len(cfg["checks"])))
        for c in cfg["checks"]:
            p = c.get("probe") or {}
            k = p.get("kind")
            if k == "cmd":
                what = "cmd: %s" % p.get("command")
            elif k == "http":
                what = "http: GET %s (%s)" % (p.get("url"), p.get("measure"))
            else:
                what = "runner: $APEX_MONITOR_CMD %s" % " ".join(p.get("metrics") or [c.get("metric")])
            print("    - %s: %s %s %s (severity %s; probe %s)" % (c.get("id"), c.get("metric"), c.get("op"), c.get("threshold"), c.get("severity"), what))
else:
    sys.exit("operate.sh: unknown helper mode %s" % mode)
PY

op_py() { python3 -c "$OPERATE_PY" "$1" "$APEX_EXECUTE_SCRIPTS" "${@:2}"; }

# plan_slug PATH — init.sh's slug: the file name without .md and a trailing -plan.
plan_slug() { local s; s="$(basename "$1" .md)"; printf '%s' "${s%-plan}"; }

# --- --all status --------------------------------------------------------------
if [[ "$TARGET" == "--all" ]]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
  STATE_BASE="$(apex_state_base "$REPO_ROOT")"
  STATE_DIR="$STATE_BASE"
  if KS="$(apex_kill_switch)"; then echo "ERROR: kill switch set ($KS) — operate refuses to run." >&2; exit 4; fi
  RC=0; N=0
  for CP in "$STATE_BASE"/*/checkpoint.json; do
    [[ -f "$CP" ]] || continue
    [[ "$(basename "$(dirname "$CP")")" =~ ^[0-9a-f]{12}$ ]] || continue
    LANDED="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("landed") is True)' "$CP" 2>/dev/null || echo False)"
    [[ "$LANDED" == True ]] || continue
    N=$((N + 1))
    P="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("plan_path") or "")' "$CP" 2>/dev/null || true)"
    if [[ -z "$P" || ! -f "$P" ]]; then
      echo "plan ${P:-?} ($(dirname "$CP")): the plan file is gone; skipped"; echo; continue
    fi
    STATE_DIR="$(dirname "$CP")"
    if KS="$(apex_kill_switch)"; then echo "plan $(plan_slug "$P"): kill switch set ($KS); skipped"; echo; RC=4; continue; fi
    op_py status "$CP" "$P" "$(plan_slug "$P")" || { [[ "$RC" -eq 0 ]] && RC=2; }
    echo
  done
  [[ "$N" -gt 0 ]] || echo "no landed plans under $STATE_BASE"
  exit "$RC"
fi

# --- one plan --------------------------------------------------------------------
PLAN="$(apex_locate_plan "$TARGET")"
[[ -f "$PLAN" ]] || { echo "ERROR: plan not found: $PLAN" >&2; exit 2; }
if [[ "$STEP" == status ]]; then APEX_RESOLVE_MODE=read; else APEX_RESOLVE_MODE=act; fi
apex_resolve "$PLAN"                                 # a repository mismatch in act mode exits 3 (apex_die)
SLUG="$(plan_slug "$PLAN_ABS")"

[[ -f "$CHECKPOINT" ]] || { echo "ERROR: $SLUG is not landed (no run state: init.sh, iterate and land.sh first) — operate runs only on a landed plan." >&2; exit 3; }
[[ "$(read_field landed)" == "True" ]] || { echo "ERROR: $SLUG is not landed (checkpoint landed is not true; land.sh sets it) — operate runs only on a landed plan." >&2; exit 3; }
if KS="$(apex_kill_switch)"; then echo "ERROR: kill switch set ($KS) — operate refuses to run." >&2; exit 4; fi

if ! WINDOW_DAYS="$(op_py window-days "$PLAN_ABS" 2>&1)"; then
  echo "ERROR: the plan's ## Monitor section is invalid — operate refuses (fail closed):" >&2
  printf '%s\n' "$WINDOW_DAYS" >&2
  exit 2
fi
[[ "$WINDOW_DAYS" =~ ^[0-9]+$ ]] || { echo "ERROR: could not read the plan's window_days" >&2; exit 2; }

if [[ "$STEP" == status ]]; then
  op_py status "$CHECKPOINT" "$PLAN_ABS" "$SLUG"
  exit $?
fi

# --- deploy ------------------------------------------------------------------------
[[ -n "${APEX_DEPLOY_CMD:-}" ]] || { echo "ERROR: APEX_DEPLOY_CMD is unset — set it to your deploy command (operate.sh never holds deploy credentials; the command's environment is yours)." >&2; exit 2; }
# The landed sha: the checkpoint's landed_sha when recorded, else the newest merge on the
# base branch's first-parent history whose subject is exactly land.sh's landing message
# for this run's branch. Never the base tip (unrelated commits move it). None: refuse.
LANDED_SHA="$(read_field landed_sha)"
if [[ -z "$LANDED_SHA" ]]; then
  BASE_BRANCH="$(read_field base_branch)"; RUN_BRANCH="$(read_field worktree_branch)"
  BASE_TIP="$(apex_base_sha "$REPO_ROOT" "$BASE_BRANCH" || true)"
  if [[ -n "$BASE_TIP" && -n "$RUN_BRANCH" ]]; then
    LAND_LOG="$(apex_git "$REPO_ROOT" log --first-parent --merges -n 5000 --format='%H %s' "$BASE_TIP" 2>/dev/null || true)"
    LANDED_SHA="$(awk -v s="apex-scope-loop: merge $RUN_BRANCH into $BASE_BRANCH (final gate passed)" 'substr($0, 42) == s { print substr($0, 1, 40); exit }' <<<"$LAND_LOG")"
  fi
fi
[[ "$LANDED_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: cannot find the landing commit of $SLUG on '$(read_field base_branch)' (land.sh's merge of $(read_field worktree_branch)) — refusing to deploy." >&2; exit 3; }
EXPECT="$SLUG@$LANDED_SHA"

cat <<EOF
== Ask Contract: deploy $SLUG ==
What:          deploy plan $SLUG at the landed commit $LANDED_SHA
What it does:  runs \$APEX_DEPLOY_CMD from $REPO_ROOT with PLAN_SLUG=$SLUG and LANDED_SHA=$LANDED_SHA
               in its environment; on exit 0 it opens a $WINDOW_DAYS-day watch window
Why:           the plan has landed; deploying ships it and starts its monitor window
Risks:         the deploy command acts on real systems with your credentials; a failed deploy is
               recorded and opens no window; operate.sh cannot undo a deploy
To proceed, a human types exactly $EXPECT at this terminal.
EOF

refuse_ack() {
  echo "REFUSED: $1" >&2
  echo "         A deploy needs a human: run operate.sh $TARGET deploy yourself, in your own terminal, and type $EXPECT there. APEX_OPERATE_ACK never authorizes a deploy." >&2
  exit 5
}
# The ack is read from the controlling terminal only — never stdin, a file or the environment.
if ! { exec 3<>/dev/tty; } 2>/dev/null; then
  refuse_ack "this process has no terminal a human is typing at (it was not started from one)."
fi
printf 'ack> ' >&3
ACK=""
IFS= read -r -t 900 ACK <&3 || refuse_ack "no ack was typed."
exec 3<&-
ACK="${ACK%$'\r'}"
if [[ "$ACK" != "$EXPECT" ]]; then
  if [[ "${ACK%%@*}" != "$SLUG" ]]; then
    refuse_ack "the ack names another plan ('${ACK%%@*}'), expected $SLUG@<landed sha>."
  fi
  refuse_ack "the ack's sha is not this plan's landed sha $LANDED_SHA (the full sha, exactly)."
fi

HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
echo "[operate] deploying $SLUG at ${LANDED_SHA:0:12} ..."
DEPLOY_RC=0; DEPLOY_SIG=0
# An interrupt (^C, a kill, the terminal closing) must still leave a record: bash runs these traps once the
# deploy command returns, and the run is then recorded with exit 128+n before operate.sh exits 128+n.
trap 'DEPLOY_SIG=2' INT; trap 'DEPLOY_SIG=15' TERM; trap 'DEPLOY_SIG=1' HUP
(cd "$REPO_ROOT" && env -u APEX_OPERATE_ACK PLAN_SLUG="$SLUG" LANDED_SHA="$LANDED_SHA" bash -c "$APEX_DEPLOY_CMD") || DEPLOY_RC=$?
[[ "$DEPLOY_SIG" -eq 0 ]] || DEPLOY_RC=$((128 + DEPLOY_SIG))
trap '' INT TERM HUP                                 # recording is not interruptible

RECORDED=1
op_py record "$CHECKPOINT" "$STATE_DIR/.checkpoint.lock" "$LANDED_SHA" "$DEPLOY_RC" "$WINDOW_DAYS" "$HEAD_SHA" || RECORDED=0

if [[ -d "$STATE_DIR/dispatch" ]]; then
  DISPATCH="$(apex_dispatch_root)"
  if [[ -z "$DISPATCH" ]]; then
    echo "[operate] WARNING: $STATE_DIR/dispatch exists but apex-dispatch is not installed beside apex-scope-loop; no operate_deploy row" >&2
  else
    ROW="$(python3 -c 'import json, sys; print(json.dumps({"slug": sys.argv[1], "landed_sha": sys.argv[2], "exit_code": int(sys.argv[3]), "ack_source": "tty", "route_id": None, "route_mode": None}))' "$SLUG" "$LANDED_SHA" "$DEPLOY_RC")"
    "$DISPATCH/scripts/ledger.sh" append operate_deploy "$ROW" --state "$STATE_DIR" --source cli >/dev/null \
      || echo "[operate] WARNING: the operate_deploy ledger row could not be appended (ledger.sh append)" >&2
  fi
fi

if [[ "$RECORDED" -ne 1 ]]; then
  echo "[operate] ERROR: the deploy ran (exit $DEPLOY_RC) but could not be recorded in $CHECKPOINT — no watch window was opened; record the deploy by hand before relying on status or monitor." >&2
  [[ "$DEPLOY_SIG" -eq 0 ]] || exit "$DEPLOY_RC"
  exit 6
fi
if [[ "$DEPLOY_SIG" -ne 0 ]]; then
  echo "[operate] deploy INTERRUPTED (signal $DEPLOY_SIG, exit $DEPLOY_RC) — recorded; no watch window opened." >&2
  exit "$DEPLOY_RC"
fi
if [[ "$DEPLOY_RC" -ne 0 ]]; then
  echo "[operate] deploy FAILED (exit $DEPLOY_RC) — recorded; no watch window opened." >&2
  exit 1
fi
echo "[operate] deployed $SLUG at ${LANDED_SHA:0:12}; watch window open for $WINDOW_DAYS day(s)."
