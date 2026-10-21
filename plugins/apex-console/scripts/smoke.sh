#!/usr/bin/env bash
# apex-console smoke test: the ADR-0001 contract. Exits non-zero on the first failure.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "smoke FAIL: $1" >&2; exit 1; }
ok()   { echo "smoke OK:   $1"; }
N=0; pass() { N=$((N + 1)); ok "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/apex-console-smoke.XXXXXX")"
SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
export APEX_CONFIG_DIR="$WORK/config"
# hermetic: report.py auto-locates transcripts under $CLAUDE_CONFIG_DIR (else ~/.claude); never read the real ones
export HOME="$WORK/home" CLAUDE_CONFIG_DIR="$WORK/claude"; mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR/projects/p"
unset APEX_STATE_ROOT
BIN="$PLUGIN_ROOT/bin/apex-console"

# 1. plugin.json has the required keys and enumerates no surfaces
PJ="$PLUGIN_ROOT/.claude-plugin/plugin.json"
python3 - "$PJ" <<'PY' || fail "plugin.json is invalid"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["name"] == "apex-console", d
for k in ("name", "version", "description", "author", "license", "keywords"):
    assert k in d, k
for k in ("skills", "commands", "agents"):
    assert k not in d, k
PY
pass "plugin.json has name/version/description/author/license/keywords and no surface arrays"

# 2. command frontmatter
C="$PLUGIN_ROOT/commands/console.md"
grep -qE '^name:[[:space:]]+console[[:space:]]*$' "$C" && grep -q '^description:' "$C" || fail "commands/console.md frontmatter"
grep -q 'Never print, echo or ask for a key value' "$C" || fail "commands/console.md does not forbid handling key values in chat"
pass "command console has valid frontmatter and keeps keys out of the chat"

# 3. README sections, ADR status, version consistency
R="$PLUGIN_ROOT/README.md"
for s in '## Compatibility' '## Namespace coordination' '## Verification' '## Architecture Decisions'; do
  grep -qF "$s" "$R" || fail "README missing section: $s"
done
ADR="$PLUGIN_ROOT/docs/adrs/0001-apex-console-contract.md"
grep -q '^- \*\*Status:\*\* Accepted' "$ADR" || fail "ADR-0001 is not Accepted"
V="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PJ")"
grep -q "apex-console v$V" "$ADR" && grep -q "Status: $V" "$R" || fail "version $V is not the same in plugin.json, ADR-0001 and README"
pass "README sections, ADR-0001 Accepted, version $V consistent"

# 4. scripts executable and compile; the UI obeys the CSP (no inline script, no inline handlers)
[ -x "$BIN" ] && [ -x "$PLUGIN_ROOT/scripts/smoke.sh" ] || fail "bin/apex-console or scripts/smoke.sh is not executable"
python3 -m py_compile "$BIN" "$PLUGIN_ROOT"/scripts/lib/*.py "$PLUGIN_ROOT/scripts/fixture.py" || fail "a python file does not compile"
for f in index.html app.js app.css demo.json; do [ -f "$PLUGIN_ROOT/ui/$f" ] || fail "missing ui/$f"; done
python3 - "$PLUGIN_ROOT/ui" <<'PY' || fail "the page breaks its own CSP (inline script or handler, or innerHTML with data)"
import json, os, re, sys
ui = sys.argv[1]
html = open(os.path.join(ui, "index.html")).read()
assert not re.search(r"<script(?![^>]*\bsrc=)[^>]*>", html, re.I), "inline <script>"
assert not re.search(r"\son[a-z]+\s*=", html, re.I), "inline event handler"
for m in re.findall(r"<script[^>]*src=\"([^\"]+)\"", html, re.I):
    assert not m.startswith("http"), "external script " + m
js = open(os.path.join(ui, "app.js")).read()
assert "innerHTML" not in js or not re.search(r"innerHTML\s*=\s*(?!['\"`]{2})", js), "innerHTML assignment"
assert "eval(" not in js and "new Function" not in js
json.load(open(os.path.join(ui, "demo.json")))
PY
pass "scripts executable and compile; the page has no inline script or handlers and no innerHTML; demo.json is JSON"

# 5. fixture: a repo with a plan, a checkpoint and a genuine apex-dispatch ledger
REPO="$(python3 "$PLUGIN_ROOT/scripts/fixture.py" "$WORK/repo" 2>"$WORK/fixture.err")" || fail "fixture failed: $(cat "$WORK/fixture.err")"
[ ! -s "$WORK/fixture.err" ] || fail "fixture rows were refused: $(cat "$WORK/fixture.err")"
"$BIN" repos add "$REPO" >/dev/null || fail "repos add failed"
"$BIN" metrics --days 7 >"$WORK/m.json" || fail "metrics failed"
python3 - "$WORK/m.json" <<'PY' || fail "metrics on the fixture are wrong"
import json, sys
d = json.load(open(sys.argv[1]))
p = 1.0
for t in d["equation"]["terms"]:
    p *= t["value"] * t["factor"]
tot = d["equation"]["total_usd"]
assert tot > 0 and abs(p - tot) < 1e-9 * max(1, tot), (p, tot)
c = {x["id"]: x for x in d["scorecard"]}
need = {"cost_per_task", "cost_per_1k_requests", "cost_per_review", "cache_hit_rate", "weekly_requests", "autonomy_rate",
        "revert_rate", "finding_addressed_rate", "mttr_hours", "first_pass_yield", "review_rounds", "lead_time_p50_hours",
        "lead_time_p90_hours", "throughput_per_week", "escalation_rate", "human_touch_per_task", "unparsed_rate",
        "policy_violations", "chain_ok_rate"}
assert need <= set(c), need - set(c)
assert c["revert_rate"]["value"] == 0.5 and c["revert_rate"]["n"] == 2, c["revert_rate"]        # T2 was reverted
assert c["first_pass_yield"]["value"] == 0.5 and c["review_rounds"]["value"] == 1.5
assert abs(c["unparsed_rate"]["value"] - 1 / 3) < 1e-9 and c["chain_ok_rate"]["value"] == 1.0
assert c["finding_addressed_rate"]["value"] == 0.5 and c["escalation_rate"]["n"] == 3
assert abs(c["cost_per_task"]["value"] * 2 - tot) < 1e-9, (c["cost_per_task"], tot)
assert c["mttr_hours"]["n"] == 1 and d["tier_mix"] == {"A": 1, "B": 1, "C": 0}
for x in d["scorecard"]:
    assert x["value"] is None or x["status"] in ("good", "watch", "off", "none"), x
PY
pass "metrics: the six equation terms multiply to the spend; revert, first-pass, rounds, UNPARSED, findings, chain and tier mix match the fixture"

# 6. progress
"$BIN" progress >"$WORK/p.json" || fail "progress failed"
python3 - "$WORK/p.json" <<'PY' || fail "progress on the fixture is wrong"
import json, sys
r = json.load(open(sys.argv[1]))["repos"][0]
p = r["plans"][0]
assert p["total"] == 4 and p["done"] == 2 and p["open_findings"] == 1 and p["enforced"] and p["chain_ok"], p
st = {t["line"]: t["status"] for t in p["tasks"]}
assert st == {5: "done", 7: "done", 9: "todo", 11: "todo"}, st
assert p["tasks"][1]["tier"] == "B" and p["tasks"][1]["rounds"] == 2 and p["tasks"][1]["attempts"] == 2
PY
pass "progress: plan done/total, task status, tier, rounds, attempts and open findings from the fixture"

# 7. the server: token, Host, header and method checks
"$BIN" serve --port 0 >"$WORK/serve.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do grep -q '^CONSOLE_URL: ' "$WORK/serve.log" 2>/dev/null && break; sleep 0.2; done
URL="$(sed -n 's/^CONSOLE_URL: //p' "$WORK/serve.log")"
[ -n "$URL" ] || fail "the server printed no CONSOLE_URL: $(cat "$WORK/serve.log")"
BASE="${URL%%/?t=*}"; JAR="$WORK/jar"
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
[ "$(code "$BASE/api/state")" = 401 ] || fail "an API call without the cookie was not refused"
[ "$(code "$BASE/?t=wrong")" = 403 ] || fail "a wrong token was not refused"
[ "$(code -c "$JAR" "$URL")" = 303 ] || fail "the token did not set the session"
grep -q 'apex_console' "$JAR" && grep -qi 'httponly' "$JAR" || fail "the session cookie is missing or not HttpOnly"
[ "$(code -b "$JAR" -H 'Host: attacker.example:80' "$BASE/api/state")" = 403 ] || fail "a foreign Host was not refused (DNS rebinding)"
[ "$(code -b "$JAR" -X POST -H 'Content-Type: application/json' -d '{}' "$BASE/api/targets")" = 401 ] || fail "a POST without X-Apex-Console was not refused"
[ "$(code -b "$JAR" -X DELETE "$BASE/api/state")" = 405 ] || fail "DELETE was not refused"
curl -s -D "$WORK/h" -o /dev/null -b "$JAR" "$BASE/api/state"
grep -qi "content-security-policy: default-src 'self'; script-src 'self'" "$WORK/h" && grep -qi 'cache-control: no-store' "$WORK/h" \
  || fail "missing CSP or no-store headers"
for p in state progress "metrics?days=28" "knobs?repo=r1" keys audit; do
  [ "$(code -b "$JAR" "$BASE/api/$p")" = 200 ] || fail "GET /api/$p did not answer 200"
done
pass "server: 127.0.0.1 with a launch token, HttpOnly cookie, Host check, X-Apex-Console on POST, CSP, every GET route answers"

POST() { curl -s -b "$JAR" -H 'X-Apex-Console: 1' -H 'Content-Type: application/json' -X POST -d "$2" "$BASE/api/$1"; }

# 8. keys: written 0600, reported as set + last4, never returned or logged
SECRET="sk-smoke-$(python3 -c 'import secrets; print(secrets.token_hex(12))')"
POST keys "{\"name\":\"OPENAI_API_KEY\",\"value\":\"$SECRET\"}" | grep -q '"ok": true' || fail "setting a key failed"
[ "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$APEX_CONFIG_DIR/keys.env")" = 0o600 ] || fail "keys.env is not mode 600"
grep -q "^export OPENAI_API_KEY='$SECRET'$" "$APEX_CONFIG_DIR/keys.env" || fail "keys.env does not hold the key as an export line"
for p in state progress "metrics?days=28" "knobs?repo=r1" keys audit; do
  curl -s -b "$JAR" "$BASE/api/$p" | grep -qF "$SECRET" && fail "GET /api/$p returned a key value"
done
grep -qF "$SECRET" "$APEX_CONFIG_DIR/console-audit.jsonl" && fail "the audit log holds a key value"
curl -s -b "$JAR" "$BASE/api/keys" | python3 -c 'import json,sys; k={x["name"]:x for x in json.load(sys.stdin)["keys"]}; assert k["OPENAI_API_KEY"]["set"] and k["OPENAI_API_KEY"]["last4"] and not k["XAI_API_KEY"]["set"]' \
  || fail "the keys summary is wrong"
POST keys '{"name":"OPENAI_API_KEY","value":"has space in it"}' | grep -q '"ok": false' || fail "a malformed key value was accepted"
POST keys '{"name":"OPENAI_API_KEY","remove":true}' | grep -q '"ok": true' && ! grep -q OPENAI_API_KEY= "$APEX_CONFIG_DIR/keys.env" || fail "removing a key failed"
pass "keys: keys.env mode 600 with export lines; set/last4 only; the value is in no API response and not in the audit log; bad values refused"

# 9. knobs: each plugin's validator refuses; an accepted change writes, is audited and undoes
POST knobs/preview '{"repo":"r1","plugin":"dispatch","patch":{"escalation":{"max_review_rounds":5}}}' | grep -q 'an overlay may lower it' \
  || fail "apex-dispatch's compile did not refuse max_review_rounds 5"
POST knobs/preview '{"repo":"r1","plugin":"decision","patch":{"egress":"everywhere"}}' | grep -q 'egress must be none or hosted' \
  || fail "apex-decision-layer's load_config did not refuse a bad egress"
POST knobs/preview '{"repo":"r1","plugin":"decision","patch":{"calibration_lock":[]}}' | grep -q 'never edited here' \
  || fail "calibration_lock was editable"
O="$(POST knobs '{"repo":"r1","plugin":"dispatch","patch":{"providers":{"codex":{"enabled":false}},"escalation":{"max_review_rounds":2}}}')"
AID="$(printf '%s' "$O" | python3 -c 'import json,sys; print(json.load(sys.stdin)["audit_id"])')" || fail "a valid dispatch change was refused: $O"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["escalation"]["max_review_rounds"]==2 and [p for p in d["providers"] if p["id"]=="codex"][0]["enabled"] is False' \
  "$REPO/.claude/apex-dispatch/policy.json" || fail "the dispatch overlay was not written"
POST audit/undo "{\"id\":\"$AID\"}" | grep -q '"ok": true' && [ ! -e "$REPO/.claude/apex-dispatch/policy.json" ] || fail "undo did not remove the overlay it created"
POST audit/undo "{\"id\":\"$AID\"}" | grep -q 'already undone' || fail "a second undo was not refused"
if [ -f "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import ac_common as C; r=C.sibling("apex-scope-loop"); print((r or "") + "/skills/apex-execute/scripts/knobslib.py")' "$PLUGIN_ROOT/scripts/lib")" ]; then
  POST knobs/preview '{"repo":"r1","plugin":"scope-loop","patch":{"review":{"cap":99}}}' | grep -q 'review.cap' || fail "knobslib did not refuse review.cap 99"
  POST knobs '{"repo":"r1","plugin":"scope-loop","patch":{"review":{"cap":2}}}' | grep -q '"ok": true' || fail "a valid scope-loop change was refused"
  python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["review"]["cap"]==2' "$REPO/.dev-plan-state/knobs/scope-loop.json" \
    || fail "the scope-loop knobs file was not written"
  SLK="scope-loop knobs written and refused by knobslib; "
else
  SLK="scope-loop knobs skipped (apex-scope-loop < 0.5.0); "
fi
pass "knobs: ${SLK}dispatch and decision validators refuse bad changes; calibration_lock is not editable; a dispatch change writes the overlay, is audited and undoes once"

# 10. kill switch: HALT written with a reason, refused without one, undone by undo
POST halt '{"repo":"r1","on":true,"reason":""}' | grep -q '"ok": false' || fail "a stop without a reason was accepted"
O="$(POST halt '{"repo":"r1","on":true,"reason":"smoke stop"}')"
[ "$(cat "$REPO/.dev-plan-state/HALT")" = "smoke stop" ] || fail "HALT was not written with the reason: $O"
curl -s -b "$JAR" "$BASE/api/progress" | python3 -c 'import json,sys; r=json.load(sys.stdin)["repos"][0]; assert r["halted"] and r["halt_reason"]=="smoke stop"' \
  || fail "progress does not show the halt"
AID="$(printf '%s' "$O" | python3 -c 'import json,sys; print(json.load(sys.stdin)["audit_id"])')"
POST audit/undo "{\"id\":\"$AID\"}" | grep -q '"ok": true' && [ ! -e "$REPO/.dev-plan-state/HALT" ] || fail "undoing the stop did not remove HALT"
pass "kill switch: HALT needs a reason, shows in progress, and undo resumes"

# 11. tier simulator: past tasks replayed by apex-scope-loop's own risk-tier.sh under a proposal; read-only
SIMP='{"repo":"r1","patch":{"exempt":[{"glob":"plugins/*/agents/*.md","reason":"agent prompts name auth terms as prose"}]},"limit":10}'
POST tiers/simulate "$SIMP" >"$WORK/sim.json"
python3 - "$WORK/sim.json" <<'PY' || fail "the tier simulator result is wrong: $(head -c 600 "$WORK/sim.json")"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["ok"] and d["summary"]["replayed"] == 2 and d["summary"]["errors"] == 0, d["summary"]
t = {x["line"]: x for x in d["tasks"]}
assert t[7]["current"] == "C" and t[7]["proposed"] == "A" and t[7]["move"] == "C→A", t[7]       # the agent-prompt task
assert any("exempted by knobs: plugins/x/agents/auth-guide.md" in r for r in t[7]["added"]), t[7]
assert any(r.startswith("tier-c path: plugins/x/agents/auth-guide.md") for r in t[7]["removed"]), t[7]
assert t[5]["current"] == t[5]["proposed"] == "A" and t[5]["move"] is None, t[5]
assert d["summary"]["looser"] == 1 and d["summary"]["moves"] == {"C→A": 1}
assert d["summary"]["mix_current"] == {"A": 1, "B": 0, "C": 1} and d["summary"]["mix_proposed"] == {"A": 2, "B": 0, "C": 0}
PY
[ ! -e "$REPO/.dev-plan-state/knobs/scope-loop.json" ] || python3 -c 'import json,sys; assert "exempt" not in json.load(open(sys.argv[1])).get("tiers", {})' "$REPO/.dev-plan-state/knobs/scope-loop.json" \
  || fail "the simulator wrote the proposal"
POST tiers/simulate '{"repo":"r1","patch":{"exempt":[{"glob":"*/*","reason":"almost everything is fine"}]}}' | grep -q 'names no directory' \
  || fail "the simulator did not refuse an invalid proposal through knobslib"
pass "tier simulator: risk-tier.sh replays past tasks under a proposed exemption (C→A with the reasons that change), writes nothing, and knobslib refuses a bad proposal"

# 12. console-plans-payload: the plans API carries scope, intent, operate state and per-task cost, read-only
python3 - "$PLUGIN_ROOT" "$REPO" "$WORK" <<'PY' || fail "console-plans-payload: could not build the operate fixture"
import hashlib, json, os, subprocess, sys, time
root, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "scripts", "lib"))
import ac_common as C
droot = C.sibling("apex-dispatch")
sys.path.append(os.path.join(droot, "scripts", "lib"))
import ledger
os.environ["APEX_DISPATCH_ENFORCE"] = "1"
head = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
def mkplan(name, body):
    rel = ".claude/plans/%s-plan.md" % name
    p = os.path.join(repo, rel)
    open(p, "w").write(body)
    h = hashlib.sha256(rel.encode()).hexdigest()[:12]
    sd = os.path.join(repo, ".dev-plan-state", h)
    os.makedirs(sd, exist_ok=True)
    return rel, sd, h
mon = ('## Monitor\n\n```json\n{"window_days": 14, "checks": [\n'
       ' {"id": "p95", "metric": "latency.p95", "op": "<", "threshold": 800, "severity": "high", "probe": {"kind": "cmd", "command": "echo 1"}},\n'
       ' {"id": "err", "metric": "errors", "op": "<", "threshold": 5, "severity": "low", "probe": {"kind": "cmd", "command": "echo 1"}},\n'
       ' {"id": "never", "metric": "up", "op": ">", "threshold": 0, "severity": "low", "probe": {"kind": "cmd", "command": "echo 1"}}]}\n```\n')
ship_body = ("# Ship plan\n\n> **Scope**: poc\n\n## Phase 1\n\n- [x] Build it [id:T1]\n  - Acceptance: `true`\n- [x] Wire it [id:T2]\n  - Acceptance: `true`\n\n" + mon)
rel, sd, h = mkplan("ship", ship_body)
os.makedirs(os.path.join(repo, ".claude", "tasks"), exist_ok=True)
open(os.path.join(repo, ".claude", "tasks", "ship-intent.md"), "w").write(
    "# Intent\n\n## Problem\n\nOperators cannot see what a landed plan does in production.\n\n## Who it's for\n\nThe operator.\n\n"
    "## Why now\n\nPlans land daily.\n\n## Non-goals\n\nDashboards.\n")
now = time.time()
iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
sid = "11111111-2222-4333-8444-555555555555"
cp = {"plan_path": rel, "plan_hash": h, "total_tasks": 2, "completed_tasks": 2, "landed": True, "halted": False, "epoch": 0,
      "operate": {"deploys": [{"ts": iso(now - 3 * 86400), "sha": "a" * 40, "head": None, "exit": 1, "ack_source": "tty"},
                              {"ts": iso(now - 2 * 86400), "sha": "b" * 40, "head": None, "exit": 0, "ack_source": "tty"}],
                  "window": {"start": iso(now - 2 * 86400), "end": iso(now + 12 * 86400), "days": 14, "last_run": iso(now - 3600),
                             "breaches": 2, "breaching": ["p95"], "measured_runs": 2,
                             "last_measured": {"p95": {"status": "breach"}, "err": {"status": "ok"}}},
                  "checks": {"p95": {"last_value": 950, "last_status": "breach", "last_ts": iso(now - 3600), "breaches": 2,
                                     "unmeasured": 0, "filed": "lessons"},
                             "err": {"last_value": None, "last_status": "unmeasured", "last_reason": "probe failed", "last_ts": iso(now - 3600),
                                     "unmeasured": True, "filed": None, "last_measured_value": 1, "last_measured_status": "ok"}}}}   # hand-written: no breaches count, a bool unmeasured
json.dump(cp, open(os.path.join(sd, "checkpoint.json"), "w"))
def row(ev, data, mode="table"):
    d = dict(data); d["route_id"] = rid; d.setdefault("session_id", sid)
    ledger.append(sd, ev, d, "hook", route_id=rid, route_mode=mode, head_sha=head, root=droot)
rid = "r-%s-L7-1" % h
row("route", {"line": 7, "status": "READY", "origin": "plan", "router": {"class": "feature", "tier": "standard"}})
row("spawn", {"agent_id": "a1", "role": "builder"})
row("worker_run", {"agent_id": "a1", "provider": "claude-session", "role": "builder", "exit_code": 0, "resolved_model": "claude-sonnet-5-5",
                   "usage": {"input": 20000, "output": 4000, "cache_read": 60000, "cache_write": 5000}})
row("verdict", {"role": "reviewer", "verdict": "APPROVE", "line": 7})
t5 = [json.loads(l) for l in open(os.path.join(sd, "dispatch", "ledger.jsonl"))][0]["ts"]
time.sleep(1.2)
rid = "r-%s-L9-1" % h
row("route", {"line": 9, "status": "READY", "origin": "plan", "router": {"class": "feature", "tier": "standard"}})
row("spawn", {"agent_id": "bg1", "role": "builder"})          # a background agent: never measured -> n/a, not a partial figure
# an orchestrator transcript with one main-session turn inside the first task's window
with open(os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "projects", "p", sid + ".jsonl"), "w") as f:
    f.write(json.dumps({"type": "assistant", "timestamp": t5, "sessionId": sid, "message": {
        "id": "m1", "model": "claude-sonnet-5-5", "usage": {"input_tokens": 1000, "output_tokens": 500}}}) + "\n")
# a landed plan with no operate block at all, scope-less (= feature)
rel2, sd2, h2 = mkplan("bare", "# Bare plan\n\n## Phase 1\n\n- [x] Only task [id:T1]\n  - Acceptance: `true`\n")
json.dump({"plan_path": rel2, "plan_hash": h2, "total_tasks": 1, "completed_tasks": 1, "landed": True, "halted": False, "epoch": 0},
          open(os.path.join(sd2, "checkpoint.json"), "w"))
# a landed plan whose watch window closed twice (operate.windows_closed): the last entry is what status prints
rel3, sd3, h3 = mkplan("closed", "# Closed plan\n\n## Phase 1\n\n- [x] Only task [id:T1]\n  - Acceptance: `true`\n\n" + mon)
w1 = {"start": iso(now - 40 * 86400), "end": iso(now - 26 * 86400), "days": 14, "outcome": "operated-clean", "closed_by": "monitor",
      "closed_at": iso(now - 26 * 86400), "open_at_close": [], "unmeasured_at_close": [], "measured_runs": 5, "breaches": 0}
w2 = {"start": iso(now - 20 * 86400), "end": iso(now - 6 * 86400), "days": 14, "outcome": "closed-with-breaches", "closed_by": "monitor",
      "closed_at": iso(now - 6 * 86400), "open_at_close": ["p95"], "unmeasured_at_close": ["never"], "measured_runs": 3, "breaches": 4,
      "last_run": iso(now - 6 * 86400)}
json.dump({"plan_path": rel3, "plan_hash": h3, "total_tasks": 1, "completed_tasks": 1, "landed": True, "halted": False, "epoch": 0,
           "operate": {"deploys": [], "window": w2, "windows_closed": [w1, w2], "checks": {}}}, open(os.path.join(sd3, "checkpoint.json"), "w"))
# ledgers filed by lessons.sh / backlog.sh in the MAIN checkout (their formats), some for other plans
asl = os.path.join(repo, ".claude", "apex-scope-loop")
os.makedirs(asl, exist_ok=True)
open(os.path.join(asl, "LESSONS.md"), "w").write(
    "# apex-scope-loop Lessons (append-only)\n\nFiled by the loop.\n\n"
    "## L-001 · 2026-10-01 · retry-storm\n**What happened:** x\n**Root cause:** y\n**Harness fix:** z\n**Plan:** other-plan.md\n**Tags:** #backend #operate:other\n\n"
    "## L-002 · 2026-10-20 · operate-ship-p95-breach\n**What happened:** Plan ship: latency.p95 950 breached.\n**Root cause:** Not yet diagnosed.\n"
    "**Harness fix:** Diagnose.\n**Plan:** ship-plan.md\n**Tags:** #operate:ship #latency.p95\n")
open(os.path.join(asl, "BACKLOG.md"), "w").write(
    "# apex-scope-loop Hardening Backlog\n\nNon-blocking review findings.\n\n"
    "## Plan: .claude/plans/ship-plan.md\n\n"
    "- [ ] B-001 · 2026-10-20 · plan-level · from operate \u2014 [operate:ship] errors 9 breached the expected errors < 5 (check err, severity low)\n"
    "- [x] B-002 · 2026-10-19 · plan-level · from operate \u2014 [operate:ship] up 0 breached the expected up > 0 (done 2026-10-20)\n"
    "- [ ] B-003 · 2026-10-19 · line 7 (T1) · from reviewer \u2014 an unrelated reviewer finding\n\n"
    "## Plan: .claude/plans/other-plan.md\n\n"
    "- [ ] B-004 · 2026-10-18 · plan-level · from operate \u2014 [operate:other] not this plan's\n\n"
    "## Repo: operate checks (monitor.json)\n\n"
    "- [ ] B-005 · 2026-10-20 · repo-level · from operate \u2014 [operate:repo] latency.p95 600 breached the expected latency.p95 < 500 (check site)\n")
# repo-level checks: one with state, one never measured
os.makedirs(os.path.join(repo, ".claude", "apex-scope-loop"), exist_ok=True)
json.dump({"checks": [{"id": "site", "metric": "latency.p95", "op": "<", "threshold": 500, "severity": "high",
                       "probe": {"kind": "cmd", "command": "echo 1"}},
                      {"id": "queue", "metric": "depth", "op": "<", "threshold": 9, "severity": "low",
                       "probe": {"kind": "cmd", "command": "echo 1"}}]},
          open(os.path.join(repo, ".claude", "apex-scope-loop", "monitor.json"), "w"))
os.makedirs(os.path.join(repo, ".dev-plan-state", "operate-repo"), exist_ok=True)
json.dump({"checks": {"site": {"last_value": 120, "last_status": "ok", "last_ts": iso(now), "breaches": 0, "unmeasured": 0}}},
          open(os.path.join(repo, ".dev-plan-state", "operate-repo", "state.json"), "w"))
print(os.path.basename(sd), file=open(os.path.join(sys.argv[3], "ship-state"), "w"))
PY
SHIP="$REPO/.dev-plan-state/$(cat "$WORK/ship-state")"
bash "$PLUGIN_ROOT/../apex-dispatch/scripts/report.sh" --state "$SHIP" --per-task --json >"$WORK/report-pt.json" || fail "console-plans-payload: report.sh --per-task failed"
sums() { (cd "$REPO/.dev-plan-state" && find . -type f -exec cksum {} + | sort | cksum; cd "$REPO/.claude" && cksum apex-scope-loop/LESSONS.md apex-scope-loop/BACKLOG.md apex-scope-loop/monitor.json tasks/ship-intent.md; stat -f '%m %z' apex-scope-loop/LESSONS.md apex-scope-loop/BACKLOG.md 2>/dev/null || stat -c '%Y %s' apex-scope-loop/LESSONS.md apex-scope-loop/BACKLOG.md); }
SUM_BEFORE="$(sums)"
"$BIN" progress >"$WORK/p2.json" || fail "console-plans-payload: progress failed"
[ "$SUM_BEFORE" = "$(sums)" ] || fail "console-plans-payload: the console wrote into the state base, LESSONS.md or BACKLOG.md"
python3 - "$WORK/p2.json" "$WORK/report-pt.json" "$(cat "$WORK/ship-state")" <<'PY' || fail "console-plans-payload: the plans payload is wrong"
import json, sys
repo = json.load(open(sys.argv[1]))["repos"][0]
rep = json.load(open(sys.argv[2]))
by = {p["hash"]: p for p in repo["plans"]}
ship, bare = by[sys.argv[3]], [p for p in repo["plans"] if p["slug"] == "bare"][0]
demo = [p for p in repo["plans"] if p["slug"] == "demo"][0]
# scope: header value; a scope-less plan is feature
assert ship["scope"] == "poc" and bare["scope"] == "feature" and demo["scope"] == "feature", (ship["scope"], bare["scope"])
# intent: summary when the file exists, null otherwise
assert ship["intent"]["problem"].startswith("Operators cannot see") and ship["intent"]["non_goals"] == "Dashboards.", ship["intent"]
assert bare["intent"] is None and demo["intent"] is None
# per-task cost is report.per_task's, task by task (null where report says n/a)
rt = {t["task"]: t for t in rep["tasks"]}
assert set(rt) == {7, 9}, rt.keys()
pt = {t["line"]: t for t in ship["tasks"]}
assert rt[7]["usd"] is not None and rt[9]["usd"] is None, (rt[7]["usd"], rt[9]["usd"])    # background agent: n/a
tl = {t["line"]: t for t in ship["tasks"]}
assert set(tl) == {7, 9}, tl.keys()
for ln, t in rt.items():     # the payload's per-task figures are the CLI's, null where it says n/a
    for k_out, k_rep in (("usd", "usd"), ("tokens", "tokens_total"), ("orchestrator_usd", "orchestrator_usd"),
                         ("orchestrator_tokens", "orchestrator_tokens_total"), ("orchestrator_na", "orchestrator_na")):
        assert tl[ln][k_out] == t[k_rep], (ln, k_out, tl[ln][k_out], t[k_rep])
assert tl[9]["usd"] is None and tl[9]["tokens"] is None and tl[7]["usd"] is not None and tl[7]["orchestrator_usd"] is not None
assert tl[9]["orchestrator_usd"] is None and tl[9]["orchestrator_na"], tl[9]
assert ship["cost"]["delegated_usd"] == rep["totals"]["usd"], (ship["cost"], rep["totals"]["usd"])
assert ship["cost"]["orchestrator_usd"] == rep["totals"]["orchestrator_usd"] is not None
assert ship["cost"]["orchestrator_unattributed_usd"] == rep["totals"]["orchestrator_unattributed_usd"]
assert ship["cost"]["status"] == rep["totals"]["orchestrator_status"] == "measured", ship["cost"]
# operate: window, deploys, checks, open-at-close
o = ship["operate"]
assert o["state"] == "ok" and [d["exit"] for d in o["deploys"]] == [1, 0] and o["last_deploy"]["sha"] == "b" * 40, o
assert o["window"]["state"] == "open" and o["window"]["day"] == 3 and o["window"]["days"] == 14, o["window"]
ck = {c["id"]: c for c in o["checks"]}
assert ck["err"]["breaches"] is None and ck["err"]["unmeasured_runs"] is None, ck["err"]      # missing or non-int (bool) count: null, never 0
assert ck["p95"]["unmeasured_runs"] == 0 and o["last_closed_window"] is None and o["windows_closed"] == 0
assert ck["p95"]["last_value"] == 950 and ck["p95"]["threshold"] == 800 and ck["p95"]["breaches"] == 2 and ck["p95"]["filed"] == "lessons", ck["p95"]
assert ck["err"]["last_value"] is None and ck["err"]["unmeasured"] is True and ck["err"]["last_measured_value"] == 1, ck["err"]
assert ck["never"]["last_value"] is None and ck["never"]["measured"] is False and ck["never"]["breaches"] is None and ck["never"]["unmeasured"] is True, ck["never"]
assert ship["operate"]["tag"] == "operate:ship"
# missing operate state is reported as missing, not zeros; a plan that has not landed has no operate block
assert bare["operate"]["state"] == "missing" and bare["operate"]["deploys"] == [] and bare["operate"]["window"] == {"state": "not-opened"}, bare["operate"]
assert demo["operate"] is None
# ingested lessons / backlog under operate:<slug>: ids and short titles, other plans' and reviewer items excluded
ig = ship["operate"]["ingested"]
assert ig["lessons"] == [{"id": "L-002", "title": "operate-ship-p95-breach"}], ig
assert [(b["id"], b["done"]) for b in ig["backlog"]] == [("B-001", False), ("B-002", True)], ig
assert ig["backlog"][0]["title"].startswith("errors 9 breached") and len(ig["backlog"][0]["title"]) <= 100, ig
assert ig["counts"] == {"lessons": 1, "backlog": 2, "backlog_open": 1}, ig
assert bare["operate"]["ingested"]["counts"] == {"lessons": 0, "backlog": 0, "backlog_open": 0}, bare["operate"]["ingested"]
# the last closed window block (what operate.sh status prints), plus the count
cl = [p for p in repo["plans"] if p["slug"] == "closed"][0]["operate"]
assert cl["windows_closed"] == 2 and cl["window"]["state"] == "closed" and cl["window"]["outcome"] == "closed-with-breaches", cl["window"]
lw = cl["last_closed_window"]
assert (lw["outcome"], lw["closed_by"], lw["open_at_close"], lw["unmeasured_at_close"], lw["measured_runs"], lw["breaches"]) == \
    ("closed-with-breaches", "monitor", ["p95"], ["never"], 3, 4), lw
assert lw["start"] and lw["end"] and lw["never_measured"] is False, lw
assert cl["ingested"]["counts"]["backlog"] == 0
# watched plans and repo-level checks
assert [w["slug"] for w in repo["watched"]] == ["ship"] and repo["watched"][0]["day"] == 3, repo["watched"]
rc = repo["repo_checks"]
assert rc["state"] == "ok" and rc["configured"], rc
assert [(b["id"], b["done"]) for b in rc["ingested"]["backlog"]] == [("B-005", False)] and "lessons" not in rc["ingested"], rc["ingested"]
assert rc["ingested"]["counts"] == {"backlog": 1, "backlog_open": 1}, rc["ingested"]
rk = {c["id"]: c for c in rc["checks"]}
assert rk["site"]["last_value"] == 120 and rk["site"]["last_status"] == "ok" and rk["queue"]["last_value"] is None and rk["queue"]["measured"] is False, rk
PY
python3 - "$WORK/p2.json" "$WORK/report-pt.json" "$(cat "$WORK/ship-state")" "$PLUGIN_ROOT" <<'PY' || fail "console-plans-payload: per-task cost differs from report.sh --per-task"
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[4], "scripts", "lib"))
import ac_collect
repo = json.load(open(sys.argv[1]))["repos"][0]
rep = {t["task"]: t for t in json.load(open(sys.argv[2]))["tasks"]}
ship = [p for p in repo["plans"] if p["hash"] == sys.argv[3]][0]
cst = ac_collect.plan_cost(os.path.join(repo["path"], ".dev-plan-state", sys.argv[3]), "dispatch")
assert set(cst["tasks"]) == set(rep) == {7, 9}
for ln, t in rep.items():
    c = cst["tasks"][ln]
    assert c["usd"] == t["usd"] and c["tokens_total"] == t["tokens_total"], (ln, c["usd"], t["usd"])
    assert c["orchestrator_usd"] == t["orchestrator_usd"] and c["orchestrator_na"] == t["orchestrator_na"]
assert rep[9]["usd"] is None and rep[7]["usd"] is not None and rep[7]["orchestrator_usd"] is not None and rep[9]["orchestrator_usd"] is None
# F-001: the cost cache holds ONE entry per state dir however many 30 s buckets pass; the bucket and the transcripts' (mtime, size)
# are in the stamp. Other cached results (scope, intent, operate, repo checks, ledgers) are keyed on files, not on time.
sd = os.path.join(repo["path"], ".dev-plan-state", sys.argv[3])
calls = []
real = ac_collect.dispatch_mods()[1].per_task
ac_collect.dispatch_mods()[1].per_task = lambda *a, **k: (calls.append(a[1]), real(*a, **k))[1]
snap = ac_collect.repo_snapshot({"id": "r1", "path": repo["path"]})
ac_collect.plan_cost(sd, "dispatch")      # loads and caches the sibling modules before the interpreter-state snapshot
sys.dont_write_bytecode = False                  # whatever the environment says: loading monitorlib must not flip it
path_before, bytecode_before = list(sys.path), sys.dont_write_bytecode
def sweep(i):
    ac_collect._cost_bucket = lambda: 1000 + i              # a stubbed 30 s bucket
    ac_collect.repo_snapshot({"id": "r1", "path": repo["path"]})
    for p in snap["plans"]:
        slug = ac_collect.plan_slug(p["plan_path"])
        scope = ac_collect.plan_scope(p["plan_abs"])
        ac_collect.plan_operate(p["checkpoint"], p["plan_abs"], slug, scope, now=1.8e9 + i * 86400, top=snap["top"])
        ac_collect.plan_intent(snap["top"], slug)
        ac_collect.plan_cost(p["dir"], p["ledger"].get("dir"))
    ac_collect.repo_checks(snap["top"], snap["state_base"])
sweep(0)
size0, costkeys0 = len(ac_collect._cache), [k for k in ac_collect._cache if k[0] == "cost"]
want = sorted(("cost", p["dir"]) for p in snap["plans"] if p["ledger"].get("dir"))
assert sorted(costkeys0) == want and ("cost", sd) in want, (costkeys0, want)      # one per state dir that has a ledger
n0 = calls.count(sd)
for i in range(1, 9):
    sweep(i)
assert len(ac_collect._cache) == size0, (size0, len(ac_collect._cache))                # nothing accumulates per bucket or per poll
assert sorted(k for k in ac_collect._cache if k[0] == "cost") == want
assert calls.count(sd) - n0 == 8, (n0, calls.count(sd))                                          # one recompute per new bucket, none within one
ac_collect._cost_bucket = lambda: 1000 + 8
ac_collect.plan_cost(sd, "dispatch"); ac_collect.plan_cost(sd, "dispatch")
assert calls.count(sd) - n0 == 8, "a repeated call in the same bucket recomputed"
tp = [os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "projects", "p", f) for f in os.listdir(os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "projects", "p"))][0]
open(tp, "a").write("\n")                                                              # a transcript grows inside the same bucket
ac_collect.plan_cost(sd, "dispatch")
assert calls.count(sd) - n0 == 9 and sorted(k for k in ac_collect._cache if k[0] == "cost") == want, "a grown transcript did not refresh the entry"
# monitorlib is loaded from its file path: no sys.path entry, no bytecode flag flipped, no module name left behind
assert sys.path == path_before, (sys.path[:3], path_before[:3])
sl = os.path.join(ac_collect.C.sibling("apex-scope-loop"), "skills", "apex-execute", "scripts")
assert sl not in sys.path and sys.path[:1] != [sl] and "monitorlib" not in sys.modules and "planlib" not in sys.modules, (sys.path[:3])
assert sys.dont_write_bytecode is False, "monitorlib turned bytecode writing off for the console process"
PY
pass "console-plans-payload: scope (scope-less = feature), intent summary, operate block (deploys, day N of M, per-check latest/breaches/unmeasured, missing state is missing), watched plans, repo checks, and per-task cost equal to report.sh --per-task (n/a stays null); the state base is untouched"

echo ""
echo "smoke passed: $N/$N checks"
