"""apex-console shared helpers: where things live, atomic writes, the audit log.

Nothing here talks to the network. The console's own files live in the config dir
(APEX_CONFIG_DIR, default ~/.config/apex): console.json (registered repos, metric
targets), console-audit.jsonl (every change the console made) and keys.env (the
API keys, mode 0600, which the console writes and never echoes back).
"""
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile

PLUGIN_ROOT = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
VERSION_RE = re.compile(r"(\d+)\.(\d+)\.(\d+)")


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_ts(s):
    """Epoch seconds from an ISO-8601 UTC string, or None."""
    if not isinstance(s, str):
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            d = datetime.datetime.strptime(s, fmt)
            if d.tzinfo is None:
                d = d.replace(tzinfo=datetime.timezone.utc)
            return d.timestamp()
        except ValueError:
            continue
    return None


def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if ts else None


def config_dir():
    d = os.environ.get("APEX_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".config", "apex")
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def read_jsonl(path, limit_bytes=64 * 1024 * 1024):
    out = []
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if size > limit_bytes:
                f.seek(size - limit_bytes)
                f.readline()
            for ln in f:
                try:
                    obj = json.loads(ln)
                except ValueError:
                    continue
                if isinstance(obj, dict):
                    out.append(obj)
    except OSError:
        pass
    return out


def write_atomic(path, text, mode=0o644):
    """Write text to path through a temp file in the same directory, then rename."""
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def write_json(path, obj, mode=0o644):
    write_atomic(path, json.dumps(obj, indent=2, sort_keys=True) + "\n", mode)


# --- sibling plugins -----------------------------------------------------------
# The same rule as apex-dispatch's scripts/lib/sibling.py: a marketplace checkout
# keeps siblings at <root>/../<name>; the plugin cache keeps
# <cache>/<marketplace>/<name>/<version>/. The highest plugin.json version wins.

def plugin_version(root):
    v = (read_json(os.path.join(root, ".claude-plugin", "plugin.json"), {}) or {}).get("version", "")
    m = VERSION_RE.fullmatch(str(v).strip())
    return tuple(int(x) for x in m.groups()) if m else None


ENV_ROOTS = {"apex-scope-loop": "APEX_SCOPE_LOOP_ROOT", "apex-dispatch": "APEX_DISPATCH_ROOT",
             "apex-decision-layer": "APEX_DECISION_LAYER_ROOT"}


def sibling(name):
    env = os.environ.get(ENV_ROOTS.get(name, ""), "")
    if env and plugin_version(env):
        return os.path.realpath(env)
    cands = []
    dev = os.path.join(PLUGIN_ROOT, "..", name)
    if plugin_version(dev):
        cands.append(os.path.realpath(dev))
    cache = os.path.join(PLUGIN_ROOT, "..", "..", name)
    if os.path.isdir(cache):
        for d in os.listdir(cache):
            p = os.path.join(cache, d)
            if os.path.isdir(p) and plugin_version(p):
                cands.append(os.path.realpath(p))
    return max(cands, key=plugin_version) if cands else None


def version_str(root):
    v = plugin_version(root) if root else None
    return ".".join(map(str, v)) if v else None


def run(argv, cwd=None, env=None, timeout=60, stdin=None):
    """(returncode, stdout, stderr); never raises for a failed command."""
    try:
        p = subprocess.run(argv, cwd=cwd, env=env, input=stdin, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, "", str(e)


def import_from(root, *mods):
    """Import modules from a plugin's lib dir (root/scripts/lib). The dir stays on
    sys.path (appended, so the console's own ac_* modules always win) because those
    modules import their siblings lazily."""
    lib = os.path.join(root, "scripts", "lib") if root else None
    if not lib or not os.path.isdir(lib):
        return None
    if lib not in sys.path:
        sys.path.append(lib)
    try:
        return [__import__(m) for m in mods]
    except Exception:
        return None


# --- audit log -------------------------------------------------------------------

def audit_path():
    return os.path.join(config_dir(), "console-audit.jsonl")


def audit_append(kind, summary, repo=None, changes=None, undo=None, undo_of=None):
    """Record one change. `undo` is a server-side recipe (never sent to the page)."""
    path = audit_path()
    seq = sum(1 for _ in open(path, encoding="utf-8")) + 1 if os.path.exists(path) else 1
    entry = {"id": "a-%s-%04d" % (datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d"), seq),
             "at": now(), "repo": repo, "kind": kind, "summary": summary, "changes": changes or [],
             "undoable": undo is not None, "undo": undo, "undo_of": undo_of}
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, sort_keys=True) + "\n")
    return entry["id"]


def audit_entries():
    entries = read_jsonl(audit_path())
    undone = {e.get("undo_of"): e["id"] for e in entries if e.get("undo_of")}
    for e in entries:
        e["undone_by"] = undone.get(e["id"])
    return entries
