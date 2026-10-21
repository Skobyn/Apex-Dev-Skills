#!/usr/bin/env bash
# operate.sh — operate a landed plan (aidlc-borrowings ADR R5, R5b, R6, R8).
#
# Usage:
#   operate.sh PLAN deploy        run $APEX_DEPLOY_CMD for the landed plan after a
#                                 human types the ack at the controlling terminal
#   operate.sh PLAN status        deploy history, watch window and declared checks
#   operate.sh --all status       the same for every landed plan under the state base
#   operate.sh PLAN monitor       measure the plan's declared checks (only while its window is open)
#   operate.sh PLAN ingest        file the plan's measured breaches (lessons / backlog), count repeats
#   operate.sh --all monitor [--ingest]
#                                 every landed plan with an open window, plus the repo-level
#                                 checks in .claude/apex-scope-loop/monitor.json; --ingest files
#                                 too (what a daily /schedule runs). `--all ingest` is refused.
#
# Monitor (ADR R5, R5b, R5c, R5d, R6; probes and the value rules are monitorlib.py's
# "Measuring" section). A plan is measured only when it is landed, has a valid ## Monitor
# section with checks, and its watch window is open; a plan with no section is skipped (and
# a landed feature plan is warned about), an invalid section is refused for that plan (exit
# 2, fail closed). A plan whose window.end has passed is not measured again: the run closes
# the window with outcome `operated-clean` (no breach in the window) or `closed-with-breaches`,
# open_at_close = the checks breaching on its last run, keeps it in operate.windows_closed
# and appends an operate_window_closed ledger row. A redeploy over a window no monitor run
# closed closes it the same way (closed_by "redeploy", no ledger row), so no outcome is lost.
# Refused before any probe runs (exit 2, named): more than 200 checks in one run, a runner
# check with APEX_MONITOR_CMD unset (or naming operate.sh / the deploy word). Each run's
# results are recorded under the checkpoint lock with an atomic write: operate.checks.<id>
# {last_value (null when unmeasured, never 0), last_status ok|breach|unmeasured, last_reason,
# note, breaches, unmeasured, filed}, window {last_run, breaching, breaches}, the pending
# signals, and <state>/operate/signals-<ts>-<pid>.json (every row carries slug, or repo).
# Repo-level checks keep their state in <state base>/operate-repo/state.json (its own lock);
# their ledger rows go to <state base>/operate-repo/dispatch/ only when that dir exists.
#
# Ingest. The first breach of a (plan, check) is filed once: severity high → lessons.sh
# PLAN add (tags operate:<slug>,<metric>), otherwise → backlog.sh PLAN add 0 "[operate:<slug>]
# ..." --from operate (a plan-level item); a repo-level breach → backlog.sh --repo add 0
# "[operate:repo] ..." --from operate only, never a lesson. Later breaches of a filed check
# only increment its count (sink `counted`); filed-once holds for the plan's lifetime,
# across windows and redeploys (a redeploy does not re-file a check already filed). Filed text is built from validated ids and
# numbers; probe-supplied text (a runner note) passes monitorlib.sanitise. With
# <state>/dispatch/ present each ingested signal appends an operate_signal row (value null
# when unmeasured). A breach that cannot be filed stays pending and exits 7.
#
# Deploy (the human-only step). Two layers:
#   1. apex-dispatch's pre-bash denies every agent Bash call whose text names
#      operate.sh and the word deploy, at every stage (with or without a run
#      lock, whatever the wrapper; a fail-closed text rule, so only the exact
#      forms `operate.sh PLAN status|monitor|ingest` and `operate.sh --all
#      status|monitor [--ingest]` pass when the text says deploy). That is the
#      control: a terminal read alone is agent-satisfiable (a self-made pty).
#   2. Here: an Ask Contract is printed, then the ack is read from /dev/tty and
#      must equal `<slug>@<landed sha>` (the full 40-hex sha shown in the
#      contract). APEX_OPERATE_ACK never authorizes a deploy, and a process with
#      no controlling terminal is refused: a human must type the ack at their
#      own terminal. A wrong slug or sha is refused.
#   Residual: a script file written to disk that calls operate.sh, a hidden
#   script name or a deploy word built by expansion defeats the hook's text
#   match; that is deliberate circumvention, out of the threat model.
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
#   (INT, TERM or HUP) is recorded with exit 128+n and operate.sh exits 128+n (also
#   when it could not be recorded); any other deploy that cannot be recorded exits 6
#   and opens no window. With <state>/dispatch/ present an `operate_deploy` ledger
#   row is appended (ledger.sh append; route_id and route_mode explicitly null, never a stale
#   active-route.json's).
#
# Status: per landed plan, the last deploy, the window as "day N of M",
# "not opened" or "closed" (with its outcome and open-at-close), the last closed
# window from operate.windows_closed, and the declared checks with their last value
# ("unmeasured" when a probe failed, never 0), breaches and where they were filed; a
# landed `feature` plan with no ## Monitor section is warned about (R5b), and so is a
# plan whose last run was all unmeasured. --all status also lists the repo-level checks.
#
# Exit codes:
#   0  done
#   1  the deploy command exited non-zero (recorded, no window opened)
#   2  usage, a needed command unset (APEX_DEPLOY_CMD; APEX_MONITOR_CMD for a runner check),
#      an invalid ## Monitor section or monitor.json, the probe cap (200 checks per run)
#   3  the plan is not landed (or not initialized), or its repository does not match
#   4  a kill switch is set (HALT file or APEX_HALT=1)
#   5  the deploy ack was refused (no human terminal, wrong or missing ack)
#   6  the deploy ran but could not be recorded in checkpoint.json (no window opened)
#   7  ingest could not file a breach (lessons.sh / backlog.sh failed); it stays pending
#   128+n  the deploy was interrupted by signal n (INT 130, TERM 143, HUP 129); recorded
#          when it can be (an interrupted deploy that could not be recorded still exits 128+n)
set -euo pipefail

usage() {
  echo "usage: operate.sh PLAN deploy|status|monitor|ingest | operate.sh --all status|monitor [--ingest]" >&2
  exit 2
}
[[ $# -eq 2 || $# -eq 3 ]] || usage
TARGET="$1"; STEP="$2"; INGEST=0
case "$STEP" in
  deploy|status|monitor|ingest) ;;
  *) usage ;;
esac
if [[ $# -eq 3 ]]; then                              # the only 3-word form: --all monitor --ingest
  [[ "$TARGET" == "--all" && "$STEP" == monitor && "$3" == "--ingest" ]] || usage
  INGEST=1
fi
if [[ "$TARGET" == "--all" && "$STEP" != status && "$STEP" != monitor ]]; then
  echo "ERROR: --all supports status only, or monitor [--ingest] (not $STEP)" >&2; exit 2
fi

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

def close_window(op, ts, by):
    """Close op["window"]: outcome from the window's breach count, open_at_close = the checks
    breaching on its last monitor run; the closed window is kept in op["windows_closed"]."""
    w = op["window"]
    b = w.get("breaches") if isinstance(w.get("breaches"), int) else 0
    outcome = "closed-with-breaches" if b > 0 else "operated-clean"
    oac = [x for x in (w.get("breaching") or []) if isinstance(x, str)]
    w.update(outcome=outcome, open_at_close=oac, breaches=b, closed_at=ts, closed_by=by)
    wc = op.get("windows_closed") if isinstance(op.get("windows_closed"), list) else []
    wc.append(dict(w))
    op["windows_closed"] = wc
    return outcome, b, oac

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
        if isinstance(op.get("window"), dict) and not op["window"].get("outcome"):
            close_window(op, iso(t), "redeploy")   # never erase an unclosed window's outcome
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

elif mode in ("status", "status-all", "run"):
    import glob, subprocess

    def slug_of(plan):
        b = os.path.basename(plan or "")
        b = b[:-3] if b.endswith(".md") else b
        return b[:-5] if b.endswith("-plan") else b

    def load(cp):
        with open(cp) as f:
            return json.load(f)

    def write_atomic(cp, s):
        tmp = cp + ".tmp"
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o644), "w") as f:
            json.dump(s, f, indent=2)
        os.replace(tmp, cp)

    class Lock:
        def __init__(self, path):
            self.path = path
        def __enter__(self):
            self.fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o644)
            fcntl.flock(self.fd, fcntl.LOCK_EX)          # checkpoint.sh's state lock (plans)
            return self
        def __exit__(self, *a):
            os.close(self.fd)

    def opof(s):
        op = s.get("operate") if isinstance(s.get("operate"), dict) else {}
        s["operate"] = op
        return op

    def fmt(v):
        """A value for humans: None is 'unmeasured', never 0."""
        if v is None or not monitorlib._is_num(v):
            return "unmeasured"
        return ("%g" % v) if isinstance(v, float) else str(v)

    def halt(repo_root, state_base, state_dir):
        for f in (os.path.join(repo_root, ".dev-plan-state", "HALT"), os.path.join(state_base, "HALT"),
                  os.path.join(state_dir, "HALT"), os.path.join(repo_root, "gibson", "HALT")):
            if os.path.isfile(f):
                return f
        return "APEX_HALT=1" if os.environ.get("APEX_HALT", "0") == "1" else None

    def walk(state_base):
        """One pass over <state base>/<12-hex>/checkpoint.json: the landed plans."""
        for cp in sorted(glob.glob(os.path.join(glob.escape(state_base), "*", "checkpoint.json"))):
            sd = os.path.dirname(cp)
            if not re.fullmatch(r"[0-9a-f]{12}", os.path.basename(sd)):
                continue
            try:
                s = load(cp)
            except (OSError, ValueError):
                continue
            if isinstance(s, dict) and s.get("landed") is True:
                yield sd, cp, (s.get("plan_path") if isinstance(s.get("plan_path"), str) else ""), s

    def check_state_line(cs):
        if not isinstance(cs, dict):
            return None
        st = cs.get("last_status") or "?"
        why = (": " + cs["last_reason"]) if st == "unmeasured" and cs.get("last_reason") else ""
        return "      last: %s (%s%s) at %s; breaches %s; unmeasured runs %s; filed %s" % (
            fmt(cs.get("last_value")), st, why, cs.get("last_ts", "?"), cs.get("breaches", 0),
            cs.get("unmeasured", 0), cs.get("filed") or "-")

    def status_one(cp, plan, slug):
        s = load(cp)
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
                return 2
            t = now()
            if w.get("outcome") or t >= end:
                extra = (", " + w["outcome"]) if w.get("outcome") else ", not yet closed by a monitor run"
                oac = w.get("open_at_close") or []
                if oac:
                    extra += ", open-at-close: " + ", ".join(str(x) for x in oac)
                print("  window: closed (ended %s%s)" % (w["end"], extra))
            else:
                n = min(days, max(1, (t - start).days + 1))
                print("  window: day %d of %d (opened %s, ends %s)" % (n, days, w["start"], w["end"]))
            if w.get("last_run"):
                print("  last monitor run: %s; %s breach(es) in this window; breaching on the last run: %s"
                      % (w["last_run"], w.get("breaches", 0), ", ".join(w.get("breaching") or []) or "none"))
            if w.get("last_run_all_unmeasured") and not w.get("outcome"):
                print("  WARNING: every check of %s was unmeasured on the last run: nothing is known about its health" % slug)
        wc = [x for x in (op.get("windows_closed") or []) if isinstance(x, dict)]
        if wc:
            x = wc[-1]
            print("  last closed window: %s (%s to %s, %s breach(es), open-at-close: %s; %d closed window(s))"
                  % (x.get("outcome"), x.get("start"), x.get("end"), x.get("breaches", 0),
                     ", ".join(x.get("open_at_close") or []) or "none", len(wc)))
        cfg, probs = monitor(plan)
        if probs:
            print("  monitor: INVALID ## Monitor section:")
            for p in probs:
                print("    - " + p)
            return 2
        if cfg is None:
            print("  monitor: no ## Monitor section (not watched)")
            if scope(plan) == "feature":
                print("  WARNING: %s is a landed feature plan with no ## Monitor section: nothing will be measured after a deploy (ADR R5b; add the section with its checks)" % slug)
        elif not cfg.get("checks"):
            print("  monitor: checks: [] (not watched; window_days %s)" % cfg.get("window_days", 14))
        else:
            print("  monitor: window_days %s, %d check(s):" % (cfg.get("window_days", 14), len(cfg["checks"])))
            cstate = op.get("checks") if isinstance(op.get("checks"), dict) else {}
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
                line = check_state_line(cstate.get(c.get("id")))
                if line:
                    print(line)
        return 0

    def repo_file(repo_root):
        return os.path.join(repo_root, ".claude", "apex-scope-loop", "monitor.json")

    def repo_dir(state_base):
        return os.path.join(state_base, "operate-repo")

    if mode == "status":
        sys.exit(status_one(sys.argv[3], sys.argv[4], sys.argv[5]))

    if mode == "status-all":
        state_base, repo_root = sys.argv[3], sys.argv[4]
        rc, n = 0, 0
        for sd, cp, plan, _s in walk(state_base):
            n += 1
            if not plan or not os.path.isfile(plan):
                print("plan %s (%s): the plan file is gone; skipped" % (plan or "?", sd))
                print()
                continue
            ks = halt(repo_root, state_base, sd)
            if ks:
                print("plan %s: kill switch set (%s); skipped" % (slug_of(plan), ks))
                print()
                rc = 4
                continue
            try:
                r = status_one(cp, plan, slug_of(plan))
            except (OSError, ValueError) as e:
                print("plan %s: unreadable checkpoint (%s)" % (slug_of(plan), e))
                r = 2
            if r and rc == 0:
                rc = r
            print()
        if n == 0:
            print("no landed plans under %s" % state_base)
        rf = repo_file(repo_root)
        if os.path.isfile(rf):
            cfg, probs = monitorlib.load_file(rf)
            print("repo checks (%s):" % rf)
            if probs:
                print("  INVALID monitor.json:")
                for p in probs:
                    print("    - " + p)
                rc = rc or 2
            else:
                try:
                    rs = load(os.path.join(repo_dir(state_base), "state.json"))
                except (OSError, ValueError):
                    rs = {}
                cstate = rs.get("checks") if isinstance(rs.get("checks"), dict) else {}
                for c in cfg["checks"]:
                    print("    - %s: %s %s %s (severity %s; repo-level, never expires)" % (c["id"], c["metric"], c["op"], c["threshold"], c["severity"]))
                    line = check_state_line(cstate.get(c["id"]))
                    if line:
                        print(line)
        sys.exit(rc)

    # --- run: monitor | ingest | both (monitor then ingest) ----------------------------------
    step, scope_, state_base, repo_root, lessons_sh, backlog_sh, ledger_sh = sys.argv[3:10]
    one = sys.argv[10:12] if scope_ == "one" else None
    measuring = step in ("monitor", "both")
    ingesting = step in ("ingest", "both")
    mcmd = os.environ.get("APEX_MONITOR_CMD", "")
    rc = 0

    def setrc(code):
        global rc
        if rc == 0:
            rc = code

    targets = []                        # dicts: kind plan|repo, label, sd, cp, lock, checks, action
    if one:
        sd, plan = one
        plans = [(sd, os.path.join(sd, "checkpoint.json"), plan, None)]
    else:
        plans = list(walk(state_base))
        if not plans:
            print("no landed plans under %s" % state_base)
    for sd, cp, plan, s in plans:
        slug = slug_of(plan)
        if not plan or not os.path.isfile(plan):
            print("plan %s (%s): the plan file is gone; skipped" % (plan or "?", sd))
            continue
        ks = halt(repo_root, state_base, sd)
        if ks:
            print("plan %s: kill switch set (%s); skipped" % (slug, ks))
            setrc(4)
            continue
        cfg, probs = monitor(plan)
        if probs:
            print("plan %s: INVALID ## Monitor section, not measured (fail closed):" % slug)
            for p in probs:
                print("  - " + p)
            setrc(2)
            continue
        if cfg is None or not cfg.get("checks"):
            print("plan %s: %s; skipped (not watched)" % (slug, "no ## Monitor section" if cfg is None else "checks: []"))
            if cfg is None and scope(plan) == "feature":
                print("  WARNING: %s is a landed feature plan with no ## Monitor section: nothing will be measured after a deploy (ADR R5b)" % slug)
            continue
        if s is None:
            s = load(cp)
        op = s.get("operate") if isinstance(s.get("operate"), dict) else {}
        w = op.get("window") if isinstance(op.get("window"), dict) else None
        action = None
        if measuring:
            if not w:
                print("plan %s: watch window not opened (no successful deploy); not measured" % slug)
            elif w.get("outcome"):
                print("plan %s: watch window closed (%s); not measured" % (slug, w["outcome"]))
            else:
                try:
                    end = parse(w["end"])
                except (KeyError, ValueError, TypeError):
                    print("plan %s: unreadable watch window %r; not measured (fail closed)" % (slug, w))
                    setrc(2)
                    continue
                action = "close" if now() >= end else "measure"
        targets.append({"kind": "plan", "slug": slug, "plan": plan, "sd": sd, "cp": cp,
                        "lock": os.path.join(sd, ".checkpoint.lock"), "checks": cfg["checks"],
                        "action": action, "label": "plan " + slug, "owner": {"slug": slug}})
    if not one and measuring:
        rf = repo_file(repo_root)
        if os.path.isfile(rf):
            cfg, probs = monitorlib.load_file(rf)
            if probs:
                print("repo checks (%s): INVALID, not measured (fail closed):" % rf)
                for p in probs:
                    print("  - " + p)
                setrc(2)
            elif cfg["checks"]:
                rd = repo_dir(state_base)
                os.makedirs(rd, exist_ok=True)
                targets.append({"kind": "repo", "slug": None, "plan": None, "sd": rd, "cp": os.path.join(rd, "state.json"),
                                "lock": os.path.join(rd, ".lock"), "checks": cfg["checks"], "action": "measure",
                                "label": "repo", "owner": {"repo": True}})

    # refusals before any probe runs: the probe cap and R6's APEX_MONITOR_CMD
    probing = [t for t in targets if t["action"] == "measure"]
    cap = monitorlib.cap_problem(sum(len(t["checks"]) for t in probing))
    if cap:
        print("ERROR: %s; nothing was measured." % cap, file=sys.stderr)
        sys.exit(2)
    if any(c["probe"]["kind"] == "runner" for t in probing for c in t["checks"]):
        prob = monitorlib.runner_cmd_problem(mcmd)
        if prob:
            print("ERROR: %s; nothing was measured (R6)." % prob, file=sys.stderr)
            sys.exit(2)

    def read_state(t):
        if t["kind"] == "plan":
            s = load(t["cp"])
            return s, opof(s)
        try:
            s = load(t["cp"])
        except FileNotFoundError:
            s = {}
        if not isinstance(s, dict):
            raise ValueError("the repo operate state is not an object")
        return s, s

    def dispatch_dir(t):
        d = os.path.join(t["sd"], "dispatch")
        return d if ledger_sh and os.path.isdir(d) else None

    def ledger(t, event, data):
        if not dispatch_dir(t):
            return
        row = dict(data, route_id=None, route_mode=None)
        r = subprocess.run([ledger_sh, "append", event, json.dumps(row), "--state", t["sd"], "--source", "cli"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        if r.returncode != 0:
            print("  WARNING: the %s ledger row could not be appended: %s" % (event, (r.stderr or "").strip()[:200]), file=sys.stderr)

    def describe(row):
        d = "%s %s breached the expected %s %s %s (check %s, severity %s, %s)" % (
            row["metric"], fmt(row["value"]), row["metric"], row["op"], fmt(row["threshold"]),
            row["check_id"], row["severity"], row["ts"])
        note = monitorlib.sanitise(row.get("note"), 120)
        return d + ("; runner note: " + note if note else "")

    def file_breach(t, row, sink):
        """Call lessons.sh or backlog.sh with argv only. True when filed."""
        if sink == "lessons":
            argv = [lessons_sh, t["plan"], "add", "operate %s %s breach" % (t["slug"], row["check_id"]),
                    "Plan %s: %s." % (t["slug"], describe(row)),
                    "Not yet diagnosed: filed by operate.sh ingest from a monitor signal of the plan's own check.",
                    "Diagnose the regression and add the guard or sensor that prevents it; repeats are counted in checkpoint.json operate.checks.",
                    "operate:%s,%s" % (t["slug"], row["metric"])]
        elif t["kind"] == "repo":
            argv = [backlog_sh, "--repo", "add", "0", "[operate:repo] " + describe(row), "--from", "operate"]
        else:
            argv = [backlog_sh, t["plan"], "add", "0", "[operate:%s] %s" % (t["slug"], describe(row)), "--from", "operate"]
        r = subprocess.run(argv, cwd=repo_root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if r.returncode != 0:
            print("  ERROR: filing %s's breach of %s to %s failed: %s" % (t["label"], row["check_id"], sink,
                  ((r.stderr or "") + (r.stdout or "")).strip()[:300]), file=sys.stderr)
            return False
        print("  ingest: %s breached; filed to %s (%s)" % (row["check_id"], sink, (r.stdout or "").strip().splitlines()[-1][:120] if (r.stdout or "").strip() else "ok"))
        return True

    for t in targets:
        closed_row = None
        if t["action"] == "measure":
            results = [(c, monitorlib.measure(c, repo_root, mcmd)) for c in t["checks"]]
            ts = iso(now())
            with Lock(t["lock"]):
                s, st = read_state(t)
                cstate = st.get("checks") if isinstance(st.get("checks"), dict) else {}
                rows, breaching, all_un = [], [], True
                for c, r in results:
                    cs = cstate.get(c["id"]) if isinstance(cstate.get(c["id"]), dict) else {}
                    for k in ("breaches", "unmeasured"):
                        if not isinstance(cs.get(k), int):
                            cs[k] = 0
                    cs.setdefault("filed", None)
                    if r["status"] == "breach":
                        cs["breaches"] += 1
                        breaching.append(c["id"])
                    if r["status"] == "unmeasured":
                        cs["unmeasured"] += 1
                    else:
                        all_un = False
                    cs.update(metric=c["metric"], last_value=r["value"], last_status=r["status"], last_ts=ts,
                              last_reason=r["reason"], note=r["note"])
                    cstate[c["id"]] = cs
                    rows.append(dict(t["owner"], check_id=c["id"], metric=c["metric"], op=c["op"], threshold=c["threshold"],
                                     severity=c["severity"], value=r["value"], status=r["status"], reason=r["reason"],
                                     note=r["note"], breach_count=cs["breaches"], ts=ts))
                st["checks"] = cstate
                pend = st.get("pending") if isinstance(st.get("pending"), list) else []
                st["pending"] = (pend + rows)[-2000:]
                if t["kind"] == "plan":
                    w = st["window"]
                    w["last_run"], w["breaching"], w["last_run_all_unmeasured"] = ts, breaching, all_un
                    w["breaches"] = (w.get("breaches") if isinstance(w.get("breaches"), int) else 0) + len(breaching)
                else:
                    st["last_run"], st["breaching"] = ts, breaching
                sig_dir = os.path.join(t["sd"], "operate")
                os.makedirs(sig_dir, exist_ok=True)
                sig = os.path.join(sig_dir, "signals-%s-%d.json" % (ts.replace(":", ""), os.getpid()))
                with open(sig, "w") as f:
                    json.dump(rows, f, indent=2)
                write_atomic(t["cp"], s)
            print("%s: measured %d check(s) (signals %s)" % (t["label"], len(rows), sig))
            for row in rows:
                print("  - %s: %s = %s (%s%s)" % (row["check_id"], row["metric"], fmt(row["value"]), row["status"],
                      (": " + row["reason"]) if row["reason"] else ""))
        elif t["action"] == "close":
            with Lock(t["lock"]):
                s, op = read_state(t)
                w = op.get("window")
                if isinstance(w, dict) and not w.get("outcome"):
                    outcome, breaches, oac = close_window(op, iso(now()), "monitor")
                    write_atomic(t["cp"], s)
                    closed_row = {"slug": t["slug"], "outcome": outcome, "breaches": breaches, "open_at_close": oac}
            if closed_row:
                print("plan %s: watch window ended (%s); closed %s%s; no longer measured" % (
                    t["slug"], op["window"]["end"], closed_row["outcome"],
                    ("; open-at-close: " + ", ".join(closed_row["open_at_close"])) if closed_row["open_at_close"] else ""))
        ledger_rows = []
        if ingesting:
            with Lock(t["lock"]):
                s, st = read_state(t)
                pend = st.get("pending") if isinstance(st.get("pending"), list) else []
                if not pend:
                    s = None
                cstate = st.get("checks") if isinstance(st.get("checks"), dict) else {}
                keep, failed = [], False
                for row in pend:
                    if failed or not isinstance(row, dict):
                        keep.append(row)
                        continue
                    cs = cstate.get(row.get("check_id")) if isinstance(cstate.get(row.get("check_id")), dict) else {}
                    sink = "counted"
                    if row.get("status") == "breach":
                        if cs.get("filed"):
                            cs["counted"] = (cs.get("counted") if isinstance(cs.get("counted"), int) else 0) + 1
                            print("  ingest: %s breached again; already filed to %s, counted (breach %s)" % (row["check_id"], cs["filed"], row["breach_count"]))
                        else:
                            sink = "backlog" if (t["kind"] == "repo" or row.get("severity") != "high") else "lessons"
                            if not file_breach(t, row, sink):
                                failed = True
                                keep.append(row)
                                continue
                            cs["filed"], cs["filed_ts"] = sink, iso(now())
                            ing = st.get("ingested") if isinstance(st.get("ingested"), dict) else {}
                            ing[sink] = (ing.get(sink) if isinstance(ing.get(sink), int) else 0) + 1
                            st["ingested"] = ing
                        cstate[row["check_id"]] = cs
                    data = dict((k, row[k]) for k in ("slug", "repo") if k in row)
                    data.update(check_id=row["check_id"], metric=row["metric"],
                                value=row["value"] if monitorlib._is_num(row.get("value")) else None,
                                threshold=row["threshold"], severity=row["severity"],
                                breach_count=row["breach_count"], sink=sink)
                    ledger_rows.append(data)
                st["checks"], st["pending"] = cstate, keep
                if s is not None:
                    write_atomic(t["cp"], s)
            if failed:
                print("%s: a breach could not be filed; it stays pending and is retried by the next ingest" % t["label"], file=sys.stderr)
                setrc(7)
        for data in ledger_rows:          # after the checkpoint lock is released (ledger.py may take it)
            ledger(t, "operate_signal", data)
        if closed_row:
            ledger(t, "operate_window_closed", closed_row)
    sys.exit(rc)
else:
    sys.exit("operate.sh: unknown helper mode %s" % mode)
PY

op_py() { python3 -c "$OPERATE_PY" "$1" "$APEX_EXECUTE_SCRIPTS" "${@:2}"; }

# op_ledger — apex-dispatch's ledger.sh, or empty when apex-dispatch is not installed beside us.
op_ledger() { local d; d="$(apex_dispatch_root)"; [[ -n "$d" && -x "$d/scripts/ledger.sh" ]] && printf '%s' "$d/scripts/ledger.sh"; return 0; }

# plan_slug PATH — init.sh's slug: the file name without .md and a trailing -plan.
plan_slug() { local s; s="$(basename "$1" .md)"; printf '%s' "${s%-plan}"; }

# --- --all status --------------------------------------------------------------
if [[ "$TARGET" == "--all" ]]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
  STATE_BASE="$(apex_state_base "$REPO_ROOT")"
  STATE_DIR="$STATE_BASE"
  if KS="$(apex_kill_switch)"; then echo "ERROR: kill switch set ($KS) — operate refuses to run." >&2; exit 4; fi
  # one python pass walks every <state base>/<12-hex>/checkpoint.json (status, or monitor [+ ingest])
  RC=0
  if [[ "$STEP" == status ]]; then
    op_py status-all "$STATE_BASE" "$REPO_ROOT" || RC=$?
  else
    op_py run "$([[ "$INGEST" -eq 1 ]] && echo both || echo monitor)" all "$STATE_BASE" "$REPO_ROOT" \
      "$APEX_EXECUTE_SCRIPTS/lessons.sh" "$APEX_EXECUTE_SCRIPTS/backlog.sh" "$(op_ledger)" || RC=$?
  fi
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
if [[ "$STEP" == monitor || "$STEP" == ingest ]]; then
  RC=0
  op_py run "$STEP" one "$STATE_BASE" "$REPO_ROOT" "$APEX_EXECUTE_SCRIPTS/lessons.sh" "$APEX_EXECUTE_SCRIPTS/backlog.sh" \
    "$(op_ledger)" "$STATE_DIR" "$PLAN_ABS" || RC=$?
  exit "$RC"
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
