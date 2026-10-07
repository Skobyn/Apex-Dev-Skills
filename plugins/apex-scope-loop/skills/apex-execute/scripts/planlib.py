#!/usr/bin/env python3
"""planlib.py — the one parser for apex-scope-loop plan files (ADR-0003).

Used by iterate.sh (task selection and the validate gate), land.sh and init.sh
(counting), and apex-dispatch's route.sh (task features), so they never
disagree about what a task, a tag, a directive or a Blocked-by reference means.

Usage:
  planlib.py next PLAN            JSON: the next unchecked, unblocked task, lanes, blocked tasks
  planlib.py task PLAN LINE_NO    JSON: one task by its 1-based line number
  planlib.py validate PLAN        prints one error per line; exit 1 if any
  planlib.py remaining PLAN       number of unchecked tasks (the one definition of done)
  planlib.py counts PLAN          "<total> <checked>"
  Any command on an unreadable plan exits 3 ("ERROR: plan is invalid: ...").

The grammar is deliberately small, and nothing in it hides a line:

  Task        a line starting at column 0 with "- [ ]" or "- [x]" and
              whitespace: always a task, wherever it appears. A checkbox in any
              other list form ("* [ ]", "1. [ ]", up to 3 spaces of indent) is a
              validation error, never silently skipped.
                - [ ] **Phase 2.1** [backend][api] Title
  Block       the lines after a task up to the next blank line or task.
  Directive   a block line "- Key: value" indented 0-4 spaces, Key one of
              Acceptance, Blocked-by, Swarm, Route, Paths, Budget. Deeper lines
              are notes, except that "Blocked-by:" counts at any depth (fail closed).
  Blocked-by  comma-separated; phase-2.1 | Phase 2.1 | **Phase 2.1** |
              gate-2-3 | Gate 2→3 | Gate 2-3. Repeated lines merge.
  Route       class=… provider=… fanout=… review=…   (may only tighten)
  Paths       comma-separated repo-relative globs (required when fanout=lanes)
  Budget      usd=<n> spawns=<n> minutes=<n>          (may only lower)

The plan is a restricted markdown dialect, verified rather than guessed, so
that what planlib runs is exactly what a CommonMark renderer shows as tasks
(a column-0 line can only be hidden by a top-level fence or HTML block):
  - code fences open at column 0 (after a blank line when they follow a
    task) and close on their exact closer at column 0; no other fence-like
    line inside; never left open
  - no '<' followed by a letter, '/', '!' or '?' anywhere outside a
    top-level fenced code block (raw HTML blocks, comments, tags, autolinks;
    code spans are not exempt), and no '$$' or ':::' block outside a
    blockquote or list item
  - a task's block lines are indented at least 2 spaces
  - a checkbox anywhere except a column-0 task is refused (including one on
    the line after an empty list marker); blockquoted examples are allowed
  - no byte-order mark; no setext underline inside a task block; no
    whitespace other than space and tab; no escaped checkboxes
  - no front matter, no carriage return inside a line
Anything outside the dialect makes the plan invalid; nothing is ever hidden.
"""
import json
import os
import posixpath
import re
import sys

LOOKAHEAD = 8
TASK_RE = re.compile(r"^- \[( |x|X)\][ \t]+(.*)$")
ID_RE = re.compile(r"\*\*\s*(Phase\s+[0-9]+(?:\.[0-9]+)*|Gate\s+[^*\s—:]+(?:\s*(?:→|->)\s*[^*\s—:]+)?)")
TAG_RE = re.compile(r"\[([a-z0-9:@._+-]+)\](?!\()")  # not markdown link text
KEYS = "Acceptance|Blocked-by|Swarm|Route|Paths|Budget"
DIRECTIVE_RE = re.compile(r"^ {0,4}[-*][ \t]+(" + KEYS + r"):\s*(.*?)\s*$")
ANY_DIRECTIVE_RE = re.compile(r"^\s*(?:[-*+][ \t]+)?(" + KEYS + r"):")
BLOCKED_ANY_RE = re.compile(r"^\s*(?:[-*+][ \t]+)?Blocked-by:\s*(.*?)\s*$")

ROUTE_VALUES = {
    "class": {"auto", "docs", "tests", "mechanical", "feature", "bugfix", "migration", "security"},
    "provider": {"auto", "claude", "claude-p", "codex", "grok", "local"},
    "fanout": {"single", "lanes"},
    "review": {"auto", "solo", "six-lens", "fanout"},
}
BUDGET_KEYS = {"usd", "spawns", "minutes"}


class PlanError(Exception):
    """The plan cannot be read safely; every command refuses it."""


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
    """Split exactly as sed and grep -n count lines (\\n only; a trailing \\r is dropped)."""
    data = open(path, encoding="utf-8", errors="replace", newline="").read()
    return [l[:-1] if l.endswith("\r") else l for l in data.split("\n")]


WS = " \t"
MARKER_RE = re.compile(r"[ \t]*(?:>|[-*+](?:[ \t]+|$)|\d{1,9}[.)](?:[ \t]+|$))[ \t]*")
OPEN_RE = re.compile(r"^(`{3,}|~{3,})(.*)$")
CLOSE_RE = re.compile(r"^(`{3,}|~{3,})[ \t]*$")
FENCELIKE_RE = re.compile(r"^\s*[`~]{3}")
CHECKBOX_RE = re.compile(r"\[[ xX]\](?:[ \t]|$)")
EXT_BLOCK_RE = re.compile(r"^(?:\$\$|:::)")
BLOCK_LINE_RE = re.compile(r"^ {2,}\S")
# An escaped or entity-spelled checkbox: either bracket written as an escape
# or entity, or an entity/escape inside otherwise literal brackets.
ESCAPED_BOX_RE = re.compile(r"^(?:\\\[|&#[xX]?0*(?:91|5[bB]);|&lbrack;|&lsqb;)"
                            r"|^\[[ xX]?(?:&[#\w]+;|\\)")
RAW_HTML_RE = re.compile(r"<[A-Za-z/!?]")


def strip_markers(line):
    """Remove leading container markers (>, -, *, +, N., N)); report whether
    any were present and whether one was a blockquote."""
    rest, prefixed, quoted = line, False, False
    while True:
        m = MARKER_RE.match(rest)
        if not m:
            return rest.lstrip(WS), prefixed, quoted
        prefixed = True
        quoted = quoted or ">" in m.group(0)
        rest = rest[m.end():]


def scan(lines):
    """Verify the plan stays inside the dialect where planlib and a CommonMark
    renderer must agree, and mark lines inside top-level code fences.

    A line at column 0 closes every open list item and blockquote, and a task
    or fence line is a block start (never a lazy continuation), so only a
    top-level fenced code block or a top-level HTML block can show a column-0
    task line as an example. HTML block starts are refused outright; fences
    must open at column 0 and close on their exact CommonMark closer; anything
    planlib cannot prove is refused. Returns (inside, errors)."""
    inside = [False] * len(lines)
    errs = []
    in_block = set()
    for i, l in enumerate(lines):
        if TASK_RE.match(l):
            in_block.update(block(lines, i))
    if lines and lines[0].startswith("\ufeff"):
        errs.append("line 1: byte-order mark; some renderers strip it and show a task planlib would not see — remove it")
    if lines and re.match(r"(?:---|\+\+\+)[ \t]*$", lines[0]):
        errs.append("line 1: front matter ('---' / '+++') may hide the plan in some renderers; remove it")
    fence = None
    for i, line in enumerate(lines):
        n = i + 1
        if "\r" in line:
            errs.append(f"line {n}: carriage return inside a line (CommonMark treats it as a line break)")
        odd = sorted({c for c in line if c.isspace() and c not in " \t\r"})
        if odd:
            errs.append(f"line {n}: whitespace other than space or tab ({', '.join(f'U+{ord(c):04X}' for c in odd)}); "
                        "renderers treat it differently, so it could hide or reveal a task — replace it with a space")
        if fence:
            inside[i] = True
            if CLOSE_RE.match(line) and line[0] == fence[0] and len(line.rstrip(WS)) >= fence[1]:
                fence = None
            elif FENCELIKE_RE.match(line):
                errs.append(f"line {n}: fence-like line inside the code fence opened at line {fence[2]} "
                            "(examples must not contain fence lines; the only one allowed is the exact closer at column 0)")
            elif TASK_RE.match(line):
                errs.append(f"line {n}: a task line sits inside the code fence opened at line {fence[2]} "
                            "(examples must not start with '- [ ]' at column 0)")
            continue
        # Raw HTML anywhere outside a top-level fence (a block, a comment, a
        # tag in a list item, a blockquote, mid-sentence, or inside backticks:
        # code-span boundaries are subtle enough that none are trusted) is
        # refused: renderers that pass HTML through emit it unbalanced, and
        # it can hide a live task or show it as example text.
        if RAW_HTML_RE.search(line):
            errs.append(f"line {n}: '<' followed by a letter, '/', '!' or '?' (raw HTML) is not allowed in a plan "
                        "outside a top-level fenced code block — write placeholders as {name}, or 'a < b' with spaces")
        rest, prefixed, quoted = strip_markers(line)
        in_blk = i in in_block
        if in_blk and not BLOCK_LINE_RE.match(line):
            errs.append(f"line {n}: a task's block lines must be indented at least 2 spaces")
        if in_blk and re.fullmatch(r"[ \t]*(?:=+|-+)[ \t]*", line):
            errs.append(f"line {n}: a setext underline turns the task above into a heading in some renderers")
        if FENCELIKE_RE.match(rest):
            m = OPEN_RE.match(line)            # matches only an unprefixed column-0 fence
            if prefixed:
                if in_blk:
                    errs.append(f"line {n}: code fence inside a task block (put a blank line before it)")
            elif m and m.group(1)[0] == "`" and "`" in m.group(2):
                pass                           # inline code, not a fence
            elif m and not in_blk:
                fence = (m.group(1)[0], len(m.group(1)), n)
                inside[i] = True
            else:
                errs.append(f"line {n}: code fences must start at column 0, after a blank line when they follow a task")
        elif EXT_BLOCK_RE.match(rest) and (not prefixed or in_blk):
            errs.append(f"line {n}: '$$' / ':::' block syntax is not allowed in a plan")
        # Any checkbox that is not a column-0 task is refused unless it is
        # blockquoted: prefixed list items, and a checkbox on the line after
        # an empty list marker ("-" then "  [ ] x"), which renderers show as
        # an open task.
        if not quoted and ESCAPED_BOX_RE.match(rest):
            errs.append(f"line {n}: an escaped checkbox ('\\[ ]', '&#91; ]') renders like one in some renderers; remove it")
        if not quoted and CHECKBOX_RE.match(rest) and not TASK_RE.match(line):
            errs.append(f"line {n}: checkbox not in the task form '- [ ] ' at column 0 "
                        "(it would not be a task; make it one or remove the checkbox)")
    if fence:
        errs.append(f"line {fence[2]}: code fence is never closed")
    return inside, errs


def block(lines, i):
    """Line indexes of the block after task line i (to a blank line or task)."""
    out = []
    j = i + 1
    while j < len(lines) and lines[j].strip(WS) and not TASK_RE.match(lines[j]):
        out.append(j)
        j += 1
    return out


def parse(path):
    lines = read_lines(path)
    inside, errs = scan(lines)
    if errs:
        raise PlanError(errs[0] + (f" (and {len(errs) - 1} more; run planlib.py validate)" if len(errs) > 1 else ""))
    tasks = []
    for i, line in enumerate(lines):
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
        repeated, late, in_example, noncanonical = [], [], [], []
        for j in block(lines, i):
            bm = BLOCKED_ANY_RE.match(lines[j])
            dm = DIRECTIVE_RE.match(lines[j])
            if bm:                                # Blocked-by at any depth, in or out of examples
                d["blocked_by_raw"].append(bm.group(1))
                if j - i > LOOKAHEAD:
                    late.append(f"Blocked-by at line {j + 1}")
                continue
            if inside[j] and ANY_DIRECTIVE_RE.match(lines[j]):
                in_example.append(j + 1)         # never used; an error in validate
                continue
            if not dm and ANY_DIRECTIVE_RE.match(lines[j]):
                noncanonical.append(j + 1)       # e.g. "+ Budget:", "Budget:", 5+ spaces: never silently dropped
                continue
            if dm:
                key = key_map[dm.group(1)]
                if j - i > LOOKAHEAD:
                    late.append(f"{dm.group(1)} at line {j + 1}")
                if d[key]:
                    repeated.append(dm.group(1))
                d[key] = dm.group(2)
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
            "_in_example": in_example,
            "_noncanonical": noncanonical,
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
    """Literal prefix of a repo-relative glob (case-folded), or None when the
    glob cannot be bounded (absolute, contains a '..' segment, backslashes)."""
    g = g.strip()
    # Reject on the raw text: normpath would collapse "**/.." or "[.][.]/.."
    # into a path that looks bounded but is not.
    if not g or g.startswith("/") or "\\" in g or ".." in g.split("/"):
        return None
    norm = posixpath.normpath(g)
    m = re.search(r"[*?\[{]", norm)
    prefix = norm[: m.start()] if m else norm
    return prefix.lower()


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
    return {k: v for k, v in t.items() if k not in ("ref",) and not k.startswith("_")}


def cmd_remaining(path):
    """Unchecked tasks, by the same rules as next (the one definition of done)."""
    return sum(1 for t in parse(path) if not t["checked"])


def cmd_next(path, max_lanes):
    try:
        tasks = parse(path)
    except PlanError as e:
        return {"status": "ERROR", "error": str(e), "task": None, "lanes": [], "blocked": []}
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
    lines = read_lines(path)
    inside, scan_errs = scan(lines)
    if scan_errs:
        return scan_errs
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
        for n in t["_noncanonical"]:
            errs.append(f"line {n}: directive not in the form '  - Key: value' (indent 0-4 spaces, '-' or '*' bullet); "
                        "it would be ignored, so a Budget or Route limit would not apply")
        for n in t["_in_example"]:
            errs.append(f"line {n}: directive inside a code example or comment in a task block "
                        "(move the example out of the task, or it could be mistaken for the task's own)")
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
    # Directive-like lines that belong to no task's block (e.g. after a blank
    # line). A Blocked-by is an error anywhere; others outside examples.
    owned = set()
    for t in tasks:
        owned.update(block(lines, t["line_no"] - 1))
    for j, line in enumerate(lines):
        if j in owned or TASK_RE.match(line):
            continue
        if BLOCKED_ANY_RE.match(line) or (not inside[j] and DIRECTIVE_RE.match(line) and line[:1].isspace()):
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
    try:
        return run(argv)
    except PlanError as e:
        print(f"ERROR: plan is invalid: {e}", file=sys.stderr)
        return 3


def run(argv):
    cmd, path = argv[1], argv[2]
    if cmd == "next":
        print(json.dumps(cmd_next(path, int(os.environ.get("APEX_MAX_LANES", "3")))))
        return 0
    if cmd == "remaining":
        print(cmd_remaining(path))
        return 0
    if cmd == "counts":
        ts = parse(path)
        print(len(ts), sum(1 for t in ts if t["checked"]))
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
