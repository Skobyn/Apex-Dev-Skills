#!/usr/bin/env python3
"""apex-dispatch report: summarise one state dir's ledger (python3 stdlib).

  report.py ROOT --state DIR [--plan PLAN] [--json]

Counts routes by class, tier, provider and route_mode; spawn_request, spawn and
worker_run rows; verdicts; escalations by rung. Estimated USD is real usage x
the policy's tier price table, only for rows that carry `usage` and a
`resolved_model` (or `model_resolved`) naming a known family (haiku, sonnet,
opus, fable); rows with usage but no resolved model go to the "unverified"
bucket, which is printed separately and excluded from USD (spec §5.1
post-agent). Non-Claude workers are priced only when they carry `usd`.
"""
import sys

sys.dont_write_bytecode = True

import collections  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ledger  # noqa: E402

SPAWNS = ("spawn_request", "spawn", "worker_run")
FAMILIES = ("haiku", "sonnet", "opus", "fable")


def prices(root):
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
            "hook_errors": sum(1 for r in rows if r.get("event") == "hook_error")}


def fmt_counter(d):
    return ", ".join("%s=%s" % (k, v) for k, v in sorted(d.items())) or "none"


def main(argv):
    if not argv:
        print("usage: report.py ROOT --state DIR [--plan PLAN] [--json]", file=sys.stderr)
        return 2
    root, rest = os.path.abspath(argv[0]), argv[1:]
    state = plan = None
    as_json = False
    i = 0
    while i < len(rest):
        a = rest[i]
        if a in ("--state", "--plan") and i + 1 < len(rest):
            if a == "--state":
                state = rest[i + 1]
            else:
                plan = rest[i + 1]
            i += 2
            continue
        if a == "--json":
            as_json = True
        else:
            print("report: unknown argument %s" % a, file=sys.stderr)
            return 2
        i += 1
    if not state:
        print("usage: report.sh (--state DIR | --plan PLAN) [--json]", file=sys.stderr)
        return 2
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
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
