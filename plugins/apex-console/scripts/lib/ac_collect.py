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
import importlib.util
import os
import re
import sys
import threading
import time

import ac_common as C

_cache = {}
_lock = threading.Lock()
_CACHE_MAX = 4096          # a safety net only: every key below is one entry per file or directory, not per poll


def _stamp(*paths):
    out = []
    for p in paths:
        try:
            st = os.stat(p)
            out.append((p, st.st_mtime_ns, st.st_size))
        except OSError:
            out.append((p, None, None))
    return tuple(out)


def cached(key, paths, fn, extra=None):
    """fn()'s value, recomputed when the (mtime, size) of `paths` or `extra` changes. The KEY names what is
    cached (one entry per file, directory or state dir) and must never carry a time or a growing value: anything
    that varies goes in `paths` or `extra`, so the entry is replaced, not added to."""
    stamp = (_stamp(*paths), extra)
    with _lock:
        hit = _cache.get(key)
        if hit and hit[0] == stamp:
            return hit[1]
    val = fn()
    with _lock:
        _cache[key] = (stamp, val)
        while len(_cache) > _CACHE_MAX:
            _cache.pop(next(iter(_cache)), None)
    return val


# --- scope-loop's own python modules ---------------------------------------------------------

_sl_mods = {}
_sl_lock = threading.RLock()


def _sl_module(name):
    """planlib / monitorlib from apex-scope-loop, loaded from their file path. monitorlib puts its directory at
    the front of sys.path and turns bytecode writing off at import; neither may leak into the console process
    (the console must not shadow its own modules, and its flag is not scope-loop's to flip), so both are restored.
    Bytecode is off while the file executes so nothing is written into the plugin directory."""
    sl = _sl_scripts()
    path = os.path.join(sl, name + ".py") if sl else None
    if not path or not os.path.isfile(path):
        return None
    with _sl_lock:
        if path in _sl_mods:
            return _sl_mods[path]
        saved_path, saved_flag = list(sys.path), sys.dont_write_bytecode
        had_planlib = "planlib" in sys.modules
        sys.dont_write_bytecode = True
        try:
            if name == "monitorlib":          # it does `import planlib`: hand it ours rather than a path lookup
                pl = _sl_module("planlib")
                if pl is None:
                    return None
                sys.modules.setdefault("planlib", pl)
            spec = importlib.util.spec_from_file_location("_apex_sl_" + name, path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
        except Exception:
            return None
        finally:
            # undo by subtraction, not by restoring a snapshot: another thread may have appended a sibling's lib
            # dir to sys.path meanwhile (ac_common.import_from) and that must survive
            sys.path[:] = [e for e in sys.path if e in saved_path or e != os.path.dirname(path)]
            sys.dont_write_bytecode = saved_flag
            if name == "monitorlib" and not had_planlib:
                sys.modules.pop("planlib", None)      # monitorlib keeps its own reference
        _sl_mods[path] = mod
        return mod


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
        mods = _sl_module("planlib")
        if not mods:
            return []
        try:
            return [{"line": t["line_no"], "checked": t["checked"], "tags": t["tags"], "id": t.get("id"),
                     "title": _title(t["line"])} for t in mods.parse(plan_abs)]
        except Exception:
            return []
    return cached(("plan", plan_abs), [plan_abs], compute)


def _title(line):
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
# come from scope-loop's own monitorlib. Ingested lessons and backlog entries are read from the main
# checkout's LESSONS.md / BACKLOG.md (lessons.sh / backlog.sh's files, never written here). Cost is
# apex-dispatch's report.per_task, the CLI's numbers. Every cache key below names a file or a state
# dir; what changes goes in the stamp.

_SCOPE_RE = re.compile(r"^(?:>[ \t]?)?\*\*Scope\*\*:[ \t]*(.*?)[ \t]*$")


def plan_slug(plan_path):
    b = os.path.basename(plan_path or "")
    b = b[:-3] if b.endswith(".md") else b
    return b[:-5] if b.endswith("-plan") else b


def plan_scope(plan_abs):
    """bugfix|poc|feature as written in the plan header; a header-less plan is feature."""
    def compute():
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
    return cached(("scope", plan_abs), [plan_abs], compute)


_INTENT_KEYS = (("problem", "Problem"), ("who", "Who it's for"), ("why_now", "Why now"), ("non_goals", "Non-goals"))


def plan_intent(top, slug):
    """The intent summary from .claude/tasks/<slug>-intent.md, or None when the file does not exist."""
    p = os.path.join(top, ".claude", "tasks", "%s-intent.md" % slug)
    if not slug or not os.path.isfile(p):
        return None

    def compute():
        try:
            with open(p, encoding="utf-8", errors="replace") as f:
                text = f.read()
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
    return cached(("intent", p), [p], compute)


def _num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def _count(v):
    """A recorded count, or None when it is missing or not an integer (a bool is not one): never 0."""
    return v if isinstance(v, int) and not isinstance(v, bool) else None


def _check_row(cid, decl, cs):
    """One declared check merged with its recorded state. A value never measured is null, not 0."""
    cs = cs if isinstance(cs, dict) else None
    row = {"id": cid, "metric": (decl or {}).get("metric"), "op": (decl or {}).get("op"),
           "threshold": (decl or {}).get("threshold"), "severity": (decl or {}).get("severity"),
           "declared": decl is not None, "measured": cs is not None,
           "last_value": _num(cs.get("last_value")) if cs else None, "last_status": cs.get("last_status") if cs else None,
           "last_ts": cs.get("last_ts") if cs else None, "last_reason": cs.get("last_reason") if cs else None,
           "breaches": _count(cs.get("breaches")) if cs else None,
           "unmeasured_runs": _count(cs.get("unmeasured")) if cs else None,
           "filed": cs.get("filed") if cs else None,
           "last_measured_value": _num(cs.get("last_measured_value")) if cs else None,
           "last_measured_status": cs.get("last_measured_status") if cs else None,
           "last_measured_ts": cs.get("last_measured_ts") if cs else None}
    row["unmeasured"] = bool(cs and cs.get("last_status") == "unmeasured") or not row["measured"]
    return row


def _monitorlib():
    return _sl_module("monitorlib")


def _ml_path():
    sl = _sl_scripts()
    return os.path.join(sl, "monitorlib.py") if sl else ""


# --- ingested lessons and backlog (read-only) ---------------------------------------------------
# lessons.sh: "## L-NNN · date · title-slug" blocks with a "**Tags:** #operate:<slug> #metric" line.
# backlog.sh: "- [ ] B-NNN · date · where · from src — text" items, a plan's under "## Plan: <plan>",
# the repo's under "## Repo: operate checks (monitor.json)"; operate.sh ingest writes the text as
# "[operate:<slug>] ..." (repo level: "[operate:repo] ..."). Ids and short titles only.

_INGEST_LIST_MAX = 50
_LESSON_RE = re.compile(r"^## (L-\d+)\b(?: · [^·]*· (.*))?$")
_ITEM_RE = re.compile(r"^- \[( |x)\] (B-\d+) · (.*)$")
_OTAG_RE = re.compile(r"^\[operate:([^\]]+)\]\s*(.*)$")


def _short(t, n=100):
    t = " ".join(str(t or "").split())
    return t if len(t) <= n else t[:n - 1] + "\u2026"


def ledger_files(top):
    """(LESSONS.md, BACKLOG.md) as lessons.sh and backlog.sh resolve them: the MAIN checkout's
    .claude/apex-scope-loop/ (APEX_LESSONS_FILE / APEX_BACKLOG_FILE override), else the common git dir for a
    bare repository."""
    def compute():
        main = None
        rc, out, _ = C.run(["git", "-C", top, "worktree", "list", "--porcelain"], timeout=10)
        if rc == 0:
            blocks = out.strip().split("\n\n")
            if blocks and blocks[0].startswith("worktree ") and "\nbare" not in "\n" + blocks[0]:
                main = os.path.realpath(blocks[0].split("\n", 1)[0][len("worktree "):])
        if main:
            d = os.path.join(main, ".claude", "apex-scope-loop")
        else:
            rc, out, _ = C.run(["git", "-C", top, "rev-parse", "--path-format=absolute", "--git-common-dir"], timeout=10)
            d = os.path.join(os.path.realpath(out.strip()), "apex-scope-loop") if rc == 0 and out.strip() \
                else os.path.join(top, ".claude", "apex-scope-loop")
        return (os.environ.get("APEX_LESSONS_FILE") or os.path.join(d, "LESSONS.md"),
                os.environ.get("APEX_BACKLOG_FILE") or os.path.join(d, "BACKLOG.md"))
    return cached(("ledger-files", top, os.environ.get("APEX_LESSONS_FILE"), os.environ.get("APEX_BACKLOG_FILE")),
                  [os.path.join(top, ".git")], compute)


def _read_lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().split("\n")
    except OSError:
        return None


def _lessons(path):
    def compute():
        lines = _read_lines(path)
        out, cur = [], None
        for ln in lines or []:
            m = _LESSON_RE.match(ln)
            if m:
                cur = {"id": m.group(1), "title": _short(m.group(2)), "tags": set()}
                out.append(cur)
            elif cur is not None and ln.startswith("**Tags:**"):
                cur["tags"] = {t.lstrip("#").lower() for t in ln[len("**Tags:**"):].split()}
        return {"readable": lines is not None, "items": out}
    return cached(("lessons", path), [path], compute)


def _backlog(path):
    def compute():
        lines = _read_lines(path)
        out, sect = [], None
        for ln in lines or []:
            if ln.startswith("## "):
                sect = "repo" if ln.startswith("## Repo:") else ("plan" if ln.startswith("## Plan:") else None)
                continue
            m = _ITEM_RE.match(ln)
            if m and sect:
                text = m.group(3).partition(" \u2014 ")[2]
                t = _OTAG_RE.match(text.strip())
                if t:
                    out.append({"id": m.group(2), "done": m.group(1) == "x", "section": sect,
                                "slug": t.group(1).lower(), "title": _short(t.group(2))})
        return {"readable": lines is not None, "items": out}
    return cached(("backlog", path), [path], compute)


def _ingest_block(lessons, backlog):
    bl = [{"id": b["id"], "title": b["title"], "done": b["done"]} for b in backlog]
    ls = [{"id": l["id"], "title": l["title"]} for l in lessons]
    return {"lessons": ls[:_INGEST_LIST_MAX], "backlog": bl[:_INGEST_LIST_MAX],
            "counts": {"lessons": len(ls), "backlog": len(bl), "backlog_open": sum(1 for b in bl if not b["done"])}}


def ingested(top, slug):
    """The lessons (tag #operate:<slug>) and backlog items ([operate:<slug>] under a plan section) that
    operate.sh ingest filed for one plan: ids and short titles, plus counts. Read-only."""
    lf, bf = ledger_files(top)
    want = ("operate:%s" % slug).lower()
    les = [l for l in _lessons(lf)["items"] if want in l["tags"]]
    bk = [b for b in _backlog(bf)["items"] if b["section"] == "plan" and b["slug"] == slug.lower()]
    return _ingest_block(les, bk)


def ingested_repo(top):
    """The repo-level backlog items ([operate:repo] under `## Repo: ...`); the repo level never files a lesson."""
    bk = [b for b in _backlog(ledger_files(top)[1])["items"] if b["section"] == "repo" and b["slug"] == "repo"]
    blk = _ingest_block([], bk)
    del blk["lessons"]
    del blk["counts"]["lessons"]
    return blk


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
           "measured_runs": _count(w.get("measured_runs")),
           "breaches": _count(w.get("breaches")),
           "last_run": w.get("last_run")}
    out["never_measured"] = bool(w.get("outcome")) and w.get("measured_runs") == 0
    return out


def _last_closed(op):
    """The last entry of operate.windows_closed, as operate.sh status prints it, or None."""
    wc = [x for x in (op.get("windows_closed") or []) if isinstance(x, dict)]
    if not wc:
        return None
    x = wc[-1]
    return {"outcome": x.get("outcome"), "closed_by": x.get("closed_by"), "closed_at": x.get("closed_at"),
            "start": x.get("start"), "end": x.get("end"), "days": _count(x.get("days")),
            "open_at_close": [str(i) for i in (x.get("open_at_close") or [])],
            "unmeasured_at_close": [str(i) for i in (x.get("unmeasured_at_close") or [])],
            "measured_runs": _count(x.get("measured_runs")), "breaches": _count(x.get("breaches")),
            "never_measured": x.get("measured_runs") == 0}


def _declared(plan_abs):
    """(cfg, problems, monitor state) of the plan's ## Monitor section through monitorlib; cached on the plan file."""
    ml = _monitorlib()
    if not ml:
        return None, ["apex-scope-loop's monitorlib is not available: declared checks not read"], "unknown"
    if not os.path.isfile(plan_abs):
        return None, ["the plan file is gone: declared checks not read"], "unknown"

    def compute():
        try:
            cfg, probs = ml.load_plan(plan_abs)
        except Exception as e:
            cfg, probs = None, ["cannot read the Monitor section: %s" % e]
        mon = "invalid" if probs else ("none" if cfg is None else ("empty" if not cfg.get("checks") else "ok"))
        return cfg, probs, mon
    return cached(("declared", plan_abs), [plan_abs, _ml_path()], compute)


def plan_operate(cp, plan_abs, slug, scope, now=None, top=None):
    """The operate panel data for a landed plan, or None for a plan that has not landed. The checkpoint is
    already read by the caller; the window is computed against `now`; the declared checks and the ingested
    entries are cached on the files they come from."""
    if cp.get("landed") is not True:
        return None
    now = now or time.time()
    op = cp.get("operate")
    out = {"slug": slug, "tag": "operate:%s" % slug}
    if not isinstance(op, dict):
        out["state"] = "missing"
        op = {}              # fall through to the declared checks so the panel still shows what would be watched
    else:
        out["state"] = "ok"
    deploys = [{"ts": d.get("ts"), "sha": d.get("sha"), "exit": d.get("exit")}
               for d in (op.get("deploys") or []) if isinstance(d, dict)]
    out.update(deploys=deploys, last_deploy=deploys[-1] if deploys else None, window=_window(op, now),
               windows_closed=len([x for x in (op.get("windows_closed") or []) if isinstance(x, dict)]),
               last_closed_window=_last_closed(op))
    cstate = op.get("checks") if isinstance(op.get("checks"), dict) else {}
    cfg, probs, mon = _declared(plan_abs)
    decl = {c["id"]: c for c in ((cfg or {}).get("checks") or []) if isinstance(c, dict) and "id" in c}
    w = op.get("window")
    oac = set(w.get("open_at_close") or []) if isinstance(w, dict) and w.get("outcome") else set()
    ids = list(decl) + [k for k in cstate if isinstance(k, str) and k not in decl]
    checks = [_check_row(i, decl.get(i), cstate.get(i)) for i in ids]
    for c in checks:
        c["open_at_close"] = c["id"] in oac
    out.update(checks=checks, monitor=mon, problems=list(probs), window_days=(cfg or {}).get("window_days"),
               scope=scope, ingested=ingested(top, slug) if top else _ingest_block([], []))
    if mon == "none":
        out["warning"] = ("no ## Monitor section: not watched" +
                          ("; a landed feature plan should declare one" if scope == "feature" else ""))
    return out


def repo_checks(top, base, now=None):
    """Repo-level checks (.claude/apex-scope-loop/monitor.json) with their state in <base>/operate-repo/state.json,
    and the backlog items operate.sh ingest filed for them (`ingested`)."""
    f = os.path.join(top, ".claude", "apex-scope-loop", "monitor.json")
    if not os.path.isfile(f):
        return {"configured": False, "state": "none", "file": None, "checks": [], "problems": [],
                "ingested": ingested_repo(top)}
    sp = os.path.join(base or "", "operate-repo", "state.json")

    def compute():
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
        rs = C.read_json(sp, None) if base and os.path.isfile(sp) else None
        cstate = rs.get("checks") if isinstance(rs, dict) and isinstance(rs.get("checks"), dict) else {}
        rows = [_check_row(c["id"], c, cstate.get(c["id"])) for c in cfg.get("checks") or [] if isinstance(c, dict)]
        return {"configured": True, "state": "ok" if rs is not None else "missing", "file": f, "checks": rows, "problems": []}
    res = cached(("repo-checks", f, sp), [f, sp, _ml_path()], compute)
    return dict(res, ingested=ingested_repo(top))


COST_TTL = 30        # seconds: how long a located-but-unchanged transcript set is trusted


def _cost_bucket():
    return int(time.time() // COST_TTL)


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
    try:       # the transcripts report.per_task will read: a growing one changes the stamp, a new one the path set
        stamp += list(mods[1].locate_transcripts(ledger_of(state_dir)["rows"])[0])
    except Exception:
        pass

    def compute():
        try:
            p = mods[1].per_task(root, state_dir)
        except Exception as e:
            return na("report.per_task failed: %s" % e)
        tasks = {x["task"]: x for x in p["tasks"] if isinstance(x.get("task"), int)}
        return {"status": p["totals"].get("orchestrator_status"), "tasks": tasks, "totals": p["totals"],
                "chain_ok": p["chain"]["ok"]}
    # ONE entry per state dir. The 30 s bucket is in the stamp (a transcript that has not appeared yet, or a
    # session whose file was replaced in place, is picked up within COST_TTL), never in the key.
    return cached(("cost", state_dir), stamp, compute, extra=_cost_bucket())
