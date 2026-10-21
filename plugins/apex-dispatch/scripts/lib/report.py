#!/usr/bin/env python3
"""apex-dispatch report: summarise one state dir's ledger (python3 stdlib).

  report.py ROOT --state DIR [--plan PLAN] [--json]
            [--compare [--baseline-state DIR]] [--decision] [--per-task [--transcript PATH]...]

Counts routes by class, tier, provider and route_mode; spawn_request, spawn and
worker_run rows; verdicts; escalations by rung. Estimated USD is real usage x
the policy's tier price table, only for rows that carry `usage` and a
`resolved_model` (or `model_resolved`) naming a known family (haiku, sonnet,
opus, fable); rows with usage but no resolved model go to the "unverified"
bucket, which is printed separately and excluded from USD (spec §5.1
post-agent). Non-Claude workers are priced only when they carry `usd`.

--compare (spec §10): one row per routed task (plan line, else ad-hoc route
id), put in an arm by its first route's route_mode: `routed` (table, decision,
escalated) or `baseline` (baseline, and shadow: the baseline route was applied,
the routed choice is only the counterfactual in `table_choice`). Per arm:
tasks, spawns, estimated USD (per task and per solved task, solved = the last
verdict is APPROVE), tier mix, review rounds (distinct heads reviewed), the
approval rate and first-round approval rate, the escalation rate and p50
wall-clock; the same per class (the table's class, which both arms record);
and routed-minus-baseline deltas. With --baseline-state DIR the baseline arm
comes from that ledger (a baseline run of the same plan). An arm below the
pre-registered minimum (MIN_N tasks, ADR-0001) is reported as insufficient.

--decision (spec §4, §10): over route rows that called the decision layer
(${APEX_DECIDE_CMD}; route.decision.backend not none) and decision_shadow rows:
what the decision said (class, calibrated, uncertain, max p, fallback) against
what routing did (router.class; table_choice.class in baseline/shadow), the
agreement rate overall, by calibration and by confidence bucket, how often the
decision moved the route (route_mode decision), and the approval rate of the
tasks where they agreed vs disagreed. No such rows: "no decision data".

--per-task (ADR-0002 R7): one entry per routed task from tasks_of(): spawns, tokens,
delegated USD (the same row_usd prices as the aggregate), review rounds and outcome
(the last verdict). USD and tokens are null / n/a, never 0, when nothing was measured,
a row could not be priced, an agent of the task was never measured (a spawn with no
usage-bearing worker_run of its agent_id, e.g. a background agent, or a post-agent
"usage unverified" advisory), or a ledger line did not parse or is not an object (counted
and warned; the unrouted figure is then n/a too). Totals: the known tasks' USD, the priced
part inside the n/a tasks, and the USD on rows outside any task, which together reconcile
with REPORT_USD_ESTIMATED. Not combinable with --compare or --decision (exit 2).

Orchestrator cost (ADR-0002 R7b, Q5; --per-task only): the main session's own tokens and
USD per task, from Claude Code session transcripts (JSONL, read only). The per-task
`usd` / `tokens` / `tokens_total` stay delegated-only; the orchestrator figures are the
separate keys `orchestrator_usd`, `orchestrator_tokens`, `orchestrator_tokens_total`,
`orchestrator_turns`. Rules:
  * Transcripts: `--transcript PATH`, repeatable (a missing file is a usage error, exit 2).
    Without it the transcript is auto-located: for each session_id found on any ledger row,
    `<config>/projects/<slug>/<session_id>.jsonl`, where <config> is $CLAUDE_CONFIG_DIR or
    ~/.claude and <slug> is the state's repository path (the checkpoint's worktree, else the
    cwd) with every non-alphanumeric character turned into `-`. No file found (or no ledger
    row carries a session_id): the orchestrator figures are null / n/a, never 0.
  * Turns: only lines with type "assistant" count; every other type (user, summary, system,
    attachments) is ignored without being counted. `isSidechain: true` turns are subagent
    work, i.e. delegated cost already in the ledger: excluded, counted as sidechain_turns.
    A line that is not a JSON object, or an assistant turn with an unparseable timestamp or
    unusable usage (no counts, a non-numeric or negative count), is `skipped`, counted and
    warned, never priced as 0. Lines sharing a message.id are one API message (the transcript
    writes one line per content block): the last one counts, the rest are deduped.
  * Usage keys map input_tokens/output_tokens/cache_read_input_tokens/
    cache_creation_input_tokens -> input/output/cache_read/cache_write, priced by row_usd
    (message.model as resolved_model). A turn whose model is not a priced family makes its
    task's orchestrator_usd null (tokens stay known); a zero-token turn costs 0.
  * Task window: from the task's first route row's ts to its last ledger row's ts (every row
    of its routes, tasks_of), inclusive, to the end of that last second (ledger ts has 1 s
    resolution). A turn belongs to the task whose window contains its timestamp. A turn in no
    window, or in two or more (overlapping plans in one session, ADR-0002 Consequences), goes
    to the `unattributed` bucket (orchestrator_unattributed_usd / _tokens / _turns). A task or
    window whose timestamps do not parse makes its figures, and the unattributed bucket, null.
  * Totals: orchestrator_usd (sum over tasks with a known figure; null when none),
    orchestrator_usd_unknown_tasks, orchestrator_unattributed_*, transcript_skipped,
    transcript_sidechain_turns, transcripts (the paths read).
`usd_unrouted` (delegated ledger rows outside any task) is a different thing from the
orchestrator `unattributed` bucket (main-session turns outside every task window).

Decision calls (decision-layer spec §11.2 item 7) are priced in their own bucket,
never in REPORT_USD_ESTIMATED: the rows of apex-decision-layer's decision log
(<state-base>/decisions/decisions.jsonl, beside this state dir) whose decision_id
this ledger references (route.decision.decision_id, decision_shadow rows), plus
their shadow answers (shadow_of). usage.cost is used when the backend reported it,
or estimated it (cost_estimated); jev usage without a cost is priced at the
configured $0.042 per million input tokens; anything else is unpriced.
"""
import sys

sys.dont_write_bytecode = True

import calendar  # noqa: E402
import collections  # noqa: E402
import datetime  # noqa: E402
import json  # noqa: E402
import math  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ledger  # noqa: E402

SPAWNS = ("spawn_request", "spawn", "worker_run")
MIN_N = 20                   # pre-registered minimum tasks per arm (ADR-0001, spec §10)
ROUTED_MODES = ("table", "decision", "escalated")
BASELINE_MODES = ("baseline", "shadow")
P_BUCKETS = ((0.0, 0.5, "<0.5"), (0.5, 0.8, "0.5-0.8"), (0.8, 1.01, ">=0.8"))
TOKEN_KEYS = ("input", "output", "cache_read", "cache_write")
FAMILIES = ("haiku", "sonnet", "opus", "fable")
DECISION_PRICE = {"jev": (0.042, 0.0)}   # $ per million input / output tokens (decision-layer spec §6.4)


def prices(root):
    """Tier prices from the overlay-merged policy (compile.runtime_policy, the
    same merge route.py reads); the compiled default only if the merge fails."""
    try:
        import compile as policy_compiler  # scripts/lib/compile.py, not the builtin
        pol = policy_compiler.runtime_policy(root)
    except Exception as e:  # an invalid overlay: report still runs, and says so
        print("report: warning: merged policy unavailable (%s); using the compiled default prices" % e, file=sys.stderr)
        pol = ledger.read_json(os.path.join(root, "resources", "compiled", "policy.json"), {}) or {}
    out = {}
    for t in sorted(pol.get("tiers", []), key=lambda x: x.get("rank", 0)):
        out.setdefault(t.get("model"), t.get("price_usd_per_mtok") or {})
    return out


def family(model):
    m = str(model or "").lower()
    for f in FAMILIES:
        if f in m:
            return f
    return None


def _num(x):
    """A finite number (bool, NaN and Infinity are not)."""
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)


def usage_tokens(u):
    """{key: count} from a usage dict, or None when it carries no usable count or any
    present count is not a finite number (a partial figure must not pass as known)."""
    if not isinstance(u, dict):
        return None
    out = {}
    for k in TOKEN_KEYS:
        v = u.get(k)
        if v is None:
            continue
        if not _num(v):
            return None
        out[k] = v
    return out or None


def row_usd(r, price):
    """(usd or None, unverified?) for one ledger row with usage. The one pricing
    predicate: the aggregate (usage_totals) and the per-task view both use it."""
    u = r.get("usage")
    if not isinstance(u, dict):
        return None, False
    usd = r.get("usd")
    if _num(usd):
        return float(usd), False
    if isinstance(usd, float) or any(u.get(k) is not None and not _num(u.get(k)) for k in TOKEN_KEYS):
        return None, True                    # NaN/Infinity usd or a non-numeric token count: unpriced
    fam = family(r.get("resolved_model") or r.get("model_resolved"))
    if fam is None or fam not in price:
        return None, True
    p = price[fam]
    v = sum(float(u.get(k) or 0) * float(p.get(k) or 0) for k in TOKEN_KEYS) / 1e6
    return (v, False) if math.isfinite(v) else (None, True)


def _ts(s):
    """Epoch seconds (UTC) of a ledger ts, or None."""
    try:
        return float(calendar.timegm(datetime.datetime.strptime(str(s), "%Y-%m-%dT%H:%M:%SZ").timetuple()))
    except ValueError:
        return None


_TS_RE = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?(Z|[+-]\d\d:?\d\d)?$")


def _turn_ts(s):
    """Epoch seconds (UTC, fractions kept) of a transcript timestamp, or None."""
    m = _TS_RE.match(s) if isinstance(s, str) else None
    if not m:
        return None
    try:
        t = calendar.timegm(datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").timetuple())
    except ValueError:
        return None
    t += float(m.group(2)) if m.group(2) else 0.0
    z = m.group(3)
    if z and z != "Z":
        off = int(z[1:3]) * 3600 + int(z[-2:]) * 60
        t -= off if z[0] == "+" else -off
    return t


def _route_key(r):
    line = ledger._route_line(r)
    return ("line", line) if line is not None else ("route", r.get("route_id"))


def _is_unverified_advisory(r):
    """post-agent.sh's row for an Agent that returned without resolvedModel or usage (a
    background launch): no worker_run follows, so that agent's usage is never measured."""
    return (r.get("event") == "hook_advisory" and r.get("hook") == "post-agent.sh"
            and "usage unverified" in str(r.get("advisory") or ""))


def task_of_row(r, route_task):
    """The task key of a row (its route, or the route it escalated from), else None."""
    return route_task.get(r.get("route_id")) or route_task.get(r.get("prior_route_id"))


def tasks_of(rows, price, route_task=None, windows=None):
    """One dict per routed task with its arm, class, tier and outcome metrics. Pass a
    dict as route_task to get the route_id -> task key map back, and a list as windows to get
    one (first route ts, last row ts) in epoch seconds per returned task, in order (per_task uses both)."""
    tasks = {}
    route_task = {} if route_task is None else route_task
    for r in rows:
        if r.get("event") != "route":
            continue
        key = _route_key(r)
        router = r.get("router") or {}
        tc = r.get("table_choice") if isinstance(r.get("table_choice"), dict) else {}
        t = tasks.get(key)
        if t is None:
            mode = r.get("route_mode")
            t = tasks[key] = {"task": key[1], "route_mode": mode,
                              "arm": "baseline" if mode in BASELINE_MODES else ("routed" if mode in ROUTED_MODES else None),
                              "class": tc.get("class") or router.get("class"), "tier": router.get("tier"),
                              "counterfactual": {"class": tc.get("class"), "tier": tc.get("tier")} if tc else None,
                              "routes": [], "agents": set(), "usd": 0.0, "unpriced_rows": 0, "verdicts": [],
                              "escalations": 0, "modes": set(), "tokens": collections.Counter(), "token_rows": 0,
                              "no_usage_runs": 0, "priced_rows": 0, "measured_agents": set(), "unverified_advisories": 0,
                              "t0": _ts(r.get("ts")), "t1": _ts(r.get("ts"))}
        t["routes"].append(r.get("route_id"))
        t["modes"].add(r.get("route_mode"))
        if r.get("route_mode") in ROUTED_MODES:
            t["tier"] = router.get("tier")          # the last routed rung is the tier the task ended on
        route_task[r.get("route_id")] = key
    for r in rows:
        key = task_of_row(r, route_task)
        if key is None:
            continue
        t = tasks[key]
        ts = _ts(r.get("ts"))
        if ts is not None:
            t["t1"] = max(t["t1"] or ts, ts)
        ev = r.get("event")
        # One agent = one spawn: an in-session agent writes spawn_request + spawn +
        # worker_run (hook), so it is counted by its `spawn` row; a shim run has
        # only its worker_run (source shim).
        if ev == "spawn":
            t["agents"].add(("agent", r.get("agent_id") or r.get("seq")))
        elif ev == "worker_run" and r.get("source") == "shim":
            t["agents"].add(("shim", r.get("run_id") or r.get("seq")))
        if ev == "verdict":
            t["verdicts"].append((r.get("head_sha"), r.get("verdict")))
        elif ev == "escalate":
            t["escalations"] += 1
        usd, unv = row_usd(r, price)
        if usd is not None:
            t["usd"] += usd
            t["priced_rows"] += 1
        u = r.get("usage")
        tok = usage_tokens(u)
        if tok is not None:
            t["tokens"].update(tok)
            t["token_rows"] += 1
            if ev == "worker_run" and isinstance(r.get("agent_id"), str):
                t["measured_agents"].add(r["agent_id"])   # this agent's usage was recorded
        elif ev == "worker_run" or isinstance(u, dict):
            t["no_usage_runs"] += 1                       # no usage, or usage with no usable count
        if _is_unverified_advisory(r):
            t["unverified_advisories"] += 1
        # Unpriced: usage without a priceable model (provider-default, ollama/...),
        # or a shim run that reported no usage at all (aider). Never counted as $0.
        if unv or (ev == "worker_run" and usd is None):
            t["unpriced_rows"] += 1
    out = []
    for t in tasks.values():
        heads = []
        for h, _ in t["verdicts"]:
            if h not in heads:
                heads.append(h)
        first = [v for h, v in t["verdicts"] if heads and h == heads[0]]
        approved = bool(t["verdicts"]) and t["verdicts"][-1][1] == "APPROVE"
        t["last_verdict"] = t["verdicts"][-1][1] if t["verdicts"] else None
        arms = {"baseline" if m in BASELINE_MODES else "routed" for m in t["modes"] if m in BASELINE_MODES + ROUTED_MODES}
        # An in-session agent (a `spawn` row) whose usage no worker_run of this task carries (matched by
        # agent_id; a spawn without one cannot be matched) was never measured, nor was an agent behind a
        # post-agent "usage unverified" advisory. per_task makes such a task's USD and tokens n/a. The
        # advisory carries no agent_id, so a background agent shows up as both: the count is a lower bound.
        # (--compare's arm_stats reads unpriced_rows only and is unchanged.)
        t["unmeasured_agents"] = max(sum(1 for kind, aid in t["agents"] if kind == "agent" and aid not in t["measured_agents"]),
                                     t["unverified_advisories"])
        t.update({"review_rounds": len(heads), "reviewed": bool(t["verdicts"]), "approved": approved,
                  "first_round_approved": bool(first) and all(v == "APPROVE" for v in first),
                  # wall-clock only for finished (approved) tasks: an open task has no end
                  "wall_min": round((t["t1"] - t["t0"]) / 60.0, 2) if approved and t["t0"] is not None and t["t1"] is not None else None,
                  "usd": round(t["usd"], 6), "spawns": len(t["agents"]), "mixed_arms": len(arms) > 1})
        if windows is not None:
            windows.append((t["t0"], t["t1"]))
        del t["verdicts"], t["t0"], t["t1"], t["agents"], t["modes"], t["measured_agents"]
        out.append(t)
    return out


def _micro(x):
    return int(round(float(x) * 1e6))


def malformed_rows(state_dir):
    """Ledger lines that are not a JSON object: read_rows skips them silently, so a
    cost view must count them rather than report a total that hides them."""
    path = ledger.ledger_path(state_dir)
    if not os.path.exists(path):
        return 0
    n = 0
    for raw in ledger._iter_lines(path):
        raw = raw.strip()
        if not raw:
            continue
        try:
            ok = isinstance(json.loads(raw.decode("utf-8")), dict)
        except ValueError:
            ok = False
        n += 0 if ok else 1
    return n


TRANSCRIPT_KEYS = (("input_tokens", "input"), ("output_tokens", "output"),
                   ("cache_read_input_tokens", "cache_read"), ("cache_creation_input_tokens", "cache_write"))
_SID_RE = re.compile(r"^[A-Za-z0-9._-]+$")


def project_slug(path):
    """Claude Code's project directory name for a working directory."""
    return re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(path))


def locate_transcripts(state_dir, rows):
    """Auto-locate: <config>/projects/<slug>/<session_id>.jsonl for each session_id on a ledger row."""
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    sids = sorted({r["session_id"] for r in rows if isinstance(r.get("session_id"), str) and _SID_RE.match(r["session_id"])})
    repos = {ledger.state_repo(state_dir), os.getcwd()}
    found = []
    for repo in sorted(repos):
        for sid in sids:
            p = os.path.join(cfg, "projects", project_slug(repo), sid + ".jsonl")
            if os.path.isfile(p) and p not in found:
                found.append(p)
    return found


def read_transcripts(paths):
    """Main-session assistant turns from transcript files: (turns, skipped, sidechain, deduped).
    A turn is {"ts", "model", "usage" (ledger keys), "key"}; see the module docstring for the rules."""
    by_id, anon = {}, []
    skipped = sidechain = deduped = 0
    for path in paths:
        with open(path, "rb") as f:
            for n, raw in enumerate(f):
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    d = json.loads(raw.decode("utf-8"))
                except ValueError:
                    d = None
                if not isinstance(d, dict):
                    skipped += 1
                    continue
                if d.get("type") != "assistant":
                    continue
                if d.get("isSidechain") is True:
                    sidechain += 1
                    continue
                msg = d.get("message") if isinstance(d.get("message"), dict) else {}
                src = msg.get("usage")
                u = {}
                if isinstance(src, dict):
                    u = {lk: src[tk] for tk, lk in TRANSCRIPT_KEYS if src.get(tk) is not None}
                tok = usage_tokens(u)
                ts = _turn_ts(d.get("timestamp"))
                if tok is None or ts is None or any(v < 0 for v in tok.values()):
                    skipped += 1
                    continue
                turn = {"ts": ts, "model": msg.get("model"), "usage": tok}
                mid = msg.get("id")
                if isinstance(mid, str) and mid:
                    deduped += 1 if mid in by_id else 0
                    by_id[mid] = turn
                else:
                    anon.append(turn)
    return list(by_id.values()) + anon, skipped, sidechain, deduped


def _turn_usd(turn, price):
    """USD of one turn through row_usd, or None when its model cannot be priced (0 tokens cost 0)."""
    if not any(turn["usage"].values()):
        return 0.0
    usd, _ = row_usd({"usage": turn["usage"], "resolved_model": turn["model"]}, price)
    return usd


def orchestrator(turns, windows, price):
    """Attribute turns to task windows. Returns (per-task list parallel to windows, unattributed)."""
    per = [{"turns": 0, "tokens": collections.Counter(), "micro": 0, "unpriced": 0} for _ in windows]
    un = {"turns": 0, "tokens": collections.Counter(), "micro": 0, "unpriced": 0}
    for t in turns:
        hits = [i for i, (a, b) in enumerate(windows) if a is not None and b is not None and a <= t["ts"] < b + 1]
        bucket = per[hits[0]] if len(hits) == 1 else un
        usd = _turn_usd(t, price)
        bucket["turns"] += 1
        bucket["tokens"].update(t["usage"])
        if usd is None:
            bucket["unpriced"] += 1
        else:
            bucket["micro"] += _micro(usd)
    return per, un


def _orch_fields(o, usable):
    """Per-task orchestrator keys; all null (n/a) with no transcript or an unusable window."""
    if o is None or not usable:
        return {"orchestrator_tokens": None, "orchestrator_tokens_total": None, "orchestrator_usd": None,
                "orchestrator_turns": None, "orchestrator_unpriced_turns": None}
    tok = {k: o["tokens"].get(k, 0) for k in TOKEN_KEYS}
    return {"orchestrator_tokens": tok, "orchestrator_tokens_total": sum(tok.values()),
            "orchestrator_usd": None if o["unpriced"] else o["micro"] / 1e6, "orchestrator_turns": o["turns"],
            "orchestrator_unpriced_turns": o["unpriced"]}


def _orch_totals(out, oun, paths, wok, skipped, sidechain, deduped):
    if not paths:
        return {"orchestrator_usd": None, "orchestrator_usd_unknown_tasks": None, "orchestrator_unattributed_usd": None,
                "orchestrator_unattributed_tokens": None, "orchestrator_unattributed_turns": None,
                "transcript_skipped": None, "transcript_sidechain_turns": None, "transcript_deduped": None,
                "transcripts": [], "orchestrator_status": "n/a (no transcript: pass --transcript PATH, or the ledger has no "
                                                         "session_id whose transcript is under ~/.claude/projects)"}
    known = [x for x in out if x["orchestrator_usd"] is not None]
    un_ok = wok and oun["unpriced"] == 0
    return {"orchestrator_usd": round(sum(_micro(x["orchestrator_usd"]) for x in known) / 1e6, 6) if known else None,
            "orchestrator_usd_unknown_tasks": len(out) - len(known),
            "orchestrator_unattributed_usd": oun["micro"] / 1e6 if un_ok else None,
            "orchestrator_unattributed_tokens": sum(oun["tokens"].values()) if wok else None,
            "orchestrator_unattributed_turns": oun["turns"] if wok else None,
            "transcript_skipped": skipped, "transcript_sidechain_turns": sidechain, "transcript_deduped": deduped,
            "transcripts": paths, "orchestrator_status": "measured" if wok else "n/a (a task window has an unparseable timestamp)"}


def per_task(root, state_dir, plan=None, transcripts=None):
    """One entry per routed task (tasks_of), delegated cost only. usd / tokens are
    None (n/a, never 0) when nothing was measured, when a row of the task could not be
    priced (usage without a priceable model, a shim run with no usage), when an agent of
    the task was never measured (a spawned agent with no usage-bearing worker_run of the
    same agent_id, e.g. a background agent; a post-agent "usage unverified" advisory), or
    when the ledger has lines that did not parse or are not objects (they may be the
    missing usage rows; usd_unrouted is then None too). The aggregate is computed from the
    same rows (usage_totals), so totals.usd + totals.usd_partial_in_unknown_tasks +
    totals.usd_unrouted reconciles with usd_estimated. Orchestrator figures: see the module
    docstring; `transcripts` is the explicit list of paths (None: auto-locate)."""
    ok, rows, msg = ledger.verify(state_dir)
    if not ok:
        rows = ledger.read_rows(state_dir)
    bad = malformed_rows(state_dir)
    rows = [r for r in rows if isinstance(r, dict)]
    price = prices(root)
    route_task = {}
    out = []
    windows = []
    tlist = tasks_of(rows, price, route_task, windows)
    paths = list(transcripts) if transcripts else locate_transcripts(state_dir, rows)
    turns, skipped, sidechain, deduped = read_transcripts(paths) if paths else ([], None, None, None)
    wok = all(a is not None and b is not None for a, b in windows)
    oper, oun = orchestrator(turns, windows, price) if paths else ([None] * len(windows), None)
    for t, o in zip(tlist, oper):
        known = not bad and not t["unmeasured_agents"]
        usd_ok = known and not t["unpriced_rows"] and t["priced_rows"] > 0
        tok_ok = known and not t["no_usage_runs"] and t["token_rows"] > 0
        tokens = {k: t["tokens"].get(k, 0) for k in TOKEN_KEYS} if tok_ok else None
        out.append({"task": t["task"], "class": t["class"], "tier": t["tier"], "route_mode": t["route_mode"],
                    "routes": t["routes"], "spawns": t["spawns"],
                    "tokens": tokens, "tokens_total": sum(tokens.values()) if tokens else None,
                    "usd": t["usd"] if usd_ok else None, "usd_priced_partial": t["usd"],
                    "unpriced_rows": t["unpriced_rows"], "unmeasured_agents": t["unmeasured_agents"],
                    "review_rounds": t["review_rounds"],
                    "escalations": t["escalations"], "approved": t["approved"],
                    "outcome": t["last_verdict"] or "no-verdict", **_orch_fields(o, paths and wok)})
    agg = usage_totals(rows, price)
    known = sum(_micro(x["usd"]) for x in out if x["usd"] is not None)
    partial = sum(_micro(x["usd_priced_partial"]) for x in out if x["usd"] is None)
    # priced cost on rows that belong to no routed task, summed row by row (not the aggregate minus the tasks')
    unrouted = 0
    for r in rows:
        if task_of_row(r, route_task) is None:
            usd, _ = row_usd(r, price)
            unrouted += _micro(usd) if usd is not None else 0
    return {"state": state_dir, "plan": plan, "chain": {"ok": ok, "message": msg, "rows": len(rows)},
            "malformed_rows": bad, "usd_estimated": agg["usd_estimated"], "tokens": agg["tokens"],
            "unverified": agg["unverified"]["count"],
            "tasks": out,
            "totals": {"tasks": len(out), "usd": round(known / 1e6, 6) if any(x["usd"] is not None for x in out) else None,
                       "usd_unknown_tasks": sum(1 for x in out if x["usd"] is None),
                       # the priced part of the n/a tasks (a lower bound on their cost, not a figure for them)
                       "usd_partial_in_unknown_tasks": round(partial / 1e6, 6),
                       "usd_unrouted": None if bad else round(unrouted / 1e6, 6),
                       **_orch_totals(out, oun, paths, wok, skipped, sidechain, deduped)}}


def _usd4(v):
    return "n/a" if v is None else "%.4f" % v


def print_per_task(p):
    print("REPORT_STATE: %s" % p["state"])
    if p["plan"]:
        print("REPORT_PLAN: %s" % p["plan"])
    print("REPORT_CHAIN: %s — %s" % ("OK" if p["chain"]["ok"] else "BROKEN", p["chain"]["message"]))
    if p["malformed_rows"]:
        print("REPORT_TASK_WARNING: %d ledger line(s) did not parse; per-task USD and tokens are n/a" % p["malformed_rows"])
    for x in p["tasks"]:
        tid = "L%d" % x["task"] if isinstance(x["task"], int) else x["task"]
        print("REPORT_TASK: task=%s class=%s tier=%s spawns=%d tokens=%s usd=%s review_rounds=%d outcome=%s "
              "orchestrator_tokens=%s orchestrator_usd=%s"
              % (tid, x["class"], x["tier"], x["spawns"], "n/a" if x["tokens_total"] is None else x["tokens_total"],
                 _usd4(x["usd"]), x["review_rounds"], x["outcome"],
                 "n/a" if x["orchestrator_tokens_total"] is None else x["orchestrator_tokens_total"], _usd4(x["orchestrator_usd"])))
    t = p["totals"]
    print("REPORT_TASKS_TOTAL: %d task(s); usd=%s (%d n/a, %.4f priced in them); aggregate REPORT_USD_ESTIMATED %.4f, "
          "of which %s on rows outside any task"
          % (t["tasks"], _usd4(t["usd"]), t["usd_unknown_tasks"], t["usd_partial_in_unknown_tasks"], p["usd_estimated"],
             _usd4(t["usd_unrouted"])))
    if t["orchestrator_status"] != "measured":
        print("REPORT_ORCHESTRATOR: %s" % t["orchestrator_status"])
        return
    print("REPORT_ORCHESTRATOR: usd=%s (%d task(s) n/a); unattributed (main-session turns in no single task window; "
          "not usd_unrouted) usd=%s tokens=%s turns=%s; skipped=%d line(s); sidechain turns excluded=%d (delegated, in the ledger); "
          "deduped=%d; transcripts=%s"
          % (_usd4(t["orchestrator_usd"]), t["orchestrator_usd_unknown_tasks"], _usd4(t["orchestrator_unattributed_usd"]),
             "n/a" if t["orchestrator_unattributed_tokens"] is None else t["orchestrator_unattributed_tokens"],
             "n/a" if t["orchestrator_unattributed_turns"] is None else t["orchestrator_unattributed_turns"],
             t["transcript_skipped"], t["transcript_sidechain_turns"], t["transcript_deduped"], ",".join(t["transcripts"])))
    if t["transcript_skipped"]:
        print("REPORT_ORCHESTRATOR_WARNING: %d transcript line(s) were not usable (malformed JSON or unusable usage) and are "
              "not in these figures" % t["transcript_skipped"])


def _median(xs):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    m = len(xs) // 2
    return xs[m] if len(xs) % 2 else round((xs[m - 1] + xs[m]) / 2.0, 4)


def _rate(num, den):
    return round(num / float(den), 4) if den else None


def arm_stats(ts):
    n = len(ts)
    reviewed = [t for t in ts if t["reviewed"]]
    solved = [t for t in ts if t["approved"]]
    usd = sum(t["usd"] for t in ts)
    unpriced = sum(t["unpriced_rows"] for t in ts)
    comparable = unpriced == 0
    return {"tasks": n, "sufficient_n": n >= MIN_N, "spawns": sum(t["spawns"] for t in ts),
            "spawns_per_task": _rate(sum(t["spawns"] for t in ts), n),
            "usd_comparable": comparable, "unpriced_rows": unpriced,
            "usd_estimated": round(usd, 6) if comparable else None,
            "usd_priced_partial": round(usd, 6),
            "usd_per_task": _rate(usd, n) if comparable else None,
            "usd_per_solved_task": _rate(usd, len(solved)) if comparable else None,
            "tiers": dict(collections.Counter(str(t["tier"]) for t in ts)),
            "review_rounds_per_task": _rate(sum(t["review_rounds"] for t in reviewed), len(reviewed)),
            "approval_rate": _rate(len(solved), len(reviewed)),
            "first_round_approval_rate": _rate(sum(1 for t in reviewed if t["first_round_approved"]), len(reviewed)),
            "escalation_rate": _rate(sum(1 for t in ts if t["escalations"]), n),
            "wall_minutes_p50": _median([t["wall_min"] for t in ts])}


def _delta(a, b, k, pct=False):
    x, y = a.get(k), b.get(k)
    if x is None or y is None:
        return None
    if pct:
        return round((x - y) / y * 100.0, 2) if y else None
    return round(x - y, 4)


def compare(root, state_dir, baseline_state=None):
    price = prices(root)
    rows = ledger.read_rows(state_dir)
    ts = tasks_of(rows, price)
    routed = [t for t in ts if t["arm"] == "routed"]
    if baseline_state:
        bts = tasks_of(ledger.read_rows(baseline_state), price)
        base = [t for t in bts if t["arm"] == "baseline"]
        labels = [r.get("label") for r in ledger.read_rows(baseline_state) if r.get("event") == "baseline"]
    else:
        base = [t for t in ts if t["arm"] == "baseline"]
        labels = [r.get("label") for r in rows if r.get("event") == "baseline"]
    a, b = arm_stats(routed), arm_stats(base)
    classes = sorted({str(t["class"]) for t in routed + base})
    by_class = {c: {"routed": arm_stats([t for t in routed if str(t["class"]) == c]),
                    "baseline": arm_stats([t for t in base if str(t["class"]) == c])} for c in classes}
    status = "no baseline data" if not base else ("no routed data" if not routed else
                                                  ("ok" if a["sufficient_n"] and b["sufficient_n"] else "insufficient n"))
    usd_status = "ok" if a["usd_comparable"] and b["usd_comparable"] else (
        "not comparable (unpriced or unverified usage rows: routed %d, baseline %d)" % (a["unpriced_rows"], b["unpriced_rows"]))
    mixed = sorted(str(t["task"]) for t in ts if t["mixed_arms"])
    warnings = (["plan line(s) %s have both baseline and routed routes in this ledger; each task counts in the arm of its "
                 "first route" % ", ".join(mixed)] if mixed else [])
    ok, _, msg = ledger.verify(state_dir)
    return {"status": status, "usd_status": usd_status, "warnings": warnings, "min_n": MIN_N,
            "chain": {"ok": ok, "message": msg}, "baseline_labels": labels, "baseline_state": baseline_state or state_dir,
            "routed": a, "baseline": b, "by_class": by_class,
            "shadow_counterfactuals": dict(collections.Counter(
                "%s/%s" % (t["counterfactual"].get("class"), t["counterfactual"].get("tier"))
                for t in base if t.get("route_mode") == "shadow" and t.get("counterfactual"))),
            "delta_routed_minus_baseline": {
                "usd_per_solved_task_pct": _delta(a, b, "usd_per_solved_task", pct=True),
                "usd_per_task_pct": _delta(a, b, "usd_per_task", pct=True),
                "spawns_per_task": _delta(a, b, "spawns_per_task"),
                "review_rounds_per_task": _delta(a, b, "review_rounds_per_task"),
                "approval_rate_pts": None if _delta(a, b, "approval_rate") is None else round(_delta(a, b, "approval_rate") * 100, 2),
                "first_round_approval_rate_pts": None if _delta(a, b, "first_round_approval_rate") is None
                else round(_delta(a, b, "first_round_approval_rate") * 100, 2),
                "escalation_rate_pts": None if _delta(a, b, "escalation_rate") is None else round(_delta(a, b, "escalation_rate") * 100, 2)},
            "tasks": ts}


def _bucket(p):
    if not isinstance(p, (int, float)):
        return "unknown"
    for lo, hi, name in P_BUCKETS:
        if lo <= p < hi:
            return name
    return "unknown"


def decision(root, state_dir):
    rows = ledger.read_rows(state_dir)
    price = prices(root)
    outcome = {}
    for t in tasks_of(rows, price):
        for rid in t["routes"]:
            outcome[rid] = t
    items = []
    for r in rows:
        if r.get("event") == "route":
            d = r.get("decision") if isinstance(r.get("decision"), dict) else {}
            if not d or d.get("backend") in (None, "none"):
                continue
            router = r.get("router") or {}
            tc = r.get("table_choice") if isinstance(r.get("table_choice"), dict) else {}
            routed_cls = tc.get("class") if r.get("route_mode") in BASELINE_MODES else router.get("class")
            said = d.get("verdict") if d.get("verdict") is not None else r.get("decision_choice")
            t = outcome.get(r.get("route_id")) or {}
            items.append({"route_id": r.get("route_id"), "source": "route", "route_mode": r.get("route_mode"),
                          "backend": d.get("backend"), "decision_id": d.get("decision_id"), "decision_class": said,
                          "routed_class": routed_cls, "calibrated": d.get("calibrated") is True,
                          "uncertain": d.get("uncertain") is True, "max_p": d.get("max_p"), "fallback": d.get("fallback"),
                          "moved_route": r.get("route_mode") == "decision", "agree": said is not None and said == routed_cls,
                          "table_class": tc.get("class"),
                          "agree_with_table": (said == tc.get("class")) if said is not None and tc.get("class") else None,
                          "approved": t.get("approved") if t.get("reviewed") else None})
        elif r.get("event") == "decision_shadow":
            said, det = r.get("decision_choice"), r.get("deterministic_choice")
            items.append({"route_id": r.get("route_id"), "source": "decision_shadow", "route_mode": r.get("route_mode"),
                          "backend": r.get("backend"), "decision_id": r.get("decision_id"), "decision_class": said,
                          "routed_class": det, "calibrated": r.get("calibrated") is True, "uncertain": r.get("uncertain") is True,
                          "max_p": r.get("max_p"), "fallback": r.get("fallback"), "moved_route": False,
                          "agree": said is not None and said == det, "table_class": det,
                          "agree_with_table": (said == det) if said is not None and det else None, "approved": None})
    if not items:
        return {"status": "no decision data", "rows": 0,
                "note": "no route row called the decision layer (${APEX_DECIDE_CMD} unset, absent or timed out: "
                        "routing was table-only) and no decision_shadow rows"}

    def agg(xs):
        ag = [x for x in xs if x["decision_class"] is not None]
        return {"n": len(xs), "agreement_rate": _rate(sum(1 for x in ag if x["agree"]), len(ag))}
    by_bucket = collections.defaultdict(list)
    for x in items:
        by_bucket[_bucket(x["max_p"])].append(x)
    oc = [x for x in items if x["approved"] is not None]
    wt = [x for x in items if x["agree_with_table"] is not None]
    return {"status": "ok", "rows": len(items),
            "agreement": agg(items),
            "agreement_with_table": {"n": len(wt), "agreement_rate": _rate(sum(1 for x in wt if x["agree_with_table"]), len(wt))},
            "by_calibration": {"calibrated": agg([x for x in items if x["calibrated"]]),
                               "uncalibrated": agg([x for x in items if not x["calibrated"]])},
            "by_confidence": {k: agg(v) for k, v in sorted(by_bucket.items())},
            "uncertain": sum(1 for x in items if x["uncertain"]),
            "moved_route": sum(1 for x in items if x["moved_route"]),
            "fallbacks": dict(collections.Counter(str(x["fallback"]) for x in items if x["fallback"])),
            "backends": dict(collections.Counter(str(x["backend"]) for x in items)),
            "approval_when_agree": _rate(sum(1 for x in oc if x["agree"] and x["approved"]), sum(1 for x in oc if x["agree"])),
            "approval_when_disagree": _rate(sum(1 for x in oc if not x["agree"] and x["approved"]),
                                            sum(1 for x in oc if not x["agree"])),
            "items": items}


def _f(v, pct=False):
    if v is None:
        return "-"
    return ("%.1f%%" % (v * 100)) if pct else ("%s" % v)


def print_compare(c):
    print("REPORT_COMPARE: %s (min n %d per arm; baseline labels: %s)" % (c["status"], c["min_n"],
                                                                        ", ".join(str(x) for x in c["baseline_labels"]) or "none"))
    for arm in ("routed", "baseline"):
        a = c[arm]
        usd = ("usd=%.4f usd/task=%s usd/solved=%s" % (a["usd_estimated"], _f(a["usd_per_task"]), _f(a["usd_per_solved_task"]))
               if a["usd_comparable"] else "usd=not comparable (%d unpriced/unverified row(s); priced part $%.4f)"
               % (a["unpriced_rows"], a["usd_priced_partial"]))
        print("REPORT_COMPARE_%s: tasks=%d spawns=%d spawns/task=%s %s tiers=%s "
              "review_rounds/task=%s approval=%s first_round=%s escalation=%s wall_p50_min=%s"
              % (arm.upper(), a["tasks"], a["spawns"], _f(a["spawns_per_task"]), usd, fmt_counter(a["tiers"]), _f(a["review_rounds_per_task"]),
                 _f(a["approval_rate"], True), _f(a["first_round_approval_rate"], True), _f(a["escalation_rate"], True),
                 _f(a["wall_minutes_p50"])))
    d = c["delta_routed_minus_baseline"]
    print("REPORT_COMPARE_USD: %s" % c["usd_status"])
    print("REPORT_COMPARE_DELTA: " + ", ".join("%s=%s" % (k, "not comparable" if k.startswith("usd") and c["usd_status"] != "ok"
                                                           else _f(v)) for k, v in sorted(d.items())))
    for w in c["warnings"]:
        print("REPORT_COMPARE_WARNING: %s" % w)
    for cls, v in sorted(c["by_class"].items()):
        print("REPORT_COMPARE_CLASS: %s routed=%d (usd/solved %s, approval %s) baseline=%d (usd/solved %s, approval %s)"
              % (cls, v["routed"]["tasks"], _f(v["routed"]["usd_per_solved_task"]), _f(v["routed"]["approval_rate"], True),
                 v["baseline"]["tasks"], _f(v["baseline"]["usd_per_solved_task"]), _f(v["baseline"]["approval_rate"], True)))
    if c["shadow_counterfactuals"]:
        print("REPORT_COMPARE_SHADOW_ROUTED_CHOICE: %s" % fmt_counter(c["shadow_counterfactuals"]))


def print_decision(d):
    if d["status"] != "ok":
        print("REPORT_DECISION: %s (%s)" % (d["status"], d["note"]))
        return
    print("REPORT_DECISION: %d row(s); agreement %s; moved the route %d; uncertain %d; backends %s"
          % (d["rows"], _f(d["agreement"]["agreement_rate"], True), d["moved_route"], d["uncertain"], fmt_counter(d["backends"])))
    print("REPORT_DECISION_TABLE: agreement with the table's own class %s (n=%d; the table's choice is recorded on "
          "decision-mode, baseline and shadow route rows)" % (_f(d["agreement_with_table"]["agreement_rate"], True),
                                                                d["agreement_with_table"]["n"]))
    print("REPORT_DECISION_CALIBRATION: calibrated n=%d agreement %s; uncalibrated n=%d agreement %s"
          % (d["by_calibration"]["calibrated"]["n"], _f(d["by_calibration"]["calibrated"]["agreement_rate"], True),
             d["by_calibration"]["uncalibrated"]["n"], _f(d["by_calibration"]["uncalibrated"]["agreement_rate"], True)))
    print("REPORT_DECISION_CONFIDENCE: " + ", ".join("p%s n=%d agreement %s" % (k, v["n"], _f(v["agreement_rate"], True))
                                                     for k, v in sorted(d["by_confidence"].items())))
    print("REPORT_DECISION_FALLBACKS: %s" % fmt_counter(d["fallbacks"]))
    print("REPORT_DECISION_OUTCOME: approval when agreeing %s, when disagreeing %s"
          % (_f(d["approval_when_agree"], True), _f(d["approval_when_disagree"], True)))
    for x in d["items"]:
        print("REPORT_DECISION_ROW: route=%s said=%s routed=%s calibrated=%s uncertain=%s max_p=%s fallback=%s %s"
              % (x["route_id"], x["decision_class"], x["routed_class"], x["calibrated"], x["uncertain"], x["max_p"],
                 x["fallback"] or "-", "agree" if x["agree"] else "DISAGREE"))


def decision_log_path(state_dir):
    return os.path.join(os.path.dirname(os.path.realpath(state_dir)), "decisions", "decisions.jsonl")


def decision_cost(state_dir, rows, log_path=None):
    """The decision bucket: calls and USD from the decision log, joined on decision_id."""
    path = log_path or decision_log_path(state_dir)
    ids = set()
    for r in rows:
        if r.get("event") == "route" and isinstance(r.get("decision"), dict) and r["decision"].get("decision_id"):
            ids.add(r["decision"]["decision_id"])
        elif r.get("event") == "decision_shadow" and r.get("decision_id"):
            ids.add(r["decision_id"])
    out = {"log": path, "calls": 0, "shadow_calls": 0, "usd_reported": 0.0, "usd_estimated": 0.0, "unpriced": 0,
           "by_backend": {}, "status": "ok"}
    if not os.path.exists(path):
        out["status"] = "no decision log"
        return out
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
    except OSError as e:
        out["status"] = "unreadable: %s" % e
        return out
    by = collections.defaultdict(lambda: {"calls": 0, "usd": 0.0})
    for line in lines:
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if not isinstance(d, dict) or not (d.get("decision_id") in ids or d.get("shadow_of") in ids):
            continue
        out["shadow_calls" if d.get("shadow_of") else "calls"] += 1
        b = str(d.get("backend"))
        by[b]["calls"] += 1
        u = d.get("usage") if isinstance(d.get("usage"), dict) else {}
        cost = u.get("cost")
        if isinstance(cost, (int, float)) and not isinstance(cost, bool):
            out["usd_estimated" if u.get("cost_estimated") else "usd_reported"] += float(cost)
            by[b]["usd"] += float(cost)
        elif b in DECISION_PRICE and isinstance(u.get("input_tokens"), (int, float)):
            pi, po = DECISION_PRICE[b]
            c = (float(u["input_tokens"]) * pi + float(u.get("output_tokens") or 0) * po) / 1e6
            out["usd_estimated"] += c
            by[b]["usd"] += c
        elif u:
            out["unpriced"] += 1
    out["usd_reported"] = round(out["usd_reported"], 8)
    out["usd_estimated"] = round(out["usd_estimated"], 8)
    out["by_backend"] = {k: {"calls": v["calls"], "usd": round(v["usd"], 8)} for k, v in sorted(by.items())}
    return out


def usage_totals(rows, price):
    """Tokens, estimated USD (row_usd) and the unverified bucket over ledger rows."""
    usd, priced, unverified, tokens = 0.0, 0, [], collections.Counter()
    for r in rows:
        if not isinstance(r.get("usage"), dict):
            continue
        tokens.update(usage_tokens(r["usage"]) or {})
        v, unv = row_usd(r, price)
        if v is not None:
            usd += v
            priced += 1
        elif unv:
            unverified.append({"seq": r.get("seq"), "event": r.get("event"), "route_id": r.get("route_id"),
                               "model": r.get("model"), "provider": r.get("provider")})
    return {"tokens": dict(tokens), "usd_estimated": round(usd, 6), "usd_rows_priced": priced,
            "unverified": {"count": len(unverified), "rows": unverified,
                           "note": "usage without a resolved model; excluded from USD"}}


def summarise(root, state_dir, plan=None):
    ok, rows, msg = ledger.verify(state_dir)
    if not ok:
        rows = ledger.read_rows(state_dir)
    rows = [r for r in rows if isinstance(r, dict)]
    price = prices(root)
    routes = [r for r in rows if r.get("event") == "route"]
    by = {k: collections.Counter() for k in ("class", "tier", "provider", "mode")}
    for r in routes:
        router = r.get("router") or {}
        by["class"][str(router.get("class"))] += 1
        by["tier"][str(router.get("tier"))] += 1
        by["provider"][str(router.get("provider"))] += 1
        by["mode"][str(r.get("route_mode"))] += 1
    spawns = collections.Counter(r["event"] for r in rows if r.get("event") in SPAWNS)
    verdicts = collections.Counter(str(r.get("verdict")) for r in rows if r.get("event") == "verdict")
    escal = collections.Counter(str(r.get("rung")) for r in rows if r.get("event") == "escalate")
    ut = usage_totals(rows, price)
    return {"state": state_dir, "plan": plan, "chain": {"ok": ok, "message": msg, "rows": len(rows)},
            "routes": {"total": len(routes), "by_class": dict(by["class"]), "by_tier": dict(by["tier"]),
                       "by_provider": dict(by["provider"]), "by_mode": dict(by["mode"])},
            "spawns": dict(spawns), "verdicts": dict(verdicts), "escalations": dict(escal),
            "tokens": ut["tokens"],
            "usd_estimated": ut["usd_estimated"], "usd_rows_priced": ut["usd_rows_priced"],
            "usd_source": "real usage x policy tier prices",
            "unverified": ut["unverified"],
            "human_gates": sum(1 for r in rows if r.get("event") == "human_gate"),
            "hook_errors": sum(1 for r in rows if r.get("event") == "hook_error"),
            "model_mismatches": sum(1 for r in rows if r.get("event") == "model_mismatch"),
            "policy_violations": sum(1 for r in rows if r.get("event") == "policy_violation"),
            "acceptance": provider_acceptance(root, state_dir),
            "decision_cost": decision_cost(state_dir, rows)}


def provider_acceptance(root, state_dir):
    """Rolling acceptance of each external provider seen in the ledgers (spec §10:
    applied ∧ gate PASS ∧ APPROVE for builders; a parsed verdict for reviewers)."""
    try:
        import compile as policy_compiler
        pol = policy_compiler.runtime_policy(root)
    except Exception:
        pol = ledger.read_json(os.path.join(root, "resources", "compiled", "policy.json"), {}) or {}
    try:
        acc = ledger.acceptance(state_dir, pol.get("providers", []))
    except Exception:
        return {}
    return {k: v for k, v in acc.items() if v["decided"] or v["pending"]}


def fmt_counter(d):
    return ", ".join("%s=%s" % (k, v) for k, v in sorted(d.items())) or "none"


def main(argv):
    if not argv:
        print("usage: report.py ROOT --state DIR [--plan PLAN] [--json] "
              "[--compare [--baseline-state DIR]] [--decision] | [--per-task [--transcript PATH]...]", file=sys.stderr)
        return 2
    root, rest = os.path.abspath(argv[0]), argv[1:]
    state = plan = base_state = None
    as_json = do_compare = do_decision = do_per_task = False
    transcripts = []
    i = 0
    while i < len(rest):
        a = rest[i]
        if a in ("--state", "--plan", "--baseline-state", "--transcript") and i + 1 < len(rest):
            if a == "--state":
                state = rest[i + 1]
            elif a == "--plan":
                plan = rest[i + 1]
            elif a == "--transcript":
                transcripts.append(rest[i + 1])
            else:
                base_state = rest[i + 1]
            i += 2
            continue
        if a == "--json":
            as_json = True
        elif a == "--compare":
            do_compare = True
            if i + 1 < len(rest) and rest[i + 1] == "baseline":
                i += 1
        elif a == "--decision":
            do_decision = True
        elif a == "--per-task":
            do_per_task = True
        else:
            print("report: unknown argument %s" % a, file=sys.stderr)
            return 2
        i += 1
    if not state:
        print("usage: report.sh (--state DIR | --plan PLAN) [--json] [--compare [baseline] [--baseline-state DIR]] "
              "[--decision] | [--per-task [--transcript PATH]...]", file=sys.stderr)
        return 2
    if base_state and not do_compare:
        print("report: --baseline-state needs --compare", file=sys.stderr)
        return 2
    if transcripts and not do_per_task:
        print("report: --transcript needs --per-task", file=sys.stderr)
        return 2
    for tp in transcripts:
        if not os.path.isfile(tp):
            print("report: transcript not found: %s" % tp, file=sys.stderr)
            return 2
    if do_per_task:
        if do_compare or do_decision:
            print("report: --per-task cannot be combined with --compare or --decision", file=sys.stderr)
            return 2
        p = per_task(root, state, plan, transcripts)
        if as_json:
            print(json.dumps(p, indent=2, sort_keys=True))
        else:
            print_per_task(p)
        return 0
    if do_compare or do_decision:
        out = {"state": state, "plan": plan}
        if do_compare:
            out["compare"] = compare(root, state, base_state)
        if do_decision:
            out["decision"] = decision(root, state)
        if as_json:
            ok, _, msg = ledger.verify(state)
            out["chain"] = {"ok": ok, "message": msg}
            print(json.dumps(out, indent=2, sort_keys=True))
            return 0
        ok, _, msg = ledger.verify(state)
        out["chain"] = {"ok": ok, "message": msg}
        print("REPORT_STATE: %s" % state)
        print("REPORT_CHAIN: %s — %s" % ("OK" if ok else "BROKEN", msg))
        if do_compare:
            print_compare(out["compare"])
        if do_decision:
            print_decision(out["decision"])
        return 0
    s = summarise(root, state, plan)
    if as_json:
        print(json.dumps(s, indent=2, sort_keys=True))
        return 0
    print("REPORT_STATE: %s" % s["state"])
    if plan:
        print("REPORT_PLAN: %s" % plan)
    print("REPORT_CHAIN: %s — %s" % ("OK" if s["chain"]["ok"] else "BROKEN", s["chain"]["message"]))
    r = s["routes"]
    print("REPORT_ROUTES: %d" % r["total"])
    print("REPORT_ROUTES_BY_CLASS: %s" % fmt_counter(r["by_class"]))
    print("REPORT_ROUTES_BY_TIER: %s" % fmt_counter(r["by_tier"]))
    print("REPORT_ROUTES_BY_PROVIDER: %s" % fmt_counter(r["by_provider"]))
    print("REPORT_ROUTES_BY_MODE: %s" % fmt_counter(r["by_mode"]))
    print("REPORT_SPAWNS: %s" % fmt_counter(s["spawns"]))
    print("REPORT_VERDICTS: %s" % fmt_counter(s["verdicts"]))
    print("REPORT_ESCALATIONS: %s" % fmt_counter(s["escalations"]))
    print("REPORT_TOKENS: %s" % fmt_counter(s["tokens"]))
    print("REPORT_USD_ESTIMATED: %.4f (%d priced rows; %s)" % (s["usd_estimated"], s["usd_rows_priced"], s["usd_source"]))
    print("REPORT_UNVERIFIED: %d row(s) with usage but no resolved model (excluded from USD)" % s["unverified"]["count"])
    dc = s["decision_cost"]
    if dc["status"] != "ok":
        print("REPORT_DECISION_COST: %s (kind: decision, priced separately)" % dc["status"])
    else:
        print("REPORT_DECISION_COST: %d call(s) + %d shadow; USD %.6f reported + %.6f estimated; %d unpriced; by backend %s "
              "(kind: decision, not in REPORT_USD_ESTIMATED)" % (dc["calls"], dc["shadow_calls"], dc["usd_reported"],
                                                                 dc["usd_estimated"], dc["unpriced"],
                                                                 ", ".join("%s=%d/$%.6f" % (k, v["calls"], v["usd"])
                                                                           for k, v in dc["by_backend"].items()) or "none"))
    for u in s["unverified"]["rows"]:
        print("REPORT_UNVERIFIED_ROW: seq=%s event=%s route=%s model=%s provider=%s"
              % (u["seq"], u["event"], u["route_id"], u["model"], u["provider"]))
    print("REPORT_HUMAN_GATES: %d" % s["human_gates"])
    print("REPORT_HOOK_ERRORS: %d" % s["hook_errors"])
    print("REPORT_MODEL_MISMATCHES: %d" % s["model_mismatches"])
    print("REPORT_POLICY_VIOLATIONS: %d" % s["policy_violations"])
    if not s["acceptance"]:
        print("REPORT_ACCEPTANCE: none (no external provider dispatches recorded)")
    for pid, a in sorted(s["acceptance"].items()):
        print("REPORT_ACCEPTANCE: %s; %d pending" % (ledger.acceptance_line(pid, a), a["pending"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
