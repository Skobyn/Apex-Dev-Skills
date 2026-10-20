#!/usr/bin/env python3
"""monitorlib.py - the plan `## Monitor` section and the repo-level monitor.json.

Usage:
  monitorlib.py validate PLAN         check the plan's `## Monitor` section
  monitorlib.py validate-file FILE    check a repo-level monitor.json (no window_days)

Exit 0 = valid; 1 = invalid, one problem per line on stdout; 2 = usage error.
Importable: validate_plan(path) / validate_file(path) return a list of problems
(empty = valid); load_plan(path) returns (config_or_None, problems).

The section (ADR R5b, R5d) holds exactly one fenced ```json block:

  {"window_days": 14, "checks": [
     {"id": "p95", "metric": "latency.p95", "op": ">", "threshold": 800,
      "severity": "high",
      "probe": {"kind": "http", "url": "https://x.example/health", "measure": "latency_ms"}}]}

  window_days  integer 1-90, default 14 (plan only; refused in monitor.json)
  checks       list; [] (or no section at all) means "not watched"
  id, metric   match the apex-dispatch ledger grammar (ledger.py _ID_RE):
               ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$ ; ids are unique
  op           one of < <= > >= == !=   (the breach condition: value OP threshold)
  threshold    a finite number
  severity     high | medium | low
  probe        http   {kind, url, measure: status|latency_ms, expect_status?, method?: "GET"}
                      http/https only, no credentials in the url, GET only, no headers,
                      fixed 10 s timeout (not configurable)
               cmd    {kind, command}   value = exit code, or the number on the last stdout line
               runner {kind, metrics?}  uses $APEX_MONITOR_CMD; metrics = list of metric names

The schema is an allow-list: an unknown key is refused at every level. A
`## Monitor` heading whose block is missing, malformed, doubled or not JSON is
refused, never read as "not watched". Fences are found with planlib.scan (the
same fence rules the task grammar uses), not a second parser.
"""
import json
import math
import os
import re
import sys
from urllib.parse import urlsplit

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import planlib  # noqa: E402

OPS = ("<", "<=", ">", ">=", "==", "!=")
SEVERITIES = ("high", "medium", "low")
MEASURES = ("status", "latency_ms")
PROBE_TIMEOUT_S = 10          # fixed; a probe cannot set its own
DEFAULT_WINDOW_DAYS = 14
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")   # = apex-dispatch ledger.py _ID_RE

HEADING_LOOSE_RE = re.compile(r"^ {0,3}#{1,6}[ \t]*monitor\b", re.I)
HEADING_RE = re.compile(r"^## Monitor[ \t]*$")
SETEXT_TITLE_RE = re.compile(r"^ {0,3}monitor[ \t]*$", re.I)
SETEXT_LINE_RE = re.compile(r"^ {0,3}(?:=+|-+)[ \t]*$")
NEXT_HEADING_RE = re.compile(r"^ {0,3}#{1,2}(?:[ \t]|$)")
CTRL_RE = re.compile(r"[\x00-\x1f\x7f]")


class _Dup(Exception):
    pass


def _pairs(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            raise _Dup(k)
        d[k] = v
    return d


def _const(name):
    raise ValueError(f"{name} is not a finite number")


def parse_json(text):
    """(value, None) or (None, problem). Duplicate keys and NaN/Infinity are refused."""
    try:
        return json.loads(text, object_pairs_hook=_pairs, parse_constant=_const), None
    except _Dup as e:
        return None, f"duplicate key {str(e)!r} in the JSON block"
    except RecursionError:
        return None, "the JSON block is nested too deeply"
    except ValueError as e:
        return None, f"invalid JSON: {e}"


def _is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _is_num(v):
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return False
    try:
        return math.isfinite(float(v))
    except OverflowError:
        return False


def _keys(obj, allowed, required, where, probs):
    for k in obj:
        if k not in allowed:
            hint = ""
            if k == "headers":
                hint = " (probes send no headers or credentials)"
            elif k in ("timeout", "timeout_s"):
                hint = f" (the probe timeout is fixed at {PROBE_TIMEOUT_S} s)"
            elif k == "window_days":
                hint = " (window_days belongs to a plan's ## Monitor block, not this file)"
            probs.append(f"{where}: unknown key {k!r}{hint}")
    for k in required:
        if k not in obj:
            probs.append(f"{where}: missing {k!r}")


def _probe(p, where, check_metric, probs):
    if not isinstance(p, dict):
        probs.append(f"{where}: probe must be an object")
        return
    kind = p.get("kind")
    if kind == "http":
        _keys(p, {"kind", "url", "measure", "expect_status", "method"}, ("url", "measure"), where, probs)
        if "method" in p and p["method"] != "GET":
            probs.append(f"{where}: http probes are GET only (method {p['method']!r})")
        url = p.get("url")
        if "url" in p:
            if not isinstance(url, str) or not url or len(url) > 2048 or CTRL_RE.search(url) or " " in url:
                probs.append(f"{where}: url must be a non-empty string without spaces or control characters (max 2048)")
            else:
                try:
                    u = urlsplit(url)
                    host = u.hostname
                except ValueError:
                    u, host = None, None
                if u is None or u.scheme not in ("http", "https") or not host:
                    probs.append(f"{where}: url must be an http:// or https:// URL with a host")
                elif u.username is not None or u.password is not None or "@" in u.netloc:
                    probs.append(f"{where}: url must not carry credentials (user:pass@)")
        if "measure" in p and p["measure"] not in MEASURES:
            probs.append(f"{where}: measure must be one of {', '.join(MEASURES)}")
        if "expect_status" in p and not (_is_int(p["expect_status"]) and 100 <= p["expect_status"] <= 599):
            probs.append(f"{where}: expect_status must be an integer 100-599")
    elif kind == "cmd":
        _keys(p, {"kind", "command"}, ("command",), where, probs)
        c = p.get("command")
        if "command" in p and (not isinstance(c, str) or not c.strip() or len(c) > 1024 or CTRL_RE.search(c)):
            probs.append(f"{where}: command must be a non-empty single-line string (max 1024)")
    elif kind == "runner":
        _keys(p, {"kind", "metrics"}, (), where, probs)
        if "metrics" in p:
            m = p["metrics"]
            if not isinstance(m, list) or not m or not all(isinstance(x, str) and ID_RE.fullmatch(x) for x in m):
                probs.append(f"{where}: metrics must be a non-empty list of metric names matching {ID_RE.pattern}")
            elif len(set(m)) != len(m):
                probs.append(f"{where}: metrics lists a name twice")
    else:
        probs.append(f"{where}: unknown probe.kind {kind!r} (allowed: http, cmd, runner)")


def validate_config(cfg, plan_level):
    """Allow-list validation of the parsed JSON. Returns a list of problems."""
    probs = []
    if not isinstance(cfg, dict):
        return ["the JSON block must be an object {\"window_days\": N, \"checks\": [...]}" if plan_level
                else "monitor.json must be an object {\"checks\": [...]}"]
    _keys(cfg, {"window_days", "checks"} if plan_level else {"checks"}, ("checks",), "monitor", probs)
    if plan_level and "window_days" in cfg:
        w = cfg["window_days"]
        if not _is_int(w) or not 1 <= w <= 90:
            probs.append(f"monitor: window_days must be an integer 1-90 (got {json.dumps(w)})")
    checks = cfg.get("checks")
    if "checks" not in cfg:
        return probs
    if not isinstance(checks, list):
        return probs + ["monitor: checks must be a list"]
    seen = {}
    for i, c in enumerate(checks):
        label = f"checks[{i}]"
        if isinstance(c, dict) and isinstance(c.get("id"), str) and c["id"]:
            label += f" (id {c['id']!r})"
        if not isinstance(c, dict):
            probs.append(f"{label}: must be an object")
            continue
        _keys(c, {"id", "metric", "op", "threshold", "severity", "probe"},
              ("id", "metric", "op", "threshold", "severity", "probe"), label, probs)
        for f in ("id", "metric"):
            if f in c and not (isinstance(c[f], str) and ID_RE.fullmatch(c[f])):
                probs.append(f"{label}: {f} must match {ID_RE.pattern} (the ledger's id grammar) (got {json.dumps(c[f])[:60]})")
        if isinstance(c.get("id"), str) and ID_RE.fullmatch(c["id"]):
            if c["id"] in seen:
                probs.append(f"{label}: duplicate check id {c['id']!r} (also checks[{seen[c['id']]}])")
            else:
                seen[c["id"]] = i
        if "op" in c and c["op"] not in OPS:
            probs.append(f"{label}: unknown op {json.dumps(c['op'])[:40]} (allowed: {' '.join(OPS)})")
        if "threshold" in c and not _is_num(c["threshold"]):
            probs.append(f"{label}: threshold must be a finite number")
        if "severity" in c and c["severity"] not in SEVERITIES:
            probs.append(f"{label}: severity must be one of {', '.join(SEVERITIES)}")
        if "probe" in c:
            _probe(c["probe"], label + " probe", c.get("metric"), probs)
    return probs


def _section(lines, inside):
    """Locate the plan's `## Monitor` section. Returns (found, blocks, problems);
    blocks = [(open_line_no, info, body_text)]."""
    heads, probs = [], []
    for i, l in enumerate(lines):
        if inside[i]:
            continue
        if HEADING_LOOSE_RE.match(l):
            heads.append(i)
            if not HEADING_RE.match(l):
                probs.append(f"line {i + 1}: the heading must be exactly '## Monitor'")
        elif i + 1 < len(lines) and SETEXT_TITLE_RE.match(l) and SETEXT_LINE_RE.match(lines[i + 1]) and not inside[i + 1]:
            heads.append(i)
            probs.append(f"line {i + 1}: write the heading as '## Monitor', not an underlined title")
    if not heads:
        return False, [], []
    if len(heads) > 1:
        probs.append(f"more than one Monitor heading (lines {', '.join(str(h + 1) for h in heads)})")
    start = heads[0]
    end = len(lines)
    for j in range(start + 1, len(lines)):
        if not inside[j] and NEXT_HEADING_RE.match(lines[j]):
            end = j
            break
    blocks, cur = [], None
    for j in range(start + 1, end):
        if cur is None:
            if inside[j]:
                m = planlib.OPEN_RE.match(lines[j])
                cur = [j + 1, (m.group(2).strip() if m else "?"), [], lines[j][0]]
        else:
            if planlib.CLOSE_RE.match(lines[j]) and lines[j][0] == cur[3]:
                blocks.append((cur[0], cur[1], "\n".join(cur[2])))
                cur = None
            else:
                cur[2].append(lines[j])
    if cur is not None:
        probs.append(f"line {cur[0]}: the code fence in the Monitor section is never closed")
    return True, blocks, probs


def load_plan(path):
    """(config, problems). config is None when the plan has no Monitor section
    (not watched) or when problems is non-empty."""
    try:
        lines = planlib.read_lines(path)
    except OSError as e:
        return None, [f"cannot read {path}: {e.strerror}"]
    inside, errs = planlib.scan(lines)
    if errs:
        return None, ["plan dialect: " + e for e in errs]
    found, blocks, probs = _section(lines, inside)
    if not found:
        return None, []
    if not blocks and not probs:
        probs.append("the ## Monitor heading has no fenced json block (write {\"window_days\": 14, \"checks\": []} for 'not watched')")
    for ln, info, _ in blocks:
        if info != "json":
            probs.append(f"line {ln}: the Monitor section may hold only a fenced json block (found info string {info!r})")
    if len(blocks) > 1:
        probs.append(f"the Monitor section holds {len(blocks)} fenced blocks (lines {', '.join(str(b[0]) for b in blocks)}); exactly one json block is allowed")
    if probs:
        return None, probs
    cfg, err = parse_json(blocks[0][2])
    if err:
        return None, [f"line {blocks[0][0]}: {err}"]
    probs = validate_config(cfg, True)
    return (None if probs else cfg), probs


def validate_plan(path):
    return load_plan(path)[1]


def load_file(path):
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except (OSError, UnicodeDecodeError) as e:
        return None, [f"cannot read {path}: {getattr(e, 'strerror', None) or e}"]
    cfg, err = parse_json(text)
    if err:
        return None, [err]
    probs = validate_config(cfg, False)
    return (None if probs else cfg), probs


def validate_file(path):
    return load_file(path)[1]


def main(argv):
    if len(argv) != 3 or argv[1] not in ("validate", "validate-file"):
        print("usage: monitorlib.py validate PLAN | validate-file FILE", file=sys.stderr)
        return 2
    probs = validate_plan(argv[2]) if argv[1] == "validate" else validate_file(argv[2])
    for p in probs:
        print(p)
    return 1 if probs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
