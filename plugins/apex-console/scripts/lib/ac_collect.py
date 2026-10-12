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
