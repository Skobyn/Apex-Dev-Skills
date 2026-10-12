"""The console's HTTP server: 127.0.0.1 only, one token per launch, JSON API (docs/api.md).

Request checks, in order: the Host header names this server (DNS rebinding); the
session cookie carries the launch token (set once by GET /?t=<token>); a POST also
carries `X-Apex-Console: 1` (a cross-site form or image cannot) and a JSON body of at
most 64 KiB. Static files come only from ui/. No route returns a key value.
"""
import hashlib
import hmac
import http.cookies
import http.server
import json
import os
import re
import secrets
import threading
import urllib.parse

import ac_collect
import ac_common as C
import ac_keys
import ac_knobs
import ac_metrics
import ac_tiersim

UI = os.path.join(C.PLUGIN_ROOT, "ui")
STATIC = {"/": ("index.html", "text/html; charset=utf-8"), "/app.js": ("app.js", "text/javascript; charset=utf-8"),
          "/app.css": ("app.css", "text/css; charset=utf-8"), "/demo.json": ("demo.json", "application/json")}
CSP = ("default-src 'self'; script-src 'self'; style-src 'self' https://fonts.googleapis.com; "
       "font-src https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; "
       "base-uri 'none'; form-action 'none'")
WRITE_LOCK = threading.Lock()


# --- the console's own config ------------------------------------------------------------

def cfg_path():
    return os.path.join(C.config_dir(), "console.json")


def load_cfg():
    cfg = C.read_json(cfg_path(), {}) or {}
    cfg.setdefault("repos", [])
    cfg.setdefault("targets", {})
    return cfg


def save_cfg(cfg):
    C.write_json(cfg_path(), cfg, 0o600)


def add_repo(path):
    full = os.path.realpath(os.path.expanduser(path))
    top = ac_collect.toplevel(full)
    if not top:
        raise ValueError("%s is not inside a git repository" % path)
    cfg = load_cfg()
    for r in cfg["repos"]:
        if r["path"] == top:
            return r["id"], False
    n = max([int(r["id"][1:]) for r in cfg["repos"] if re.fullmatch(r"r\d+", r["id"])] + [0]) + 1
    cfg["repos"].append({"id": "r%d" % n, "path": top})
    save_cfg(cfg)
    return "r%d" % n, True


def repo_by_id(rid):
    for r in load_cfg()["repos"]:
        if r["id"] == rid:
            return r
    raise LookupError("unknown repo %s" % rid)


def snapshots(rid="all"):
    repos = load_cfg()["repos"] if rid in (None, "", "all") else [repo_by_id(rid)]
    out = []
    for r in repos:
        try:
            out.append(ac_collect.repo_snapshot(r))
        except Exception as e:     # one broken repo never hides the others
            out.append({"id": r["id"], "path": r["path"], "name": os.path.basename(r["path"]), "error": str(e),
                        "plans": [], "adhoc": [], "decisions": [], "lock": None, "halt_files": [], "state_base": None,
                        "top": r["path"]})
    return out


# --- routes -------------------------------------------------------------------------------

def needed_keys(snaps):
    need = set()
    for s in snaps:
        if not s.get("state_base"):
            continue
        try:
            d = ac_knobs.dispatch_get(s["top"], s["state_base"])
            for p in d.get("providers", []):
                if p.get("enabled") and p.get("key_env") and p["id"] != "claude-session":
                    need.add(p["key_env"])
            dc = ac_knobs.decision_get(s["top"])
            cfg = dc.get("config") or {}
            backends = set((cfg.get("primary") or {}).values()) | {(cfg.get("shadow") or {}).get("backend")}
            if cfg.get("egress") == "hosted":
                if "frontier" in backends:
                    need.add("ANTHROPIC_API_KEY")
                if "jev" in backends:
                    need.add("OPENROUTER_API_KEY")
            need.update(dc.get("key_envs") or [])
        except Exception:
            continue
    return need


def api_state():
    roots, versions = ac_collect.plugins()
    cfg = load_cfg()
    snaps = snapshots()
    repos = []
    for s in snaps:
        repos.append({"id": s["id"], "name": s["name"], "path": s["path"], "ok": not s.get("error"),
                      "error": s.get("error"), "state_base": s.get("state_base"), "plugins": versions,
                      "active": bool(s.get("lock")), "halted": bool(s.get("halt_files"))})
    keys = ac_keys.summary(needed_keys(snaps))
    return {"version": C.version_str(C.PLUGIN_ROOT), "generated_at": C.now(),
            "config_dir": C.config_dir().replace(os.path.expanduser("~"), "~", 1), "repos": repos,
            "targets": dict(ac_metrics.DEFAULT_TARGETS, **cfg["targets"]),
            "keys": {"set": sum(1 for k in keys["keys"] if k["set"]),
                     "missing_needed": [k["name"] for k in keys["keys"] if k["needed"] and not k["set"]]}}


def api_metrics(q):
    rid = q.get("repo", "all")
    try:
        days = int(q.get("days", 28))
    except ValueError:
        days = 28
    days = max(7, min(365, days))
    out = ac_metrics.compute(snapshots(rid), days, load_cfg()["targets"])
    out["repo"] = rid
    # Change markers: each knob change or stop/resume inside the charted weeks, so a
    # chart shows whether a change moved the numbers.
    start = C.parse_ts((out["series"]["weeks"] or [None])[0] + "T00:00:00Z") if out["series"]["weeks"] else None
    out["events"] = [{"at": e["at"], "kind": e["kind"], "repo": e.get("repo"), "summary": e["summary"], "id": e["id"]}
                     for e in C.audit_entries()
                     if e.get("kind") in ("knobs", "halt") and (rid in (None, "", "all") or e.get("repo") == rid)
                     and start is not None and (C.parse_ts(e.get("at")) or 0) >= start]
    return out


def _task_status(line, done_lines, active_line, failed_lines):
    if line in done_lines:
        return "done"
    if line == active_line:
        return "active"
    if line in failed_lines:
        return "failed"
    return "todo"


def api_progress():
    out = []
    for s in snapshots():
        lk = s.get("lock")
        plans = []
        for p in s["plans"]:
            cp = p["checkpoint"]
            done = {}
            for c in cp.get("completes") or []:
                if isinstance(c, dict) and isinstance(c.get("line"), int):
                    done[c["line"]] = c
            reviews = cp.get("reviews") or {}
            failed = {int(k) for k, v in reviews.items() if str(k).isdigit() and isinstance(v, dict) and v.get("attempt", 1) > 1}
            active_line = lk.get("line") if lk and lk.get("id") == p["hash"] else None
            cost = {}
            last = None
            for r in p["ledger"]["rows"]:
                if r.get("_t") and (last is None or r["_t"] > last):
                    last = r["_t"]
                if r.get("event") == "worker_run" and r.get("_usd") is not None:
                    ln = r.get("_line") if r.get("_line") is not None else r.get("line")
                    cost[ln] = cost.get(ln, 0.0) + r["_usd"]
            tasks = []
            for t in p["tasks"]:
                ln = t["line"]
                rv = reviews.get(str(ln)) or {}
                heads = {(x.get("attempt", 1), x.get("sha")) for x in rv.get("records") or [] if isinstance(x, dict)}
                tasks.append({"line": ln, "title": t["title"], "tags": t["tags"],
                              "status": "done" if (t["checked"] or ln in done) else _task_status(ln, done, active_line, failed),
                              "tier": ((cp.get("tiers") or {}).get(str(ln)) or {}).get("tier"),
                              "rounds": len(heads) or None, "attempts": rv.get("attempt"),
                              "completed_at": (done.get(ln) or {}).get("at"), "usd": round(cost[ln], 4) if ln in cost else None})
            lt = C.parse_ts(cp.get("last_iteration_at"))
            last = max([x for x in (last, lt) if x] or [0]) or None
            open_f = sum(1 for f in p["findings"] if f.get("status") == "open")
            usd = sum(v for v in cost.values())
            plans.append({"hash": p["hash"], "path": p["plan_path"], "name": os.path.splitext(os.path.basename(p["plan_path"]))[0],
                          "total": len(tasks) or cp.get("total_tasks"),
                          "done": sum(1 for t in tasks if t["status"] == "done") if tasks else cp.get("completed_tasks"),
                          "phase": cp.get("current_phase"), "halted": bool(cp.get("halted")), "halt_reason": cp.get("halt_reason"),
                          "landed": bool(cp.get("landed")), "last_activity": C.iso(last), "usd": round(usd, 4) if cost else None,
                          "open_findings": open_f, "enforced": p["enforced"], "chain_ok": p["ledger"]["ok"], "tasks": tasks})
        adhoc = []
        for a in s["adhoc"]:
            rows = a["ledger"]["rows"]
            adhoc.append({"id": a["id"], "routes": sum(1 for r in rows if r.get("event") == "route"),
                          "usd": round(sum(r["_usd"] for r in rows if r.get("event") == "worker_run" and r.get("_usd") is not None), 4),
                          "last_activity": C.iso(max([r["_t"] for r in rows if r.get("_t")] or [0]) or None)})
        halt_reason = None
        for h in s.get("halt_files") or []:
            try:
                halt_reason = (open(h, encoding="utf-8").read().strip() or "halted")[:300]
                break
            except OSError:
                continue
        out.append({"id": s["id"], "name": s["name"], "path": s["path"], "error": s.get("error"),
                    "halted": bool(s.get("halt_files")), "halt_reason": halt_reason, "lock": lk,
                    "plans": plans, "adhoc": adhoc})
    return {"repos": out}


def api_knobs(q):
    rid = q.get("repo")
    s = snapshots(rid)[0]
    if s.get("error") or not s.get("state_base"):
        raise LookupError("repo %s: %s" % (rid, s.get("error") or "no state base"))
    sl = ac_knobs.sl_get(s["state_base"])
    return {"repo": rid, "active_lock": s.get("lock"), "scope_loop": sl,
            "dispatch": ac_knobs.dispatch_get(s["top"], s["state_base"]), "decision": ac_knobs.decision_get(s["top"])}


def post_tiersim(body):
    rid = body.get("repo")
    s = snapshots(rid)[0]
    if s.get("error") or not s.get("state_base"):
        raise LookupError("repo %s: %s" % (rid, s.get("error") or "no state base"))
    out = ac_tiersim.simulate(s, body.get("patch") or {}, body.get("limit") or 30)
    out["repo"] = rid
    return out


def _sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest() if text is not None else None


def post_knobs(body, apply):
    rid = body.get("repo")
    s = snapshots(rid)[0]
    if s.get("error"):
        raise LookupError(s["error"])
    path, raw, text, changes, warnings = ac_knobs.plan(s, body.get("plugin"), body.get("patch"))
    if not apply:
        return {"ok": True, "changes": changes, "warnings": warnings}
    ac_knobs.write(path, text)
    summary = "%s: %s" % (body.get("plugin"), ", ".join("%s %s -> %s" % (c["key"], json.dumps(c["from"]), json.dumps(c["to"]))
                                                       for c in changes[:4]) + (" (+%d more)" % (len(changes) - 4) if len(changes) > 4 else ""))
    aid = C.audit_append("knobs", summary, rid, changes,
                         undo={"path": path, "text": raw, "written_sha": _sha(text), "plugin": body.get("plugin")})
    return {"ok": True, "changes": changes, "warnings": warnings, "audit_id": aid}


def post_undo(body):
    entry = next((e for e in C.audit_entries() if e["id"] == body.get("id")), None)
    if not entry:
        raise LookupError("no audit entry %s" % body.get("id"))
    if not entry.get("undoable") or not entry.get("undo"):
        raise ValueError("this change cannot be undone")
    if entry.get("undone_by"):
        raise ValueError("already undone by %s" % entry["undone_by"])
    u = entry["undo"]
    if entry["kind"] == "knobs":
        try:
            cur = open(u["path"], encoding="utf-8").read()
        except OSError:
            cur = None
        if _sha(cur) != u.get("written_sha"):
            raise ValueError("the file changed after this edit; undo it by hand or make a new change")
        ac_knobs.write(u["path"], u.get("text"))
        aid = C.audit_append("knobs", "undo %s: %s" % (entry["id"], entry["summary"]), entry.get("repo"),
                             [{"key": c["key"], "from": c["to"], "to": c["from"]} for c in entry.get("changes") or []],
                             undo={"path": u["path"], "text": cur, "written_sha": _sha(u.get("text")), "plugin": u.get("plugin")},
                             undo_of=entry["id"])
    elif entry["kind"] == "halt":
        on = u.get("on")
        set_halt(u["path"], on, u.get("reason") or "restored by undo")
        aid = C.audit_append("halt", "undo %s" % entry["id"], entry.get("repo"), [], undo_of=entry["id"],
                             undo={"path": u["path"], "on": not on, "reason": u.get("reason")})
    else:
        raise ValueError("this change cannot be undone")
    return {"ok": True, "audit_id": aid}


def set_halt(path, on, reason):
    if on:
        C.write_atomic(path, (reason or "halted from apex-console").strip()[:300] + "\n", 0o644)
    else:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def post_halt(body):
    s = snapshots(body.get("repo"))[0]
    if not s.get("state_base"):
        raise LookupError("no state base for this repo")
    path = os.path.join(s["state_base"], "HALT")
    on = bool(body.get("on"))
    reason = str(body.get("reason") or "").strip()
    if on and len(reason) < 4:
        raise ValueError("say why you are stopping the work (a few words)")
    if not on and s.get("halt_files") and path not in s["halt_files"]:
        raise ValueError("this repo is halted by %s, which the console did not write; remove it by hand"
                         % ", ".join(s["halt_files"]))
    set_halt(path, on, reason)
    aid = C.audit_append("halt", ("stop: " + reason) if on else "resume", body.get("repo"),
                         [{"key": "HALT", "from": not on, "to": on}], undo={"path": path, "on": not on, "reason": reason})
    return {"ok": True, "audit_id": aid}


def post_keys(body):
    name = str(body.get("name") or "")
    if body.get("remove"):
        ac_keys.remove_key(name)
        aid = C.audit_append("keys", "removed %s" % name, None, [{"key": name, "from": "set", "to": "unset"}])
    else:
        how = ac_keys.set_key(name, body.get("value"))
        aid = C.audit_append("keys", "%s %s" % (how, name), None, [{"key": name, "from": None, "to": "set"}])
    return {"ok": True, "audit_id": aid}


def post_keys_check(body):
    checks = []
    env = ac_keys.env_with_keys()
    root = C.sibling("apex-decision-layer")
    snaps = snapshots()
    for s in snaps or [None]:
        if root:
            argv = [os.path.join(root, "bin", "apex-decide"), "doctor", "--json"] + (["--probe"] if body.get("probe") else [])
            if s:
                argv += ["--repo", s["top"]]
            rc, out, err = C.run(argv, env=env, timeout=60)
            try:
                for c in json.loads(out).get("checks", []):
                    if c.get("name", "").endswith(("_key", "_reach", "_egress")) or c.get("name") in ("egress", "primary"):
                        checks.append({"name": "%s%s" % ((s["name"] + ": ") if s else "", c.get("name")),
                                       "status": c.get("status"), "detail": str(c.get("detail"))[:300]})
            except ValueError:
                checks.append({"name": "apex-decide doctor", "status": "fail", "detail": (err or out).strip()[:300]})
    vals = ac_keys.read()
    for p in ac_keys.CATALOG:
        checks.append({"name": p[0], "status": "ok" if p[0] in vals else "skipped",
                       "detail": "set in keys.env" if p[0] in vals else "not set"})
    return {"ok": True, "checks": checks}


def post_repos(body):
    if body.get("add"):
        rid, new = add_repo(body["add"])
        C.audit_append("repos", "%s %s" % ("added" if new else "already registered", body["add"]), rid)
    elif body.get("remove"):
        cfg = load_cfg()
        cfg["repos"] = [r for r in cfg["repos"] if r["id"] != body["remove"]]
        save_cfg(cfg)
        C.audit_append("repos", "removed %s" % body["remove"], body["remove"])
    return api_state()


def post_targets(body):
    sid = body.get("id")
    if sid not in {s[0] for s in ac_metrics.SCORECARD}:
        raise ValueError("unknown metric %s" % sid)
    t = body.get("target")
    if t is not None and not (isinstance(t, (int, float)) and not isinstance(t, bool) and t >= 0):
        raise ValueError("a target is a number >= 0, or null to clear it")
    cfg = load_cfg()
    old = cfg["targets"].get(sid, ac_metrics.DEFAULT_TARGETS.get(sid))
    if t is None:
        cfg["targets"].pop(sid, None)
    else:
        cfg["targets"][sid] = t
    save_cfg(cfg)
    C.audit_append("targets", "%s target %s -> %s" % (sid, old, t), None, [{"key": sid, "from": old, "to": t}])
    return {"ok": True}


def api_audit(q):
    try:
        limit = max(1, min(1000, int(q.get("limit", 100))))
    except ValueError:
        limit = 100
    entries = C.audit_entries()[-limit:][::-1]
    return {"entries": [{k: v for k, v in e.items() if k != "undo"} for e in entries]}


GET = {"/api/state": lambda q: api_state(), "/api/metrics": api_metrics, "/api/progress": lambda q: api_progress(),
       "/api/knobs": api_knobs, "/api/keys": lambda q: ac_keys.summary(needed_keys(snapshots())), "/api/audit": api_audit}
POST = {"/api/knobs/preview": lambda b: post_knobs(b, False), "/api/knobs": lambda b: post_knobs(b, True),
        "/api/keys": post_keys, "/api/keys/check": post_keys_check, "/api/halt": post_halt,
        "/api/audit/undo": post_undo, "/api/repos": post_repos, "/api/targets": post_targets,
        "/api/tiers/simulate": post_tiersim}
READ_ONLY_POST = {"/api/tiers/simulate", "/api/knobs/preview"}   # no write lock: they change nothing


# --- HTTP -------------------------------------------------------------------------------

class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "apex-console"
    sys_version = ""

    def log_message(self, fmt, *args):
        if os.environ.get("APEX_CONSOLE_DEBUG"):
            super().log_message(fmt, *args)

    def _send(self, code, body, ctype="application/json", extra=None):
        data = body if isinstance(body, bytes) else json.dumps(body, default=str).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", CSP)
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _err(self, code, msg, errors=None):
        self._send(code, {"ok": False, "error": msg, "errors": errors or [msg]})

    def _host_ok(self):
        port = self.server.server_address[1]
        return self.headers.get("Host", "") in ("127.0.0.1:%d" % port, "localhost:%d" % port)

    def _authed(self):
        c = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
        v = c.get("apex_console")
        return bool(v) and hmac.compare_digest(v.value, self.server.token)

    def do_GET(self):
        if not self._host_ok():
            return self._err(403, "this console answers only on 127.0.0.1")
        u = urllib.parse.urlsplit(self.path)
        q = dict(urllib.parse.parse_qsl(u.query))
        if u.path == "/" and "t" in q:
            if not hmac.compare_digest(q["t"], self.server.token):
                return self._err(403, "wrong token: use the address the console printed when it started")
            self.send_response(303)
            self.send_header("Set-Cookie", "apex_console=%s; HttpOnly; SameSite=Strict; Path=/" % self.server.token)
            self.send_header("Location", "/")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if u.path == "/favicon.ico":
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if u.path in STATIC and (self._authed() or u.path != "/" or "demo" in q):
            name, ctype = STATIC[u.path]
            try:
                with open(os.path.join(UI, name), "rb") as f:
                    return self._send(200, f.read(), ctype)
            except OSError:
                return self._err(404, "not found")
        if not self._authed():
            return self._err(401, "open the address the console printed when it started (it carries the token)")
        fn = GET.get(u.path)
        if not fn:
            return self._err(404, "not found")
        try:
            return self._send(200, fn(q))
        except LookupError as e:
            return self._err(404, str(e))
        except Exception as e:
            return self._err(500, "%s: %s" % (type(e).__name__, e))

    def do_POST(self):
        if not self._host_ok():
            return self._err(403, "this console answers only on 127.0.0.1")
        if not self._authed() or self.headers.get("X-Apex-Console") != "1":
            return self._err(401, "not authorised")
        fn = POST.get(urllib.parse.urlsplit(self.path).path)
        if not fn:
            return self._err(404, "not found")
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = -1
        if n < 0 or n > 64 * 1024:
            return self._err(413, "the request body must be JSON under 64 KiB")
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
            if not isinstance(body, dict):
                raise ValueError
        except ValueError:
            return self._err(400, "the request body must be a JSON object")
        try:
            if urllib.parse.urlsplit(self.path).path in READ_ONLY_POST:
                return self._send(200, fn(body))
            with WRITE_LOCK:
                return self._send(200, fn(body))
        except ac_knobs.KnobError as e:
            return self._err(422, "the plugin refused this change", e.errors)
        except (ValueError, LookupError) as e:
            return self._err(422, str(e))
        except Exception as e:
            return self._err(500, "%s: %s" % (type(e).__name__, e))

    do_PUT = do_DELETE = do_PATCH = lambda self: self._err(405, "method not allowed")


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def serve(port=0, token=None):
    httpd = Server(("127.0.0.1", port), Handler)
    httpd.token = token or secrets.token_urlsafe(24)
    return httpd
