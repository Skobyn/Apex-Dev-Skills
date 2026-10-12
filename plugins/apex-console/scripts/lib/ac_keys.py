"""API keys: <config-dir>/keys.env, mode 0600, one `export NAME='value'` per line.

The console writes this file and reports, per key, whether it is set, its last four
characters and who uses it. It never returns a value. The plugins read keys from
the environment only, so the file must be sourced by the shell profile Claude Code
starts from; the console says whether it is.
"""
import os
import re
import stat

import ac_common as C

NAME_RE = re.compile(r"^[A-Z][A-Z0-9_]{2,63}$")
# A key value: printable ASCII without whitespace or quotes (every provider key is).
VALUE_RE = re.compile(r"^[\x21-\x7e]{8,512}$")
LINE_RE = re.compile(r"^\s*(?:export\s+)?([A-Z][A-Z0-9_]*)=(.*)$")

# Who reads which key (apex-dispatch resources/dispatch.default.json key_env, doctor.py;
# apex-decision-layer backends/frontier.py and backends/jev.py).
CATALOG = [
    ("ANTHROPIC_API_KEY", ["apex-dispatch: claude-p worker", "apex-decision-layer: frontier backend"]),
    ("CLAUDE_CODE_OAUTH_TOKEN", ["apex-dispatch: claude-p worker (subscription login instead of an API key)"]),
    ("OPENAI_API_KEY", ["apex-dispatch: codex and openai-sdk workers"]),
    ("XAI_API_KEY", ["apex-dispatch: grok worker"]),
    ("TYPESAFE_API_KEY", ["apex-decision-layer: jev backend (typesafe transport)"]),
    ("JEV_API_KEY", ["apex-decision-layer: jev backend (typesafe transport, alternative name)"]),
    ("OPENROUTER_API_KEY", ["apex-decision-layer: jev backend (openrouter transport)"]),
]
PROFILES = ("~/.zshrc", "~/.zprofile", "~/.bashrc", "~/.bash_profile", "~/.profile", "~/.config/fish/config.fish")


def path():
    return os.path.join(C.config_dir(), "keys.env")


def _unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        v = v[1:-1]
    return v


def read():
    """{name: value} from keys.env. Values stay inside this module's callers."""
    out = {}
    try:
        with open(path(), encoding="utf-8") as f:
            for ln in f:
                m = LINE_RE.match(ln)
                if m:
                    out[m.group(1)] = _unquote(m.group(2))
    except OSError:
        pass
    return out


def _write(values):
    lines = ["# Written by apex-console. Source it from your shell profile:",
             "#   [ -f %s ] && . %s" % (path(), path()), ""]
    for k in sorted(values):
        lines.append("export %s='%s'" % (k, values[k]))
    C.write_atomic(path(), "\n".join(lines) + "\n", mode=0o600)


def _meta_path():
    return os.path.join(C.config_dir(), "keys.meta.json")


def set_key(name, value):
    if not NAME_RE.match(name or ""):
        raise ValueError("a key name is upper case letters, digits and underscores (3-64 characters)")
    if not isinstance(value, str) or not VALUE_RE.match(value):
        raise ValueError("a key value is 8-512 printable characters with no spaces or quotes")
    if "'" in value or '"' in value or "\\" in value:
        raise ValueError("a key value may not contain quotes or backslashes")
    vals = read()
    existed = name in vals
    vals[name] = value
    _write(vals)
    meta = C.read_json(_meta_path(), {}) or {}
    meta[name] = {"updated_at": C.now()}
    C.write_json(_meta_path(), meta, 0o600)
    return "replaced" if existed else "added"


def remove_key(name):
    vals = read()
    if name not in vals:
        raise ValueError("%s is not set" % name)
    del vals[name]
    _write(vals)
    meta = C.read_json(_meta_path(), {}) or {}
    meta.pop(name, None)
    C.write_json(_meta_path(), meta, 0o600)


def _profiles_sourcing():
    out = []
    p = path()
    home = os.path.expanduser("~")
    needles = {p, p.replace(home, "~", 1), p.replace(home, "$HOME", 1), "keys.env"}
    for prof in PROFILES:
        full = os.path.expanduser(prof)
        try:
            with open(full, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            continue
        if any(n in text for n in needles):
            out.append(prof)
    return out


def summary(needed=(), extra_names=()):
    """needed: key names an enabled provider or backend of a registered repo reads.
    extra_names: key names a repository's config names (api_key_env)."""
    vals = read()
    meta = C.read_json(_meta_path(), {}) or {}
    exists = os.path.exists(path())
    mode_ok = None
    if exists:
        mode_ok = stat.S_IMODE(os.stat(path()).st_mode) & 0o077 == 0
    known = [n for n, _ in CATALOG]
    names = known + [n for n in extra_names if n not in known]
    names += sorted(n for n in vals if n not in names)
    used = dict(CATALOG)
    keys = []
    for n in names:
        v = vals.get(n)
        keys.append({"name": n, "set": v is not None, "last4": v[-4:] if v and len(v) >= 12 else None,
                     "updated_at": (meta.get(n) or {}).get("updated_at"),
                     "in_console_env": bool(os.environ.get(n)),
                     "used_by": used.get(n, ["named in a repository's decision-layer config (api_key_env)"]
                                         if n in extra_names else ["custom"]),
                     "needed": n in needed})
    home = os.path.expanduser("~")
    shown = path().replace(home, "~", 1)
    return {"path": shown, "exists": exists, "mode_ok": mode_ok,
            "profile": {"sourced_in": _profiles_sourcing(), "snippet": "[ -f %s ] && . %s" % (shown, shown)},
            "keys": keys}


def env_with_keys():
    """The console's environment plus keys.env, for running the plugins' own checks."""
    env = dict(os.environ)
    env.update(read())
    return env
