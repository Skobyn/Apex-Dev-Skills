"""Read what the plugins wrote for one repository. Read-only.

Per registered repository:
- the scope-loop state base, resolved by apex-scope-loop's own apex_state_base;
- each plan state dir <base>/<plan-hash>/ (checkpoint.json, findings/, gate/) and each
  ad-hoc dir <base>/adhoc/<id>/;
- each state dir's apex-dispatch ledger, verified by apex-dispatch's own
  ledger.verify and priced by its own report.row_usd (so the console's spend is the
  number report.sh prints);
- the decision layer's log <base>/decisions/decisions.jsonl;
- the ACTIVE lock and the HALT kill switches.
Results are cached on the files' (mtime, size).
"""
import glob
import os
import threading

import ac_common as C

_cache = {}
_lock = threading.Lock()


def _stamp(*paths):
    out = []
    for p in paths:
        try:
            st = os.stat(p)
            out.append((p, st.st_mtime_ns, st.st_size))
        except OSError:
            out.append((p, None, None))
    return tuple(out)


def cached(key, paths, fn):
    stamp = _stamp(*paths)
    with _lock:
        hit = _cache.get(key)
        if hit and hit[0] == stamp:
            return hit[1]
    val = fn()
    with _lock:
        _cache[key] = (stamp, val)
    return val


# --- plugins -------------------------------------------------------------------------

def plugins():
    roots = {n: C.sibling(n) for n in ("apex-scope-loop", "apex-dispatch", "apex-decision-layer")}
    return roots, {n: C.version_str(r) for n, r in roots.items()}


def _sl_scripts():
    r = C.sibling("apex-scope-loop")
    return os.path.join(r, "skills", "apex-execute", "scripts") if r else None


def toplevel(path):
    rc, out, _ = C.run(["git", "-C", path, "rev-parse", "--show-toplevel"], timeout=10)
    return out.strip() if rc == 0 and out.strip() else None


def state_base(repo_path):
    """apex-scope-loop's apex_state_base for this repository (its own function)."""
    def compute():
        sl = _sl_scripts()
        top = toplevel(repo_path) or repo_path
        if sl and os.path.isfile(os.path.join(sl, "_lib.sh")):
            rc, out, _ = C.run(["bash", "-c", 'REPO_ROOT="$2"; source "$1/_lib.sh" >/dev/null 2>&1 && apex_state_base "$2"',
                                "_", sl, top], timeout=15)
            if rc == 0 and out.strip():
                return out.strip()
        return os.path.join(top, ".dev-plan-state")
    return cached(("base", repo_path, os.environ.get("APEX_STATE_ROOT")), [os.path.join(repo_path, ".git")], compute)


# --- dispatch ledgers ------------------------------------------------------------------

_dispatch_mods = None


def dispatch_mods():
    """(ledger, report, prices) from the installed apex-dispatch, or None."""
    global _dispatch_mods
    if _dispatch_mods is None:
        root = C.sibling("apex-dispatch")
        mods = C.import_from(root, "ledger", "report") if root else None
        if mods:
            ledger, report = mods
            try:
                price = report.prices(root)
            except Exception:
                price = {}
            _dispatch_mods = (ledger, report, price)
        else:
            _dispatch_mods = False
    return _dispatch_mods or None


def ledger_of(state_dir):
    """{ok, message, rows, dir} for a state dir's dispatch ledger. Each row with usage
    gets `_usd` (None when unpriced) from apex-dispatch's own pricing."""
    d = None
    for name in ("dispatch", "dispatch-shadow"):
        if os.path.isfile(os.path.join(state_dir, name, "ledger.jsonl")):
            d = name
            break
    if d is None:
        return {"ok": True, "message": "no ledger", "rows": [], "dir": None}

    def compute():
        mods = dispatch_mods()
        if not mods:
            rows = C.read_jsonl(os.path.join(state_dir, d, "ledger.jsonl"))
            return {"ok": None, "message": "apex-dispatch is not installed: chain not verified", "rows": rows, "dir": d}
        ledger, report, price = mods
        try:
            ok, rows, msg = ledger.verify(state_dir)
            if not ok:
                rows = ledger.read_rows(state_dir)
        except Exception as e:
            ok, rows, msg = False, C.read_jsonl(os.path.join(state_dir, d, "ledger.jsonl")), str(e)
        for r in rows:
            if isinstance(r.get("usage"), dict):
                try:
                    r["_usd"] = report.row_usd(r, price)[0]
                except Exception:
                    r["_usd"] = None
            r["_t"] = C.parse_ts(r.get("ts"))
            try:
                r["_line"] = ledger._route_line(r)
            except Exception:
                r["_line"] = None
        return {"ok": ok, "message": msg, "rows": rows, "dir": d}
    return cached(("ledger", state_dir), [os.path.join(state_dir, d, "ledger.jsonl"),
                                          os.path.join(state_dir, d, "ledger.head")], compute)


# --- plans ------------------------------------------------------------------------------

def plan_tasks(plan_abs):
    sl = _sl_scripts()
    if not sl or not os.path.isfile(plan_abs):
        return []

    def compute():
        import sys
        if sl not in sys.path:
            sys.path.append(sl)
        try:
            import planlib
            mods = planlib
        except Exception:
            mods = None
        if not mods:
            return []
        try:
            return [{"line": t["line_no"], "checked": t["checked"], "tags": t["tags"], "id": t.get("id"),
                     "title": _title(t["line"])} for t in mods.parse(plan_abs)]
        except Exception:
            return []
    return cached(("plan", plan_abs), [plan_abs], compute)


def _title(line):
    import re
    t = re.sub(r"^\s*[-*]\s*\[[ xX]\]\s*", "", line)
    t = re.sub(r"\[[^\]]*\]", "", t)              # tags
    t = re.sub(r"`[^`]*`", lambda m: m.group(0)[1:-1], t)
    return " ".join(t.split())[:160]


def findings(state_dir):
    out = []
    for f in glob.glob(os.path.join(state_dir, "findings", "L*.json")):
        d = C.read_json(f, {}) or {}
        for it in d.get("items") or []:
            if isinstance(it, dict):
                it = dict(it)
                it["_line"] = d.get("line")
                out.append(it)
    return out


def state_dirs(base):
    plans, adhoc = [], []
    if not base or not os.path.isdir(base):
        return plans, adhoc
    for d in sorted(os.listdir(base)):
        p = os.path.join(base, d)
        if os.path.isfile(os.path.join(p, "checkpoint.json")):
            plans.append(p)
    a = os.path.join(base, "adhoc")
    if os.path.isdir(a):
        adhoc = [os.path.join(a, d) for d in sorted(os.listdir(a)) if os.path.isdir(os.path.join(a, d))]
    return plans, adhoc


def lock(base):
    o = C.read_json(os.path.join(base, "ACTIVE", "owner.json")) if base else None
    if not isinstance(o, dict) or not o:
        return None
    if str(o.get("stage") or "").upper() == "DONE":
        return None
    return {"kind": o.get("kind"), "id": o.get("id"), "line": o.get("line_no"), "stage": o.get("stage"),
            "since": o.get("started_at"), "updated": o.get("updated_at"), "plan": o.get("plan") or o.get("label")}


def halt_files(repo_path, base):
    top = toplevel(repo_path) or repo_path
    cands = [os.path.join(top, ".dev-plan-state", "HALT"), os.path.join(base or "", "HALT"),
             os.path.join(top, "gibson", "HALT")]
    out = []
    for c in cands:
        if base and os.path.isfile(c) and c not in out:
            out.append(c)
    return out


def repo_snapshot(repo):
    """Everything the metrics and the progress view need for one repository."""
    path = repo["path"]
    base = state_base(path)
    top = toplevel(path) or path
    plans, adhoc = state_dirs(base)
    snap = {"id": repo["id"], "path": path, "name": os.path.basename(top.rstrip("/")) or path, "top": top,
            "state_base": base, "lock": lock(base), "halt_files": halt_files(path, base), "plans": [], "adhoc": [],
            "decisions": C.read_jsonl(os.path.join(base, "decisions", "decisions.jsonl")) if base else []}
    for sd in plans:
        cp = C.read_json(os.path.join(sd, "checkpoint.json"), {}) or {}
        pp = cp.get("plan_path") or ""
        pabs = pp if os.path.isabs(pp) else os.path.join(top, pp)
        snap["plans"].append({"dir": sd, "hash": os.path.basename(sd), "checkpoint": cp, "plan_path": pp,
                              "plan_abs": pabs, "tasks": plan_tasks(pabs), "ledger": ledger_of(sd),
                              "findings": findings(sd), "enforced": os.path.isdir(os.path.join(sd, "dispatch"))})
    for sd in adhoc:
        snap["adhoc"].append({"dir": sd, "id": os.path.basename(sd), "ledger": ledger_of(sd)})
    return snap


# --- plan scope, intent, operate state and per-task cost (all read-only) ------------------------
# Scope mirrors operate.sh's scope() (the plan header `> **Scope**: x`; absent = feature). Intent is
# .claude/tasks/<slug>-intent.md. Operate state is checkpoint.json's `operate` block (operate.sh's
# schema) plus <state base>/operate-repo/state.json, read as files: operate.sh has no JSON status and
# the console never runs it (deploy, monitor and ingest are human/scheduled steps). Declared checks
# come from scope-loop's own monitorlib. Cost is apex-dispatch's report.per_task, the CLI's numbers.

import re
import time

_SCOPE_RE = re.compile(r"^(?:>[ \t]?)?\*\*Scope\*\*:[ \t]*(.*?)[ \t]*$")


def plan_slug(plan_path):
    b = os.path.basename(plan_path or "")
    b = b[:-3] if b.endswith(".md") else b
    return b[:-5] if b.endswith("-plan") else b


def plan_scope(plan_abs):
    """bugfix|poc|feature as written in the plan header; a header-less plan is feature."""
    try:
        with open(plan_abs, encoding="utf-8", errors="replace") as f:
            for n, line in enumerate(f, 1):
                line = line.rstrip("\r\n")
                if n > 1 and (line.strip() == "---" or line.startswith("## ")):
                    break
                m = _SCOPE_RE.match(line)
                if m:
                    return m.group(1) or "feature"
    except OSError:
        pass
    return "feature"


_INTENT_KEYS = (("problem", "Problem"), ("who", "Who it's for"), ("why_now", "Why now"), ("non_goals", "Non-goals"))


def plan_intent(top, slug):
    """The intent summary from .claude/tasks/<slug>-intent.md, or None when the file does not exist."""
    p = os.path.join(top, ".claude", "tasks", "%s-intent.md" % slug)
    if not slug or not os.path.isfile(p):
        return None
    try:
        text = open(p, encoding="utf-8", errors="replace").read()
    except OSError as e:
        return {"file": os.path.relpath(p, top), "error": "unreadable: %s" % (e.strerror or e)}
    secs, cur = {}, None
    for line in text.splitlines():
        m = re.match(r"^##\s+(.*?)\s*$", line)
        if m:
            cur = m.group(1).strip().lower()
            secs.setdefault(cur, [])
        elif cur is not None:
            secs[cur].append(line)
    out = {"file": os.path.relpath(p, top)}
    for key, head in _INTENT_KEYS:
        body = " ".join(" ".join(secs.get(head.lower(), [])).split())
        out[key] = body[:400] or None
    return out


def _num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def _check_row(cid, decl, cs):
    """One declared check merged with its recorded state. A value never measured is null, not 0."""
    cs = cs if isinstance(cs, dict) else None
    row = {"id": cid, "metric": (decl or {}).get("metric"), "op": (decl or {}).get("op"),
           "threshold": (decl or {}).get("threshold"), "severity": (decl or {}).get("severity"),
           "declared": decl is not None, "measured": cs is not None,
           "last_value": _num(cs.get("last_value")) if cs else None, "last_status": cs.get("last_status") if cs else None,
           "last_ts": cs.get("last_ts") if cs else None, "last_reason": cs.get("last_reason") if cs else None,
           "breaches": cs.get("breaches") if cs and isinstance(cs.get("breaches"), int) else (0 if cs else None),
           "unmeasured_runs": cs.get("unmeasured") if cs and isinstance(cs.get("unmeasured"), int) else (0 if cs else None),
           "filed": cs.get("filed") if cs else None,
           "last_measured_value": _num(cs.get("last_measured_value")) if cs else None,
           "last_measured_status": cs.get("last_measured_status") if cs else None,
           "last_measured_ts": cs.get("last_measured_ts") if cs else None}
    row["unmeasured"] = bool(cs and cs.get("last_status") == "unmeasured") or not row["measured"]
    return row


def _monitorlib():
    sl = _sl_scripts()
    if not sl or not os.path.isfile(os.path.join(sl, "monitorlib.py")):
        return None
    import sys
    if sl not in sys.path:
        sys.path.append(sl)
    try:
        import monitorlib
        return monitorlib
    except Exception:
        return None


def _window(op, now):
    w = op.get("window") if isinstance(op.get("window"), dict) else None
    if w is None:
        return {"state": "not-opened"}
    try:
        start, end, days = C.parse_ts(w["start"]), C.parse_ts(w["end"]), int(w["days"])
    except (KeyError, ValueError, TypeError):
        start = end = days = None
    if start is None or end is None or not days:
        return {"state": "unreadable"}
    closed = bool(w.get("outcome")) or now >= end
    out = {"state": "closed" if closed else "open", "start": w.get("start"), "end": w.get("end"), "days": days,
           "day": None if closed else min(days, max(1, int((now - start) // 86400) + 1)),
           "outcome": w.get("outcome"), "closed_by": w.get("closed_by"),
           "open_at_close": list(w.get("open_at_close") or []) if w.get("outcome") else None,
           "unmeasured_at_close": list(w.get("unmeasured_at_close") or []) if w.get("outcome") else None,
           "measured_runs": w.get("measured_runs") if isinstance(w.get("measured_runs"), int) else None,
           "breaches": w.get("breaches") if isinstance(w.get("breaches"), int) else None,
           "last_run": w.get("last_run")}
    out["never_measured"] = bool(w.get("outcome")) and w.get("measured_runs") == 0
    return out


def plan_operate(cp, plan_abs, slug, scope, now=None):
    """The operate panel data for a landed plan, or None for a plan that has not landed."""
    if cp.get("landed") is not True:
        return None
    now = now or time.time()
    op = cp.get("operate")
    out = {"slug": slug, "tag": "operate:%s" % slug}
    if not isinstance(op, dict):
        out.update(state="missing", deploys=[], last_deploy=None, window={"state": "not-opened"}, windows_closed=0,
                   checks=[], monitor="unknown", problems=[])
        # fall through to the declared checks so the panel still shows what would be watched
        op = {}
    else:
        out["state"] = "ok"
    deploys = [{"ts": d.get("ts"), "sha": d.get("sha"), "exit": d.get("exit")}
               for d in (op.get("deploys") or []) if isinstance(d, dict)]
    out.update(deploys=deploys, last_deploy=deploys[-1] if deploys else None, window=_window(op, now),
               windows_closed=len([x for x in (op.get("windows_closed") or []) if isinstance(x, dict)]))
    cstate = op.get("checks") if isinstance(op.get("checks"), dict) else {}
    ml, cfg, probs, mon = _monitorlib(), None, [], "unknown"
    if ml and os.path.isfile(plan_abs):
        try:
            cfg, probs = ml.load_plan(plan_abs)
        except Exception as e:
            cfg, probs = None, ["cannot read the Monitor section: %s" % e]
        mon = "invalid" if probs else ("none" if cfg is None else ("empty" if not cfg.get("checks") else "ok"))
    elif not ml:
        probs = ["apex-scope-loop's monitorlib is not available: declared checks not read"]
    elif not os.path.isfile(plan_abs):
        probs = ["the plan file is gone: declared checks not read"]
    decl = {c["id"]: c for c in ((cfg or {}).get("checks") or []) if isinstance(c, dict) and "id" in c}
    w = (cp.get("operate") or {}).get("window") if isinstance(cp.get("operate"), dict) else None
    oac = set(w.get("open_at_close") or []) if isinstance(w, dict) and w.get("outcome") else set()
    ids = list(decl) + [k for k in cstate if isinstance(k, str) and k not in decl]
    checks = [_check_row(i, decl.get(i), cstate.get(i)) for i in ids]
    for c in checks:
        c["open_at_close"] = c["id"] in oac
    out.update(checks=checks, monitor=mon, problems=probs, window_days=(cfg or {}).get("window_days"),
               scope=scope)
    if mon == "none":
        out["warning"] = ("no ## Monitor section: not watched" +
                          ("; a landed feature plan should declare one" if scope == "feature" else ""))
    return out


def repo_checks(top, base, now=None):
    """Repo-level checks (.claude/apex-scope-loop/monitor.json) with their state in <base>/operate-repo/state.json."""
    f = os.path.join(top, ".claude", "apex-scope-loop", "monitor.json")
    if not os.path.isfile(f):
        return {"configured": False, "state": "none", "file": None, "checks": [], "problems": []}
    ml = _monitorlib()
    if not ml:
        return {"configured": True, "state": "unreadable", "file": f, "checks": [],
                "problems": ["apex-scope-loop's monitorlib is not available"]}
    try:
        cfg, probs = ml.load_file(f)
    except Exception as e:
        cfg, probs = None, [str(e)]
    if probs or not cfg:
        return {"configured": True, "state": "invalid", "file": f, "checks": [], "problems": probs}
    sp = os.path.join(base or "", "operate-repo", "state.json")
    rs = C.read_json(sp, None) if base and os.path.isfile(sp) else None
    cstate = rs.get("checks") if isinstance(rs, dict) and isinstance(rs.get("checks"), dict) else {}
    rows = [_check_row(c["id"], c, cstate.get(c["id"])) for c in cfg.get("checks") or [] if isinstance(c, dict)]
    return {"configured": True, "state": "ok" if rs is not None else "missing", "file": f, "checks": rows, "problems": []}


def plan_cost(state_dir, ledger_dir):
    """apex-dispatch's report.per_task for one state dir (the numbers `report.sh --per-task --json` prints), or
    {"status": "n/a (...)"} when it cannot be computed. Read-only; transcripts are located by report.py."""
    na = lambda why: {"status": "n/a (%s)" % why, "tasks": {}, "totals": None}
    if ledger_dir is None:
        return na("no ledger")
    mods = dispatch_mods()
    root = C.sibling("apex-dispatch")
    if not mods or not root or not hasattr(mods[1], "per_task"):
        return na("apex-dispatch's report.per_task is not available")
    stamp = [os.path.join(state_dir, ledger_dir, "ledger.jsonl"), os.path.join(state_dir, ledger_dir, "ledger.head")]

    def compute():
        try:
            p = mods[1].per_task(root, state_dir)
        except Exception as e:
            return na("report.per_task failed: %s" % e)
        tasks = {x["task"]: x for x in p["tasks"] if isinstance(x.get("task"), int)}
        return {"status": p["totals"].get("orchestrator_status"), "tasks": tasks, "totals": p["totals"],
                "chain_ok": p["chain"]["ok"]}
    # transcripts grow while a session runs and are not in the stamp, so the cache lives 30 seconds
    return cached(("cost", state_dir, int(time.time() // 30)), stamp, compute)
