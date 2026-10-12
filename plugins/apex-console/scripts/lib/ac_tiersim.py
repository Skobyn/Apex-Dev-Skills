"""Tier simulator: replay completed tasks' diffs under proposed tier definitions.

Each completed task (a `completes` entry with the diff base its tier record kept) is
classified twice by apex-scope-loop's own risk-tier.sh, as a read-only replay
(`--no-record --since <base> --head <completed head>`): once under the knobs file in
force, once under the proposed one (`--knobs <tmp>`). Nothing is recorded, and the
classifier is never copied: what the simulator shows is what risk-tier.sh would do.
The heuristic alone is replayed: reviewer raises and the decision layer are not.
"""
import concurrent.futures
import json
import os
import re
import tempfile

import ac_common as C
import ac_knobs

MAX_TASKS = 60
ORDER = {"A": 0, "B": 1, "C": 2}


def _risk_tier():
    sl = C.sibling("apex-scope-loop")
    p = os.path.join(sl, "skills", "apex-execute", "scripts", "risk-tier.sh") if sl else None
    return p if p and os.path.isfile(p) else None


def _parse(out):
    tier = None
    reasons = []
    for ln in out.splitlines():
        if ln.startswith("TIER: "):
            tier = ln[6:].strip()
        elif ln.startswith("REASON: "):
            r = ln[8:].strip()
            if r != "no elevated-risk signals":
                reasons.append(r)
    return tier, reasons


def _classify(rt, top, plan_abs, line, since, head, knobs_file):
    argv = ["bash", rt, plan_abs, str(line), "--no-record", "--since", since, "--head", head]
    if knobs_file:
        argv += ["--knobs", knobs_file]
    env = dict(os.environ)
    env.pop("APEX_DECIDE_CMD", None)
    rc, out, err = C.run(argv, cwd=top, env=env, timeout=120)
    tier, reasons = _parse(out)
    if rc != 0 or tier not in ORDER:
        msg = (err or out).strip().splitlines()
        return None, [], (msg[-1] if msg else "risk-tier.sh exited %d" % rc)[:300]
    return tier, reasons, None


def tasks_of(snap, limit):
    """The last `limit` completed tasks of a repository that a replay can classify."""
    out = []
    for p in snap["plans"]:
        cp = p["checkpoint"]
        tiers = cp.get("tiers") or {}
        titles = {t["line"]: t["title"] for t in p["tasks"]}
        last = {}
        for c in cp.get("completes") or []:
            if isinstance(c, dict) and isinstance(c.get("line"), int):
                last[c["line"]] = c
        for line, c in last.items():
            tr = tiers.get(str(line)) or {}
            out.append({"plan": p["hash"], "plan_path": p["plan_path"], "plan_abs": p["plan_abs"], "line": line,
                        "title": titles.get(line), "completed_at": c.get("at"), "head": c.get("head"),
                        "since": tr.get("since"), "recorded": tr.get("tier")})
    out.sort(key=lambda t: t.get("completed_at") or "", reverse=True)
    return out[:limit]


def simulate(snap, tiers_patch, limit=30):
    rt = _risk_tier()
    if not rt:
        raise ac_knobs.KnobError(["apex-scope-loop 0.6.0+ (risk-tier.sh --head/--knobs) is not installed"])
    if not isinstance(tiers_patch, dict):
        raise ac_knobs.KnobError(["patch is the tiers object of the proposed knobs"])
    limit = max(1, min(MAX_TASKS, int(limit or 30)))
    # The proposed file: the file in force with the tiers patch merged, validated by knobslib.
    path, raw, text, changes = ac_knobs.sl_plan(snap["state_base"], {"tiers": tiers_patch})
    fd, tmp = tempfile.mkstemp(prefix="apex-tiersim-", suffix=".json")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    try:
        tasks = tasks_of(snap, limit)

        def run(t):
            if not (t["since"] and t["head"]):
                t.update(current=None, proposed=None, error="no recorded diff base for this task (tiered before 0.3)")
                return t
            cur, rc_, e1 = _classify(rt, snap["top"], t["plan_abs"], t["line"], t["since"], t["head"], None)
            pro, rp, e2 = _classify(rt, snap["top"], t["plan_abs"], t["line"], t["since"], t["head"], tmp)
            t.update(current=cur, proposed=pro, error=e1 or e2,
                     added=[r for r in rp if r not in rc_], removed=[r for r in rc_ if r not in rp],
                     reasons_current=rc_, reasons_proposed=rp)
            return t

        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as ex:
            done = list(ex.map(run, tasks))
    finally:
        os.unlink(tmp)
    moves = {}
    for t in done:
        if t.get("current") and t.get("proposed") and t["current"] != t["proposed"]:
            t["move"] = "%s→%s" % (t["current"], t["proposed"])
            moves[t["move"]] = moves.get(t["move"], 0) + 1
        else:
            t["move"] = None
        t.pop("plan_abs", None)
    ok = [t for t in done if not t.get("error")]
    looser = sum(1 for t in ok if t["move"] and ORDER[t["proposed"]] < ORDER[t["current"]])
    stricter = sum(1 for t in ok if t["move"] and ORDER[t["proposed"]] > ORDER[t["current"]])
    mix = lambda key: {k: sum(1 for t in ok if t.get(key) == k) for k in ORDER}
    return {"ok": True, "changes": changes, "tasks": done,
            "summary": {"replayed": len(ok), "errors": len(done) - len(ok), "changed": looser + stricter,
                        "looser": looser, "stricter": stricter, "moves": moves,
                        "mix_current": mix("current"), "mix_proposed": mix("proposed"),
                        "note": "Replays risk-tier.sh's heuristic only: reviewer raises and the decision layer "
                                "are not replayed, so a recorded tier can be higher than both."}}
