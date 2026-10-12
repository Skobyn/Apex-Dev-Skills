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

echo ""
echo "smoke passed: $N/$N checks"
