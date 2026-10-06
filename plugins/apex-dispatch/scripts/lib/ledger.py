#!/usr/bin/env python3
"""apex-dispatch ledger: a hash-chained, append-only JSONL log (python3 stdlib).

The single writer of <state>/dispatch/ledger.jsonl (<state>/dispatch-shadow/ while not enforcing,
see enforcing()). route.py imports it
(`import ledger; ledger.append(...)`); hooks, shims and the CLI go through
scripts/ledger.sh, which runs this file.

Row format. Every row is one JSON object on one line. The caller's fields are
validated against resources/ledger-events.json, then these are stamped:

  seq            0-based position in the chain
  event          the event name
  ts             UTC, second resolution
  source         hook | shim | cli (who appended it)
  route_id       explicit, else the row's own field, else active-route.json's
  head_sha       explicit, else the row's own field, else HEAD of the state's
                 worktree (checkpoint.json worktree_path) or the cwd repository
  route_mode     explicit, else the row's own field, else active-route.json's
  doctor_profile <state>/dispatch/doctor.json "profile", or null
  prev_hash      the previous row's hash ("0" * 64 for seq 0)
  hash           sha256 over the canonical JSON of the row without "hash"
                 (sort_keys, separators (",", ":"), ensure_ascii)

Appends hold an exclusive flock on <state>/dispatch/ledger.lock, write the line
with one O_APPEND write + fsync, then replace <state>/dispatch/ledger.head
({"seq", "hash"}) atomically. The head file is what detects a truncated tail:
the chain alone cannot tell "the last rows were deleted" from "there were no
more rows".

  ledger.py ROOT append EVENT JSON|- --state DIR --source S [--route-id R] [--head SHA] [--route-mode M]
  ledger.py ROOT verify --state DIR
  ledger.py ROOT evidence --state DIR --line N --head SHA
  ledger.py ROOT export-trace --state DIR [--out F]
  ledger.py ROOT export --state DIR [--plan PLAN] [--out F]
  ledger.py ROOT baseline capture --state DIR [--label L]
"""
import sys

sys.dont_write_bytecode = True

import datetime  # noqa: E402
import fcntl  # noqa: E402
import hashlib  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import subprocess  # noqa: E402

GENESIS = "0" * 64
LEDGER = "ledger.jsonl"
HEAD = "ledger.head"
LOCK = "ledger.lock"
SHA_RE = re.compile(r"^[0-9a-f]{40}$|^[0-9a-f]{64}$")
SPAWN_EVENTS = ("spawn_request", "spawn", "worker_run")
_SCHEMA = {}


class LedgerError(Exception):
    pass


def plugin_root():
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def schema(root=None):
    root = root or plugin_root()
    if root not in _SCHEMA:
        with open(os.path.join(root, "resources", "ledger-events.json"), encoding="utf-8") as f:
            _SCHEMA[root] = json.load(f)
    return _SCHEMA[root]


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def row_hash(row):
    body = {k: v for k, v in row.items() if k != "hash"}
    return hashlib.sha256(canonical(body).encode("utf-8")).hexdigest()


def enforcing(root=None):
    """Whether apex-dispatch may create <state>/dispatch/ (the directory whose
    presence puts apex-scope-loop's checkpoint.sh into provenance mode). True
    with APEX_DISPATCH_ENFORCE=1, or once the plugin ships hooks/subagent-stop.sh
    (the hook that writes the reviews-raw records provenance mode needs).
    Until then routing records into <state>/dispatch-shadow/ so it cannot wedge
    checkpoint.sh review (transitional; see README "Enforcement switch")."""
    if os.environ.get("APEX_DISPATCH_ENFORCE", "") == "1":
        return True
    return os.path.isfile(os.path.join(root or plugin_root(), "hooks", "subagent-stop.sh"))


def dispatch_dir(state_dir, write=False, root=None):
    """<state>/dispatch/ when it exists (an enforcing run started it; keep one
    chain) or when writing while enforcing; otherwise <state>/dispatch-shadow/."""
    d = os.path.join(state_dir, "dispatch")
    if os.path.isdir(d) or (write and enforcing(root)):
        return d
    return os.path.join(state_dir, "dispatch-shadow")


def ledger_path(state_dir):
    return os.path.join(dispatch_dir(state_dir), LEDGER)


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


# ---------------------------------------------------------------- validate ----

_TYPES = {"string": str, "integer": int, "number": (int, float), "boolean": bool, "object": dict, "array": list}


def _type_ok(value, spec):
    nullable = spec.endswith("|null")
    base = spec[:-5] if nullable else spec
    if value is None:
        return nullable
    if base in ("integer", "number") and isinstance(value, bool):
        return False
    return isinstance(value, _TYPES[base])


def validate(event, data, source, root=None):
    sch = schema(root)
    ev = sch["events"].get(event)
    if ev is None:
        raise LedgerError("unknown event %r (known: %s)" % (event, ", ".join(sorted(sch["events"]))))
    if source not in sch["sources"]:
        raise LedgerError("source must be one of %s (got %r)" % ("|".join(sch["sources"]), source))
    if not isinstance(data, dict):
        raise LedgerError("event data must be a JSON object")
    problems = []
    for field, spec in ev.get("required", {}).items():
        if field not in data:
            problems.append("%s: missing required field %s" % (event, field))
        elif not _type_ok(data[field], spec):
            problems.append("%s.%s: expected %s" % (event, field, spec))
    for field, allowed in ev.get("enums", {}).items():
        if field in data and data[field] not in allowed:
            problems.append("%s.%s: %r is not one of %s" % (event, field, data[field], "|".join(allowed)))
    rm = data.get("route_mode")
    if rm is not None and rm not in sch["route_modes"]:
        problems.append("%s.route_mode: %r is not one of %s" % (event, rm, "|".join(sch["route_modes"])))
    for k in ("seq", "prev_hash", "hash"):
        if k in data:
            problems.append("%s: %s is stamped by the ledger and may not be supplied" % (event, k))
    if problems:
        raise LedgerError("; ".join(problems))


# ------------------------------------------------------------------ stamps ----

def _git_head(repo):
    if not repo or not os.path.isdir(repo):
        return None
    try:
        out = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True, text=True, timeout=5)
    except Exception:
        return None
    sha = out.stdout.strip()
    return sha if out.returncode == 0 and SHA_RE.match(sha) else None


def state_repo(state_dir):
    """The repository a state dir's work happens in: the checkpoint's worktree, else the cwd."""
    cp = read_json(os.path.join(state_dir, "checkpoint.json"), {}) or {}
    wt = cp.get("worktree_path")
    if isinstance(wt, str) and os.path.isdir(wt):
        return wt
    return os.getcwd()


def _iter_lines(path):
    with open(path, "rb") as f:
        for raw in f:
            yield raw


def _last_row(path):
    """The last row of the ledger (read from the tail), or None when empty."""
    try:
        size = os.path.getsize(path)
    except FileNotFoundError:
        return None
    if size == 0:
        return None
    with open(path, "rb") as f:
        block, data = 4096, b""
        pos = size
        while pos > 0:
            step = min(block, pos)
            pos -= step
            f.seek(pos)
            data = f.read(step) + data
            if data.rstrip(b"\n").count(b"\n") >= 1:
                break
    lines = [ln for ln in data.split(b"\n") if ln.strip()]
    if not lines:
        return None
    if not data.endswith(b"\n"):
        raise LedgerError("the ledger's last line is incomplete (torn write); run ledger.sh verify")
    try:
        return json.loads(lines[-1].decode("utf-8"))
    except ValueError:
        raise LedgerError("the ledger's last row is not JSON; run ledger.sh verify")


def append(state_dir, event, data, source, route_id=None, head_sha=None, route_mode=None, root=None):
    """Validate, stamp and append one row; return the stamped row."""
    data = dict(data or {})
    data.pop("event", None)
    data.pop("ts", None)
    data.pop("source", None)
    data.pop("doctor_profile", None)
    if route_id is not None:
        data["route_id"] = route_id
    if route_mode is not None:
        data["route_mode"] = route_mode
    if head_sha is not None:
        data["head_sha"] = head_sha
    ddir = dispatch_dir(state_dir, write=True, root=root)
    active = read_json(os.path.join(ddir, "active-route.json"), {}) or {}
    data.setdefault("route_id", active.get("route_id"))
    data.setdefault("route_mode", active.get("route_mode"))
    validate(event, data, source, root)
    if data.get("head_sha") is None:
        data["head_sha"] = _git_head(state_repo(state_dir))
    elif not (isinstance(data["head_sha"], str) and SHA_RE.match(data["head_sha"])):
        raise LedgerError("head_sha must be a full hex SHA (got %r)" % data["head_sha"])
    doc = read_json(os.path.join(ddir, "doctor.json"), {}) or {}
    os.makedirs(ddir, exist_ok=True)
    lock_fd = os.open(os.path.join(ddir, LOCK), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        path = os.path.join(ddir, LEDGER)
        last = _last_row(path)
        if last is not None:
            if row_hash(last) != last.get("hash"):
                raise LedgerError("the ledger's last row does not hash to its recorded hash; run ledger.sh verify")
            seq, prev = int(last.get("seq", -1)) + 1, last["hash"]
        else:
            head = read_json(os.path.join(ddir, HEAD))
            if head:
                raise LedgerError("the ledger is empty but %s records seq %s: it was truncated" % (HEAD, head.get("seq")))
            seq, prev = 0, GENESIS
        row = dict(data)
        row.update({"seq": seq, "event": event, "ts": now(), "source": source,
                    "doctor_profile": doc.get("profile"), "prev_hash": prev})
        row["hash"] = row_hash(row)
        line = (canonical(row) + "\n").encode("utf-8")
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, line)
            os.fsync(fd)
        finally:
            os.close(fd)
        tmp = os.path.join(ddir, "%s.tmp.%d" % (HEAD, os.getpid()))
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"seq": seq, "hash": row["hash"]}, f)
            f.write("\n")
        os.replace(tmp, os.path.join(ddir, HEAD))
        return row
    finally:
        os.close(lock_fd)


# ------------------------------------------------------------------ verify ----

def read_rows(state_dir, write=False):
    """All parseable rows in file order (no verification). write=True reads the
    directory the next append will write (route.py numbers route ids from it)."""
    rows = []
    path = os.path.join(dispatch_dir(state_dir, write=write), LEDGER)
    if not os.path.exists(path):
        return rows
    for raw in _iter_lines(path):
        raw = raw.strip()
        if not raw:
            continue
        try:
            rows.append(json.loads(raw.decode("utf-8")))
        except ValueError:
            pass
    return rows


def verify(state_dir):
    """Walk the chain. Return (ok, rows, message); message names the first bad row
    (1-based file row) and what is wrong: tampered, reordered, deleted, truncated."""
    path = ledger_path(state_dir)
    head = read_json(os.path.join(dispatch_dir(state_dir), HEAD))
    if not os.path.exists(path):
        if head:
            return False, [], "truncated: %s records seq %s but %s is missing" % (HEAD, head.get("seq"), LEDGER)
        return True, [], "empty ledger (0 rows)"
    rows, prev = [], GENESIS
    with open(path, "rb") as f:
        data = f.read()
    if data and not data.endswith(b"\n"):
        return False, rows, "row %d: incomplete last line (torn write or truncated mid-row)" % (data.count(b"\n") + 1)
    parsed = []
    for n, raw in enumerate([ln for ln in data.split(b"\n") if ln != b""], 1):
        try:
            row = json.loads(raw.decode("utf-8"))
        except ValueError:
            return False, rows, "row %d: not JSON (tampered)" % n
        if not isinstance(row, dict):
            return False, rows, "row %d: not a JSON object (tampered)" % n
        parsed.append(row)
    later = [r.get("seq") for r in parsed]
    for n, row in enumerate(parsed, 1):
        seq = row.get("seq")
        if row_hash(row) != row.get("hash"):
            return False, rows, "row %d (seq %s): tampered — content does not hash to its recorded hash" % (n, seq)
        if seq != n - 1:
            if (n - 1) in later[n:]:
                return False, rows, "row %d: reordered — seq %s at position %d (seq %d comes later)" % (n, seq, n - 1, n - 1)
            if isinstance(seq, int) and seq > n - 1:
                return False, rows, ("row %d: deleted — seq jumps to %s where %d was expected (seq %d..%d missing)"
                                     % (n, seq, n - 1, n - 1, seq - 1))
            return False, rows, "row %d: reordered or duplicated — seq %s at position %d" % (n, seq, n - 1)
        if row.get("prev_hash") != prev:
            return False, rows, ("row %d (seq %s): tampered — prev_hash does not match row %d's hash "
                                 "(an earlier row was rewritten and rehashed)" % (n, seq, n - 1))
        prev = row["hash"]
        rows.append(row)
    if head is not None:
        hs = head.get("seq")
        if not rows:
            return False, rows, "truncated: %s records seq %s but the ledger has no rows" % (HEAD, hs)
        if isinstance(hs, int) and hs > rows[-1]["seq"]:
            return False, rows, ("truncated: %s records seq %s, the chain ends at seq %s (rows %d..%d deleted)"
                                 % (HEAD, hs, rows[-1]["seq"], rows[-1]["seq"] + 1, hs))
        if hs == rows[-1]["seq"] and head.get("hash") != rows[-1]["hash"]:
            return False, rows, "row %d (seq %s): its hash does not match %s (last row rewritten)" % (len(rows), hs, HEAD)
        if isinstance(hs, int) and hs < rows[-1]["seq"]:
            return False, rows, "%s records seq %s but the chain continues to seq %s (rows appended outside ledger.sh)" % (
                HEAD, hs, rows[-1]["seq"])
    return True, rows, "%d rows, chain intact" % len(rows)


# ---------------------------------------------------------------- evidence ----

def _route_line(row):
    if isinstance(row.get("line"), int):
        return row["line"]
    m = re.match(r"^r-[0-9a-f]{12}-L([0-9]+)-[0-9]+$", str(row.get("route_id") or ""))
    return int(m.group(1)) if m else None


def _is_ancestor(repo, ancestor, head):
    try:
        r = subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", ancestor, head],
                           capture_output=True, timeout=10)
    except Exception:
        return None
    if r.returncode == 0:
        return True
    if r.returncode == 1:
        return False
    return None


def evidence(state_dir, line, head):
    """Ledger evidence that plan line LINE was done through a routed delegation
    (spec §5.3 G). Exit-0 conditions, all required:
      1. the chain verifies;
      2. a `route` row with status READY names the line (its `line` field, or the
         L<line> part of an r-<plan-hash>-L<line>-<n> route id);
      3. that route's recorded head_sha is HEAD or an ancestor of HEAD (the route
         was computed on this history, not on a discarded fork); a route row
         without a head_sha is accepted on condition 4 alone;
      4. at least one spawn_request, spawn or worker_run row carries that
         route's route_id (the work was delegated, not done inline).
    Returns (ok, message)."""
    ok, rows, msg = verify(state_dir)
    if not ok:
        return False, "chain does not verify: " + msg
    routes = [r for r in rows if r.get("event") == "route" and r.get("status") == "READY" and _route_line(r) == line]
    if not routes:
        return False, "no READY route row for plan line %d" % line
    repo = state_repo(state_dir)
    on_history, notes = [], []
    for r in routes:
        rh = r.get("head_sha")
        if not rh or rh == head:
            on_history.append(r)
            continue
        anc = _is_ancestor(repo, rh, head)
        if anc:
            on_history.append(r)
        else:
            notes.append("%s was routed at %s, %s" % (r.get("route_id"), rh[:12],
                                                      "not an ancestor of HEAD" if anc is False else "not resolvable in " + repo))
    if not on_history:
        return False, "no route row for line %d is on HEAD's history (%s)" % (line, "; ".join(notes))
    ids = {r.get("route_id") for r in on_history}
    spawns = [r for r in rows if r.get("event") in SPAWN_EVENTS and r.get("route_id") in ids]
    if not spawns:
        return False, ("route(s) %s for line %d have no spawn_request/spawn/worker_run row (work done inline?)"
                       % (",".join(sorted(i for i in ids if i)), line))
    used = sorted({r.get("route_id") for r in spawns})
    return True, "line %d: route %s, %d spawn/worker row(s), chain intact (%d rows)" % (line, ",".join(used), len(spawns), len(rows))


# ------------------------------------------------------------------ export ----

def _usage_tokens(row):
    u = row.get("usage")
    if not isinstance(u, dict):
        return 0
    return sum(int(u.get(k) or 0) for k in ("input", "output", "cache_read", "cache_write")
               if isinstance(u.get(k), (int, float)))


def trace_lines(state_dir, rows):
    """apex-agent-observability's trace line shape: ts, event, session,
    subagent_id, parent_id, tool, token_estimate, edge (exactly these keys)."""
    session = "dispatch-" + os.path.basename(os.path.normpath(state_dir))
    out = []
    for r in rows:
        ev = r.get("event")
        rid = r.get("route_id")
        sub, parent, tool, edge = None, rid, None, None
        if ev == "spawn_request":
            name, tool = "PreToolUse", "Agent"
        elif ev == "spawn":
            name, sub = "SubagentStart", r.get("agent_id")
            edge = "%s->%s" % (rid or "root", sub)
        elif ev == "worker_run":
            name, sub, tool = "SubagentStop", r.get("worker_id") or r.get("provider"), r.get("provider")
        elif ev == "verdict":
            name, sub = "SubagentStop", r.get("agent_id") or r.get("role")
        else:
            name = "Dispatch:" + str(ev)
        tok = _usage_tokens(r)
        out.append({"ts": r.get("ts"), "event": name, "session": session, "subagent_id": sub,
                    "parent_id": parent, "tool": tool, "token_estimate": tok, "edge": edge})
    return out


def _write_lines(out_path, objs):
    text = "".join(json.dumps(o, separators=(",", ":")) + "\n" for o in objs)
    if not out_path or out_path == "-":
        sys.stdout.write(text)
        return
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    tmp = "%s.tmp.%d" % (out_path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, out_path)


def summary_rows(rows):
    """One row per routed task (plan line or ad-hoc id): the per-task summary that
    `export` writes (route, spawns, verdicts, escalations, usage)."""
    tasks = {}
    route_task = {}
    for r in rows:
        if r.get("event") == "route":
            key = ("line", _route_line(r)) if _route_line(r) is not None else ("route", r.get("route_id"))
            t = tasks.setdefault(key, {"task": key[1], "routes": [], "spawns": 0, "verdicts": [], "escalations": 0,
                                       "tokens": 0, "class": None, "tier": None, "provider": None, "route_mode": None})
            router = r.get("router") or {}
            t["routes"].append(r.get("route_id"))
            t.update({"class": router.get("class"), "tier": router.get("tier"), "provider": router.get("provider"),
                      "route_mode": r.get("route_mode")})
            route_task[r.get("route_id")] = key
    for r in rows:
        key = route_task.get(r.get("route_id")) or route_task.get(r.get("prior_route_id"))
        if key is None:
            continue
        t = tasks[key]
        ev = r.get("event")
        if ev in SPAWN_EVENTS:
            t["spawns"] += 1
            t["tokens"] += _usage_tokens(r)
        elif ev == "verdict":
            t["verdicts"].append(r.get("verdict"))
        elif ev == "escalate":
            t["escalations"] += 1
    return [dict(v, kind="task_summary") for v in tasks.values()]


def baseline_capture(state_dir, label, root):
    pj = read_json(os.path.join(root, ".claude-plugin", "plugin.json"), {}) or {}
    sl = read_json(os.path.join(root, "..", "apex-scope-loop", ".claude-plugin", "plugin.json"), {}) or {}
    ver = {}
    try:
        with open(os.path.join(root, "resources", "compiled", "VERSION"), encoding="utf-8") as f:
            for ln in f:
                if "=" in ln:
                    k, v = ln.strip().split("=", 1)
                    ver[k] = v
    except OSError:
        pass
    data = {"label": label, "apex_dispatch_version": pj.get("version"), "apex_scope_loop_version": sl.get("version"),
            "policy_inputs_sha256": ver.get("inputs_sha256"),
            "dispatch_mode_env": os.environ.get("APEX_DISPATCH_MODE") or None}
    return append(state_dir, "baseline", data, "cli", route_mode="baseline", root=root)


# --------------------------------------------------------------------- CLI ----

def _opts(argv, valued, flags=()):
    out, pos, i = {}, [], 0
    while i < len(argv):
        a = argv[i]
        if a in valued:
            if i + 1 >= len(argv):
                raise SystemExit(_usage("%s needs a value" % a))
            out[a.lstrip("-").replace("-", "_")] = argv[i + 1]
            i += 2
            continue
        if a in flags:
            out[a.lstrip("-").replace("-", "_")] = True
        elif a.startswith("--"):
            raise SystemExit(_usage("unknown option %s" % a))
        else:
            pos.append(a)
        i += 1
    return out, pos


def _usage(msg):
    print("ledger: " + msg, file=sys.stderr)
    return 2


def main(argv):
    if len(argv) < 2:
        return _usage("usage: ledger.sh (append|verify|evidence|export-trace|export|baseline) ... --state DIR")
    root, cmd, rest = os.path.abspath(argv[0]), argv[1], argv[2:]
    try:
        if cmd == "append":
            o, pos = _opts(rest, {"--state", "--source", "--route-id", "--head", "--route-mode"})
            if len(pos) != 2 or not o.get("state") or not o.get("source"):
                return _usage("usage: ledger.sh append EVENT JSON|- --state DIR --source hook|shim|cli "
                              "[--route-id R] [--head SHA] [--route-mode M]")
            raw = sys.stdin.read() if pos[1] == "-" else pos[1]
            try:
                data = json.loads(raw)
            except ValueError as e:
                print("ledger: event data is not JSON: %s" % e, file=sys.stderr)
                return 1
            row = append(o["state"], pos[0], data, o["source"], o.get("route_id"), o.get("head"),
                         o.get("route_mode"), root)
            print("LEDGER_ROW: %d %s" % (row["seq"], row["hash"]))
            return 0
        if cmd == "verify":
            o, pos = _opts(rest, {"--state"})
            if pos or not o.get("state"):
                return _usage("usage: ledger.sh verify --state DIR")
            ok, rows, msg = verify(o["state"])
            if ok:
                print("ledger verify: OK — %s" % msg)
                return 0
            print("ledger verify: FAIL — %s (%s)" % (msg, ledger_path(o["state"])), file=sys.stderr)
            return 1
        if cmd == "evidence":
            o, pos = _opts(rest, {"--state", "--line", "--head"})
            if pos or not o.get("state") or not o.get("line") or not o.get("head"):
                return _usage("usage: ledger.sh evidence --state DIR --line N --head SHA")
            if not re.fullmatch(r"[1-9][0-9]{0,8}", o["line"]):
                return _usage("--line must be a plan line number")
            if not SHA_RE.match(o["head"]):
                return _usage("--head must be a full hex SHA")
            ok, msg = evidence(o["state"], int(o["line"]), o["head"])
            if ok:
                print("ledger evidence: OK — %s" % msg)
                return 0
            print("ledger evidence: MISSING — %s" % msg, file=sys.stderr)
            return 1
        if cmd in ("export-trace", "export"):
            o, pos = _opts(rest, {"--state", "--out", "--plan"})
            if pos or not o.get("state"):
                return _usage("usage: ledger.sh %s --state DIR [--out F]%s" % (cmd, " [--plan PLAN]" if cmd == "export" else ""))
            ok, rows, msg = verify(o["state"])
            if not ok:
                print("ledger %s: refusing, the chain does not verify: %s" % (cmd, msg), file=sys.stderr)
                return 1
            if cmd == "export-trace":
                _write_lines(o.get("out"), trace_lines(o["state"], rows))
            else:
                out = o.get("out") or os.path.join(dispatch_dir(o["state"]), "export", "summary.jsonl")
                summ = summary_rows(rows)
                head = {"kind": "ledger_head", "rows": len(rows), "hash": rows[-1]["hash"] if rows else GENESIS,
                        "plan": os.path.abspath(o["plan"]) if o.get("plan") else None, "exported_at": now()}
                _write_lines(out, [head] + summ)
                if out != "-":
                    print("LEDGER_EXPORT: %s (%d task rows)" % (out, len(summ)))
            return 0
        if cmd == "baseline":
            o, pos = _opts(rest, {"--state", "--label"})
            if pos != ["capture"] or not o.get("state"):
                return _usage("usage: ledger.sh baseline capture --state DIR [--label L]")
            row = baseline_capture(o["state"], o.get("label") or "baseline@0.3.0", root)
            print("LEDGER_ROW: %d %s" % (row["seq"], row["hash"]))
            return 0
    except LedgerError as e:
        print("ledger: %s" % e, file=sys.stderr)
        return 1
    return _usage("unknown subcommand %s" % cmd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
