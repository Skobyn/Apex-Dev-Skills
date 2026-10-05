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
import re
import sys

LOOKAHEAD = 8
TASK_RE = re.compile(r"^- \[( |x|X)\] (.*)$")
ID_RE = re.compile(r"\*\*((?:Phase|Gate)\b[^*]*)\*\*")
TAG_RE = re.compile(r"\[([a-z0-9:@._+-]+)\]")
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


def parse(path):
    lines = open(path, encoding="utf-8").read().splitlines()
    tasks = []
    for i, line in enumerate(lines):
        m = TASK_RE.match(line)
        if not m:
            continue
        body = m.group(2)
        idm = ID_RE.search(body)
        tid = idm.group(1).strip() if idm else None
        tags = [t for t in TAG_RE.findall(body) if t not in ("x", " ")]
        d = {"acceptance": "", "blocked_by_raw": "", "swarm": "", "route_raw": "", "paths_raw": "", "budget_raw": ""}
        key_map = {"Acceptance": "acceptance", "Blocked-by": "blocked_by_raw", "Swarm": "swarm",
                   "Route": "route_raw", "Paths": "paths_raw", "Budget": "budget_raw"}
        for j in range(i + 1, min(i + 1 + LOOKAHEAD, len(lines))):
            nxt = lines[j]
            if not nxt.strip() or TASK_RE.match(nxt):
                break
            dm = DIRECTIVE_RE.match(nxt)
            if dm:
                d[key_map[dm.group(1)]] = dm.group(2)
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
            "blocked_by": [r.strip() for r in d["blocked_by_raw"].split(",") if r.strip()],
            "swarm": d["swarm"],
            "route_raw": d["route_raw"],
            "route": parse_kv(d["route_raw"]),
            "paths": [p.strip() for p in d["paths_raw"].split(",") if p.strip()],
            "budget_raw": d["budget_raw"],
            "budget": parse_kv(d["budget_raw"]),
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
            by_ref.setdefault(t["ref"], t)
    return by_ref


def blockers(task, by_ref):
    """Return (unchecked blocker refs, unknown refs) for a task."""
    open_refs, unknown = [], []
    for raw in task["blocked_by"]:
        ref = norm_ref(raw)
        dep = by_ref.get(ref) if ref else None
        if dep is None:
            unknown.append(raw)
        elif not dep["checked"]:
            open_refs.append(dep["id"])
    return open_refs, unknown


def glob_prefix(g):
    g = g.strip().lstrip("./")
    m = re.search(r"[*?\[{]", g)
    return g[: m.start()] if m else g


def disjoint(paths_a, paths_b):
    for a in paths_a:
        for b in paths_b:
            pa, pb = glob_prefix(a), glob_prefix(b)
            if pa.startswith(pb) or pb.startswith(pa):
                return False
    return True


def public(t):
    return {k: v for k, v in t.items() if k not in ("ref",)}


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
        if t["checked"]:
            continue
        if not t["acceptance"]:
            errs.append(f"{where}: no Acceptance: line within {LOOKAHEAD} lines")
        for raw in t["blocked_by"]:
            ref = norm_ref(raw)
            if ref is None or ref not in by_ref:
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
    # Cycle check over Blocked-by edges.
    graph = {}
    for t in tasks:
        if t["ref"]:
            graph[t["ref"]] = [norm_ref(r) for r in t["blocked_by"] if norm_ref(r) in by_ref]
    state = {}

    def visit(n, stack):
        state[n] = 1
        for m in graph.get(n, []):
            if state.get(m) == 1:
                cyc = stack[stack.index(m):] + [m] if m in stack else [n, m]
                errs.append("Blocked-by cycle: " + " -> ".join(by_ref[x]["id"] for x in cyc))
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
