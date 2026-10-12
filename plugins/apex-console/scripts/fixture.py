#!/usr/bin/env python3
"""Build a fixture repository for the console's smoke test: a git repo with a plan,
a scope-loop checkpoint and an apex-dispatch ledger written through apex-dispatch's own
ledger.append (a genuine hash chain). Usage: fixture.py DIR -> prints the repo path."""
import json
import os
import subprocess
import sys
import time

here = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.join(here, "lib"))
import ac_common as C  # noqa: E402

repo = os.path.realpath(sys.argv[1])
os.makedirs(repo, exist_ok=True)
git = lambda *a: subprocess.run(["git", "-C", repo] + list(a), check=True, capture_output=True, text=True).stdout.strip()
git("init", "-q", "-b", "main")
git("config", "user.email", "fixture@example.com")
git("config", "user.name", "fixture")
os.makedirs(os.path.join(repo, ".claude", "plans"), exist_ok=True)
plan = os.path.join(repo, ".claude", "plans", "demo-plan.md")
open(plan, "w").write("# Demo plan\n\n## Phase 1\n\n- [x] Add the model [id:T1]\n  - Acceptance: `true`\n"
                      "- [x] Add the API route [id:T2]\n  - Acceptance: `true`\n- [ ] Add billing [id:T3] [security]\n"
                      "  - Acceptance: `true`\n- [ ] Write docs [id:T4]\n  - Acceptance: `true`\n")
open(os.path.join(repo, ".gitignore"), "w").write(".dev-plan-state/\n")
git("add", "-A")
git("commit", "-qm", "plan")
base = git("rev-parse", "HEAD")
open(os.path.join(repo, "model.py"), "w").write("x = 1\n")
git("add", "-A")
git("commit", "-qm", "T1")
h1 = git("rev-parse", "HEAD")
open(os.path.join(repo, "api.py"), "w").write("y = 2\n")
os.makedirs(os.path.join(repo, "plugins", "x", "agents"), exist_ok=True)   # an agent prompt that names auth terms
open(os.path.join(repo, "plugins", "x", "agents", "auth-guide.md"), "w").write("Store the stripe secret in the vault.\n")
git("add", "-A")
git("commit", "-qm", "T2")
h2 = git("rev-parse", "HEAD")
git("revert", "--no-edit", h2)            # T2's commit is later reverted

import hashlib  # noqa: E402
phash = hashlib.sha256(b".claude/plans/demo-plan.md").hexdigest()[:12]   # apex-scope-loop's PLAN_HASH
sd = os.path.join(repo, ".dev-plan-state", phash)
os.makedirs(os.path.join(sd, "findings"), exist_ok=True)
now = time.time()
ts = lambda h: C.iso(now - h * 3600)
cp = {"plan_path": ".claude/plans/demo-plan.md", "plan_hash": phash, "total_tasks": 4, "completed_tasks": 2,
      "current_phase": "Phase 1", "halted": False, "halt_reason": None, "landed": False, "epoch": 0,
      "last_iteration_at": ts(1),
      "tiers": {"5": {"tier": "A", "since": base, "head": h1, "epoch": 0},
                "7": {"tier": "B", "since": h1, "head": h2, "epoch": 0}},
      "reviews": {"5": {"attempt": 1, "records": [{"attempt": 1, "sha": h1, "verdict": "APPROVE", "at": ts(30)}]},
                  "7": {"attempt": 2, "records": [{"attempt": 1, "sha": h1, "verdict": "REQUEST_CHANGES", "at": ts(20)},
                                                  {"attempt": 2, "sha": h2, "verdict": "APPROVE", "at": ts(10)}]}},
      "approvals": {}, "operator_overrides": [],
      "completes": []}
json.dump(cp, open(os.path.join(sd, "checkpoint.json"), "w"), indent=2)
json.dump({"line": 7, "items": [{"id": "F1", "severity": "blocking", "status": "closed", "class": "logic", "created": ts(20)},
                                 {"id": "F2", "severity": "blocking", "status": "open", "class": "logic", "created": ts(19)}]},
          open(os.path.join(sd, "findings", "L7.json"), "w"))

droot = C.sibling("apex-dispatch")
sys.path.append(os.path.join(droot, "scripts", "lib"))
import ledger  # noqa: E402
os.environ["APEX_DISPATCH_ENFORCE"] = "1"
rows = [("route", {"route_id": "r-%s-L5-1" % phash, "line": 5, "status": "READY", "origin": "plan",
                   "router": {"class": "feature", "tier": "standard", "risk_tier": "A"}}, h1),
        ("worker_run", {"route_id": "r-%s-L5-1" % phash, "provider": "claude-session", "role": "builder", "exit_code": 0,
                        "resolved_model": "claude-sonnet-5-5", "usage": {"input": 20000, "output": 4000, "cache_read": 60000, "cache_write": 5000}}, h1),
        ("worker_run", {"route_id": "r-%s-L5-1" % phash, "provider": "claude-session", "role": "reviewer", "exit_code": 0,
                        "resolved_model": "claude-sonnet-5-5", "usage": {"input": 10000, "output": 1000, "cache_read": 20000, "cache_write": 0}}, h1),
        ("verdict", {"route_id": "r-%s-L5-1" % phash, "role": "reviewer", "verdict": "APPROVE", "line": 5}, h1),
        ("route", {"route_id": "r-%s-L7-1" % phash, "line": 7, "status": "READY", "origin": "plan",
                   "router": {"class": "feature", "tier": "standard", "risk_tier": "B"}}, h1),
        ("worker_run", {"route_id": "r-%s-L7-1" % phash, "provider": "claude-session", "role": "builder", "exit_code": 0,
                        "resolved_model": "claude-opus-5-5", "usage": {"input": 30000, "output": 9000, "cache_read": 10000, "cache_write": 8000}}, h1),
        ("verdict", {"route_id": "r-%s-L7-1" % phash, "role": "reviewer", "verdict": "UNPARSED", "line": 7}, h1),
        ("escalate", {"route_id": "r-%s-L7-1" % phash, "prior_route_id": "r-%s-L7-1" % phash, "failures": 1, "action": "effort_up", "rung": "effort-up", "line": 7}, h1),
        ("route", {"route_id": "r-%s-L7-2" % phash, "line": 7, "status": "READY", "origin": "plan",
                   "router": {"class": "feature", "tier": "strong", "risk_tier": "B"}}, h2),
        ("worker_run", {"route_id": "r-%s-L7-2" % phash, "provider": "claude-session", "role": "builder", "exit_code": 0,
                        "resolved_model": "claude-opus-5-5", "usage": {"input": 25000, "output": 7000, "cache_read": 40000, "cache_write": 2000}}, h2),
        ("verdict", {"route_id": "r-%s-L7-2" % phash, "role": "reviewer", "verdict": "APPROVE", "line": 7}, h2)]
for ev, data, head in rows:
    try:
        ledger.append(sd, ev, data, "hook", head_sha=head, root=droot)
    except ledger.LedgerError as e:
        print("fixture: %s row refused: %s" % (ev, e), file=sys.stderr)
time.sleep(1.1)                            # completions land after the routes that led to them
cp["completes"] = [{"line": 5, "id": "T1", "head": h1, "at": C.now()}, {"line": 7, "id": "T2", "head": h2, "at": C.now()}]
json.dump(cp, open(os.path.join(sd, "checkpoint.json"), "w"), indent=2)
print(repo)
