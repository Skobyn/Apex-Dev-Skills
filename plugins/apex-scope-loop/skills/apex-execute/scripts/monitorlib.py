#!/usr/bin/env python3
"""monitorlib.py - the plan `## Monitor` section and the repo-level monitor.json.

Usage:
  monitorlib.py validate PLAN         check the plan's `## Monitor` section
  monitorlib.py validate-file FILE    check a repo-level monitor.json (no window_days)

Exit 0 = valid; 1 = invalid, one problem per line on stdout; 2 = usage error.
Importable: validate_plan(path) / validate_file(path) return a list of problems
(empty = valid); load_plan(path) returns (config_or_None, problems); see its
docstring for the two meanings of a None config.

The section (ADR R5b, R5d) holds exactly one fenced ```json block:

  {"window_days": 14, "checks": [
     {"id": "p95", "metric": "latency.p95", "op": "<", "threshold": 800,
      "severity": "high",
      "probe": {"kind": "http", "url": "https://x.example/health", "measure": "latency_ms"}}]}

  window_days  integer 1-90, default 14 (plan only; refused in monitor.json)
  checks       list; [] (or no section at all) means "not watched"
  id, metric   match the apex-dispatch ledger grammar (ledger.py _ID_RE):
               ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$ ; ids are unique
  op           one of < <= > >= ==   (the ADR's set; no !=). op is the EXPECTED (healthy)
               condition: a check passes while `value op threshold` holds, and it is
               breached when NOT (value op threshold). "p99 must stay under 2000 ms"
               is "op": "<", "threshold": 2000. A success criterion is a pass
               condition, so it maps directly onto a check.
  threshold    a finite number
  severity     high | medium | low
  probe        http   {kind, url, measure: status|latency_ms, expect_status?, method?: "GET"}
                      http/https only, no credentials in the url, GET only, no headers,
                      fixed 10 s timeout (not configurable)
               cmd    {kind, command}   value: see "Measuring" below. A command that names
                      operate.sh, the word deploy or APEX_DEPLOY_CMD (any case) is refused,
                      so a drafted Monitor section cannot hide a deploy behind the monitor step.
               runner {kind, metrics?}  uses $APEX_MONITOR_CMD; metrics = list of metric names
  At most 50 checks per plan (or per monitor.json); one operate.sh run measures at most
  200 checks in all (MAX_PROBES_PER_RUN), and refuses, naming the cap, beyond that.

Measuring (operate.sh monitor; Phase 3.4). Every probe runs with a fixed 10 s timeout, the
repository root as its cwd, stdin /dev/null and an environment with every APEX_* variable
removed (so APEX_OPERATE_ACK and APEX_DEPLOY_CMD never reach a probe); a timed-out probe's
process group is killed. A probe that fails is `unmeasured` (value None, a reason): never 0
and never a pass. breach = NOT (value op threshold).
  cmd     the plan's command text, verbatim, is the single argument of `/bin/sh -c` (nothing
          is interpolated into it, no positional arguments). The value rule: when the command
          prints nothing on stdout, the value is its exit code; when it prints, the last
          non-empty stdout line must be a plain decimal number and the command must exit 0,
          and that number is the value. Anything else (a non-number last line, output with a
          non-zero exit, a signal, the timeout) is unmeasured.
  http    one GET, no redirects followed (a 3xx is the measured status), no proxy, no
          credentials or extra headers, body read up to 1 MiB, 10 s in all. measure status: the
          HTTP code (4xx/5xx included); measure latency_ms: the milliseconds to the end of
          the body, but unmeasured when expect_status is set and the status differs (a fast
          error page is not a healthy latency). A connection error or timeout is unmeasured.
  runner  $APEX_MONITOR_CMD is split with shlex (no shell) and run as `CMD METRIC...` (the
          probe's metrics, else the check's metric) once per runner check. Its stdout must be
          one JSON object with exactly the requested metrics as keys, each a finite number or
          null. Bad JSON, NaN/Infinity, a duplicate, missing or extra key, a non-number, a
          non-zero exit or the timeout makes the check unmeasured with the reason recorded;
          null is unmeasured ("the runner reported null"). The last stderr line, sanitised,
          is kept as the signal's note.
  sanitise(text) is the only door for probe-supplied text (reasons, notes): one line, an
  allow-list of characters (no backtick, #, *, >, [, ], <, |), no list marker at the start,
  at most 160 characters.

The schema is an allow-list: an unknown key is refused at every level. A
`## Monitor` heading whose block is missing, malformed, doubled or not JSON is
refused, never read as "not watched". Fences are found with planlib.scan (the
same fence rules the task grammar uses), not a second parser.
"""
import json
import math
import os
import re
import shlex
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import planlib  # noqa: E402

# op is the expected (healthy) condition; breach = NOT (value op threshold) (ADR operate pseudocode).
# The allow-list mirrors the ADR's op set exactly: there is no "!=".
OPS = ("<", "<=", ">", ">=", "==")
SEVERITIES = ("high", "medium", "low")
MEASURES = ("status", "latency_ms")
PROBE_TIMEOUT_S = 10          # fixed; a probe cannot set its own
MAX_CHECKS = 50               # per plan section or monitor.json
MAX_PROBES_PER_RUN = 200      # per operate.sh run (--all included)
# a cmd probe may not name operate.sh, the word deploy or APEX_DEPLOY_CMD (any case)
CMD_DENY_RE = re.compile(r"operate\.sh|deploy|apex_deploy_cmd", re.I)
DEFAULT_WINDOW_DAYS = 14
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")   # = apex-dispatch ledger.py _ID_RE

# any-level heading with the word "monitor", or a level-2 heading that merely starts with it
# (## Monitoring, ## Monitors): both must be exactly "## Monitor" or they are refused, never ignored
HEADING_LOOSE_RE = re.compile(r"^ {0,3}(?:#{1,6}[ \t]*monitor\b|##[ \t]*monitor)", re.I)
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
        elif isinstance(c, str) and CMD_DENY_RE.search(c):
            probs.append(f"{where}: command must not name operate.sh, the word deploy or APEX_DEPLOY_CMD "
                         f"(found {CMD_DENY_RE.search(c).group(0)!r}): a monitor probe never deploys")
    elif kind == "runner":
        _keys(p, {"kind", "metrics"}, (), where, probs)
        if "metrics" in p:
            m = p["metrics"]
            if not isinstance(m, list) or not m or not all(isinstance(x, str) and ID_RE.fullmatch(x) for x in m):
                probs.append(f"{where}: metrics must be a non-empty list of metric names matching {ID_RE.pattern}")
            elif len(set(m)) != len(m):
                probs.append(f"{where}: metrics lists a name twice")
            elif isinstance(check_metric, str) and check_metric not in m:
                probs.append(f"{where}: the check's metric {check_metric!r} is not in the probe's metrics list")
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
    if len(checks) > MAX_CHECKS:
        return probs + [f"monitor: at most {MAX_CHECKS} checks (got {len(checks)}): the probe cap per plan"]
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
                probs.append(f"line {i + 1}: the heading must be exactly '## Monitor' - use '## Monitor', not {l.strip()!r}")
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
    """(config, problems). A None config has two meanings, told apart by problems:
      (None, [])        the plan has no ## Monitor section: not watched
      (None, problems)  the section is refused (or the plan cannot be read)
    Callers must test `problems`, never `cfg is None`. A valid section returns
    (cfg, []), with cfg["checks"] == [] meaning the stub: also not watched."""
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


# --- measuring (operate.sh monitor) -----------------------------------------------

_SAFE_RE = re.compile(r"[^A-Za-z0-9 _.,:;=()/+%@'\"-]")
_LEAD_RE = re.compile(r"^(?:[-+=_ ]|\d+[.)])+")


def sanitise(text, limit=160):
    """Probe-supplied text made safe for LESSONS.md / BACKLOG.md / status: one line, an
    allow-list of characters (anything else becomes _), no list marker or heading at the
    start, at most `limit` characters. None stays None."""
    if text is None:
        return None
    s = " ".join(str(text).split())
    s = _SAFE_RE.sub("_", s)
    s = _LEAD_RE.sub("", s).strip()
    if len(s) > limit:
        s = s[:limit - 3].rstrip() + "..."
    return s


NUM_RE = re.compile(r"^[-+]?(?:\d{1,30}(?:\.\d{0,30})?|\.\d{1,30})(?:[eE][-+]?\d{1,3})?$")


def parse_number(text):
    """A plain decimal number (int or float), else None. No nan, inf, 1_000 or hex."""
    t = (text or "").strip()
    if not NUM_RE.match(t):
        return None
    if re.match(r"^[-+]?\d+$", t):
        return int(t)
    v = float(t)
    return v if math.isfinite(v) else None


def passes(value, op, threshold):
    """op is the EXPECTED condition: True while it holds. breach = not passes(...)."""
    return {"<": value < threshold, "<=": value <= threshold, ">": value > threshold,
            ">=": value >= threshold, "==": value == threshold}[op]


def probe_env():
    """The environment a probe runs in: the caller's, minus every APEX_* variable."""
    return {k: v for k, v in os.environ.items() if not k.startswith("APEX_")}


def run_bounded(argv, cwd, timeout=PROBE_TIMEOUT_S):
    """(returncode, stdout, stderr, timed_out). A new session, so a timeout kills the
    whole process group (no orphan keeps the pipes open). Never raises on a bad argv."""
    try:
        p = subprocess.Popen(argv, cwd=cwd, env=probe_env(), stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    except OSError as e:
        return None, "", f"cannot start: {e.strerror or e}", False
    try:
        out, err = p.communicate(timeout=timeout)
        return p.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace"), False
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            p.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        return None, "", "", True


def _unmeasured(reason, note=None):
    return {"value": None, "reason": sanitise(reason), "note": note}


def measure_cmd(probe, cwd):
    rc, out, _err, timed_out = run_bounded(["/bin/sh", "-c", probe["command"]], cwd)
    if timed_out:
        return _unmeasured(f"the command timed out after {PROBE_TIMEOUT_S} s")
    if rc is None or rc < 0:
        return _unmeasured("the command could not run or was killed by a signal")
    lines = [l for l in out.splitlines() if l.strip()]
    if not lines:
        return {"value": rc, "reason": None, "note": None}
    if rc != 0:
        return _unmeasured(f"the command printed output and exited {rc}")
    v = parse_number(lines[-1])
    if v is None:
        return _unmeasured("the last stdout line is not a number: " + lines[-1][:60])
    return {"value": v, "reason": None, "note": None}


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None                     # never follow: the 3xx is the measured status


def _http_once(url, box):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
    opener.addheaders = []              # no User-Agent or any other added header
    t0 = time.monotonic()
    try:
        resp = opener.open(urllib.request.Request(url, method="GET"), timeout=PROBE_TIMEOUT_S)
        try:
            resp.read(1 << 20)
            box["status"] = resp.status
        finally:
            resp.close()
    except urllib.error.HTTPError as e:
        try:
            e.read(1 << 20)
        except Exception:
            pass
        box["status"] = e.code
    except Exception as e:              # URLError, timeout, reset, TLS: not a measurement
        box["error"] = type(e).__name__ + ": " + str(getattr(e, "reason", e))[:80]
        return
    box["latency_ms"] = round((time.monotonic() - t0) * 1000.0, 1)


def measure_http(probe):
    url = probe["url"]
    if urlsplit(url).scheme not in ("http", "https"):
        return _unmeasured("the url is not http(s)")
    box = {}
    t = threading.Thread(target=_http_once, args=(url, box), daemon=True)
    t.start()
    t.join(PROBE_TIMEOUT_S)
    if t.is_alive() or ("status" not in box and "error" not in box):
        return _unmeasured(f"the GET timed out after {PROBE_TIMEOUT_S} s")
    if "error" in box:
        return _unmeasured("the GET failed: " + box["error"])
    if probe["measure"] == "status":
        return {"value": box["status"], "reason": None, "note": None}
    exp = probe.get("expect_status")
    if exp is not None and box["status"] != exp:
        return _unmeasured(f"status {box['status']} is not the expected {exp}, so latency is not measured")
    return {"value": box["latency_ms"], "reason": None, "note": None}


def runner_cmd_problem(cmd):
    """None when $APEX_MONITOR_CMD is usable, else the problem."""
    if not cmd or not cmd.strip():
        return "APEX_MONITOR_CMD is unset: a runner check needs it (set it to your metrics command)"
    if CMD_DENY_RE.search(cmd):
        return "APEX_MONITOR_CMD must not name operate.sh, the word deploy or APEX_DEPLOY_CMD"
    try:
        if not shlex.split(cmd):
            return "APEX_MONITOR_CMD is empty"
    except ValueError as e:
        return f"APEX_MONITOR_CMD cannot be split: {e}"
    return None


def measure_runner(probe, check_metric, cwd, cmd):
    """{metric: result} for the probe's metrics, every one failed closed together."""
    metrics = list(probe.get("metrics") or [check_metric])
    def all_un(reason, note=None):
        return {m: _unmeasured(reason, note) for m in metrics}
    prob = runner_cmd_problem(cmd)
    if prob:
        return all_un(prob)
    rc, out, err, timed_out = run_bounded(shlex.split(cmd) + metrics, cwd)
    errl = [l for l in err.splitlines() if l.strip()]
    note = sanitise(errl[-1], 120) if errl else None
    if timed_out:
        return all_un(f"the runner timed out after {PROBE_TIMEOUT_S} s")
    if rc != 0:
        return all_un(f"the runner exited {rc}", note)
    reply, perr = parse_json(out.strip() or "null")
    if perr:
        return all_un("the runner reply is not valid JSON: " + out.strip()[:60], note)
    if not isinstance(reply, dict):
        return all_un("the runner reply is not one JSON object", note)
    if set(reply) != set(metrics):
        extra = sorted(set(reply) - set(metrics))[:3]
        missing = sorted(set(metrics) - set(reply))[:3]
        return all_un(f"the runner reply keys differ from the requested metrics (extra {extra}, missing {missing})", note)
    res = {}
    for m in metrics:
        v = reply[m]
        if v is None:
            res[m] = _unmeasured("the runner reported null", note)
        elif not _is_num(v):
            res[m] = _unmeasured(f"the runner value for {m} is not a finite number", note)
        else:
            res[m] = {"value": v, "reason": None, "note": note}
    return res


def measure(check, cwd, monitor_cmd):
    """{value, reason, note, status: ok|breach|unmeasured} for one validated check."""
    p = check["probe"]
    try:
        if p["kind"] == "cmd":
            r = measure_cmd(p, cwd)
        elif p["kind"] == "http":
            r = measure_http(p)
        else:
            r = measure_runner(p, check["metric"], cwd, monitor_cmd)[check["metric"]]   # validated: in the list
    except Exception as e:              # fail closed: a probe bug is unmeasured, never a pass
        r = _unmeasured("the probe failed: " + type(e).__name__)
    if r["value"] is None or not _is_num(r["value"]):
        r["value"] = None
        r["status"] = "unmeasured"
    else:
        r["status"] = "ok" if passes(r["value"], check["op"], check["threshold"]) else "breach"
    return r


def cap_problem(n):
    return None if n <= MAX_PROBES_PER_RUN else (
        f"this run would measure {n} checks: the probe cap is {MAX_PROBES_PER_RUN} per run (MAX_PROBES_PER_RUN)")


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
