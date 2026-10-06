#!/usr/bin/env bash
# apex-dispatch structural smoke test
# Verifies the plugin contract from ADR-0001. Exits non-zero on first failure.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKET_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
fail() { echo "smoke FAIL: $1" >&2; exit 1; }
ok()   { echo "smoke OK:   $1"; }
N=0; pass() { N=$((N + 1)); ok "$1"; }

# 1. plugin.json exists and has required fields
PJ="$PLUGIN_ROOT/.claude-plugin/plugin.json"
[ -f "$PJ" ] || fail "missing $PJ"
for k in name version description author license keywords; do
  grep -q "\"$k\"" "$PJ" || fail "plugin.json missing key: $k"
done
grep -q '"name": "apex-dispatch"' "$PJ" || fail "plugin.json name is not apex-dispatch"
pass "plugin.json has name/version/description/author/license/keywords"

# 2. plugin.json does NOT enumerate skills/commands/agents arrays
for forbidden in '"skills"' '"commands"' '"agents"'; do
  if grep -qE "$forbidden[[:space:]]*:[[:space:]]*\[" "$PJ"; then
    fail "plugin.json enumerates $forbidden array (must be auto-discovered)"
  fi
done
pass "plugin.json does not enumerate skills/commands/agents"

# 3. registered in the marketplace with a matching description
python3 - "$MARKET_ROOT/.claude-plugin/marketplace.json" "$PJ" <<'PY' || fail "apex-dispatch not registered in marketplace.json with the plugin's description"
import json, sys
m = json.load(open(sys.argv[1])); p = json.load(open(sys.argv[2]))
e = [x for x in m["plugins"] if x.get("source") == "./plugins/apex-dispatch"]
assert len(e) == 1 and e[0]["name"] == "apex-dispatch" and e[0]["description"] == p["description"]
PY
pass "registered in marketplace.json (source ./plugins/apex-dispatch, same description)"

# 4. root README lists the plugin
grep -q '(plugins/apex-dispatch)' "$MARKET_ROOT/README.md" || fail "root README has no apex-dispatch row"
pass "root README row present"

# 5. README has the required sections
R="$PLUGIN_ROOT/README.md"
for h in "## Compatibility" "## Namespace coordination" "## Verification" "## Architecture Decisions"; do
  grep -q "^$h" "$R" || fail "README missing section: $h"
done
pass "README has Compatibility / Namespace coordination / Verification / Architecture Decisions"

# 6. ADR-0001 exists with a Status
ADR="$PLUGIN_ROOT/docs/adrs/0001-apex-dispatch-contract.md"
[ -f "$ADR" ] || fail "missing $ADR"
grep -qE "^- \*\*Status:\*\* (Proposed|Accepted)" "$ADR" || fail "ADR-0001 has no Proposed/Accepted status"
pass "ADR-0001 exists with a status"

# 7. namespace claimed in README and ADR
for f in "$R" "$ADR"; do grep -q 'apex-dispatch:routes/' "$f" || fail "$f does not claim the apex-dispatch:* namespace"; done
pass "namespace apex-dispatch:* claimed"

# 8. every script is executable
for s in "$PLUGIN_ROOT"/scripts/*.sh "$PLUGIN_ROOT"/bin/*.sh "$PLUGIN_ROOT"/hooks/*.sh; do
  [ -e "$s" ] || continue
  [ -x "$s" ] || fail "not executable: $s"
done
pass "scripts are executable"

# 9. no platform coupling in engine sources (only directories that exist are
#    searched, so a missing bin/ or hooks/ cannot mask a hit)
COUPLING_DIRS=()
for d in "$PLUGIN_ROOT/scripts" "$PLUGIN_ROOT/bin" "$PLUGIN_ROOT/hooks"; do
  [ -d "$d" ] && COUPLING_DIRS+=("$d")
done
COUPLING_HITS=""
if [ "${#COUPLING_DIRS[@]}" -gt 0 ]; then
  COUPLING_HITS="$(grep -rIl 'apex-app\|getapexinsights\|claude-flow' "${COUPLING_DIRS[@]}" 2>/dev/null | grep -v '/scripts/smoke.sh$' || true)"
fi
[ -z "$COUPLING_HITS" ] || fail "engine sources reference apex-app/getapexinsights/claude-flow: $(printf '%s' "$COUPLING_HITS" | head -3 | tr '\n' ' ')"
pass "no apex-app/getapexinsights/claude-flow coupling in engine sources"

# 10. version is semver
python3 -c "import json,re,sys; v=json.load(open(sys.argv[1]))['version']; assert re.fullmatch(r'\d+\.\d+\.\d+', v)" "$PJ" || fail "version is not semver"
pass "version is semver"

# --- Phase 2.2: policy, overlay, compile ------------------------------------
COMPILE="$PLUGIN_ROOT/scripts/compile.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/apex-dispatch-smoke.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# 11. policy inputs exist and every compiled artifact is current
for f in resources/dispatch.default.json resources/sections.json resources/schema.json scripts/lib/compile.py; do
  [ -f "$PLUGIN_ROOT/$f" ] || fail "missing $f"
done
[ -x "$COMPILE" ] || fail "scripts/compile.sh is not executable"
bash "$COMPILE" --check >/dev/null 2>"$WORK/check.err" || fail "compile.sh --check: $(cat "$WORK/check.err")"
pass "compile.sh --check passes on the committed tree"

# 12. a stale or missing artifact is detected and named (in a copy of the plugin)
cp -R "$PLUGIN_ROOT" "$WORK/copy"
printf '\n' >> "$WORK/copy/agents/reviewer.md"
rm "$WORK/copy/resources/settings-snippet.json"
if bash "$WORK/copy/scripts/compile.sh" --check >/dev/null 2>"$WORK/stale.err"; then
  fail "compile.sh --check passed with a stale artifact"
fi
grep -q 'stale: agents/reviewer.md' "$WORK/stale.err" || fail "--check did not name the stale agents/reviewer.md"
grep -q 'missing: resources/settings-snippet.json' "$WORK/stale.err" || fail "--check did not name the missing settings snippet"
bash "$WORK/copy/scripts/compile.sh" >/dev/null && bash "$WORK/copy/scripts/compile.sh" --check >/dev/null \
  || fail "compile.sh did not repair the stale copy"
pass "stale and missing artifacts are detected by name and repaired by compile.sh"

# 13. overlay merge: omit inherits, [] clears, merge by id with the project winning
merged() { bash "$COMPILE" --print-merged --overlay "$1"; }
printf '%s' '{"classes":[{"id":"docs","budgets":{"usd":0.25}},{"id":"chore","tier_floor":"cheap","tier_ceiling":"cheap","roster":["docs"],"fanout":{"shape":"single","max_lanes":1},"review_shape":{"A":"solo","B":"six-lens","C":"fanout6+adversarial"},"review_diversity":{"A":"off","B":"warn","C":"block"},"providers_allowed":["claude-session"],"requires_command_acceptance":false,"external_builders":false,"budgets":{"usd":0.1,"spawns":1,"minutes":5}}],"tag_classes":[],"semantic":{"min_p":0.9}}' > "$WORK/ov-merge.json"
merged "$WORK/ov-merge.json" > "$WORK/merged.json" || fail "a valid overlay was rejected"
python3 - "$WORK/merged.json" "$PLUGIN_ROOT/resources/compiled/policy.json" <<'PY' || fail "overlay merge semantics wrong (omit/[]/by-id/deep)"
import json, sys
m = json.load(open(sys.argv[1])); d = json.load(open(sys.argv[2]))
cls = {c["id"]: c for c in m["classes"]}
assert m["roles"] == d["roles"] and m["tiers"] == d["tiers"]                 # omitted: inherited
assert m["tag_classes"] == []                                                 # []: cleared
assert cls["docs"]["budgets"] == {"usd": 0.25, "spawns": 2, "minutes": 15}    # by id, project wins, rest kept
assert cls["docs"]["roster"] == [c for c in d["classes"] if c["id"] == "docs"][0]["roster"]
assert [c["id"] for c in m["classes"]][-1] == "chore" and len(m["classes"]) == len(d["classes"]) + 1
assert m["semantic"]["min_p"] == 0.9 and m["semantic"]["timeout_ms"] == d["semantic"]["timeout_ms"]  # map deep-merge
PY
pass "overlay: omit inherits, [] clears, lists merge by id with the project winning, maps deep-merge"

# 14. overlay: disabled subtracts with a reason; invalid overlays fail clearly
printf '%s' '{"disabled":[{"section":"roles","id":"researcher","reason":"no web research in this repo"}]}' > "$WORK/ov-dis.json"
merged "$WORK/ov-dis.json" | python3 -c 'import json,sys; m=json.load(sys.stdin); assert "researcher" not in [r["id"] for r in m["roles"]]; assert all("researcher" not in p["roles_allowed"] for p in m["providers"])' \
  || fail "disabled with a reason did not subtract the entry"
expect_reject() {  # $1 label, $2 overlay JSON, $3 expected stderr fragment
  printf '%s' "$2" > "$WORK/ov-bad.json"
  if merged "$WORK/ov-bad.json" >/dev/null 2>"$WORK/bad.err"; then fail "overlay accepted: $1"; fi
  grep -q -- "$3" "$WORK/bad.err" || fail "overlay '$1' rejected without naming '$3': $(cat "$WORK/bad.err")"
}
expect_reject "disabled without reason" '{"disabled":[{"id":"researcher"}]}' 'has no reason'
expect_reject "unknown class reference" '{"tag_classes":[{"id":"x-tags","tags":["x"],"class":"no-such-class"}]}' 'unknown class reference "no-such-class"'
expect_reject "unknown role in roster" '{"classes":[{"id":"docs","roster":["ghost"]}]}' 'unknown role reference "ghost"'
expect_reject "bad enum value" '{"classes":[{"id":"docs","brief":"freeform"}]}' 'is not one of'
expect_reject "clearing hard rules" '{"hard_rules":[]}' 'cannot be cleared'
expect_reject "unknown section" '{"routes":[]}' "unknown section 'routes'"
expect_reject "uncalibrated may lower cost" '{"semantic":{"uncalibrated_may_lower_cost":true}}' 'must be false'
printf '%s' 'not json' > "$WORK/ov-garbage.json"
if merged "$WORK/ov-garbage.json" >/dev/null 2>&1; then fail "garbage overlay accepted"; fi
pass "overlay: disabled subtracts (reason required); invalid overlays exit non-zero with a named reason"

# 15. generated agents: reviewers have no Bash, builders have no Agent; no isolation or Bash patterns
AG="$PLUGIN_ROOT/agents"
for a in builder builder-high builder-xhigh tester docs researcher reviewer adversarial-reviewer diagnoser provider-runner; do
  [ -f "$AG/$a.md" ] || fail "missing generated agent agents/$a.md"
  grep -q "^name: $a\$" "$AG/$a.md" || fail "agents/$a.md frontmatter name is not $a"
done
for a in reviewer adversarial-reviewer diagnoser; do
  grep -q '^tools: Read, Grep, Glob$' "$AG/$a.md" || fail "agents/$a.md tools are not exactly Read, Grep, Glob"
  grep -q '^disallowedTools: Bash, Edit, Write, MultiEdit, NotebookEdit, Agent, mcp__\*$' "$AG/$a.md" || fail "agents/$a.md disallowedTools incomplete"
done
for a in builder builder-high builder-xhigh; do
  grep -E '^tools:' "$AG/$a.md" | grep -qw Agent && fail "agents/$a.md grants Agent"
  grep -E '^disallowedTools:' "$AG/$a.md" | grep -qw Agent || fail "agents/$a.md does not disallow Agent"
done
grep -q '^effort: high$' "$AG/builder-high.md" && grep -q '^effort: xhigh$' "$AG/builder-xhigh.md" || fail "builder effort variants wrong"
for f in "$AG"/*.md; do
  grep -q 'isolation:' "$f" && fail "$(basename "$f") contains isolation:"
  grep -q 'Bash(' "$f" && fail "$(basename "$f") contains a Bash( pattern"
  keys="$(awk '/^---$/{n++; next} n==1{print}' "$f" | sed 's/:.*//' | sort | tr '\n' ' ')"
  for k in $keys; do
    case "$k" in name|description|tools|disallowedTools|effort|maxTurns|model) ;; *) fail "$(basename "$f") has frontmatter key $k";; esac
  done
  case "$(basename "$f" .md)" in gibson-reviewer|plan-author) fail "agent name collides with apex-scope-loop";; esac
done
pass "generated agents: reviewers Read/Grep/Glob only, builders without Agent, no isolation or Bash patterns"

# 16. hooks.json wraps "hooks"; settings snippet has the deny rules and no ask
python3 - "$PLUGIN_ROOT/hooks/hooks.json" "$PLUGIN_ROOT/resources/settings-snippet.json" "$PLUGIN_ROOT/hooks" <<'PY' || fail "hooks.json or settings-snippet.json violates the contract"
import json, os, sys
h = json.load(open(sys.argv[1])); s = json.load(open(sys.argv[2]))
assert list(h) == ["hooks"] and isinstance(h["hooks"], dict)
scripts = sorted(f for f in os.listdir(sys.argv[3]) if f.endswith(".sh"))
cmds = [x["command"] for groups in h["hooks"].values() for g in groups for x in g["hooks"]]
assert all('"${CLAUDE_PLUGIN_ROOT}/hooks/' in c for c in cmds)
assert all(x.get("timeout") for groups in h["hooks"].values() for g in groups for x in g["hooks"])
assert sorted({c.split("/hooks/")[1].rstrip('"') for c in cmds}) == scripts  # registered == present
deny = s["permissions"]["deny"]
for r in ["Bash(* --dangerously-*)", "Bash(* --yolo*)", "Bash(* --always-approve*)", "Bash(* --full-auto*)", "Bash(git push --force*)"]:
    assert r in deny, r
assert "ask" not in s["permissions"] and "ask" not in json.dumps(s).lower().replace("task", "")
sb = s["sandbox"]
assert sb["enabled"] is True and sb["failIfUnavailable"] is True and sb["allowUnsandboxedCommands"] is False
PY
pass "hooks.json wraps hooks (only present scripts); settings snippet has the deny rules and sandbox, no ask"

# 17. providers: an overlay may only toggle enabled, narrow classes/roles, lower max_tier,
#     raise min_acceptance and add forbidden flags; nothing else, and no new provider ids
printf '%s' '{"providers":[{"id":"codex","enabled":false,"forbidden_flags":["--extra-risky"],"allowed_classes":["docs","tests"],"roles_allowed":["tester"],"max_tier":"cheap","min_acceptance":0.9}]}' > "$WORK/ov-prov.json"
merged "$WORK/ov-prov.json" 2>"$WORK/prov.err" | python3 -c 'import json,sys; m={p["id"]:p for p in json.load(sys.stdin)["providers"]}["codex"]; assert m["forbidden_flags"][-1] == "--extra-risky" and "-a" in m["forbidden_flags"] and "danger-full-access" in m["forbidden_flags"]; assert m["enabled"] is False and m["allowed_classes"] == ["docs","tests"] and m["max_tier"] == "cheap" and m["min_acceptance"] == 0.9' \
  || fail "allowed provider overlay edits were not accepted/applied: $(cat "$WORK/prov.err")"
# reviewer probes: appended forced flags that override earlier ones
expect_reject "claude-p bypassPermissions" '{"providers":[{"id":"claude-p","forced_flags":["-p","--setting-sources","user","--permission-mode","dontAsk","--permission-prompts","none","--output-format","json","--permission-mode","bypassPermissions"]}]}' 'providers\[claude-p\].forced_flags: an overlay may not set this field'
expect_reject "claude-p setting sources + allowedTools" '{"providers":[{"id":"claude-p","forced_flags":["-p","--setting-sources","user,project,local","--allowedTools","Bash"]}]}' 'providers\[claude-p\].forced_flags: an overlay may not set this field'
expect_reject "grok sandbox off" '{"providers":[{"id":"grok","forced_flags":["-p","--sandbox","strict","--worktree","--no-subagents","--output-format","streaming-messages-json","--sandbox","off"]}]}' 'providers\[grok\].forced_flags: an overlay may not set this field'
expect_reject "codex add-dir /" '{"providers":[{"id":"codex","forced_flags":["exec","--add-dir","/"]}]}' 'providers\[codex\].forced_flags: an overlay may not set this field'
expect_reject "codex network access" '{"providers":[{"id":"codex","forced_flags":["exec","-c","sandbox_workspace_write.network_access=true"]}]}' 'providers\[codex\].forced_flags: an overlay may not set this field'
# reviewer probes: new provider ids
expect_reject "new claude-p2 provider" '{"providers":[{"id":"claude-p2","status":"verified","kind":"subprocess","family":"anthropic-separate-session","binary":"claude","key_env":null,"forced_flags":["-p","--permission-mode","bypassPermissions"],"forbidden_flags":[],"allowed_classes":["docs"],"max_tier":"cheap","roles_allowed":["docs"],"reports_usage":true,"sandbox_mode":null,"min_acceptance":0.7,"acceptance_window":20,"hosts":[],"enabled":true}]}' 'providers\[claude-p2\]: an overlay may not add a provider'
expect_reject "new in-session provider running codex" '{"providers":[{"id":"evil","status":"verified","kind":"in-session","family":"anthropic","binary":"codex","key_env":null,"forced_flags":[],"forbidden_flags":[],"allowed_classes":["docs"],"max_tier":"cheap","roles_allowed":["docs"],"reports_usage":true,"sandbox_mode":null,"min_acceptance":0.7,"acceptance_window":20,"hosts":[],"enabled":true}]}' 'providers\[evil\]: an overlay may not add a provider'
# any non-allowlisted field on a default provider
for f in '"binary":"/tmp/codex"' '"kind":"in-session"' '"family":"anthropic"' '"sandbox_mode":"read-only"' '"hosts":["evil.example"]' '"key_env":"OTHER_KEY"' '"reports_usage":false' '"status":"verified"' '"acceptance_window":1'; do
  k="${f%%\":*}"; k="${k#\"}"
  expect_reject "setting provider $k" '{"providers":[{"id":"codex",'"$f"'}]}' "providers\\[codex\\].$k: an overlay may not set this field"
done
expect_reject "widening allowed_classes" '{"providers":[{"id":"grok","allowed_classes":["docs","tests","feature"]}]}' 'allowed_classes: an overlay may only narrow'
expect_reject "widening roles_allowed" '{"providers":[{"id":"codex","roles_allowed":["builder","provider-runner"]}]}' 'roles_allowed: an overlay may only narrow'
expect_reject "raising max_tier" '{"providers":[{"id":"codex","max_tier":"max"}]}' 'max_tier: an overlay may only lower it'
expect_reject "lowering min_acceptance" '{"providers":[{"id":"codex","min_acceptance":0.1}]}' 'min_acceptance: an overlay may only raise it'
expect_reject "clearing forbidden_flags" '{"providers":[{"id":"codex","forbidden_flags":[]}]}' 'forbidden_flags: add-only'
expect_reject "clearing providers" '{"providers":[]}' 'providers cannot be cleared'
pass "overlay: providers allowlist (enabled, narrow classes/roles, lower max_tier, raise min_acceptance, add forbidden flags); no new providers"

# 18. tiers are not overlayable at all; role restrictions hold
expect_reject "changing a tier model" '{"tiers":[{"id":"strong","model":"sonnet"}]}' 'tiers cannot be changed, added or cleared'
expect_reject "changing a tier budget" '{"tiers":[{"id":"cheap","maxTurns":5}]}' 'tiers cannot be changed, added or cleared'
expect_reject "adding a tier" '{"tiers":[{"id":"ultra","rank":4,"model":"fable","effort":"xhigh","maxTurns":10,"context_budget_tokens":1000,"price_usd_per_mtok":{"input":1,"output":1,"cache_read":0.1,"cache_write":1}}]}' 'tiers cannot be changed, added or cleared'
expect_reject "disabling a tier" '{"disabled":[{"section":"tiers","id":"max","reason":"cost"}]}' 'tiers cannot be disabled'
expect_reject "making a read-only role writable" '{"roles":[{"id":"researcher","read_only":false}]}' 'may not make a read-only role writable'
expect_reject "granting a role a tool" '{"roles":[{"id":"docs","tools":["Read","Grep","Glob","Edit","Write","MultiEdit","Bash"]}]}' 'roles\[docs\].tools: an overlay may not grant Bash'
expect_reject "dropping a disallowed tool" '{"roles":[{"id":"docs","disallowed_tools":["Agent","NotebookEdit"]}]}' 'roles\[docs\].disallowed_tools: an overlay may not remove Bash'
python3 -c '
import json, sys
t = sorted(json.load(open(sys.argv[1]))["tiers"], key=lambda x: x["rank"])
S = {"haiku": 0, "sonnet": 1, "opus": 2, "fable": 2}; E = ["low", "medium", "high", "xhigh"]
assert all(S[a["model"]] <= S[b["model"]] and E.index(a["effort"]) <= E.index(b["effort"]) for a, b in zip(t, t[1:]))
' "$PLUGIN_ROOT/resources/dispatch.default.json" || fail "default tiers are not monotonic in model strength and effort"
pass "overlay: tiers cannot be changed, added, cleared or disabled; role restrictions hold; default tiers monotonic"

# 19. appended route_floor rules may only match or tighten (rules combine by max)
expect_reject "weaker Tier C diversity" '{"hard_rules":[{"id":"my-c","kind":"route_floor","match":"all","description":"x","when":{"risk_tier":"C"},"then":{"review_diversity":"off"}}]}' 'weaker than hard rule tier-c-floor'
expect_reject "weaker Tier B review shape" '{"hard_rules":[{"id":"my-b","kind":"route_floor","match":"all","description":"x","when":{"risk_tier":"B"},"then":{"review_shape":"solo"}}]}' 'weaker than hard rule tier-b-review'
expect_reject "lower floor for security tags" '{"hard_rules":[{"id":"my-sec","kind":"route_floor","match":"any","description":"x","when":{"tags_any":["security"]},"then":{"tier_floor":"cheap"}}]}' 'weaker than hard rule tier-c-floor'
printf '%s' '{"hard_rules":[{"id":"my-b-strict","kind":"route_floor","match":"all","description":"x","when":{"risk_tier":"B"},"then":{"review_diversity":"block"}}]}' > "$WORK/ov-rule.json"
merged "$WORK/ov-rule.json" >/dev/null 2>&1 || fail "a stricter appended hard rule was rejected"
grep -q 'combine by max (strictest wins)' "$ADR" || fail "ADR-0001 does not state that matching hard rules combine by max"
expect_reject "appended tier_ceiling" '{"hard_rules":[{"id":"my-ceil","kind":"route_floor","match":"all","description":"x","when":{"role":"builder"},"then":{"tier_ceiling":"cheap"}}]}' 'may not set a tier ceiling'
pass "overlay: appended route_floor rules may only match or tighten (no tier_ceiling); ADR states max (strictest wins)"

# 20. escalation: review rounds and the halt rung stay at 3 or below
expect_reject "raising max_review_rounds" '{"escalation":{"max_review_rounds":4}}' 'max_review_rounds: 4 is above 3'
expect_reject "moving the halt rung up" '{"escalation":{"rungs":[{"id":"halt","at_failures":5}]}}' 'halt rung at_failures 5 is above 3'
printf '%s' '{"escalation":{"max_review_rounds":2}}' > "$WORK/ov-esc.json"
merged "$WORK/ov-esc.json" >/dev/null 2>&1 || fail "a stricter max_review_rounds was rejected"
pass "overlay: escalation may be made stricter, never looser"

# 21. roles a hard rule's review shape needs cannot be disabled
expect_reject "disabling adversarial-reviewer" '{"disabled":[{"section":"roles","id":"adversarial-reviewer","reason":"cost"}]}' 'roles\[adversarial-reviewer\]: required by hard rule tier-c-floor'
expect_reject "switching reviewer off" '{"roles":[{"id":"reviewer","enabled":false}]}' 'roles\[reviewer\]: required by hard rule'
pass "overlay: reviewer and adversarial-reviewer cannot be disabled"

# 22. agents/ is fully generated; --check is byte-exact
rm -rf "$WORK/copy2"; cp -R "$PLUGIN_ROOT" "$WORK/copy2"
printf -- '---\nname: x\ndescription: hand-written\n---\nbody\n' > "$WORK/copy2/agents/x.md"
if bash "$WORK/copy2/scripts/compile.sh" --check >/dev/null 2>"$WORK/foreign.err"; then fail "--check passed with a hand-written agents/x.md"; fi
grep -q 'not generated: agents/x.md' "$WORK/foreign.err" || fail "--check did not name the hand-written agents/x.md: $(cat "$WORK/foreign.err")"
rm "$WORK/copy2/agents/x.md"
python3 -c 'import sys; p=sys.argv[1]; b=open(p,"rb").read(); open(p,"wb").write(b.replace(b"\n", b"\r\n"))' "$WORK/copy2/agents/builder.md"
if bash "$WORK/copy2/scripts/compile.sh" --check >/dev/null 2>"$WORK/crlf.err"; then fail "--check passed with a CRLF agents/builder.md"; fi
grep -q 'stale: agents/builder.md' "$WORK/crlf.err" || fail "--check did not name the CRLF agents/builder.md"
grep -qF 'Generated agents omit `model:`** deliberately' "$ADR" || fail "ADR-0001 does not record why generated agents omit model:"
pass "--check flags any non-generated agents/*.md and detects a CRLF artifact"

echo ""
echo "smoke passed: $N/$N checks"
