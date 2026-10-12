"""Metrics over the plugins' own records (see docs/adrs/0001 for each definition).

Units, mapped onto Uber's software-factory cost equation
(users x sessions/user x turns/session x requests/turn x tokens/request x price/token):
- operator  -> a registered repository with at least one route in the window;
- session   -> a task: a plan line (repo, plan hash, line) or an ad-hoc route family;
- turn      -> a route row (each re-route after a failure or REQUEST_CHANGES is a new turn);
- request   -> a worker_run row (one agent run: in-session subagent or provider shim);
- tokens    -> input + output + cache_read + cache_write of those runs;
- price     -> apex-dispatch's own USD for them (report.row_usd) per token.
The six terms multiply to the window's spend by construction. Unpriced runs count as
requests and tokens but add no USD; their number is reported.

A value that cannot be computed is None, never 0; each metric carries n.
"""
import math
import os
import re
import time

import ac_collect
import ac_common as C

REVIEW_ROLE = re.compile(r"review|adversar|lens:", re.I)

SCORECARD = [
    # id, label, group, source, direction, unit, default target, formula
    ("cost_per_task", "Cost per completed task", "cost", "uber", "down", "usd", None,
     "the agent-run USD of each task completed in the window (all its runs, any time) / tasks completed in the window"),
    ("cost_per_1k_requests", "Cost per 1,000 agent runs", "cost", "uber", "down", "usd", None,
     "USD of priced agent runs in the window / priced agent runs in the window x 1000"),
    ("cost_per_review", "Cost per review", "cost", "uber", "down", "usd", None,
     "USD of reviewer agent runs in the window / verdicts recorded in the window"),
    ("cache_hit_rate", "Prompt cache hit rate", "cost", "uber", "up", "ratio", 0.6,
     "cache_read tokens / (input + cache_read + cache_write tokens) of agent runs in the window"),
    ("weekly_requests", "Agent runs per week", "adoption", "uber", "up", "count", None,
     "agent runs (worker_run rows) in the window / weeks in the window"),
    ("autonomy_rate", "Tasks done without a human", "adoption", "uber", "up", "ratio", 0.8,
     "completed tasks with no G12 approval, review waiver or human gate / completed tasks (window)"),
    ("revert_rate", "Revert rate", "quality", "uber", "down", "ratio", 0.02,
     "completed tasks whose commits were later reverted (git: 'This reverts commit <sha>') / completed tasks "
     "whose commits git can still find"),
    ("finding_addressed_rate", "Findings addressed", "quality", "uber", "up", "ratio", 0.8,
     "blocking review findings raised in the window that are now closed / blocking findings raised in the window"),
    ("mttr_hours", "Time to recover from a failure", "quality", "uber", "down", "hours", None,
     "median hours from a task's first escalation (a recorded failure) to its completion, for failed tasks "
     "that completed in the window"),
    ("first_pass_yield", "First-pass yield", "quality", "factory", "up", "ratio", 0.7,
     "completed tasks approved in review round 1 of attempt 1 / completed tasks (window)"),
    ("review_rounds", "Review rounds per task", "quality", "factory", "down", "count", 1.5,
     "distinct reviewed heads across all attempts, averaged over completed tasks (window)"),
    ("lead_time_p50_hours", "Lead time, median", "flow", "factory", "down", "hours", None,
     "median hours from a task's first route to its completion (window)"),
    ("lead_time_p90_hours", "Lead time, 90th percentile", "flow", "factory", "down", "hours", None,
     "90th percentile hours from a task's first route to its completion (window)"),
    ("throughput_per_week", "Tasks completed per week", "flow", "factory", "up", "count", None,
     "tasks completed in the window / weeks in the window"),
    ("escalation_rate", "Escalation rate", "flow", "factory", "down", "ratio", 0.15,
     "escalate rows / route rows in the window"),
    ("human_touch_per_task", "Human touches per task", "flow", "factory", "down", "count", 0.3,
     "(G12 approvals + review waivers + human gates) in the window / tasks completed in the window"),
    ("unparsed_rate", "Unreadable verdicts", "integrity", "factory", "down", "ratio", 0.0,
     "UNPARSED verdict rows / verdict rows in the window"),
    ("policy_violations", "Policy violations", "integrity", "factory", "down", "count", 0,
     "policy_violation rows in the window (a read-only agent wrote, or a route was broken)"),
    ("chain_ok_rate", "Ledgers intact", "integrity", "factory", "up", "ratio", 1.0,
     "ledgers whose hash chain verifies / ledgers (all time)"),
]
DEFAULT_TARGETS = {s[0]: s[6] for s in SCORECARD if s[6] is not None}


def pct(xs, q):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    k = (len(xs) - 1) * q
    f, c = math.floor(k), math.ceil(k)
    return xs[f] if f == c else xs[f] + (xs[c] - xs[f]) * (k - f)


def div(a, b):
    return (a / b) if (a is not None and b) else None


def status(value, target, direction):
    if value is None or target is None:
        return "none"
    if direction == "up":
        if value >= target:
            return "good"
        return "watch" if value >= target * 0.85 else "off"
    if value <= target:
        return "good"
    return "watch" if (target > 0 and value <= target * 1.15) else "off"


# --- flattening -------------------------------------------------------------------------

def task_key(snap, plan_hash, line):
    return (snap["id"], plan_hash, line)


def flatten(snaps):
    """All rows and task facts across repositories, each tagged with its task key."""
    rows, tasks, ledgers, findings, decisions = [], {}, [], [], []
    for s in snaps:
        for p in s["plans"]:
            cp, ph = p["checkpoint"], p["hash"]
            lg = p["ledger"]
            if lg["dir"]:
                ledgers.append(lg["ok"])
            for r in lg["rows"]:
                ln = r.get("_line") if r.get("_line") is not None else r.get("line")
                r["_task"] = task_key(s, ph, ln) if isinstance(ln, int) else (s["id"], ph, "route:" + str(r.get("route_id")))
                r["_repo"] = s["id"]
                rows.append(r)
            reviews = cp.get("reviews") or {}
            approvals = cp.get("approvals") or {}
            waivers = [w for w in cp.get("operator_overrides") or [] if isinstance(w, dict) and w.get("kind") == "review_waiver"]
            for c in cp.get("completes") or []:
                if not isinstance(c, dict) or not isinstance(c.get("line"), int):
                    continue
                key = task_key(s, ph, c["line"])
                rv = reviews.get(str(c["line"])) or {}
                recs = [x for x in rv.get("records") or [] if isinstance(x, dict)]
                t = tasks.setdefault(key, {"key": key, "repo": s["id"], "plan": ph, "line": c["line"], "completes": []})
                t["completes"].append(c)
                t["done_at"] = C.parse_ts(c.get("at"))
                t["head"] = c.get("head")
                t["attempts"] = rv.get("attempt", 1)
                t["records"] = recs
                t["tier"] = ((cp.get("tiers") or {}).get(str(c["line"])) or {}).get("tier")
                t["since"] = ((cp.get("tiers") or {}).get(str(c["line"])) or {}).get("since")
                t["g12"] = str(c["line"]) in approvals
                t["waived"] = any(str(w.get("line")) == str(c["line"]) for w in waivers)
                t["top"] = s["top"]
            for a_line, a in approvals.items():
                if isinstance(a, dict):
                    rows.append({"event": "_g12", "_t": C.parse_ts(a.get("at")), "_repo": s["id"],
                                 "_task": task_key(s, ph, int(a_line)) if str(a_line).isdigit() else None})
            for w in waivers:
                rows.append({"event": "_waiver", "_t": C.parse_ts(w.get("at")), "_repo": s["id"], "_task": None})
            for f in p["findings"]:
                f["_repo"] = s["id"]
                findings.append(f)
        for a in s["adhoc"]:
            lg = a["ledger"]
            if lg["dir"]:
                ledgers.append(lg["ok"])
            for r in lg["rows"]:
                r["_task"] = (s["id"], "adhoc", a["id"])
                r["_repo"] = s["id"]
                rows.append(r)
        decisions.extend(s["decisions"])
    return rows, tasks, ledgers, findings, decisions


# --- reverts ---------------------------------------------------------------------------

_REVERT = re.compile(r"This reverts commit ([0-9a-f]{7,40})")


def reverted_shas(top):
    def compute():
        rc, out, _ = C.run(["git", "-C", top, "log", "--all", "--format=%B", "--grep=This reverts commit", "-n", "2000"], timeout=20)
        return set(_REVERT.findall(out)) if rc == 0 else None
    return ac_collect.cached(("reverts", top), [os.path.join(top, ".git")], compute)


def task_commits(top, since, head):
    if not (since and head):
        return None

    def compute():
        rc, out, _ = C.run(["git", "-C", top, "rev-list", "%s..%s" % (since, head)], timeout=20)
        return out.split() if rc == 0 else None
    return ac_collect.cached(("commits", top, since, head), [], compute)


def was_reverted(task):
    shas = reverted_shas(task["top"])
    commits = task_commits(task["top"], task.get("since"), task.get("head"))
    if shas is None or commits is None:
        return None
    return any(c.startswith(s) or s.startswith(c) for c in commits for s in shas)


# --- one window -------------------------------------------------------------------------

def window(rows, tasks, findings, t0, t1, days, nrepos_all):
    def inw(t):
        return t is not None and t0 <= t < t1
    wr = [r for r in rows if inw(r.get("_t"))]
    routes = [r for r in wr if r.get("event") == "route"]
    runs = [r for r in wr if r.get("event") == "worker_run"]
    verdicts = [r for r in wr if r.get("event") == "verdict"]
    done = [t for t in tasks.values() if inw(t.get("done_at"))]
    weeks = days / 7.0

    tok = {k: 0 for k in ("input", "output", "cache_read", "cache_write")}
    usd, unpriced = 0.0, 0
    for r in runs:
        u = r.get("usage") if isinstance(r.get("usage"), dict) else {}
        for k in tok:
            v = u.get(k)
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                tok[k] += v
        if r.get("_usd") is None:
            unpriced += 1
        else:
            usd += r["_usd"]
    tokens = sum(tok.values())
    repos = {r["_repo"] for r in routes}
    task_ids = {r["_task"] for r in routes}

    eq = [
        ("operators", "Active repos", len(repos) or None, "repos", "adoption",
         "repositories with at least one route in the window"),
        ("sessions", "Tasks per repo", div(len(task_ids), len(repos)), "tasks/repo", "adoption",
         "distinct tasks routed / active repos"),
        ("turns", "Turns per task", div(len(routes), len(task_ids)), "routes/task", "overhead",
         "route rows / distinct tasks routed (a re-route is a new turn)"),
        ("requests", "Runs per turn", div(len(runs), len(routes)), "runs/route", "overhead",
         "agent runs (worker_run rows) / route rows"),
        ("tokens", "Tokens per run", div(tokens, len(runs)), "tokens/run", "overhead",
         "input + output + cache tokens / agent runs"),
        ("price", "Price per million tokens", div(usd * 1e6, tokens), "USD/Mtok", "price",
         "USD (apex-dispatch pricing) / tokens x 1e6"),
    ]

    # task cost, attributed over all time
    cost_by_task = {}
    for r in rows:
        if r.get("event") == "worker_run" and r.get("_usd") is not None:
            cost_by_task[r["_task"]] = cost_by_task.get(r["_task"], 0.0) + r["_usd"]
    first_route = {}
    first_escalate = {}
    for r in rows:
        if r.get("_t") is None:
            continue
        if r.get("event") == "route":
            first_route[r["_task"]] = min(first_route.get(r["_task"], r["_t"]), r["_t"])
        if r.get("event") == "escalate":
            first_escalate[r["_task"]] = min(first_escalate.get(r["_task"], r["_t"]), r["_t"])

    costs = [cost_by_task[t["key"]] for t in done if t["key"] in cost_by_task]
    rev_runs = [r for r in runs if REVIEW_ROLE.search(str(r.get("role") or ""))]
    rev_usd = sum(r["_usd"] for r in rev_runs if r.get("_usd") is not None)
    leads = [(t["done_at"] - first_route[t["key"]]) / 3600.0 for t in done
             if t["key"] in first_route and t["done_at"] >= first_route[t["key"]]]
    mttr = [(t["done_at"] - first_escalate[t["key"]]) / 3600.0 for t in done
            if t["key"] in first_escalate and t["done_at"] >= first_escalate[t["key"]]]
    fpy, rounds = [], []
    for t in done:
        recs = t.get("records") or []
        heads = {(x.get("attempt", 1), x.get("sha")) for x in recs if x.get("sha")}
        rounds.append(len(heads) if heads else None)
        if recs:
            fpy.append(t.get("attempts", 1) == 1 and len(heads) == 1 and all(x.get("verdict") == "APPROVE" for x in recs))
    touched = [t for t in done if t.get("g12") or t.get("waived")]
    human_rows = [r for r in wr if r.get("event") in ("_g12", "_waiver", "human_gate")]
    reverts = [was_reverted(t) for t in done]
    known = [x for x in reverts if x is not None]
    blocking = [f for f in findings if f.get("severity") == "blocking" and inw(C.parse_ts(f.get("created") or f.get("at")))]
    cache_den = tok["input"] + tok["cache_read"] + tok["cache_write"]

    vals = {
        "cost_per_task": (div(sum(costs), len(costs)), len(costs)),
        "cost_per_1k_requests": (div(usd * 1000.0, len(runs) - unpriced), len(runs)),
        "cost_per_review": (div(rev_usd, len(verdicts)), len(verdicts)),
        "cache_hit_rate": (div(tok["cache_read"], cache_den), len(runs)),
        "weekly_requests": (div(len(runs), weeks) if runs else None, len(runs)),
        "autonomy_rate": (div(len(done) - len(touched), len(done)), len(done)),
        "revert_rate": (div(sum(1 for x in known if x), len(known)), len(known)),
        "finding_addressed_rate": (div(sum(1 for f in blocking if f.get("status") == "closed"), len(blocking)), len(blocking)),
        "mttr_hours": (pct(mttr, 0.5), len(mttr)),
        "first_pass_yield": (div(sum(1 for x in fpy if x), len(fpy)), len(fpy)),
        "review_rounds": (div(sum(x for x in rounds if x), len([x for x in rounds if x])), len([x for x in rounds if x])),
        "lead_time_p50_hours": (pct(leads, 0.5), len(leads)),
        "lead_time_p90_hours": (pct(leads, 0.9), len(leads)),
        "throughput_per_week": (div(len(done), weeks) if done else None, len(done)),
        "escalation_rate": (div(sum(1 for r in wr if r.get("event") == "escalate"), len(routes)), len(routes)),
        "human_touch_per_task": (div(len(human_rows), len(done)), len(done)),
        "unparsed_rate": (div(sum(1 for r in verdicts if r.get("verdict") == "UNPARSED"), len(verdicts)), len(verdicts)),
        "policy_violations": (sum(1 for r in wr if r.get("event") == "policy_violation") if wr else None, len(wr)),
    }
    tiers = {"A": 0, "B": 0, "C": 0}
    for t in done:
        if t.get("tier") in tiers:
            tiers[t["tier"]] += 1
    return {"equation": eq, "usd": usd, "unpriced": unpriced, "vals": vals, "tiers": tiers,
            "runs": len(runs), "done": len(done), "repos": len(repos), "cache": div(tok["cache_read"], cache_den)}


def compute(snaps, days=28, targets=None, now=None):
    now = now or time.time()
    targets = dict(DEFAULT_TARGETS, **(targets or {}))
    rows, tasks, ledgers, findings, _decisions = flatten(snaps)
    t1, t0 = now, now - days * 86400
    cur = window(rows, tasks, findings, t0, t1, days, len(snaps))
    prev = window(rows, tasks, findings, t0 - days * 86400, t0, days, len(snaps))

    terms = []
    for (tid, label, v, unit, group, formula), (_, _, pv, _, _, _) in zip(cur["equation"], prev["equation"]):
        terms.append({"id": tid, "label": label, "value": v, "prev": pv, "unit": unit, "group": group, "formula": formula,
                      "factor": 1e-6 if tid == "price" else 1})

    chain_ok = div(sum(1 for x in ledgers if x is True), len([x for x in ledgers if x is not None]))
    card = []
    for sid, label, group, source, direction, unit, _dt, formula in SCORECARD:
        if sid == "chain_ok_rate":
            v, n, pv = chain_ok, len(ledgers), None
        else:
            v, n = cur["vals"][sid]
            pv = prev["vals"][sid][0]
        tgt = targets.get(sid)
        card.append({"id": sid, "label": label, "group": group, "source": source, "direction": direction,
                     "unit": unit, "value": v, "prev": pv, "target": tgt, "status": status(v, tgt, direction),
                     "n": n, "formula": formula})

    nweeks = max(8, int(math.ceil(days / 7.0)))
    week0 = now - nweeks * 7 * 86400
    weeks, series = [], {k: [] for k in ("requests", "spend", "cost_per_1k_requests", "cost_per_task",
                                          "tasks_completed", "active_repos", "cache_hit_rate")}
    for i in range(nweeks):
        a = week0 + i * 7 * 86400
        w = window(rows, tasks, findings, a, a + 7 * 86400, 7, len(snaps))
        weeks.append(C.iso(a)[:10])
        series["requests"].append(w["runs"])
        series["spend"].append(round(w["usd"], 4))
        series["cost_per_1k_requests"].append(w["vals"]["cost_per_1k_requests"][0])
        series["cost_per_task"].append(div(w["usd"], w["done"]))
        series["tasks_completed"].append(w["done"])
        series["active_repos"].append(w["repos"])
        series["cache_hit_rate"].append(w["cache"])
    series["weeks"] = weeks

    notes = []
    if cur["unpriced"]:
        notes.append("%d agent runs carried usage without a priced model: they count as runs and tokens, not spend."
                     % cur["unpriced"])
    if any(x is False for x in ledgers):
        notes.append("A ledger's hash chain does not verify; run apex-dispatch ledger.sh verify on it.")
    if not rows:
        notes.append("No ledger rows yet. Metrics fill in as apex-dispatch routes tasks in the registered repos.")
    return {"days": days, "window": {"from": C.iso(t0), "to": C.iso(t1)},
            "equation": {"terms": terms, "total_usd": round(cur["usd"], 6), "prev_total_usd": round(prev["usd"], 6),
                         "unpriced_runs": cur["unpriced"],
                         "note": "value x factor of the six terms multiply to total_usd (Uber's software-factory cost equation; price is shown per million tokens, so its factor is 1e-6)."},
            "scorecard": card, "series": series, "tier_mix": cur["tiers"], "notes": notes}
