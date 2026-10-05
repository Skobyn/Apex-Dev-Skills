#!/usr/bin/env python3
"""planlib.py — the one parser for apex-scope-loop plan files (ADR-0003).

Used by iterate.sh (task selection), promote-to-loop.sh (validation) and
apex-dispatch's route.sh (task features), so the three never disagree about
what a task, a tag, a directive or a Blocked-by reference means.

Usage:
  planlib.py next PLAN            JSON: the next unchecked, unblocked task, lanes, blocked tasks
  planlib.py task PLAN LINE_NO    JSON: one task by its 1-based line number
  planlib.py validate PLAN        prints one error per line; exit 1 if any

Task line:      - [ ] **Phase 2.1** [backend][api] Title
Directives:     indented "- Key: value" lines (up to LOOKAHEAD lines, stopping
                at a blank line or the next checkbox):
                Acceptance, Blocked-by, Swarm, Route, Paths, Budget
Blocked-by:     comma-separated; phase-2.1 | Phase 2.1 | **Phase 2.1** |
                gate-2-3 | Gate 2→3 | Gate 2-3
Route:          class=… provider=… fanout=… review=…   (may only tighten)
Paths:          comma-separated globs (required when fanout=lanes)
Budget:         usd=<n> spawns=<n> minutes=<n>          (may only lower)
"""
import json
import posixpath
import re
import sys

LOOKAHEAD = 8
TASK_RE = re.compile(r"^- \[( |x|X)\] (.*)$")
ID_RE = re.compile(r"\*\*\s*(Phase\s+[0-9]+(?:\.[0-9]+)*|Gate\s+[^*\s—:]+(?:\s*(?:→|->)\s*[^*\s—:]+)?)")
TAG_RE = re.compile(r"\[([a-z0-9:@._+-]+)\](?!\()")  # not markdown link text
FENCE_RE = re.compile(r"^\s*(```|~~~)")
DIRECTIVE_RE = re.compile(r"^\s*(?:-\s*)?(Acceptance|Blocked-by|Swarm|Route|Paths|Budget):\s*(.*?)\s*$")

ROUTE_VALUES = {
    "class": {"auto", "docs", "tests", "mechanical", "feature", "bugfix", "migration", "security"},
    "provider": {"auto", "claude", "claude-p", "codex", "grok", "local"},
    "fanout": {"single", "lanes"},
    "review": {"auto", "solo", "six-lens", "fanout"},
}
BUDGET_KEYS = {"usd", "spawns", "minutes"}


def norm_ref(text):
    """Normalise a task id or Blocked-by reference to ('phase'|'gate', key)."""
    t = text.strip().strip("*").strip().lower()
    t = t.replace("→", "-").replace("->", "-")
    m = re.match(r"^(phase|gate)[\s-]+(.+)$", t)
    if not m:
        return None
    kind, key = m.group(1), m.group(2).strip()
    key = re.sub(r"\s+", "", key)
    if kind == "gate":
        key = key.replace(".", "-")
    return (kind, key)


def read_lines(path):
    """Split exactly as sed and grep -n count lines (\n only; a trailing \r is dropped)."""
    data = open(path, encoding="utf-8", newline="").read()
    return [l[:-1] if l.endswith("\r") else l for l in data.split("\n")]


def parse(path):
    lines = read_lines(path)
    in_fence = [False] * len(lines)
    fenced = False
    for i, line in enumerate(lines):
        if FENCE_RE.match(line):
            in_fence[i] = True
            fenced = not fenced
            continue
        in_fence[i] = fenced
    tasks = []
    for i, line in enumerate(lines):
        if in_fence[i]:
            continue                     # examples inside code fences are never tasks
        m = TASK_RE.match(line)
        if not m:
            continue
        body = m.group(2)
        idm = ID_RE.search(body)
        tid = re.sub(r"\s+", " ", idm.group(1).strip()) if idm else None
        tags = [t for t in TAG_RE.findall(body) if t not in ("x", " ")]
        d = {"acceptance": "", "blocked_by_raw": [], "swarm": "", "route_raw": "", "paths_raw": "", "budget_raw": ""}
        key_map = {"Acceptance": "acceptance", "Blocked-by": "blocked_by_raw", "Swarm": "swarm",
                   "Route": "route_raw", "Paths": "paths_raw", "Budget": "budget_raw"}
        repeated, late = [], []
        # A task's block runs to the next blank line, checkbox or fence. Every
        # directive in it counts (Blocked-by lines merge: fail closed); one
        # beyond LOOKAHEAD lines or repeated is a validation error.
        j = i + 1
        while j < len(lines) and lines[j].strip() and not TASK_RE.match(lines[j]) and not FENCE_RE.match(lines[j]):
            dm = DIRECTIVE_RE.match(lines[j])
            if dm:
                key = key_map[dm.group(1)]
                if j - i > LOOKAHEAD:
                    late.append(f"{dm.group(1)} at line {j + 1}")
                if key == "blocked_by_raw":
                    d[key].append(dm.group(2))
                else:
                    if d[key]:
                        repeated.append(dm.group(1))
                    d[key] = dm.group(2)
            j += 1
        acc = d["acceptance"]
        if len(acc) >= 2 and acc.startswith("`") and acc.endswith("`") and acc.count("`") == 2:
            acc = acc[1:-1]
        tasks.append({
            "line_no": i + 1,
            "checked": m.group(1) != " ",
            "line": line,
            "id": tid,
            "ref": norm_ref(tid) if tid else None,
            "tags": tags,
            "acceptance": acc,
            "blocked_by": [r.strip() for raw in d["blocked_by_raw"] for r in raw.split(",") if r.strip()],
            "swarm": d["swarm"],
            "route_raw": d["route_raw"],
            "route": parse_kv(d["route_raw"]),
            "paths": [p.strip() for p in d["paths_raw"].split(",") if p.strip()],
            "budget_raw": d["budget_raw"],
            "budget": parse_kv(d["budget_raw"]),
            "_repeated": repeated,
            "_late": late,
        })
    return tasks


def parse_kv(text):
    out = {}
    for tok in text.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            out[k.strip()] = v.strip()
        else:
            out.setdefault("_invalid", []).append(tok)
    return out


def index(tasks):
    by_ref = {}
    for t in tasks:
        if t["ref"]:
            by_ref.setdefault(t["ref"], []).append(t)
    return by_ref


def blockers(task, by_ref):
    """Return (open blocker ids, unknown refs). A duplicated id blocks until
    every task carrying it is checked (fail closed)."""
    open_refs, unknown = [], []
    for raw in task["blocked_by"]:
        ref = norm_ref(raw)
        deps = by_ref.get(ref) if ref else None
        if not deps:
            unknown.append(raw)
        elif not all(dep["checked"] for dep in deps):
            open_refs.append(deps[0]["id"])
    return open_refs, unknown


def glob_prefix(g):
    """Literal directory-safe prefix of a repo-relative glob, or None when the
    glob cannot be bounded (absolute, escapes with .., or starts with a wildcard)."""
    g = g.strip()
    if not g or g.startswith("/") or "\\" in g:
        return None
    norm = posixpath.normpath(g)
    if norm == ".." or norm.startswith("../") or "/../" in f"/{norm}/":
        return None
    m = re.search(r"[*?\[{]", norm)
    prefix = norm[: m.start()] if m else norm
    return prefix.lower()   # case-insensitive filesystems: compare case-folded


def disjoint(paths_a, paths_b):
    for a in paths_a:
        for b in paths_b:
            pa, pb = glob_prefix(a), glob_prefix(b)
            if pa is None or pb is None or pa == "" or pb == "":
                return False
            if pa.startswith(pb) or pb.startswith(pa):
                return False
    return True


def public(t):
    return {k: v for k, v in t.items() if k not in ("ref", "_repeated", "_late")}


def cmd_next(path, max_lanes):
    tasks = parse(path)
    by_ref = index(tasks)
    blocked, ready = [], []
    for t in tasks:
        if t["checked"]:
            continue
        open_refs, unknown = blockers(t, by_ref)
        if open_refs or unknown:
            blocked.append({"line_no": t["line_no"], "id": t["id"], "open": open_refs, "unknown": unknown})
        else:
            ready.append(t)
    if not any(not t["checked"] for t in tasks):
        return {"status": "COMPLETE", "task": None, "lanes": [], "blocked": []}
    if not ready:
        return {"status": "BLOCKED", "task": None, "lanes": [], "blocked": blocked}
    sel = ready[0]
    lanes = []
    if sel["route"].get("fanout") == "lanes" and sel["paths"]:
        lanes = [sel]
        for t in ready[1:]:
            if len(lanes) >= max_lanes:
                break
            if t["route"].get("fanout") != "lanes" or not t["paths"] or not t["acceptance"]:
                continue
            if all(disjoint(t["paths"], o["paths"]) for o in lanes):
                lanes.append(t)
        if len(lanes) < 2:
            lanes = []
    return {"status": "READY", "task": public(sel), "lanes": [t["line_no"] for t in lanes], "blocked": blocked}


def cmd_task(path, line_no):
    for t in parse(path):
        if t["line_no"] == line_no:
            return public(t)
    return None


def cmd_validate(path):
    tasks = parse(path)
    by_ref = index(tasks)
    errs = []
    seen = {}
    for t in tasks:
        where = f"line {t['line_no']}"
        if t["ref"]:
            if t["ref"] in seen:
                errs.append(f"{where}: duplicate task id '{t['id']}' (also line {seen[t['ref']]})")
            seen.setdefault(t["ref"], t["line_no"])
        for k in t["_repeated"]:
            errs.append(f"{where}: {k}: given more than once")
        for k in t["_late"]:
            errs.append(f"{where}: {k} is beyond the {LOOKAHEAD}-line look-ahead; move it up")
        for p in t["paths"]:
            if glob_prefix(p) is None:
                errs.append(f"{where}: Paths entry '{p}' must be repo-relative without '..'")
        if t["checked"]:
            continue
        if not t["acceptance"]:
            errs.append(f"{where}: no Acceptance: line within {LOOKAHEAD} lines")
        for raw in t["blocked_by"]:
            ref = norm_ref(raw)
            if ref is None or not by_ref.get(ref):
                errs.append(f"{where}: Blocked-by '{raw}' does not name a task in this plan")
        r = t["route"]
        for tok in r.get("_invalid", []):
            errs.append(f"{where}: Route token '{tok}' is not key=value")
        for k, v in r.items():
            if k == "_invalid":
                continue
            if k not in ROUTE_VALUES:
                errs.append(f"{where}: Route key '{k}' unknown (allowed: {', '.join(sorted(ROUTE_VALUES))})")
            elif v not in ROUTE_VALUES[k]:
                errs.append(f"{where}: Route {k}={v} not one of {', '.join(sorted(ROUTE_VALUES[k]))}")
        if r.get("fanout") == "lanes" and not t["paths"]:
            errs.append(f"{where}: Route fanout=lanes requires a Paths: line")
        b = t["budget"]
        for tok in b.get("_invalid", []):
            errs.append(f"{where}: Budget token '{tok}' is not key=value")
        for k, v in b.items():
            if k == "_invalid":
                continue
            if k not in BUDGET_KEYS:
                errs.append(f"{where}: Budget key '{k}' unknown (allowed: usd, spawns, minutes)")
            else:
                try:
                    if float(v) <= 0:
                        raise ValueError
                except ValueError:
                    errs.append(f"{where}: Budget {k}={v} must be a positive number")
    # Directive lines that belong to no task's block (e.g. after a blank line).
    owned = set()
    lines = read_lines(path)
    for t in tasks:
        j = t["line_no"]
        while j < len(lines) and lines[j].strip() and not TASK_RE.match(lines[j]) and not FENCE_RE.match(lines[j]):
            owned.add(j)
            j += 1
    fenced = False
    for j, line in enumerate(lines):
        if FENCE_RE.match(line):
            fenced = not fenced
            continue
        if not fenced and DIRECTIVE_RE.match(line) and line[:1].isspace() and j not in owned:
            errs.append(f"line {j + 1}: directive outside any task block (a blank line separates it from its task?)")
    # Cycle check over Blocked-by edges.
    graph = {}
    for t in tasks:
        if t["ref"]:
            graph.setdefault(t["ref"], []).extend(norm_ref(r) for r in t["blocked_by"] if norm_ref(r) in by_ref)
    state = {}

    def visit(n, stack):
        state[n] = 1
        for m in graph.get(n, []):
            if state.get(m) == 1:
                cyc = stack[stack.index(m):] + [m] if m in stack else [n, m]
                errs.append("Blocked-by cycle: " + " -> ".join(by_ref[x][0]["id"] for x in cyc))
                return True
            if state.get(m) is None and visit(m, stack + [m]):
                return True
        state[n] = 2
        return False

    for n in graph:
        if state.get(n) is None and visit(n, [n]):
            break
    return errs


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, path = argv[1], argv[2]
    if cmd == "next":
        import os
        print(json.dumps(cmd_next(path, int(os.environ.get("APEX_MAX_LANES", "3")))))
        return 0
    if cmd == "task":
        t = cmd_task(path, int(argv[3]))
        print(json.dumps(t))
        return 0 if t else 1
    if cmd == "validate":
        errs = cmd_validate(path)
        for e in errs:
            print(e)
        return 1 if errs else 0
    print(f"unknown command {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
