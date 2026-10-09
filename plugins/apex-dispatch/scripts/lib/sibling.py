#!/usr/bin/env python3
"""Find a sibling plugin of this marketplace, the same way everywhere.

Two layouts exist:
- a checkout of the marketplace: <marketplace>/plugins/<name>/ beside this plugin
  (<plugin_root>/../<name>);
- the Claude Code plugin cache: <cache>/<marketplace>/<name>/<version>/, so the
  sibling of <cache>/<marketplace>/apex-dispatch/0.5.2 lives at
  <plugin_root>/../../<name>/<version>/, often with several versions installed.

The highest version (from each candidate's .claude-plugin/plugin.json) wins, never
the first directory a glob happens to list (which picked 0.1.0 over 0.4.2). A
minimum version, when given, drops older candidates. An environment override
(for example APEX_SCOPE_LOOP_ROOT) wins when it names a plugin directory; one that
does not is ignored, as the shell lookups always did.

CLI: sibling.py PLUGIN_ROOT NAME [--min X.Y.Z] [--env VAR] -> prints the
directory and exits 0, or prints why on stderr and exits 1.
"""
import json
import os
import re
import sys


def version_of(root):
    try:
        with open(os.path.join(root, ".claude-plugin", "plugin.json"), encoding="utf-8") as f:
            v = json.load(f).get("version", "")
    except (OSError, ValueError, AttributeError):
        return None
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", str(v).strip())
    return tuple(int(x) for x in m.groups()) if m else None


def parse_version(v):
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", str(v or "").strip())
    return tuple(int(x) for x in m.groups()) if m else None


def candidates(plugin_root, name):
    out = []
    dev = os.path.join(plugin_root, "..", name)
    if version_of(dev):
        out.append(os.path.realpath(dev))
    cache = os.path.join(plugin_root, "..", "..", name)
    if os.path.isdir(cache):
        for d in sorted(os.listdir(cache)):
            p = os.path.join(cache, d)
            if os.path.isdir(p) and version_of(p):
                out.append(os.path.realpath(p))
    seen, uniq = set(), []
    for p in out:
        if p not in seen:
            seen.add(p)
            uniq.append(p)
    return uniq


def find(plugin_root, name, minimum=None, env=None):
    """(path, reason): path is the chosen sibling or None, reason says why not."""
    if env and os.environ.get(env) and version_of(os.environ[env]):
        return os.path.realpath(os.environ[env]), None
    cands = candidates(plugin_root, name)
    if not cands:
        return None, "%s not found beside %s" % (name, os.path.realpath(plugin_root))
    floor = parse_version(minimum)
    ok = [c for c in cands if floor is None or version_of(c) >= floor]
    if not ok:
        have = ", ".join(".".join(map(str, version_of(c))) for c in cands)
        return None, "%s %s or newer is required; installed: %s" % (name, minimum, have)
    return max(ok, key=version_of), None


def main(argv):
    if len(argv) < 2:
        print("usage: sibling.py PLUGIN_ROOT NAME [--min X.Y.Z] [--env VAR]", file=sys.stderr)
        return 2
    root, name, rest = argv[0], argv[1], argv[2:]
    minimum = env = None
    while rest:
        flag = rest.pop(0)
        if flag in ("--min", "--env") and rest:
            if flag == "--min":
                minimum = rest.pop(0)
            else:
                env = rest.pop(0)
        else:
            print("sibling.py: unknown argument %s" % flag, file=sys.stderr)
            return 2
    path, why = find(root, name, minimum, env)
    if not path:
        print("sibling: " + why, file=sys.stderr)
        return 1
    print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
