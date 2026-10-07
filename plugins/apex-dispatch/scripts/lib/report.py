#!/usr/bin/env python3
"""apex-dispatch report: summarise one state dir's ledger (python3 stdlib).

  report.py ROOT --state DIR [--plan PLAN] [--json]
            [--compare [--baseline-state DIR]] [--decision]

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
"""
import sys

sys.dont_write_bytecode = True

import collections  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ledger  # noqa: E402

SPAWNS = ("spawn_request", "spawn", "worker_run")
MIN_N = 20                   # pre-registered minimum tasks per arm (ADR-0001, spec §10)
ROUTED_MODES = ("table", "decision", "escalated")
BASELINE_MODES = ("baseline", "shadow")
P_BUCKETS = ((0.0, 0.5, "<0.5"), (0.5, 0.8, "0.5-0.8"), (0.8, 1.01, ">=0.8"))
FAMILIES = ("haiku", "sonnet", "opus", "fable")


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


def row_usd(r, price):
    """(usd or None, unverified?) for one ledger row with usage."""
    u = r.get("usage")
    if not isinstance(u, dict):
        return None, False
    if isinstance(r.get("usd"), (int, float)) and not isinstance(r.get("usd"), bool):
        return float(r["usd"]), False
    fam = family(r.get("resolved_model") or r.get("model_resolved"))
    if fam is None or fam not in price:
        return None, True
    p = price[fam]
    return sum(float(u.get(k) or 0) * float(p.get(k) or 0) for k in ("input", "output", "cache_read", "cache_write")) / 1e6, False


def _ts(s):
    import datetime
    try:
        return datetime.datetime.strptime(str(s), "%Y-%m-%dT%H:%M:%SZ").timestamp()
    except ValueError:
        return None


def _route_key(r):
    line = ledger._route_line(r)
    return ("line", line) if line is not None else ("route", r.get("route_id"))


def tasks_of(rows, price):
    """One dict per routed task with its arm, class, tier and outcome metrics."""
    tasks, route_task = {}, {}
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
                              "escalations": 0, "modes": set(), "t0": _ts(r.get("ts")), "t1": _ts(r.get("ts"))}
        t["routes"].append(r.get("route_id"))
        t["modes"].add(r.get("route_mode"))
        if r.get("route_mode") in ROUTED_MODES:
            t["tier"] = router.get("tier")          # the last routed rung is the tier the task ended on
        route_task[r.get("route_id")] = key
    for r in rows:
        key = route_task.get(r.get("route_id")) or route_task.get(r.get("prior_route_id"))
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
        arms = {"baseline" if m in BASELINE_MODES else "routed" for m in t["modes"] if m in BASELINE_MODES + ROUTED_MODES}
        t.update({"review_rounds": len(heads), "reviewed": bool(t["verdicts"]), "approved": approved,
                  "first_round_approved": bool(first) and all(v == "APPROVE" for v in first),
                  # wall-clock only for finished (approved) tasks: an open task has no end
                  "wall_min": round((t["t1"] - t["t0"]) / 60.0, 2) if approved and t["t0"] is not None and t["t1"] is not None else None,
                  "usd": round(t["usd"], 6), "spawns": len(t["agents"]), "mixed_arms": len(arms) > 1})
        del t["verdicts"], t["t0"], t["t1"], t["agents"], t["modes"]
        out.append(t)
    return out


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


def summarise(root, state_dir, plan=None):
    ok, rows, msg = ledger.verify(state_dir)
    if not ok:
        rows = ledger.read_rows(state_dir)
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
    usd, priced, unverified, tokens = 0.0, 0, [], collections.Counter()
    for r in rows:
        u = r.get("usage")
        if not isinstance(u, dict):
            continue
        for k in ("input", "output", "cache_read", "cache_write"):
            if isinstance(u.get(k), (int, float)):
                tokens[k] += u[k]
        if isinstance(r.get("usd"), (int, float)):
            usd += r["usd"]
            priced += 1
            continue
        fam = family(r.get("resolved_model") or r.get("model_resolved"))
        if fam is None or fam not in price:
            unverified.append({"seq": r.get("seq"), "event": r.get("event"), "route_id": r.get("route_id"),
                               "model": r.get("model"), "provider": r.get("provider")})
            continue
        p = price[fam]
        usd += sum(float(u.get(k) or 0) * float(p.get(k) or 0) for k in ("input", "output", "cache_read", "cache_write")) / 1e6
        priced += 1
    return {"state": state_dir, "plan": plan, "chain": {"ok": ok, "message": msg, "rows": len(rows)},
            "routes": {"total": len(routes), "by_class": dict(by["class"]), "by_tier": dict(by["tier"]),
                       "by_provider": dict(by["provider"]), "by_mode": dict(by["mode"])},
            "spawns": dict(spawns), "verdicts": dict(verdicts), "escalations": dict(escal),
            "tokens": dict(tokens),
            "usd_estimated": round(usd, 6), "usd_rows_priced": priced, "usd_source": "real usage x policy tier prices",
            "unverified": {"count": len(unverified), "rows": unverified,
                           "note": "usage without a resolved model; excluded from USD"},
            "human_gates": sum(1 for r in rows if r.get("event") == "human_gate"),
            "hook_errors": sum(1 for r in rows if r.get("event") == "hook_error"),
            "model_mismatches": sum(1 for r in rows if r.get("event") == "model_mismatch"),
            "policy_violations": sum(1 for r in rows if r.get("event") == "policy_violation")}


def fmt_counter(d):
    return ", ".join("%s=%s" % (k, v) for k, v in sorted(d.items())) or "none"


def main(argv):
    if not argv:
        print("usage: report.py ROOT --state DIR [--plan PLAN] [--json]", file=sys.stderr)
        return 2
    root, rest = os.path.abspath(argv[0]), argv[1:]
    state = plan = base_state = None
    as_json = do_compare = do_decision = False
    i = 0
    while i < len(rest):
        a = rest[i]
        if a in ("--state", "--plan", "--baseline-state") and i + 1 < len(rest):
            if a == "--state":
                state = rest[i + 1]
            elif a == "--plan":
                plan = rest[i + 1]
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
        else:
            print("report: unknown argument %s" % a, file=sys.stderr)
            return 2
        i += 1
    if not state:
        print("usage: report.sh (--state DIR | --plan PLAN) [--json]", file=sys.stderr)
        return 2
    if base_state and not do_compare:
        print("report: --baseline-state needs --compare", file=sys.stderr)
        return 2
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
    for u in s["unverified"]["rows"]:
        print("REPORT_UNVERIFIED_ROW: seq=%s event=%s route=%s model=%s provider=%s"
              % (u["seq"], u["event"], u["route_id"], u["model"], u["provider"]))
    print("REPORT_HUMAN_GATES: %d" % s["human_gates"])
    print("REPORT_HOOK_ERRORS: %d" % s["hook_errors"])
    print("REPORT_MODEL_MISMATCHES: %d" % s["model_mismatches"])
    print("REPORT_POLICY_VIOLATIONS: %d" % s["policy_violations"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
