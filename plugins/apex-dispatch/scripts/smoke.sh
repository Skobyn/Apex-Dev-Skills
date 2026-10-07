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

# --- Phase 2.3: route.sh (table-only) ----------------------------------------
ROUTE="$PLUGIN_ROOT/scripts/route.sh"
for v in $(compgen -e | grep '^APEX_' || true); do unset "$v"; done
# hooks/subagent-stop.sh ships (Phase 3.2), so <state>/dispatch/ (provenance mode)
# is the default. The Phase 2 and 3.1 checks below exercise the transitional
# <state>/dispatch-shadow/ through the human opt-out APEX_DISPATCH_ENFORCE=0;
# check 35 covers the switch and the Phase 3.2 checks run enforced.
export APEX_DISPATCH_ENFORCE=0
export GIT_AUTHOR_NAME=smoke GIT_AUTHOR_EMAIL=smoke@example.invalid GIT_COMMITTER_NAME=smoke GIT_COMMITTER_EMAIL=smoke@example.invalid
has() { grep -q -- "$1" <<<"$2"; }
val() { sed -n "s/^$1: //p" <<<"$2" | head -1; }

# 23. route.sh is executable and --version equals plugin.json version
[ -x "$ROUTE" ] && [ -f "$PLUGIN_ROOT/scripts/lib/route.py" ] || fail "scripts/route.sh or scripts/lib/route.py missing"
[ "$(bash "$ROUTE" --version)" = "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PJ")" ] \
  || fail "route.sh --version does not equal plugin.json version"
pass "route.sh --version == plugin.json version"

# Fixture: a plain git repo with one plan (no toolchain markers).
FX="$WORK/fx"; mkdir -p "$FX/plans"; git init -q -b main "$FX"
cat >"$FX/plans/p.md" <<'PLAN'
# Fixture plan

- [ ] **Phase 1.1** [backend] no acceptance line

- [ ] **Phase 1.2** [tier:c] [docs] tier C asks for docs
  - Acceptance: `pytest -q`
  - Route: class=docs

- [ ] **Phase 1.3** [mechanical] lane a
  - Acceptance: `pytest tests/a -q`
  - Route: fanout=lanes
  - Paths: src/a/**

- [ ] **Phase 1.4** [mechanical] lane b
  - Acceptance: `pytest tests/b -q`
  - Route: fanout=lanes
  - Paths: src/b/**

- [ ] **Phase 1.5** [mechanical] overlaps lane a
  - Acceptance: `pytest tests/c -q`
  - Route: fanout=lanes
  - Paths: src/**

- [ ] **Gate 1→2** [gate:human] approve
  - Acceptance: user types approve gate-1-2

- [ ] **Phase 2.1** [backend] prose acceptance
  - Acceptance: the endpoint feels faster
PLAN
git -C "$FX" add -A; git -C "$FX" commit -qm fx
rt() { (cd "$FX" && bash "$ROUTE" "$@") 2>&1; }
ln_of() { grep -n -- "$1" "$FX/plans/p.md" | head -1 | cut -d: -f1; }
L_NOACC="$(ln_of 'Phase 1.1')"; L_C="$(ln_of 'Phase 1.2')"; L_A="$(ln_of 'Phase 1.3')"; L_B="$(ln_of 'Phase 1.4')"
L_OV="$(ln_of 'Phase 1.5')"; L_G="$(ln_of 'Gate 1')"; L_PROSE="$(ln_of 'Phase 2.1')"

# 24. input gate: NEEDS_SPEC without Acceptance, or without a command where the class needs one; [gate:] is HUMAN_GATE
O="$(rt plan plans/p.md --line "$L_NOACC" --dry-run)"
[ "$(val ROUTE_STATUS "$O")" = NEEDS_SPEC ] && has '^ROUTE_MISSING: acceptance' "$O" || fail "no Acceptance did not give NEEDS_SPEC: $O"
O="$(rt plan plans/p.md --line "$L_PROSE" --dry-run)"
[ "$(val ROUTE_STATUS "$O")" = NEEDS_SPEC ] && has '^ROUTE_MISSING: acceptance-command' "$O" || fail "prose Acceptance for a feature did not give NEEDS_SPEC: $O"
[ "$(val ROUTE_STATUS "$(rt plan plans/p.md --line "$L_G" --dry-run)")" = HUMAN_GATE ] || fail "[gate:human] task did not give HUMAN_GATE"
[ ! -e "$FX/.dev-plan-state" ] || fail "a --dry-run wrote state"
pass "input gate: NEEDS_SPEC (missing Acceptance / command), HUMAN_GATE for [gate:], dry-run writes nothing"

# 25. hard floor: [tier:c] routes class=security (strong, six lenses + adversarial, block, G12, single) over Route: class=docs
O="$(rt plan plans/p.md --line "$L_C" --dry-run)"
for kv in "ROUTE_STATUS=READY" "ROUTE_CLASS=security" "ROUTE_TIER=strong" "ROUTE_MODEL=opus" "ROUTE_RISK_TIER=C" \
          "ROUTE_REVIEW_SHAPE=fanout6+adversarial" "ROUTE_DIVERSITY=block" "ROUTE_HUMAN_GATE=G12" "ROUTE_FANOUT=single" \
          "ROUTE_PROVIDER=claude-session" "SEMANTIC_SOURCE=table"; do
  [ "$(val "${kv%%=*}" "$O")" = "${kv#*=}" ] || fail "[tier:c] route: want ${kv%%=*}=${kv#*=}, got: $(val "${kv%%=*}" "$O")"
done
has '^ROUTE_FLOORS: .*tier-c-floor' "$O" || fail "[tier:c] route does not name the tier-c-floor hard rule"
pass "hard floor: [tier:c] → class security, strong/opus, fanout6+adversarial, diversity block, G12, single (Route: class=docs overridden)"

# 26. fan-out: lanes only with disjoint Paths (and never for an overlapping lane)
O="$(rt plan plans/p.md --line "$L_A" --lanes "$L_A,$L_B" --dry-run)"
[ "$(val ROUTE_FANOUT "$O")" = "lanes:2" ] && [ "$(val ROUTE_LANES "$O")" = "$L_A,$L_B" ] || fail "disjoint Paths did not fan out: $(val ROUTE_FANOUT "$O")"
O="$(rt plan plans/p.md --line "$L_A" --lanes "$L_A,$L_OV" --dry-run)"
[ "$(val ROUTE_FANOUT "$O")" = single ] && has '^ROUTE_NOTE: fan-out single: .*overlaps' "$O" || fail "overlapping Paths fanned out: $(val ROUTE_FANOUT "$O")"
[ "$(val ROUTE_FANOUT "$(rt plan plans/p.md --line "$L_A" --dry-run)")" = single ] || fail "fan-out without --lanes"
[ "$(val ROUTE_FANOUT "$(rt plan plans/p.md --line "$L_C" --lanes "$L_C,$L_A" --dry-run)")" = single ] || fail "a Tier C task fanned out"
pass "fan-out: lanes only with --lanes and pairwise-disjoint Paths; single otherwise and for Tier C"

# 27. kill switches and the ACTIVE lock: HALTED with APEX_HALT=1 or a HALT file; another plan's lock is BUSY
[ "$(val ROUTE_STATUS "$(APEX_HALT=1 rt plan plans/p.md --line "$L_A" --dry-run)")" = HALTED ] || fail "APEX_HALT=1 did not give HALTED"
mkdir -p "$FX/.dev-plan-state"; touch "$FX/.dev-plan-state/HALT"
[ "$(val ROUTE_STATUS "$(rt plan plans/p.md --line "$L_A" --dry-run)")" = HALTED ] || fail "a HALT file did not give HALTED"
rm -f "$FX/.dev-plan-state/HALT"
O="$(rt plan plans/p.md --line "$L_A")"
RID="$(val ROUTE_ID "$O")"; RFILE="$(val ROUTE_FILE "$O")"
[ "$(val ROUTE_STATUS "$O")" = READY ] && [ -f "$RFILE" ] || fail "a READY route wrote no active-route.json: $O"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["route_id"]==sys.argv[2] and d["router"]["class"]=="mechanical" and "state" in d' "$RFILE" "$RID" \
  || fail "active-route.json does not carry the route_id and fields"
python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; assert [x["event"] for x in r]==["route"] and r[0]["route_id"]==sys.argv[2] and r[0]["source"]=="cli" and r[0]["seq"]==0' "$(dirname "$RFILE")/ledger.jsonl" "$RID" \
  || fail "the READY route did not append one route row to ledger.jsonl"
[ ! -e "$(dirname "$RFILE")/routes.jsonl" ] || fail "route.sh still writes routes.jsonl"
cp "$FX/plans/p.md" "$FX/plans/q.md"
O="$(rt plan plans/q.md --line "$L_A")"
[ "$(val ROUTE_STATUS "$O")" = BUSY ] || fail "a second plan was not BUSY while the first holds ACTIVE: $O"
pass "kill switches → HALTED; READY writes active-route.json + a ledger route row; another ACTIVE plan → BUSY"

# 28. escalate rungs from policy: 1 effort+1, 2 model+1 + diagnoser, 3 HALT; the next plan route follows the rung
SD="$(dirname "$(dirname "$RFILE")")"
setfail() { printf '{"consecutive_failures": %s}\n' "$1" >"$SD/checkpoint.json"; }
setfail 1; O="$(rt escalate "$RID")"
has '^RUNG: effort-up' "$O" && [ "$(val NEXT_EFFORT "$O")" = high ] && [ "$(val NEXT_BUILDER "$O")" = builder-high ] || fail "rung 1 is not effort+1: $O"
O="$(rt plan plans/p.md --line "$L_A")"
[ "$(val ROUTE_MODE "$O")" = escalated ] && [ "$(val ROUTE_EFFORT "$O")" = high ] && has '^ROUTE_ROSTER: builder-high' "$O" || fail "the route after one failure did not raise effort: $O"
setfail 2; O="$(rt escalate "$RID")"
has '^RUNG: model-up' "$O" && [ "$(val NEXT_MODEL "$O")" = opus ] && has '^DIAGNOSER: diagnoser' "$O" || fail "rung 2 is not model+1 with a diagnoser: $O"
setfail 3; O="$(rt escalate "$RID")"
has '^RUNG: halt' "$O" && has '^ACTION: HALT' "$O" || fail "rung 3 is not HALT: $O"
[ "$(val ROUTE_STATUS "$(rt plan plans/p.md --line "$L_A")")" = HALTED ] || fail "a plan route at the HALT rung was not HALTED"
if rt escalate "not-a-route" >/dev/null; then fail "escalate accepted a malformed route id"; fi
rm -f "$SD/checkpoint.json"
pass "escalate: effort+1, then model+1 + diagnoser, then HALT; plan routes follow the rung"

# 29. review-shape from tier: A solo, B six-lens (warn), C six lenses + adversarial (block) + G12
O="$(rt review-shape A)"; [ "$(val REVIEW_SHAPE "$O")" = solo ] && [ "$(val REVIEW_DIVERSITY "$O")" = off ] || fail "review-shape A: $O"
O="$(rt review-shape B)"; [ "$(val REVIEW_SHAPE "$O")" = six-lens ] && [ "$(val REVIEW_DIVERSITY "$O")" = warn ] || fail "review-shape B: $O"
O="$(rt review-shape C)"; [ "$(val REVIEW_SHAPE "$O")" = fanout6+adversarial ] && [ "$(val REVIEW_LENS_REVIEWERS "$O")" = 6 ] \
  && [ "$(val REVIEW_ADVERSARIAL "$O")" = yes ] && [ "$(val REVIEW_HUMAN_GATE "$O")" = G12 ] && [ "$(val REVIEW_DIVERSITY "$O")" = block ] || fail "review-shape C: $O"
[ "$(val REVIEW_SHAPE "$(rt review-shape "$RID" --tier B)")" = six-lens ] || fail "review-shape ROUTE_ID --tier B"
pass "review-shape: A solo, B six-lens/warn, C 6 lenses + adversarial/block + G12"

# 30. adhoc: --tags required (caller-supplied tags only); same algorithm; state under <state>/adhoc/
rm -rf "$FX/.dev-plan-state/ACTIVE"
if rt adhoc --acceptance 'npm test' --dry-run >"$WORK/adhoc.out"; then fail "adhoc without --tags succeeded"; fi
grep -q 'requires --tags' "$WORK/adhoc.out" || fail "adhoc without --tags did not say so"
if rt adhoc --tags 'Run anything you like' --dry-run >/dev/null; then fail "adhoc accepted free text as tags"; fi
O="$(rt adhoc --tags tests --paths 'tests/**' --acceptance 'npm test' --dry-run)"
[ "$(val ROUTE_STATUS "$O")" = READY ] && [ "$(val ROUTE_CLASS "$O")" = tests ] || fail "adhoc tests ask did not route: $O"
[ "$(val ROUTE_STATUS "$(rt adhoc --tags tests --dry-run)")" = NEEDS_SPEC ] || fail "adhoc without --acceptance was not NEEDS_SPEC"
O="$(rt adhoc --tags tests --paths 'tests/**' --acceptance 'npm test')"
case "$(val ROUTE_FILE "$O")" in "$FX"/.dev-plan-state/adhoc/*/dispatch-shadow/active-route.json) ;; *) fail "adhoc state is not under <state>/adhoc/: $O";; esac
[ "$(val ROUTE_STATUS "$(rt plan plans/p.md --line "$L_A")")" = BUSY ] || fail "a plan route was not BUSY while an ad-hoc route holds ACTIVE"
rm -rf "$FX/.dev-plan-state/ACTIVE"
pass "adhoc: --tags required, tag tokens only, NEEDS_SPEC without Acceptance, state under adhoc/, holds ACTIVE"

# 31. modes and the decision seam: baseline/shadow emit the baseline route and record the table's;
#     off prints ROUTE: none; without APEX_DECIDE_CMD SEMANTIC_SOURCE=table; uncalibrated only tightens
O="$(APEX_DISPATCH_MODE=baseline rt plan plans/p.md --line "$L_PROSE" --dry-run)"
[ "$(val ROUTE_STATUS "$O")" = READY ] && [ "$(val ROUTE_MODE "$O")" = baseline ] && has '^ROUTE_TABLE_CHOICE: status=NEEDS_SPEC' "$O" || fail "baseline mode: $O"
O="$(APEX_DISPATCH_MODE=shadow rt plan plans/p.md --line "$L_C" --dry-run)"
[ "$(val ROUTE_MODE "$O")" = shadow ] && [ "$(val ROUTE_MODEL "$O")" = inherit ] && has '^ROUTE_TABLE_CHOICE: status=READY class=security' "$O" || fail "shadow mode: $O"
has '^ROUTE: none' "$(APEX_DISPATCH_MODE=off rt plan plans/p.md --line "$L_A" --dry-run)" || fail "off mode did not print ROUTE: none"
printf -- '- [ ] **Phase 3.1** untagged work\n  - Acceptance: `pytest -q`\n' >>"$FX/plans/p.md"; L_AUTO="$(ln_of 'Phase 3.1')"
printf '#!/bin/sh\nprintf "%%s\\n" "$FAKE_DECISION"\n' >"$WORK/decide"; chmod +x "$WORK/decide"
dec() { APEX_DECIDE_CMD="$WORK/decide" FAKE_DECISION="$1" rt plan plans/p.md --line "$L_AUTO" --dry-run; }
O="$(dec '{"verdict":"docs","probabilities":{"docs":0.95,"feature":0.05},"calibrated":false,"uncertain":false}')"
[ "$(val ROUTE_CLASS "$O")" = feature ] && [ "$(val SEMANTIC_SOURCE "$O")" = decision-shadow ] || fail "an uncalibrated decision lowered cost: $O"
O="$(dec '{"verdict":"docs","probabilities":{"docs":0.95,"feature":0.05},"calibrated":true,"uncertain":false}')"
[ "$(val ROUTE_CLASS "$O")" = docs ] && [ "$(val ROUTE_MODE "$O")" = decision ] || fail "a calibrated decision was not applied: $O"
O="$(dec '{"verdict":"docs","probabilities":{"docs":0,"feature":0},"calibrated":true}')"
[ "$(val ROUTE_CLASS "$O")" = feature ] && [ "$(val SEMANTIC_SOURCE "$O")" = table ] || fail "an all-zero probability map was accepted: $O"
O="$(rt plan plans/p.md --line "$L_AUTO" --dry-run)"
[ "$(val SEMANTIC_SOURCE "$O")" = table ] && [ "$(val ROUTE_CLASS "$O")" = feature ] || fail "route.sh without the decision layer: $O"
printf '%s' '{"escalation":{"max_review_rounds":4}}' >"$WORK/ov-route.json"
if APEX_DISPATCH_POLICY="$WORK/ov-route.json" rt plan plans/p.md --line "$L_AUTO" --dry-run >"$WORK/ov-route.out"; then fail "route.sh accepted an overlay that loosens a bound"; fi
grep -q 'policy is invalid' "$WORK/ov-route.out" || fail "route.sh did not name the invalid overlay"
pass "modes: baseline/shadow emit baseline and record the table; off; decision seam (absent → table, uncalibrated only tightens, invalid → table); route.sh enforces the overlay bounds"

# --- Phase 2.4: ledger.sh, report.sh, doctor.sh ------------------------------
LEDGER="$PLUGIN_ROOT/scripts/ledger.sh"; REPORT="$PLUGIN_ROOT/scripts/report.sh"; DOCTOR="$PLUGIN_ROOT/scripts/doctor.sh"
for f in "$LEDGER" "$REPORT" "$DOCTOR"; do [ -x "$f" ] || fail "$(basename "$f") missing or not executable"; done
[ -f "$PLUGIN_ROOT/resources/ledger-events.json" ] || fail "missing resources/ledger-events.json"
lg() { (cd "$FX" && bash "$LEDGER" "$@") 2>&1; }
# In-process writer (what route.py, the hooks and the shims use): lgpy STATE EVENT JSON SOURCE [ROUTE_ID] [ROUTE_MODE]
lgpy() { (cd "$FX" && python3 -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import ledger
a = sys.argv[2:] + ["", ""]
print(ledger.append(a[0], a[1], json.loads(a[2]), a[3], route_id=a[4] or None, route_mode=a[5] or None)["seq"])' "$PLUGIN_ROOT/scripts/lib" "$@") 2>&1; }
HEAD_FX="$(git -C "$FX" rev-parse HEAD)"

# 32. append validates against the event schema and stamps the chain fields
LS="$WORK/ls"; mkdir -p "$LS"
RX="r-0123456789ab-L5-1"
lgpy "$LS" route '{"route_id":"'"$RX"'","status":"READY","origin":"plan","router":{"class":"docs","tier":"cheap","provider":"claude-session"},"line":5}' cli "" table >/dev/null || fail "a valid route row was refused"
lgpy "$LS" spawn_request '{"role":"builder","model":"haiku"}' hook "$RX" >/dev/null || fail "a valid spawn_request row was refused"
lgpy "$LS" worker_run '{"provider":"codex","role":"builder","exit_code":0,"usage":{"input":1000,"output":100}}' shim "$RX" >/dev/null || fail "a valid worker_run row was refused"
lgpy "$LS" spawn '{"agent_id":"ag-1","role":"builder","usage":{"input":1000000},"resolved_model":"claude-sonnet-5-5"}' hook "$RX" >/dev/null || fail "a valid spawn row was refused"
lgpy "$LS" verdict '{"role":"reviewer","verdict":"APPROVE"}' hook "$RX" >/dev/null || fail "a valid verdict row was refused"
for ev in route spawn_request spawn worker_run verdict; do   # provenance rows never come through the CLI
  if lg append "$ev" '{"role":"builder","model":"haiku","agent_id":"x","provider":"codex","exit_code":0,"verdict":"APPROVE","status":"READY","origin":"plan","router":{}}' --state "$LS" --source hook --route-id "$RX" >"$WORK/lg.out"; then
    fail "ledger.sh append accepted provenance event $ev"; fi
  grep -q "$ev is a provenance event" "$WORK/lg.out" || fail "CLI refusal of $ev does not say why: $(cat "$WORK/lg.out")"
done
if lgpy "$LS" verdict '{"role":"reviewer","verdict":"LGTM"}' hook "$RX" >"$WORK/lg.out"; then fail "an out-of-enum verdict was accepted"; fi
grep -q 'is not one of' "$WORK/lg.out" || fail "out-of-enum verdict: $(cat "$WORK/lg.out")"
lg append escalate '{"prior_route_id":"'"$RX"'","failures":1,"rung":"effort-up","action":"effort_up"}' --state "$LS" --source cli >/dev/null || fail "a valid escalate row was refused"
for bad in "bogus|{}|hook|unknown event" "human_gate|{\"gate\":\"G12\",\"decision\":\"maybe\"}|cli|is not one of" \
           "escalate|{\"prior_route_id\":\"x\",\"rung\":\"r\",\"action\":\"halt\"}|cli|missing required field failures" \
           "hook_error|{\"hook\":\"x\",\"error\":\"y\"}|model|source must be one of" \
           "hook_error|{\"hook\":\"x\",\"error\":\"y\",\"hash\":\"00\"}|hook|stamped by the ledger"; do
  IFS='|' read -r ev js src want <<<"$bad"
  if lg append "$ev" "$js" --state "$LS" --source "$src" --route-id "$RX" >"$WORK/lg.out"; then fail "ledger accepted an invalid $ev row"; fi
  grep -q -- "$want" "$WORK/lg.out" || fail "invalid $ev row refused without naming '$want': $(cat "$WORK/lg.out")"
done
LJ="$LS/dispatch-shadow/ledger.jsonl"
python3 - "$LJ" <<'PY' || fail "ledger rows lack the stamped fields or the chain links"
import hashlib, json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
assert [r["event"] for r in rows] == ["route", "spawn_request", "worker_run", "spawn", "verdict", "escalate"], rows
prev = "0" * 64
for i, r in enumerate(rows):
    for k in ("seq", "event", "ts", "source", "route_id", "head_sha", "route_mode", "prev_hash", "hash", "doctor_profile"):
        assert k in r, (i, k)
    assert r["seq"] == i and r["prev_hash"] == prev
    body = json.dumps({k: v for k, v in r.items() if k != "hash"}, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    assert hashlib.sha256(body.encode()).hexdigest() == r["hash"]
    prev = r["hash"]
assert rows[1]["route_id"] == "r-0123456789ab-L5-1" and rows[1]["source"] == "hook" and rows[2]["source"] == "shim"
assert rows[0]["head_sha"] and len(rows[0]["head_sha"]) == 40
PY
lg verify --state "$LS" | grep -q '^ledger verify: OK — 6 rows' || fail "verify did not pass the sample chain"
pass "ledger append: schema-validated (event, enums, required fields, source, no caller-supplied hash); CLI refuses provenance events; rows stamped and chained"

# 33. verify names the first bad row: tampered, rehashed, deleted, reordered, truncated
vbad() {  # $1 label, $2 python edit of the rows list, $3 expected stderr fragment
  rm -rf "$WORK/lt"; cp -R "$LS" "$WORK/lt"
  python3 -c '
import hashlib, json, sys
p = sys.argv[1]; rows = [json.loads(l) for l in open(p)]
def rehash(r):
    r["hash"] = hashlib.sha256(json.dumps({k: v for k, v in r.items() if k != "hash"}, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest()
'"$2"'
open(p, "w").write("".join(json.dumps(r, sort_keys=True, separators=(",", ":")) + "\n" for r in rows))' "$WORK/lt/dispatch-shadow/ledger.jsonl"
  if lg verify --state "$WORK/lt" >"$WORK/v.out"; then fail "verify passed a $1 ledger"; fi
  grep -q -- "$3" "$WORK/v.out" || fail "verify did not name the $1 row: $(cat "$WORK/v.out")"
}
vbad "tampered" 'rows[2]["exit_code"] = 1' 'row 3 (seq 2): tampered'
vbad "rewritten-and-rehashed" 'rows[2]["exit_code"] = 1; rehash(rows[2])' 'row 4 (seq 3): tampered — prev_hash'
vbad "deleted" 'del rows[2]' 'row 3: deleted'
vbad "reordered" 'rows[2], rows[3] = rows[3], rows[2]' 'row 3: reordered'
vbad "truncated" 'rows.pop()' 'truncated: ledger.head records seq 5'
vbad "rewritten last row" 'rows[5]["rung"] = "x"; rehash(rows[5])' 'does not match ledger.head'
rm -rf "$WORK/lt"; cp -R "$LS" "$WORK/lt"; printf '{"seq": 6, "torn' >>"$WORK/lt/dispatch-shadow/ledger.jsonl"
if lg verify --state "$WORK/lt" >"$WORK/v.out"; then fail "verify passed a torn last line"; fi
grep -q 'row 7: incomplete last line' "$WORK/v.out" || fail "verify did not name the torn row: $(cat "$WORK/v.out")"
if lg append hook_error '{"hook":"x","error":"y"}' --state "$WORK/lt" --source hook >/dev/null; then fail "append extended a torn ledger"; fi
# append must not hide a truncation or a rewritten tail that verify catches
for edit in 'rows.pop()' 'rows[5]["rung"] = "x"; rehash(rows[5])'; do
  vbad "pre-append" "$edit" 'ledger.head'
  if lg append hook_error '{"hook":"x","error":"y"}' --state "$WORK/lt" --source hook >"$WORK/a.out"; then fail "append extended a ledger whose head disagrees ($edit)"; fi
  grep -q 'refusing to append' "$WORK/a.out" || fail "append refusal does not say why: $(cat "$WORK/a.out")"
  if lg verify --state "$WORK/lt" >/dev/null; then fail "verify passed after a refused append ($edit)"; fi
done
rm -rf "$WORK/lt"; cp -R "$LS" "$WORK/lt"; rm "$WORK/lt/dispatch-shadow/ledger.head"
if lg verify --state "$WORK/lt" >/dev/null; then fail "verify passed with ledger.head removed"; fi
if lg append hook_error '{"hook":"x","error":"y"}' --state "$WORK/lt" --source hook >/dev/null; then fail "append extended a ledger without its head"; fi
# the benign crash (row written, head not yet replaced) verifies and the next append repairs the head
rm -rf "$WORK/lt"; cp -R "$LS" "$WORK/lt"
python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; json.dump({"seq": r[-2]["seq"], "hash": r[-2]["hash"]}, open(sys.argv[2], "w"))' "$WORK/lt/dispatch-shadow/ledger.jsonl" "$WORK/lt/dispatch-shadow/ledger.head"
lg verify --state "$WORK/lt" >/dev/null || fail "verify failed the benign head-one-behind crash state"
lg append hook_error '{"hook":"x","error":"y"}' --state "$WORK/lt" --source hook >/dev/null || fail "append refused the benign crash state"
python3 -c 'import json,sys; h=json.load(open(sys.argv[1])); assert h["seq"]==6' "$WORK/lt/dispatch-shadow/ledger.head" || fail "append did not repair the head"
lg verify --state "$WORK/lt" | grep -q 'OK — 7 rows, chain intact$' || fail "verify after repair"
pass "verify: fails tampered, rehashed, deleted, reordered, truncated, torn and head-less ledgers; append refuses them too; a crash between row and head is repaired"

# 34. route.sh plan (not --dry-run) appended verifiable route rows; evidence semantics (spec §5.3 G)
lg verify --state "$SD" >/dev/null || fail "the fixture plan's ledger (route + escalate rows from route.sh) does not verify: $(lg verify --state "$SD")"
python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; ev=[x["event"] for x in r]; assert ev.count("route")>=2 and ev.count("escalate")==3, ev; assert all(x["source"]=="cli" for x in r); assert r[0]["route_mode"]=="table" and r[0]["head_sha"]==sys.argv[2], r[0]' \
  "$SD/dispatch-shadow/ledger.jsonl" "$HEAD_FX" || fail "route.sh/escalate rows are not stamped as expected"
if lg evidence --state "$SD" --line "$L_A" --head "$HEAD_FX" >"$WORK/e.out"; then fail "evidence passed with a route row but no spawn row"; fi
grep -q 'no spawn_request/spawn/worker_run row' "$WORK/e.out" || fail "evidence without spawns: $(cat "$WORK/e.out")"
lgpy "$SD" spawn_request '{"role":"builder","model":"sonnet"}' hook "r-000000000000-L${L_A}-1" >/dev/null
if lg evidence --state "$SD" --line "$L_A" --head "$HEAD_FX" >/dev/null; then fail "evidence accepted a spawn row for another route"; fi
lgpy "$SD" spawn_request '{"role":"builder","model":"sonnet"}' cli "$RID" >/dev/null
if lg evidence --state "$SD" --line "$L_A" --head "$HEAD_FX" >/dev/null; then fail "evidence accepted a spawn row written with source cli"; fi
lgpy "$SD" spawn_request '{"role":"builder","model":"sonnet"}' hook "$RID" >/dev/null
lg evidence --state "$SD" --line "$L_A" --head "$HEAD_FX" | grep -q '^ledger evidence: OK' || fail "evidence refused route + spawn rows at HEAD: $(lg evidence --state "$SD" --line "$L_A" --head "$HEAD_FX")"
if lg evidence --state "$SD" --line "$L_B" --head "$HEAD_FX" >"$WORK/e.out"; then fail "evidence passed for a line with no route row"; fi
grep -q "no READY route row for plan line $L_B" "$WORK/e.out" || fail "evidence for an unrouted line: $(cat "$WORK/e.out")"
PH="$(basename "$SD")"; RT='{"status":"READY","origin":"plan","router":{}'
lgpy "$SD" route "$RT"',"line":'"$L_B"'}' cli "r-$PH-L$L_OV-1" table >/dev/null; lgpy "$SD" spawn '{"agent_id":"a9","role":"builder"}' hook "r-$PH-L$L_OV-1" >/dev/null
for ln in "$L_B" "$L_OV"; do
  if lg evidence --state "$SD" --line "$ln" --head "$HEAD_FX" >/dev/null; then fail "evidence accepted a route whose id and line field disagree (line $ln)"; fi
done
lgpy "$SD" route "$RT"'}' cli "r-000000000000-L$L_G-1" table >/dev/null; lgpy "$SD" spawn '{"agent_id":"a8","role":"builder"}' hook "r-000000000000-L$L_G-1" >/dev/null
if lg evidence --state "$SD" --line "$L_G" --head "$HEAD_FX" >/dev/null; then fail "evidence accepted another plan's route"; fi
lg evidence --state "$SD" --line "$L_G" --head "$HEAD_FX" --plan-hash 000000000000 >/dev/null || fail "evidence --plan-hash did not select that plan"
if lg evidence --state "$SD" --line "$L_A" --head "$HEAD_FX" --plan-hash 000000000000 >/dev/null; then fail "evidence --plan-hash for another plan accepted this plan's route"; fi
git -C "$FX" commit -q --allow-empty -m next; HEAD2="$(git -C "$FX" rev-parse HEAD)"
lg evidence --state "$SD" --line "$L_A" --head "$HEAD2" >/dev/null || fail "evidence refused a HEAD that descends from the route's head"
git -C "$FX" checkout -q --orphan side; git -C "$FX" commit -q --allow-empty -m side; HSIDE="$(git -C "$FX" rev-parse HEAD)"; git -C "$FX" checkout -q main
if lg evidence --state "$SD" --line "$L_A" --head "$HSIDE" >"$WORK/e.out"; then fail "evidence passed for a HEAD whose history lacks the route's head"; fi
grep -q "on HEAD's history" "$WORK/e.out" || fail "evidence off-history: $(cat "$WORK/e.out")"
rm -rf "$WORK/lt"; cp -R "$SD" "$WORK/lt"; sed -i.bak '1s/"table"/"decision"/' "$WORK/lt/dispatch-shadow/ledger.jsonl"
if lg evidence --state "$WORK/lt" --plan-hash "$PH" --line "$L_A" --head "$HEAD_FX" >"$WORK/e.out"; then fail "evidence passed on a tampered chain"; fi
grep -q 'chain does not verify' "$WORK/e.out" || fail "evidence on a tampered chain: $(cat "$WORK/e.out")"
[ "$(lg evidence --state "$SD" --line x --head "$HEAD_FX" >/dev/null; echo $?)" = 2 ] || fail "evidence --line x was not a usage error"
grep -qiF 'at least one `spawn_request`, `spawn` or `worker_run` row written with source `hook` or `shim` carries' "$PLUGIN_ROOT/README.md" || fail "README does not define ledger evidence"
for f in "$PLUGIN_ROOT/README.md" "$ADR"; do grep -q 'not proof against a determined orchestrator' "$f" || fail "$(basename "$f") does not state the evidence limit"; done
pass "route.sh appends verifiable route/escalate rows; evidence = chain + this plan's READY route for the line (id and line agree) on HEAD's history + a hook/shim spawn row for it"

# 35. enforcement switch: <state>/dispatch/ with APEX_DISPATCH_ENFORCE=1 or hooks/subagent-stop.sh (shipped: the default); =0 opts out;
#     escalate --state; iterate.sh fails closed on BUSY; tier-c-floor tags
[ ! -e "$SD/dispatch" ] && [ -d "$SD/dispatch-shadow" ] || fail "route.sh created <state>/dispatch/ without enforcement"
rm -rf "$FX/.dev-plan-state/ACTIVE"
O="$(APEX_DISPATCH_ENFORCE=1 rt adhoc --tags docs --acceptance 'npm test')"
case "$(val ROUTE_FILE "$O")" in "$FX"/.dev-plan-state/adhoc/*/dispatch/active-route.json) ;; *) fail "APEX_DISPATCH_ENFORCE=1 did not write <state>/dispatch/: $O";; esac
[ "$(val ROUTE_ENFORCED "$O")" = yes ] || fail "ROUTE_ENFORCED is not yes under APEX_DISPATCH_ENFORCE=1"
lg verify --state "$(dirname "$(dirname "$(val ROUTE_FILE "$O")")")" >/dev/null || fail "the enforced ad-hoc ledger does not verify"
rm -rf "$FX/.dev-plan-state/ACTIVE"
mkdir -p "$WORK/enf"; printf '{"worktree_path": "%s"}\n' "$FX" >"$WORK/enf/checkpoint.json"
APEX_DISPATCH_ENFORCE=1 lg append hook_advisory '{"hook":"x","advisory":"y"}' --state "$WORK/enf" --source hook >/dev/null || fail "enforced append failed"
[ -d "$WORK/enf/dispatch" ] && python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["dispatch_enforced"] is True' "$WORK/enf/checkpoint.json" \
  || fail "creating <state>/dispatch/ did not record dispatch_enforced in checkpoint.json"
mkdir -p "$WORK/enf2"; printf '{"worktree_path": "%s"}\n' "$FX" >"$WORK/enf2/checkpoint.json"
APEX_DISPATCH_ENFORCE=1 "$PLUGIN_ROOT/scripts/doctor.sh" --state "$WORK/enf2" >/dev/null 2>&1 || true
[ -d "$WORK/enf2/dispatch" ] && python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["dispatch_enforced"] is True' "$WORK/enf2/checkpoint.json" \
  || fail "doctor.sh created <state>/dispatch/ without recording dispatch_enforced"
for f in checkpoint.sh land.sh; do grep -q 'dispatch_enforced' "$MARKET_ROOT/plugins/apex-scope-loop/skills/apex-execute/scripts/$f" || fail "$f does not refuse a dispatch-enforced run whose dispatch/ is gone"; done
rm -rf "$WORK/copy3"; mkdir -p "$WORK/copy3/hooks"; touch "$WORK/copy3/hooks/subagent-stop.sh"
APEX_DISPATCH_ENFORCE= python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import ledger; assert ledger.enforcing(sys.argv[2]) and not ledger.enforcing(sys.argv[3])' \
  "$PLUGIN_ROOT/scripts/lib" "$WORK/copy3" "$WORK" || fail "enforcing() does not follow hooks/subagent-stop.sh"
APEX_DISPATCH_ENFORCE= python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import ledger; assert ledger.enforcing()' "$PLUGIN_ROOT/scripts/lib" \
  || fail "this plugin ships hooks/subagent-stop.sh but enforcing() is off by default"
APEX_DISPATCH_ENFORCE=0 python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import ledger; assert not ledger.enforcing(sys.argv[2])' "$PLUGIN_ROOT/scripts/lib" "$WORK/copy3" \
  || fail "APEX_DISPATCH_ENFORCE=0 did not keep the shadow directory"
O="$(cd / && bash "$ROUTE" escalate "$RID" --state "$SD" 2>&1)"
has '^RUNG: ' "$O" && has "^PRIOR_ROUTE: $RID" "$O" || fail "route.sh escalate --state did not use the given state dir: $O"
grep -q 'escalate "$RID" --state "$STATE_DIR"' "$MARKET_ROOT/plugins/apex-scope-loop/skills/apex-execute/scripts/checkpoint.sh" || fail "checkpoint.sh fail does not pass --state to route.sh escalate"
grep -q 'BUSY) *echo "STATUS: BUSY"; exit 0' "$MARKET_ROOT/plugins/apex-scope-loop/skills/apex-execute/scripts/iterate.sh" || fail "iterate.sh has no BUSY arm for ROUTE_STATUS"
printf -- '- [ ] **Phase 4.1** [auth] login flow\n  - Acceptance: `pytest -q`\n  - Route: fanout=lanes\n  - Paths: src/auth/**\n' >>"$FX/plans/p.md"; L_AUTH="$(ln_of 'Phase 4.1')"
O="$(rt plan plans/p.md --line "$L_AUTH" --dry-run)"
[ "$(val ROUTE_CLASS "$O")" = security ] && [ "$(val ROUTE_HUMAN_GATE "$O")" = G12 ] || fail "[auth] did not hit the tier-c-floor: $O"
[ "$(val ROUTE_FANOUT "$(rt plan plans/p.md --line "$L_A" --lanes "$L_A,$L_AUTH" --dry-run)")" = single ] || fail "an [auth] task was accepted as a lane"
python3 -c 'import json,sys; r=[x for x in json.load(open(sys.argv[1]))["hard_rules"] if x["id"]=="tier-c-floor"][0]; assert {"auth","pii","money","billing"} <= set(r["when"]["tags_any"])' "$PLUGIN_ROOT/resources/compiled/policy.json" || fail "tier-c-floor lacks auth/pii/money/billing"
grep -q 'APEX_DISPATCH_ENFORCE' "$PLUGIN_ROOT/README.md" && grep -q 'APEX_DISPATCH_ENFORCE' "$ADR" || fail "README/ADR do not document the enforcement switch"
pass "enforcement switch: on by default (hooks/subagent-stop.sh ships) or with APEX_DISPATCH_ENFORCE=1; =0 keeps dispatch-shadow/; escalate --state; iterate BUSY arm; [auth] → tier-c-floor"

# 36. export-trace writes apex-agent-observability's exact line shape; export writes task summaries
lg export-trace --state "$LS" --out "$WORK/trace.jsonl" >/dev/null || fail "export-trace failed"
python3 - "$WORK/trace.jsonl" <<'PY' || fail "export-trace lines do not match the AgentTrace shape"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
assert len(rows) == 6
for r in rows:
    assert list(r) == ["ts", "event", "session", "subagent_id", "parent_id", "tool", "token_estimate", "edge"], list(r)
    assert isinstance(r["token_estimate"], int)
ev = [r["event"] for r in rows]
assert ev[1] == "PreToolUse" and ev[3] == "SubagentStart" and rows[3]["edge"] == "r-0123456789ab-L5-1->ag-1"
PY
lg export --state "$LS" --out "$WORK/summary.jsonl" >/dev/null || fail "export failed"
python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; assert r[0]["kind"]=="ledger_head" and r[1]["task"]==5 and r[1]["spawns"]==3 and r[1]["verdicts"]==["APPROVE"]' "$WORK/summary.jsonl" || fail "export summary rows wrong"
if lg export-trace --state "$WORK/lt" >/dev/null 2>&1; then fail "export-trace exported a tampered chain"; fi
pass "export-trace: AgentTrace line shape (ts,event,session,subagent_id,parent_id,tool,token_estimate,edge); export: per-task summary"

# 37. report.sh summarises the sample: routes, spawns, verdicts, USD from real usage x price, unverified bucket
O="$(bash "$REPORT" --state "$LS")"
has '^REPORT_CHAIN: OK' "$O" && has '^REPORT_ROUTES_BY_CLASS: docs=1' "$O" && has '^REPORT_SPAWNS: spawn=1, spawn_request=1, worker_run=1' "$O" \
  && has '^REPORT_VERDICTS: APPROVE=1' "$O" && has '^REPORT_ESCALATIONS: effort-up=1' "$O" || fail "report.sh summary: $O"
has '^REPORT_USD_ESTIMATED: 3.0000 (1 priced rows' "$O" || fail "report.sh USD is not real usage x the sonnet price: $O"
has '^REPORT_UNVERIFIED: 1 row' "$O" || fail "report.sh did not bucket the usage row without a resolved model: $O"
bash "$REPORT" --state "$LS" --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["unverified"]["count"]==1 and d["routes"]["by_mode"]=={"table":1}' || fail "report.sh --json"
has '^REPORT_ROUTES: ' "$(cd "$FX" && bash "$REPORT" --plan plans/p.md)" || fail "report.sh --plan did not resolve the plan's state"
has '^REPORT_CHAIN: BROKEN' "$(bash "$REPORT" --state "$WORK/lt")" || fail "report.sh did not flag a broken chain"
[ "$(bash "$REPORT" >/dev/null 2>&1; echo $?)" = 2 ] || fail "report.sh without --state/--plan is not a usage error"
pass "report.sh: routes by class/tier/provider/mode, spawns, verdicts, escalations, USD from usage x price, unverified bucket, --json, --plan"

# 38. doctor.sh writes doctor.json with a status per check; claude absent/old → fail (JSON still written)
mkdir -p "$WORK/fakebin"; printf '#!/bin/sh\n[ "$1" = --version ] && echo "2.1.300 (Claude Code)"; exit 0\n' >"$WORK/fakebin/claude"; chmod +x "$WORK/fakebin/claude"
printf '#!/bin/sh\necho "2.1.100 (Claude Code)"\n' >"$WORK/fakebin/claude-old"; chmod +x "$WORK/fakebin/claude-old"
doc() { (cd "$FX" && env -u CLAUDE_CODE_SUBAGENT_MODEL "$@" bash "$DOCTOR" --state "$WORK/ds" --repo "$FX") >"$WORK/doc.out" 2>&1; }
dj() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); c={x["id"]:x["status"] for x in d["checks"]}; exec(sys.argv[2])' "$WORK/ds/dispatch-shadow/doctor.json" "$1"; }
RC=0; doc APEX_CLAUDE_BIN="$WORK/fakebin/claude" || RC=$?
[ "$RC" = 0 ] || fail "doctor.sh with claude 2.1.300 exited $RC: $(cat "$WORK/doc.out")"
dj '
assert d["status"] in ("ok", "warn") and c["claude-binary"] == "ok" and d["claude_version"] == "2.1.300", d
assert all(x["status"] in ("ok", "warn", "fail", "unverified", "skipped") and x["detail"] for x in d["checks"])
for k in ("scope-loop-sibling", "compile-check", "subagent-model-env", "settings-snippet", "provider-forced-flags-probe",
          "probe:agent-id-in-tool-stdin", "probe:updatedinput-model", "installed-version", "compiled-version"):
    assert k in c, k
assert c["scope-loop-sibling"] == "ok" and c["compile-check"] == "ok" and c["subagent-model-env"] == "ok"
assert c["settings-snippet"] == "warn" and c["probe:agent-id-in-tool-stdin"] == "unverified" and c["provider-forced-flags-probe"] == "unverified"
assert d["profile"] and d["providers"]["claude-session"]["available"] is True
' || fail "doctor.json (claude present) wrong: $(cat "$WORK/doc.out")"
has '^DOCTOR_FILE: .*/dispatch-shadow/doctor.json' "$(cat "$WORK/doc.out")" || fail "doctor did not print DOCTOR_FILE"
[ ! -e "$WORK/ds/dispatch" ] || fail "doctor.sh created <state>/dispatch/ without enforcement"
RC=0; doc APEX_CLAUDE_BIN="$WORK/no-such-claude" || RC=$?
[ "$RC" = 1 ] && dj 'assert d["status"] == "fail" and c["claude-binary"] == "fail" and d["claude_version"] is None' || fail "doctor.sh without claude: rc=$RC $(cat "$WORK/doc.out")"
RC=0; doc APEX_CLAUDE_BIN="$WORK/fakebin/claude-old" || RC=$?
[ "$RC" = 1 ] && dj 'assert c["claude-binary"] == "fail" and d["claude_version"] == "2.1.100"' || fail "doctor.sh accepted claude 2.1.100"
RC=0; doc APEX_CLAUDE_BIN="$WORK/fakebin/claude" CLAUDE_CODE_SUBAGENT_MODEL=haiku || RC=$?
[ "$RC" = 1 ] && dj 'assert c["subagent-model-env"] == "fail"' || fail "doctor.sh did not fail on CLAUDE_CODE_SUBAGENT_MODEL"
mkdir -p "$FX/.claude"; python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); json.dump({"permissions": s["permissions"]}, open(sys.argv[2], "w"))' "$PLUGIN_ROOT/resources/settings-snippet.json" "$FX/.claude/settings.json"
doc APEX_CLAUDE_BIN="$WORK/fakebin/claude" || true
dj 'assert c["settings-snippet"] == "ok"' || fail "doctor.sh did not see the applied settings snippet"
[ "$(bash "$DOCTOR" --bogus >/dev/null 2>&1; echo $?)" = 2 ] || fail "doctor.sh --bogus is not a usage error"
pass "doctor.sh: doctor.json with per-check status; claude absent/old and CLAUDE_CODE_SUBAGENT_MODEL fail; snippet warn/ok; live probes unverified"

# --- Phase 2.5: skills and commands ------------------------------------------

# 39. both skills exist: name is unquoted kebab-case matching the directory; allowed-tools is an explicit list
for skill in dispatch-route dispatch-worker; do
  SK="$PLUGIN_ROOT/skills/$skill/SKILL.md"
  [ -f "$SK" ] || fail "missing skill: $SK"
  [ "$(head -1 "$SK")" = "---" ] || fail "$skill SKILL.md has no frontmatter"
  fm="$(awk '/^---$/{c++; next} c==1' "$SK")"
  name_line="$(grep -m1 '^name:' <<<"$fm" || true)"
  [[ "$name_line" =~ ^name:[[:space:]]+$skill[[:space:]]*$ ]] || fail "$skill SKILL.md name: must be unquoted kebab-case '$skill' (got: $name_line)"
  grep -q '^description:[[:space:]]*[^[:space:]]' <<<"$fm" || fail "$skill SKILL.md missing description:"
  tools_line="$(grep -m1 '^allowed-tools:' <<<"$fm" || true)"
  [ -n "$tools_line" ] || fail "$skill SKILL.md missing allowed-tools:"
  if grep -qE '\*|mcp__' <<<"$tools_line"; then fail "$skill SKILL.md allowed-tools has a wildcard: $tools_line"; fi
  [[ "$tools_line" =~ ^allowed-tools:[[:space:]]+[A-Za-z][A-Za-z,[:space:]]*$ ]] || fail "$skill SKILL.md allowed-tools is not an explicit tool list: $tools_line"
done
for s in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
  if grep -qE '^allowed-tools:.*(\*|mcp__)' "$s"; then fail "$s has a wildcard in allowed-tools"; fi
done
pass "skills dispatch-route and dispatch-worker: kebab-case name matching dir, description, explicit allowed-tools without wildcards"

# 40. all six commands exist with name: matching the filename and a description:
for cmd in route run done report doctor compile; do
  C="$PLUGIN_ROOT/commands/$cmd.md"
  [ -f "$C" ] || fail "missing command: $C"
  [ "$(head -1 "$C")" = "---" ] || fail "$cmd command has no frontmatter"
  fm="$(awk '/^---$/{c++; next} c==1' "$C")"
  grep -qE "^name:[[:space:]]+$cmd[[:space:]]*$" <<<"$fm" || fail "$cmd command frontmatter name: missing or not '$cmd'"
  grep -q '^description:[[:space:]]*[^[:space:]]' <<<"$fm" || fail "$cmd command missing description:"
  grep -q '\$ARGUMENTS' "$C" || fail "$cmd command never uses \$ARGUMENTS"
done
pass "commands route/run/done/report/doctor/compile: name matches filename, description, \$ARGUMENTS"

# 41. every script path a command or skill references exists: ${CLAUDE_PLUGIN_ROOT}/<path> and $D/<x>.sh
#     in this plugin, $S/<x>.sh in the sibling apex-scope-loop's apex-execute scripts
SL_SCRIPTS="$MARKET_ROOT/plugins/apex-scope-loop/skills/apex-execute/scripts"
python3 - "$PLUGIN_ROOT" "$SL_SCRIPTS" "$PLUGIN_ROOT"/commands/*.md "$PLUGIN_ROOT"/skills/*/SKILL.md <<'PY' || fail "a command or skill references a script path that does not exist"
import os, re, sys
root, sl, files = sys.argv[1], sys.argv[2], sys.argv[3:]
bad, seen = [], 0
for f in files:
    t = open(f).read()
    refs = [(os.path.join(root, p), p) for p in
            re.findall(r'\$\{CLAUDE_PLUGIN_ROOT\}/((?:scripts|resources|bin|hooks|agents)/[A-Za-z0-9_./-]*[A-Za-z0-9_])', t)]
    refs += [(os.path.join(root, "scripts", p), "$D/" + p) for p in re.findall(r'\$D/([A-Za-z0-9_.-]+\.sh)', t)]
    refs += [(os.path.join(sl, p), "$S/" + p) for p in re.findall(r'\$S/([A-Za-z0-9_.-]+\.sh)', t)]
    for path, ref in refs:
        seen += 1
        if not os.path.exists(path):
            bad.append("%s: %s" % (os.path.relpath(f, root), ref))
for b in bad:
    print("smoke: missing referenced path " + b, file=sys.stderr)
if seen == 0:
    print("smoke: no script references found in commands/skills", file=sys.stderr)
sys.exit(1 if bad or seen == 0 else 0)
PY
for cmd in route report doctor compile; do
  grep -qF "\${CLAUDE_PLUGIN_ROOT}/scripts/$cmd.sh" "$PLUGIN_ROOT/commands/$cmd.md" || fail "commands/$cmd.md does not call \${CLAUDE_PLUGIN_ROOT}/scripts/$cmd.sh"
done
pass "every referenced script path exists (plugin \${CLAUDE_PLUGIN_ROOT}/\$D paths, sibling apex-scope-loop \$S paths); route/report/doctor/compile call their scripts"

# --- Phase 3.1: PreToolUse hooks (pre-agent, pre-bash, pre-edit, pre-mcp) ---
HOOKS=(pre-agent pre-bash pre-edit pre-mcp)
HOOKS32=(post-agent post-bash-prune subagent-start subagent-stop stop-gate)
# Fixture with two disjoint lanes; route.sh takes the ACTIVE lock (stage BUILD) and writes active-route.json.
HX="$WORK/hx"; mkdir -p "$HX/plans"; git init -q -b main "$HX"
cat >"$HX/plans/p.md" <<'PLAN'
# Hook fixture

- [ ] **Phase 1.1** [mechanical] lane a
  - Acceptance: `pytest tests/a -q`
  - Route: fanout=lanes
  - Paths: src/a/**

- [ ] **Phase 1.2** [mechanical] lane b
  - Acceptance: `pytest tests/b -q`
  - Route: fanout=lanes
  - Paths: src/b/**
PLAN
git -C "$HX" add -A; git -C "$HX" commit -qm hx
HL_A="$(grep -n 'Phase 1.1' "$HX/plans/p.md" | cut -d: -f1)"; HL_B="$(grep -n 'Phase 1.2' "$HX/plans/p.md" | cut -d: -f1)"
# hk HOOK JSON -> the hook's stdout (stderr dropped); one JSON object or the check fails
hk() { (cd "$HX" && printf '%s' "$2" | bash "$PLUGIN_ROOT/hooks/$1.sh" 2>/dev/null); }
pl() { python3 -c 'import json, sys
k, cwd, a = sys.argv[1], sys.argv[2], sys.argv[3:]
if k == "bash": d = {"tool_name": "Bash", "tool_input": {"command": a[0]}}
elif k == "edit": d = {"tool_name": "Write", "tool_input": {"file_path": a[0], "content": "x"}}
elif k == "mcp": d = {"tool_name": a[0], "tool_input": {}}
else:
    ti = {"subagent_type": a[0], "prompt": "p"}
    if a[1]: ti["model"] = a[1]
    d = {"tool_name": "Agent", "tool_input": ti}
for kv in a[2 if k == "agent" else 1:]:
    key, _, v = kv.partition("=")
    d[key] = v
d.update({"session_id": "smoke", "tool_use_id": "t1", "hook_event_name": "PreToolUse", "cwd": cwd})
print(json.dumps(d))' "$@"; }
one() { python3 -c 'import json, sys
s = sys.stdin.read()
assert s.endswith("\n") and s.count("\n") == 1, repr(s)
o = json.loads(s)
assert isinstance(o, dict)
h = o.get("hookSpecificOutput")
print("{}" if not o else ("context" if "permissionDecision" not in h else h["permissionDecision"] + (" updated" if "updatedInput" in h else "")))'; }
dec() { hk "$1" "$2" | one; }
is_deny() { [ "$(dec "$1" "$2")" = deny ] || fail "$3"; }
is_allow() { [ "$(dec "$1" "$2")" = "{}" ] || fail "$3"; }

# 42. all nine hooks exist, executable, `bash -n` clean; hooks.json == compile output (events, matchers,
#     ${CLAUDE_PLUGIN_ROOT} paths, timeout 10)
for h in "${HOOKS[@]}" "${HOOKS32[@]}"; do
  f="$PLUGIN_ROOT/hooks/$h.sh"
  [ -x "$f" ] || fail "hooks/$h.sh missing or not executable"
  bash -n "$f" || fail "hooks/$h.sh does not parse"
done
bash -n "$PLUGIN_ROOT/scripts/lib/hook-common.bash" || fail "scripts/lib/hook-common.bash does not parse"
python3 - "$PLUGIN_ROOT" <<'PY' || fail "hooks.json does not register the hooks exactly as compile.py renders them"
import json, os, sys
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "scripts", "lib"))
import compile as c
want, _ = c.render_hooks(root)
have = json.load(open(os.path.join(root, "hooks", "hooks.json")))
assert have == want, "hooks.json differs from compile.py's rendering"
cmd = lambda s: {"type": "command", "command": 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/%s.sh"' % s, "timeout": 10}
pre = {g["matcher"]: g["hooks"][0] for g in have["hooks"]["PreToolUse"]}
assert pre == {m: cmd(s) for m, s in [("Agent|Task", "pre-agent"), ("Bash", "pre-bash"),
               ("Edit|Write|MultiEdit|NotebookEdit", "pre-edit"), ("^mcp__", "pre-mcp")]}, pre
post = {g["matcher"]: g["hooks"][0] for g in have["hooks"]["PostToolUse"]}
assert post == {"Agent|Task": cmd("post-agent"), "Bash": cmd("post-bash-prune")}, post
assert have["hooks"]["PostToolUseFailure"] == [{"matcher": "Agent|Task", "hooks": [cmd("post-agent")]}]
for ev, s in (("SubagentStart", "subagent-start"), ("SubagentStop", "subagent-stop")):
    assert have["hooks"][ev] == [{"matcher": "^(apex-dispatch|apex-scope-loop):", "hooks": [cmd(s)]}], ev
assert have["hooks"]["Stop"] == [{"hooks": [cmd("stop-gate")]}]
assert sorted(have["hooks"]) == ["PostToolUse", "PostToolUseFailure", "PreToolUse", "Stop", "SubagentStart", "SubagentStop"]
PY
pass "nine hooks: executable, bash -n clean, registered (events, matchers, \${CLAUDE_PLUGIN_ROOT}, timeout 10) == compile output"

# 43. without an ACTIVE lock every hook is a no-op: exactly one JSON object, {} (deny-worthy input and garbage included)
[ ! -e "$HX/.dev-plan-state" ] || fail "hook fixture already has state"
for h in "${HOOKS[@]}"; do
  [ "$(dec "$h" 'not json{')" = "{}" ] || fail "$h without a lock: garbage stdin did not give {}"
  [ "$(dec "$h" '')" = "{}" ] || fail "$h without a lock: empty stdin did not give {}"
done
is_allow pre-bash "$(pl bash "$HX" 'APEX_GIBSON=0 bash x')" "pre-bash acted without an ACTIVE lock"
is_allow pre-agent "$(pl agent "$HX" Explore opus)" "pre-agent acted without an ACTIVE lock"
is_allow pre-edit "$(pl edit "$HX" .dev-plan-state/x)" "pre-edit acted without an ACTIVE lock"
[ ! -e "$HX/.dev-plan-state" ] || fail "a hook wrote state without an ACTIVE lock"
pass "no ACTIVE lock: every hook prints exactly one JSON object, {} (garbage, empty and deny-worthy input alike)"

# Take the lock: a READY lanes route for 1.1 + 1.2.
O="$(cd "$HX" && bash "$ROUTE" plan plans/p.md --line "$HL_A" --lanes "$HL_A,$HL_B" 2>&1)"
[ "$(val ROUTE_STATUS "$O")" = READY ] && [ "$(val ROUTE_FANOUT "$O")" = "lanes:2" ] || fail "hook fixture route is not a READY lanes route: $O"
HRID="$(val ROUTE_ID "$O")"; HSD="$(dirname "$(dirname "$(val ROUTE_FILE "$O")")")"
OWNER="$HX/.dev-plan-state/ACTIVE/owner.json"
[ -f "$OWNER" ] || fail "route.sh took no ACTIVE lock"
stage() { python3 -c 'import json, sys; o = json.load(open(sys.argv[1])); print(o["stage"]) if len(sys.argv) == 2 else (o.update(stage=sys.argv[2]), json.dump(o, open(sys.argv[1], "w")))' "$OWNER" "$@"; }
rows() { python3 -c 'import json, sys
r = [json.loads(l) for l in open(sys.argv[1])]
print(sum(1 for x in r if x["event"] == sys.argv[2] and x.get("source") == "hook" and all(str(x.get(k)) == v for k, v in (a.split("=", 1) for a in sys.argv[3:]))))' "$HSD/dispatch-shadow/ledger.jsonl" "$@"; }

# 44. under the lock: garbage stdin fails open ({} + stderr advisory + hook_error row); one JSON object for every hook
for h in "${HOOKS[@]}"; do
  [ "$(dec "$h" 'not json{')" = "{}" ] || fail "$h under a lock: garbage stdin did not fail open with {}"
  ERR="$(cd "$HX" && printf 'not json{' | bash "$PLUGIN_ROOT/hooks/$h.sh" 2>&1 >/dev/null)"
  grep -q 'failing open' <<<"$ERR" || fail "$h: no stderr advisory on unparseable stdin"
done
[ "$(rows hook_error)" -ge 4 ] || fail "unparseable stdin wrote no hook_error ledger rows"
for h in "${HOOKS[@]}"; do
  for k in agent bash edit mcp; do
    case "$k" in agent) J="$(pl agent "$HX" Explore sonnet)" ;; bash) J="$(pl bash "$HX" 'git status')" ;;
                 edit) J="$(pl edit "$HX" src/a/x.py)" ;; mcp) J="$(pl mcp "$HX" mcp__srv__tool)" ;; esac
    hk "$h" "$J" | one >/dev/null || fail "$h printed other than exactly one JSON object for a $k payload"
  done
done
pass "ACTIVE lock: unparseable stdin fails open ({} + advisory + hook_error row); every hook prints exactly one JSON object"

# 45. pre-agent: roster, model pin, depth 1, HALT, reviewer gate binding -> stage REVIEW, stage lock, spawn budget
is_deny pre-agent "$(pl agent "$HX" Explore sonnet)" "a subagent_type outside the roster was allowed"
is_deny pre-agent "$(pl agent "$HX" apex-dispatch:tester sonnet)" "apex-dispatch:tester (not on the mechanical roster) was allowed"
is_deny pre-agent "$(pl agent "$HX" apex-dispatch:builder opus)" "model opus on a sonnet route was allowed (deny-on-mismatch)"
hk pre-agent "$(pl agent "$HX" apex-dispatch:builder opus)" | grep -q 'ROUTE_MODEL sonnet' || fail "the model denial does not name ROUTE_MODEL"
U="$(hk pre-agent "$(pl agent "$HX" apex-dispatch:builder '')")"
python3 -c 'import json, sys; h = json.loads(sys.argv[1])["hookSpecificOutput"]; assert h["permissionDecision"] == "allow" and h["updatedInput"] == {"subagent_type": "apex-dispatch:builder", "prompt": "p", "model": "sonnet"}' "$U" \
  || fail "a spawn without model was not pinned to the route's model with a full updatedInput: $U"
is_allow pre-agent "$(pl agent "$HX" apex-dispatch:builder sonnet)" "a roster builder at the route's model was denied"
[ "$(rows spawn_request route_id="$HRID" role=builder)" = 2 ] || fail "allowed spawns did not write hook-sourced spawn_request rows"
is_deny pre-agent "$(pl agent "$HX" apex-dispatch:builder sonnet agent_id=a1 agent_type=apex-dispatch:builder)" "a nested spawn from a builder was allowed"
is_deny pre-agent "$(pl agent "$HX" apex-dispatch:builder sonnet agent_type=apex-dispatch:builder)" "a spawn from a builder worker session was allowed"
(cd "$HX" && APEX_HALT=1 bash "$PLUGIN_ROOT/hooks/pre-agent.sh" <<<"$(pl agent "$HX" apex-dispatch:builder sonnet)" 2>/dev/null) | grep -q '"deny"' || fail "a spawn under APEX_HALT=1 was allowed"
is_deny pre-agent "$(pl agent "$HX" apex-dispatch:reviewer '')" "a reviewer spawn without a gate result was allowed"
mkdir -p "$HSD/gate"
printf '{"result":"PASS","head_sha":"%s"}\n' 0000000000000000000000000000000000000000 >"$HSD/gate/last.json"
is_deny pre-agent "$(pl agent "$HX" apex-dispatch:reviewer '')" "a reviewer spawn on a gate bound to another head was allowed"
printf '{"result":"PASS","head_sha":"%s"}\n' "$(git -C "$HX" rev-parse HEAD)" >"$HSD/gate/last.json"
[ "$(stage)" = BUILD ] || fail "stage is not BUILD before review"
is_allow pre-agent "$(pl agent "$HX" apex-dispatch:reviewer '')" "a reviewer spawn on a gate bound to HEAD was denied"
[ "$(stage)" = REVIEW ] || fail "allowing a reviewer spawn did not set stage REVIEW"
is_deny pre-agent "$(pl agent "$HX" apex-dispatch:builder sonnet)" "a builder spawn during REVIEW was allowed"
stage BUILD
is_allow pre-agent "$(pl agent "$HX" apex-dispatch:builder sonnet)" "the third builder spawn (budget 4) was denied"
is_allow pre-agent "$(pl agent "$HX" apex-dispatch:builder sonnet)" "the fourth builder spawn (budget 4) was denied"
hk pre-agent "$(pl agent "$HX" apex-dispatch:builder sonnet)" | grep -q 'spawn budget' || fail "a fifth builder spawn over ROUTE_BUDGET_SPAWNS=4 was not denied"
pass "pre-agent: roster, model deny-on-mismatch then updatedInput, depth 1, HALT, reviewer only on a gate at HEAD (-> stage REVIEW), no builders in REVIEW, spawn budget; spawn_request rows"

# 46. pre-bash: tamper hardening, provider CLIs, git configuration/internals, protected state, the GATE stage lock
for c in 'APEX_GIBSON=0 bash x' 'export APEX_GIBSON=0' 'env APEX_DISPATCH_MODE=baseline bash iterate.sh' 'APEX_HALT=0 bash x' 'unset APEX_HALT' \
         'export APEX_DISPATCH_ENFORCE=1' 'APEX_STATE_ROOT=/tmp/x bash iterate.sh' \
         'codex exec "do it"' 'claude -p hi' 'npx @openai/codex exec x' 'aider --yes x' 'make run --dangerously-skip-permissions' \
         'git config core.autocrlf true' 'git config --global core.hooksPath /tmp/h' 'git config --unset core.filemode' \
         'git config filter.x.clean cat' 'git config merge.ours.driver true' 'git update-index --assume-unchanged a.py' \
         'git update-index --skip-worktree a.py' 'git -c core.hooksPath=/dev/null commit -m x' 'git -c filter.lfs.clean=cat add .' \
         'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=true git checkout .' 'git sparse-checkout set src' \
         'echo "*.py" >> .git/info/exclude' 'cp hook.sh .git/hooks/pre-commit' 'rm -rf .dev-plan-state/ACTIVE' 'rm -f .dev-plan-state/HALT' 'cd .dev-plan-state && rm x' \
         "sed -i s/BUILD/GATE/ .dev-plan-state/ACTIVE/owner.json" 'mv .claude/apex-dispatch/policy.json /tmp/' 'echo {} > .mcp.json' \
         'bash -c "git config core.autocrlf false"' 'echo $(rm -f .dev-plan-state/x)' "python3 $PLUGIN_ROOT/scripts/lib/ledger.py append" \
         'echo x > ~/.gitconfig' \
         "for f in \$(git ls-files '*.lock'); do git update-index --assume-unchanged \"\$f\"; done" \
         'git ls-files -m | while read f; do git update-index --skip-worktree "$f"; done' \
         'if [ -d .dev-plan-state/ACTIVE ]; then rm -rf .dev-plan-state/ACTIVE; fi' \
         'if true; then git config core.autocrlf true; fi' '! git config core.autocrlf true' \
         'echo "x `git config core.autocrlf true`"' 'case x in x) git config core.filemode false;; esac' \
         'python3 -c "import ledger; ledger.append()"' \
         "python3 -c \"import sys; sys.path.insert(0, '$PLUGIN_ROOT/scripts/lib'); from ledger import append; append({'kind': 'x'})\"" \
         "python3 -c 'import ledger as L; L.append({})'" "python3 -c 'import os, ledger'"; do
  is_deny pre-bash "$(pl bash "$HX" "$c")" "pre-bash allowed: $c"
done
for c in 'git config --get user.name' 'git config user.name' 'git config --list --show-origin' 'git config get user.email' \
         'git status && git diff HEAD~1' 'git -c core.quotepath=false log --oneline' 'APEX_HALT=1 bash x' 'claude --version' \
         'grep -rn "APEX_HALT=" .' 'ls -la 2>/dev/null | head' 'cat .dev-plan-state/ACTIVE/owner.json' 'git update-index --no-skip-worktree a.py' \
         'git commit -m wip' 'echo hi > notes.txt' 'touch .dev-plan-state/HALT' \
         'grep -rn -- --dangerously-skip-permissions docs' 'git commit -m "docs: never pass --yolo"' \
         "python3 -c \"print('ledger ok')\"" 'git -c core.editor=true commit --amend --no-edit' \
         'for f in a b; do echo "$f"; done' 'if git diff --quiet; then echo clean; fi' \
         'pytest tests/test_ledger.py' 'python3 -m pytest -q tests/test_ledger.py' 'python3 -m pytest -k ledger' 'python3 -m pytest tests -m ledger' \
         'python3 -c "import app.ledger"' 'python3 scripts/lib/ledger.py --help' "printf 'x' > /tmp/apex-smoke-scratch"; do
  is_allow pre-bash "$(pl bash "$HX" "$c")" "pre-bash denied: $c"
done
stage GATE
for c in 'git commit -m x' 'for x in a; do git commit -m x; done' 'git add -A' 'git stash' 'git checkout -- a.py' 'echo x > src/a/x.py' 'sed -i s/a/b/ src/a/x.py' 'git branch topic'; do
  is_deny pre-bash "$(pl bash "$HX" "$c")" "pre-bash allowed during GATE: $c"
done
for c in 'git status' 'git log -1' 'git branch --show-current' 'echo x >/dev/null' 'git stash list'; do
  is_allow pre-bash "$(pl bash "$HX" "$c")" "pre-bash denied during GATE: $c"
done
stage BUILD
bash "$LEDGER" verify --state "$HSD" >/dev/null 2>&1 || fail "the ledger does not verify after hook rows"
pass "pre-bash: tamper env, provider CLIs only via shims, bypass flags, git config writes/index flags/-c overrides/.git writes, run state; reads allowed; GATE denies git mutation and writes"

# 47. pre-edit: protected paths for any role, GATE/REVIEW, read-only roles, outside the worktree, lanes' Paths
for f in .dev-plan-state/x .dev-plan-state/ACTIVE/owner.json .claude/apex-dispatch/policy.json .claude/settings.json \
         .claude/settings.local.json .mcp.json .git/config .git/info/attributes "$PLUGIN_ROOT/hooks/pre-bash.sh" \
         /usr/local/apex-smoke-outside.py; do
  is_deny pre-edit "$(pl edit "$HX" "$f")" "pre-edit allowed a write to $f"
done
is_allow pre-edit "$(pl edit "$HX" src/a/x.py)" "pre-edit denied a write inside lane a's Paths"
is_allow pre-edit "$(pl edit "$HX" "$HX/src/b/y.py")" "pre-edit denied a write inside lane b's Paths"
is_deny pre-edit "$(pl edit "$HX" src/c/z.py)" "pre-edit allowed a write outside every lane's Paths"
is_deny pre-edit "$(pl edit "$HX" src/a/x.py agent_id=r1 agent_type=apex-dispatch:reviewer)" "pre-edit allowed a write from a read-only reviewer"
stage REVIEW
is_deny pre-edit "$(pl edit "$HX" src/a/x.py)" "pre-edit allowed a write during REVIEW"
stage BUILD
pass "pre-edit: .dev-plan-state, .claude/apex-dispatch, settings, .mcp.json, .git, plugin files, outside the worktree denied; lanes' Paths; read-only roles; REVIEW"

# 48. pre-mcp: a no-op unless the merged policy sets mcp.default_deny; then only allowlisted servers
is_allow pre-mcp "$(pl mcp "$HX" mcp__other__tool)" "pre-mcp denied with mcp.default_deny false"
mkdir -p "$HX/.claude/apex-dispatch"
printf '{"mcp": {"default_deny": true, "servers_allow": ["docs"]}}\n' >"$HX/.claude/apex-dispatch/policy.json"
is_deny pre-mcp "$(pl mcp "$HX" mcp__other__tool)" "pre-mcp allowed a server outside servers_allow under default_deny"
is_allow pre-mcp "$(pl mcp "$HX" mcp__docs__search)" "pre-mcp denied an allowlisted server"
is_allow pre-mcp "$(pl bash "$HX" 'true')" "pre-mcp acted on a non-MCP tool"
rm -rf "$HX/.claude"
pass "pre-mcp: no-op by default; under mcp.default_deny only servers_allow (+ the role's mcp_allow) pass"

# 49. hot path: a governed invocation stays well under the 10 s hook timeout; the no-lock path starts no python
T0="$(date +%s%N)"; hk pre-bash "$(pl bash "$HX" 'git status')" >/dev/null; T1="$(date +%s%N)"
MS=$(( (T1 - T0) / 1000000 ))
[ "$MS" -lt 2000 ] || fail "pre-bash took ${MS} ms under a lock (budget 2000 ms, timeout 10 s)"
grep -q 'python3' "$PLUGIN_ROOT/scripts/lib/hook-common.bash" && \
  awk '/STATE_BASE\/ACTIVE/{lock=NR} /python3 -B/{py=NR} END{exit !(lock && py && lock < py)}' "$PLUGIN_ROOT/scripts/lib/hook-common.bash" \
  || fail "hook-common.bash does not check the ACTIVE lock before starting python3"
pass "a governed pre-bash call took ${MS} ms (< 2000 ms; timeout 10 s); python3 starts only after the ACTIVE lock check"

# 50. apex-scope-loop's real layout: the plan worktree lives at <state>/worktree inside .dev-plan-state/.
#     Work inside it is allowed; the run state around it (checkpoint.json, gate/, ACTIVE, the worktree dir itself) is not.
WX="$WORK/wx"; mkdir -p "$WX/plans"; git init -q -b main "$WX"
printf '# W\n\n- [ ] **Phase 1.1** [mechanical] work in the worktree\n  - Acceptance: `pytest -q`\n  - Paths: src/a/**, tests/**\n' >"$WX/plans/p.md"
printf '.dev-plan-state/\n' >"$WX/.gitignore"
git -C "$WX" add -A; git -C "$WX" commit -qm wx
(cd "$WX" && bash "$MARKET_ROOT/plugins/apex-scope-loop/skills/apex-execute/scripts/init.sh" plans/p.md >/dev/null 2>&1) || fail "apex-scope-loop init.sh failed in the worktree fixture"
O="$(cd "$WX" && bash "$ROUTE" plan plans/p.md --line 3 2>&1)"
[ "$(val ROUTE_STATUS "$O")" = READY ] || fail "worktree fixture route is not READY: $O"
WSD="$(dirname "$(dirname "$(val ROUTE_FILE "$O")")")"; WWT="$WSD/worktree"
[ -d "$WWT" ] && [ -f "$WSD/checkpoint.json" ] && [ -d "$WX/.dev-plan-state/ACTIVE" ] || fail "init.sh did not put the worktree at <state>/worktree"
wk() { (cd "$WWT" && printf '%s' "$2" | bash "$PLUGIN_ROOT/hooks/$1.sh" 2>/dev/null) | one; }
for f in src/a/x.py "$WWT/src/a/x.py" tests/test_a.py "$WWT/tests/test_a.py"; do
  [ "$(wk pre-edit "$(pl edit "$WWT" "$f")")" = "{}" ] || fail "pre-edit denied $f inside the <state>/worktree plan worktree"
done
for c in 'echo y > src/a/x.py' 'mkdir -p src/a/new && touch src/a/new/f.py' 'rm src/a/x.py' 'cp src/a/x.py src/a/y.py' \
         'mkdir -p tests' 'git add -A && git commit -m wip' 'cp templates/conf.py .' 'cp src/a/x.py ./' 'cd src && cp a/x.py ..' \
         'mv build/out.py .' "find . -name '*.pyc' -delete" 'patch -p1 < fix.diff' 'rsync -a vendor/ .' 'chmod -R u+w .' 'touch .' 'find src -name "*.tmp" -delete' 'rsync -a --delete --exclude=.git vendor/ .' \
         'mv -t src/a src/b/x.py' 'git worktree list' "find ../worktree -name '*.pyc' -delete" "find $WWT -name '*.pyc' -delete" \
         "cd src && find .. -name '*.pyc' -delete" 'find . -type d -empty -delete' 'rsync -a --delete --exclude .git vendor/ .' \
         "rsync -a --delete -f '- .git' vendor/ ." 'rsync -a --delete vendor/ build/' "find . -name '*.pyc' -delete" \
         'find . -name __pycache__ -exec rm -rf {} +' 'find src ! -name x -delete' "find \"\$TMPDIR\" -name '*.log' -delete" \
         "find \"\$OUT\" -name '*.o' -delete"; do
  [ "$(wk pre-bash "$(pl bash "$WWT" "$c")")" = "{}" ] || fail "pre-bash denied in the <state>/worktree plan worktree: $c"
done
for f in "$WSD/checkpoint.json" ../checkpoint.json ../gate/last.json "$WX/.dev-plan-state/ACTIVE/owner.json" .dev-plan-state/x .git; do
  [ "$(wk pre-edit "$(pl edit "$WWT" "$f")")" = deny ] || fail "pre-edit allowed $f from the <state>/worktree plan worktree"
done
for c in 'rm -rf .' 'mv . ../x' 'rmdir .' 'find ../worktree -delete' "find $WWT -delete" 'find -L ../worktree -exec rm -rf {} +' \
         'find . -name .git -delete' "find . -name '.g*' -delete" "find . -path './.git' -delete" "find $WWT -name worktree -exec rm -rf {} +" \
         'git -C .. worktree remove worktree --force' 'git -C src worktree remove ..' "git -C $WWT/.. worktree remove worktree" \
         "git -C $WX worktree remove ${WWT#"$WX"/}" 'rsync -a --del vendor/ .' 'rsync -a --delete --exclude=.github vendor/ .' \
         'rsync -a --delete --exclude=.git --delete-excluded vendor/ .' 'rsync -a --delete --exclude=.gitignore vendor/ .' \
         'rsync -a --delete vendor/ "$PWD"' \
         "find . ! -name '*.py' -delete" "find . -type f ! -name '*.keep' -delete" "find . -not -name '*.py' -type f -delete" \
         "find . -name '*.pyc' -o -type f -delete" 'find . -path ./node_modules -prune -o -type f -delete' \
         'find "$OUT" -delete' 'find "$OUT" -type f -delete' \
         'mv -vt /tmp ../worktree' 'mv -t/tmp ../worktree' 'mv --target=/tmp ../worktree' 'mv --target-directory /tmp ../worktree' \
         'mv -t ../ src' 'git worktree remove --force .' "git worktree remove $WWT" 'git worktree move . /tmp/elsewhere' \
         'find . -delete' 'find . -type f -delete' 'rsync -a --delete vendor/ .' 'echo x > ../checkpoint.json' 'rm -rf ../gate' "rm -rf $WX/.dev-plan-state/ACTIVE" 'rm -rf ../worktree' 'touch ../dispatch-shadow/x' \
         'mkdir -p .dev-plan-state && echo x > .dev-plan-state/y'; do
  [ "$(wk pre-bash "$(pl bash "$WWT" "$c")")" = deny ] || fail "pre-bash allowed from the <state>/worktree plan worktree: $c"
done
pass "init.sh layout (<state>/worktree): edits, writes, rm/cp/mkdir, commits and the worktree root as a cp/mv/patch/chmod/find target pass; removing or moving the root, checkpoint, gate, ACTIVE and nested state stay denied"

# --- Phase 3.2: post-agent, subagent-start/stop, stop-gate, post-bash-prune ---
# pj key=value... -> one JSON object (values parsed as JSON when they parse; dotted keys nest)
pj() { python3 -c 'import json, sys
d = {}
for kv in sys.argv[1:]:
    k, _, v = kv.partition("=")
    try:
        v = json.loads(v)
    except ValueError:
        pass
    cur = d
    *path, last = k.split(".")
    for x in path:
        cur = cur.setdefault(x, {})
    cur[last] = v
print(json.dumps(d))' "$@"; }
# hr HOOK DIR JSON -> stdout of the hook run in DIR; rc in $HRC, stderr in $WORK/hr.err
hr() { HRC=0; HOUT="$( (cd "$2" && printf '%s' "$3" | bash "$PLUGIN_ROOT/hooks/$1.sh" 2>"$WORK/hr.err") )" || HRC=$?; printf '%s\n' "$HOUT" | one >/dev/null || fail "$1 printed other than exactly one JSON object: [$HOUT] $(cat "$WORK/hr.err")"; }
# rowsin LEDGER EVENT [k=v...] -> number of hook-sourced rows matching
rowsin() { python3 -c 'import json, sys
r = [json.loads(l) for l in open(sys.argv[1])]
print(sum(1 for x in r if x["event"] == sys.argv[2] and x.get("source") == "hook" and all(str(x.get(k)) == v for k, v in (a.split("=", 1) for a in sys.argv[3:]))))' "$@"; }
jget() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d = d[k]
print(d)' "$1" "$2"; }

# 51. the five Phase 3.2 hooks: without a lock {} for garbage, empty and real payloads; under a lock garbage fails open
NX="$WORK/nx"; mkdir -p "$NX"; git init -q -b main "$NX"; git -C "$NX" commit -q --allow-empty -m nx
for h in "${HOOKS32[@]}"; do
  for j in 'not json{' '' "$(pj tool_name=Agent hook_event_name=PostToolUse tool_input.subagent_type=apex-dispatch:builder "cwd=$NX")" \
           "$(pj agent_id=x1 agent_type=apex-dispatch:reviewer last_assistant_message='VERDICT: APPROVE' "cwd=$NX")" "$(pj hook_event_name=Stop "cwd=$NX")"; do
    hr "$h" "$NX" "$j"; [ "$HRC" = 0 ] && [ "$HOUT" = "{}" ] || fail "$h without a lock did not give {} exit 0 (rc=$HRC, $HOUT)"
  done
  hr "$h" "$HX" 'not json{'; [ "$HRC" = 0 ] && [ "$HOUT" = "{}" ] && grep -q 'failing open' "$WORK/hr.err" || fail "$h under a lock: garbage stdin did not fail open"
done
[ ! -e "$NX/.dev-plan-state" ] || fail "a Phase 3.2 hook wrote state without an ACTIVE lock"
pass "post-agent, post-bash-prune, subagent-start, subagent-stop, stop-gate: {} and exit 0 without a lock (garbage, empty, real payloads); fail open under a lock"

# 52. carried hardening: quoted/escaped parens are find arguments; ancestors of the run state and the worktree
#     are not removed; a `$` find start is checked against every root's basename; mark_enforced skips the lock
for c in "find . '(' -type f ')' -delete" 'find . \( -type f \) -delete' 'find . "(" -type f ")" -delete' 'rm -rf ../../..' \
         "find $WX -delete" "find $WX -name .dev-plan-state -exec rm -rf {} +" "find $WX -name '.dev*' -delete" 'rm -rf /' \
         "mv $WX /tmp/elsewhere" 'find "$OUT" -name worktree -delete' 'find "$OUT" -name .dev-plan-state -delete' \
         'find "$OUT" -name wx -exec rm -rf {} +' "find ../../.. -path '*/.dev-plan-state' -exec rm -rf {} +"; do
  [ "$(wk pre-bash "$(pl bash "$WWT" "$c")")" = deny ] || fail "pre-bash allowed from the plan worktree: $c"
done
for c in "find . '(' -name '*.pyc' ')' -delete" "echo '(' x ')'" "find $WX -name '*.pyc' -delete" 'find "$OUT" -name "*.o" -delete' \
         'rm -rf src/a'; do
  [ "$(wk pre-bash "$(pl bash "$WWT" "$c")")" = "{}" ] || fail "pre-bash denied from the plan worktree: $c"
done
bx() { (cd "$WX" && printf '%s' "$2" | bash "$PLUGIN_ROOT/hooks/$1.sh" 2>/dev/null) | one; }
for c in 'rm -rf .' "rm -rf $WX" 'find . -delete' 'find . -type f -delete' "find . -name .dev-plan-state -prune -o -delete"; do
  [ "$(bx pre-bash "$(pl bash "$WX" "$c")")" = deny ] || fail "pre-bash allowed in the base checkout: $c"
done
[ "$(bx pre-bash "$(pl bash "$WX" "find . -name '*.pyc' -delete")")" = "{}" ] || fail "a filtered find in the base checkout was denied"
ME="$WORK/me"; mkdir -p "$ME/dispatch"; printf '{"dispatch_enforced": true, "worktree_path": "%s"}\n' "$NX" >"$ME/checkpoint.json"
python3 -c 'import fcntl, os, sys, time; fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR); fcntl.flock(fd, fcntl.LOCK_EX); time.sleep(6)' "$ME/.checkpoint.lock" &
LKPID=$!; sleep 0.3
T0="$(date +%s%N)"; lg append hook_advisory '{"hook":"x","advisory":"y"}' --state "$ME" --source cli >/dev/null || fail "append to an enforced state failed"
MS=$(( ($(date +%s%N) - T0) / 1000000 )); kill "$LKPID" 2>/dev/null || true; wait "$LKPID" 2>/dev/null || true
[ "$MS" -lt 1500 ] || fail "an append to a state already marked dispatch_enforced waited ${MS} ms for the checkpoint lock"
pass "quoted/escaped ( ) stay find arguments; ancestors of the run (rm -rf ../../.., rm -rf . in the base, find <base> -delete) denied; \$ starts checked against every root name; mark_enforced skips the lock when already set (${MS} ms)"

# A fresh single-builder route for the agent-lifecycle checks (dispatch-shadow, route mode table).
UX="$WORK/ux"; mkdir -p "$UX/plans" "$UX/src"; git init -q -b main "$UX"
printf '# U\n\n- [ ] **Phase 1.1** [mechanical] one builder\n  - Acceptance: `pytest -q`\n  - Paths: src/**\n' >"$UX/plans/p.md"
printf '.dev-plan-state/\n' >"$UX/.gitignore"; echo a >"$UX/src/a.py"; git -C "$UX" add -A; git -C "$UX" commit -qm ux
O="$(cd "$UX" && bash "$ROUTE" plan plans/p.md --line 3 2>&1)"; [ "$(val ROUTE_STATUS "$O")" = READY ] || fail "lifecycle fixture route is not READY: $O"
URID="$(val ROUTE_ID "$O")"; USD_="$(dirname "$(dirname "$(val ROUTE_FILE "$O")")")"; UD="$USD_/dispatch-shadow"; UL="$UD/ledger.jsonl"
UOWN="$UX/.dev-plan-state/ACTIVE/owner.json"
ustage() { python3 -c 'import json, sys; o = json.load(open(sys.argv[1])); print(o["stage"]) if len(sys.argv) == 2 else (o.update(stage=sys.argv[2]), json.dump(o, open(sys.argv[1], "w")))' "$UOWN" "$@"; }
uh() { hr "$1" "$UX" "$2"; }
ua() { (cd "$UX" && printf '%s' "$1" | bash "$PLUGIN_ROOT/hooks/pre-agent.sh" 2>/dev/null); }
start() { uh subagent-start "$(pj agent_id="$1" agent_type="$2" session_id=s "cwd=$UX")"; }
stopa() { uh subagent-stop "$(pj agent_id="$1" agent_type="$2" "last_assistant_message=$3" stop_hook_active="${4:-false}" agent_transcript_path="${5:-}" session_id=s "cwd=$UX")"; }

# 53. subagent-start registers agent_id -> role -> route; the live set gates REVIEW; subagent-stop writes raw review records
start b1 apex-dispatch:builder
[ "$(jget "$UD/agents/b1.json" role)" = builder ] && [ "$(jget "$UD/agents/b1.json" route_id)" = "$URID" ] || fail "subagent-start did not register b1 -> builder -> $URID"
[ "$(rowsin "$UL" spawn agent_id=b1 role=builder route_id="$URID")" = 1 ] || fail "subagent-start wrote no hook-sourced spawn row"
start e1 Explore; start ../x apex-dispatch:builder
[ ! -e "$UD/agents/e1.json" ] && [ -z "$(ls "$UD/agents" | grep -v '^b1.json$' || true)" ] || fail "a foreign agent type or a path-like agent_id was registered"
mkdir -p "$USD_/gate"; printf '{"result":"PASS","head_sha":"%s"}\n' "$(git -C "$UX" rev-parse HEAD)" >"$USD_/gate/last.json"
O="$(ua "$(pl agent "$UX" apex-dispatch:reviewer '')")"
grep -q 'still registered as running' <<<"$O" || fail "a reviewer spawn was allowed while builder b1 is live: $O"
stopa b1 apex-dispatch:builder 'done'
[ -n "$(jget "$UD/agents/b1.json" stopped_at)" ] && [ "$(jget "$UD/agents/b1.json" stopped_at)" != None ] || fail "subagent-stop did not record b1's stop"
[ "$(ua "$(pl agent "$UX" apex-dispatch:reviewer '')" | one)" = "{}" ] || fail "the reviewer spawn was denied after the builder stopped"
[ "$(ustage)" = REVIEW ] || fail "the reviewer spawn did not move the stage to REVIEW"; ustage BUILD
start r1 apex-dispatch:reviewer; stopa r1 apex-dispatch:reviewer "$(printf 'Findings: none\nLENS: security\n**VERDICT: APPROVE**')"
R1="$UD/reviews-raw/r1.json"; [ -f "$R1" ] || fail "subagent-stop wrote no reviews-raw record for reviewer r1"
python3 - "$R1" "$(git -C "$UX" rev-parse HEAD)" "$URID" <<'PY' || fail "the r1 raw record does not carry record_id/line/head/role/lens/verdict/family"
import json, re, sys
r, head, rid = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
assert re.fullmatch(r"[A-Za-z0-9_-]{8,128}", r["record_id"]) and r["record_id"].startswith("r1-"), r
assert r["line"] == 3 and r["head_sha"] == head and r["role"] == "lens:security" and r["lens"] == "security", r
assert r["verdict"] == "APPROVE" and r["provider"] == "claude-session" and r["family"] == "anthropic" and r["route"] == rid, r
PY
RID1="$(jget "$R1" record_id)"; stopa r1 apex-dispatch:reviewer 'VERDICT: REQUEST_CHANGES'
[ "$(jget "$R1" record_id)" = "$RID1" ] && [ "$(jget "$R1" verdict)" = APPROVE ] || fail "a second stop rewrote r1's record"
[ "$(rowsin "$UL" verdict agent_id=r1 verdict=APPROVE role=lens:security)" = 1 ] || fail "no single hook-sourced verdict row for r1"
start a1 apex-dispatch:adversarial-reviewer; stopa a1 apex-dispatch:adversarial-reviewer "$(printf 'tried 3 inputs\nVERDICT: REQUEST_CHANGES')"
[ "$(jget "$UD/reviews-raw/a1.json" role)" = adversarial ] && [ "$(jget "$UD/reviews-raw/a1.json" verdict)" = REQUEST_CHANGES ] || fail "the adversarial reviewer's record lacks role adversarial"
start g1 apex-scope-loop:gibson-reviewer; stopa g1 apex-scope-loop:gibson-reviewer "$(printf 'LENS: adversarial\nVERDICT: APPROVE')"
[ "$(jget "$UD/reviews-raw/g1.json" role)" = adversarial ] || fail "gibson-reviewer's LENS: adversarial did not give role adversarial"
start n1 apex-dispatch:reviewer; stopa n1 apex-dispatch:reviewer 'I approve of this.'
[ ! -e "$UD/reviews-raw/n1.json" ] && [ "$(rowsin "$UL" hook_advisory agent_id=n1)" = 1 ] || fail "a reviewer without a VERDICT line got a record (or no advisory row)"
python3 -c 'import json, sys; json.dump({"agent_id": "old1", "role": "builder", "started_at": "2000-01-01T00:00:00Z", "stopped_at": None}, open(sys.argv[1], "w"))' "$UD/agents/old1.json"
[ "$(ua "$(pl agent "$UX" apex-dispatch:reviewer '')" | one)" = "{}" ] || fail "a registration older than the route's wall-clock budget still blocked review"
ustage BUILD
pass "subagent-start registers agent_id -> role -> route + spawn row; REVIEW refused while a builder is live; subagent-stop: reviews-raw record (record_id, line, HEAD, role/lens, verdict, family) once per agent + verdict row; adversarial/gibson roles; no VERDICT, no record"

# 54. transcript audit of read-only roles: a write or git mutation refuses the record, writes policy_violation, exits 2 once
TR="$WORK/transcripts"; mkdir -p "$TR"
tr_write() {  # tr_write FILE NAME INPUT_JSON IS_ERROR
  python3 -c 'import json, sys
f, name, inp, err = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), sys.argv[4] == "1"
with open(f, "a") as o:
    n = sum(1 for _ in open(f)) if __import__("os").path.exists(f) else 0
    tid = "tu%d" % n
    o.write(json.dumps({"type": "assistant", "cwd": sys.argv[5], "message": {"content": [{"type": "tool_use", "id": tid, "name": name, "input": inp}]}}) + "\n")
    o.write(json.dumps({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": tid, "is_error": err, "content": "x"}]}}) + "\n")' "$@" "$UX"; }
tr_write "$TR/v1.jsonl" Read '{"file_path": "src/a.py"}' 0
tr_write "$TR/v1.jsonl" Bash '{"command": "git commit -am sneaky"}' 0
start v1 apex-dispatch:reviewer; stopa v1 apex-dispatch:reviewer 'VERDICT: APPROVE' false "$TR/v1.jsonl"
[ "$HRC" = 2 ] && [ "$HOUT" = "{}" ] && grep -q 'read-only role reviewer' "$WORK/hr.err" || fail "a reviewer that committed was not refused with exit 2 (rc=$HRC)"
[ -n "$(jget "$UD/reviews-raw/v1.json" refused)" ] && [ "$(rowsin "$UL" policy_violation agent_id=v1)" = 1 ] || fail "no refused record / policy_violation row for v1"
stopa v1 apex-dispatch:reviewer 'VERDICT: APPROVE' true "$TR/v1.jsonl"
[ "$HRC" = 0 ] && [ "$HOUT" = "{}" ] || fail "the audit blocked again with stop_hook_active (rc=$HRC)"
python3 -c 'import json,sys; assert "verdict" not in json.load(open(sys.argv[1]))' "$UD/reviews-raw/v1.json" || fail "a refused record was replaced by a verdict on the re-fired stop"
tr_write "$TR/v2.jsonl" Bash '{"command": "git commit -am denied"}' 1
tr_write "$TR/v2.jsonl" Bash '{"command": "git log --oneline -3"}' 0
tr_write "$TR/v2.jsonl" Grep '{"pattern": "x"}' 0
start v2 apex-scope-loop:gibson-reviewer; stopa v2 apex-scope-loop:gibson-reviewer 'VERDICT: APPROVE' false "$TR/v2.jsonl"
[ "$HRC" = 0 ] && [ "$(jget "$UD/reviews-raw/v2.json" verdict)" = APPROVE ] || fail "a denied attempt or read-only git was treated as a violation (rc=$HRC)"
tr_write "$TR/v3.jsonl" Write '{"file_path": "src/a.py", "content": "y"}' 0
start v3 apex-dispatch:reviewer
T0="$(date +%s%N)"; stopa v3 apex-dispatch:reviewer 'VERDICT: APPROVE' false "$TR/v3.jsonl"; MS=$(( ($(date +%s%N) - T0) / 1000000 ))
[ "$HRC" = 2 ] || fail "a reviewer's Write was not refused"
[ "$MS" -lt 2000 ] || fail "subagent-stop with a transcript audit took ${MS} ms (budget 2000 ms, timeout 10 s)"
tr_write "$TR/b2.jsonl" Bash '{"command": "git commit -am work"}' 0
start b2 apex-dispatch:builder; stopa b2 apex-dispatch:builder 'done' false "$TR/b2.jsonl"; [ "$HRC" = 0 ] || fail "a builder's commit was audited as a violation"
pass "subagent-stop audit: a read-only role's successful write or git mutation -> refused record + policy_violation + exit 2, once (stop_hook_active passes); denied attempts and read-only git pass; builders are not audited; ${MS} ms"

# 55. post-agent: worker_run with resolvedModel/usage/duration/tools (once per tool use), model_mismatch, failures;
#     the USD estimate feeds pre-agent's ROUTE_BUDGET_USD
pa() { uh post-agent "$(pj tool_name=Agent hook_event_name="${2:-PostToolUse}" tool_use_id="$1" tool_input.subagent_type=apex-dispatch:builder tool_input.model=sonnet "cwd=$UX" "${@:3}")"; }
pa u1 PostToolUse tool_response.agentId=b3 tool_response.status=completed tool_response.resolvedModel=claude-sonnet-5-5 tool_response.totalDurationMs=5400 \
  tool_response.totalToolUseCount=14 tool_response.usage.input_tokens=41000 tool_response.usage.output_tokens=6000 tool_response.usage.cache_read_input_tokens=100000
[ "$HOUT" = "{}" ] || fail "post-agent answered a matching run with $HOUT"
python3 - "$UL" <<'PY' || fail "post-agent did not write a worker_run row with resolved_model, normalised usage, duration, tool count and a USD estimate"
import json, sys
r = [json.loads(l) for l in open(sys.argv[1]) if '"worker_run"' in l]
w = [x for x in r if x.get("tool_use_id") == "u1"]
assert len(w) == 1, w
w = w[0]
assert w["source"] == "hook" and w["provider"] == "claude-session" and w["role"] == "builder" and w["exit_code"] == 0, w
assert w["resolved_model"] == "claude-sonnet-5-5" and w["usage"] == {"input": 41000, "output": 6000, "cache_read": 100000}, w
assert w["duration_ms"] == 5400 and w["tool_count"] == 14 and abs(w["usd_estimate"] - (41000 * 3 + 6000 * 15 + 100000 * 0.3) / 1e6) < 1e-9, w
PY
pa u1 PostToolUse tool_response.resolvedModel=claude-sonnet-5-5 tool_response.usage.input_tokens=1
[ "$(rowsin "$UL" worker_run tool_use_id=u1)" = 1 ] || fail "a repeated tool_use_id wrote a second worker_run row"
pa u2 PostToolUse tool_response.resolvedModel=claude-opus-4-1 tool_response.status=completed tool_response.usage.output_tokens=10
grep -q 'model_mismatch' <<<"$HOUT" && [ "$(rowsin "$UL" model_mismatch tool_use_id=u2 route_model=sonnet)" = 1 ] || fail "an opus run on a sonnet route was not recorded as model_mismatch: $HOUT"
pa u3 PostToolUse tool_response.status=async_launched tool_response.agentId=b4
[ "$(rowsin "$UL" worker_run tool_use_id=u3)" = 0 ] && [ "$(rowsin "$UL" hook_advisory tool_use_id=u3)" = 1 ] || fail "a background launch without usage was priced or not noted"
pa u4 PostToolUseFailure error=boom
[ "$(rowsin "$UL" worker_run tool_use_id=u4 exit_code=1)" = 1 ] || fail "PostToolUseFailure did not write a failed worker_run row"
[ "$(ua "$(pl agent "$UX" apex-dispatch:builder sonnet)" | one)" = "{}" ] || fail "a builder spawn under the USD budget was denied"
pa u5 PostToolUse tool_response.resolvedModel=claude-sonnet-5-5 tool_response.status=completed tool_response.usage.input_tokens=600000
grep -q 'ROUTE_BUDGET_USD' <<<"$HOUT" || fail "post-agent did not say the USD budget is reached: $HOUT"
O="$(ua "$(pl agent "$UX" apex-dispatch:builder sonnet)")"
grep -q 'USD budget is spent' <<<"$O" || fail "pre-agent allowed a builder spawn over ROUTE_BUDGET_USD: $O"
bash "$LEDGER" verify --state "$USD_" >/dev/null 2>&1 || fail "the lifecycle ledger does not verify"
O="$(bash "$REPORT" --state "$USD_")"
has '^REPORT_MODEL_MISMATCHES: 1' "$O" && has '^REPORT_POLICY_VIOLATIONS: 2' "$O" || fail "report.sh does not count model_mismatch/policy_violation rows: $O"
pass "post-agent: one worker_run per tool use (resolvedModel, usage, duration, tools, USD estimate), model_mismatch + additionalContext, background launches unpriced, failures exit_code 1; pre-agent denies builder spawns once ROUTE_BUDGET_USD is reached"

# 56. stop-gate: escapes (stop_hook_active, HALT, not BUILD), then blocks once per route on uncommitted work and on inline work
sg() { uh stop-gate "$(pj hook_event_name=Stop session_id=s stop_hook_active="${1:-false}" "cwd=$UX")"; }
echo dirty >"$UX/src/b.py"
sg true; [ "$HRC" = 0 ] || fail "stop-gate blocked with stop_hook_active"
(cd "$UX" && printf '%s' "$(pj hook_event_name=Stop "cwd=$UX")" | APEX_HALT=1 bash "$PLUGIN_ROOT/hooks/stop-gate.sh" >/dev/null 2>&1) || fail "stop-gate blocked under APEX_HALT=1"
ustage GATE; sg; [ "$HRC" = 0 ] || fail "stop-gate blocked outside BUILD"; ustage BUILD
sg; [ "$HRC" = 2 ] && [ "$HOUT" = "{}" ] && grep -q 'uncommitted changes' "$WORK/hr.err" || fail "stop-gate did not block once on an uncommitted worktree (rc=$HRC)"
sg; [ "$HRC" = 0 ] || fail "stop-gate blocked twice for one route"
git -C "$UX" add -A; git -C "$UX" commit -qm wip
O="$(cd "$UX" && bash "$ROUTE" plan plans/p.md --line 3 2>&1)"; URID2="$(val ROUTE_ID "$O")"; [ "$URID2" != "$URID" ] || fail "re-route gave the same id"
git -C "$UX" commit -q --allow-empty -m inline
sg; [ "$HRC" = 2 ] && grep -q 'done inline' "$WORK/hr.err" || fail "stop-gate did not block a route whose HEAD moved with no spawn (rc=$HRC)"
[ "$(rowsin "$UL" hook_advisory blocked=True)" = 2 ] || fail "stop-gate blocks were not ledgered"
pass "stop-gate: never with stop_hook_active, HALT or outside BUILD; blocks once per route (exit 2, reason on stderr) on uncommitted work or HEAD moved without a spawn"

# 57. post-bash-prune is record-only: a long runner output is kept under logs/ with an advisory row; output is never replaced
LONG="$(python3 -c 'print("\n".join(["test_%d PASSED" % i for i in range(300)] + ["FAILED tests/test_x.py::t - assert 1 == 2"]))')"
pb() { uh post-bash-prune "$(pj tool_name=Bash hook_event_name=PostToolUse tool_use_id="$1" "tool_input.command=$2" "tool_response.stdout=$3" tool_response.stderr= "cwd=$UX")"; }
pb pb1 'uv run pytest -q' "$LONG"; [ "$HOUT" = "{}" ] || fail "post-bash-prune answered with $HOUT (it may not replace output)"
[ "$(wc -l <"$UD/logs/pb1.log")" -ge 300 ] && [ "$(rowsin "$UL" hook_advisory tool_use_id=pb1 runner=pytest failure_lines=1)" = 1 ] || fail "a long pytest run was not kept under logs/ with an advisory row"
pb pb2 'pytest -q' 'ok'; pb pb3 'cat big.txt' "$LONG"
[ ! -e "$UD/logs/pb2.log" ] && [ ! -e "$UD/logs/pb3.log" ] || fail "post-bash-prune logged a short run or a non-runner command"
pass "post-bash-prune: record-only (Phase 0 spike 9): long runner output kept at logs/<tool_use_id>.log + hook_advisory; short or non-runner output untouched"

# 58. end to end, enforced by default: route -> spawn (pre-agent, subagent-start/stop, post-agent) -> gate (stage GATE)
#     -> reviewer (stage REVIEW) -> raw record -> checkpoint.sh review --agent-id -> complete (ledger evidence) -> DONE
EX="$WORK/ex"; mkdir -p "$EX/plans"; git init -q -b main "$EX"
printf '# E\n\n- [ ] **Phase 1.1** [mechanical] rename a helper\n  - Acceptance: `true`\n  - Paths: src/**\n' >"$EX/plans/p.md"
printf '.dev-plan-state/\n' >"$EX/.gitignore"; git -C "$EX" add -A; git -C "$EX" commit -qm ex
EXS="$MARKET_ROOT/plugins/apex-scope-loop/skills/apex-execute/scripts"
(cd "$EX" && env -u APEX_DISPATCH_ENFORCE bash "$EXS/init.sh" plans/p.md >/dev/null 2>&1) || fail "init.sh failed in the end-to-end fixture"
O="$(cd "$EX" && env -u APEX_DISPATCH_ENFORCE bash "$ROUTE" plan plans/p.md --line 3 2>&1)"
[ "$(val ROUTE_STATUS "$O")" = READY ] && [ "$(val ROUTE_ENFORCED "$O")" = yes ] || fail "the default route is not enforced (ROUTE_ENFORCED yes): $O"
ERID="$(val ROUTE_ID "$O")"; ESD="$(dirname "$(dirname "$(val ROUTE_FILE "$O")")")"; EWT="$ESD/worktree"
[ -d "$ESD/dispatch" ] && [ ! -e "$ESD/dispatch-shadow" ] && [ "$(jget "$ESD/checkpoint.json" dispatch_enforced)" = True ] || fail "enforcement did not create <state>/dispatch/ and record dispatch_enforced"
eh() { HRC=0; HOUT="$( (cd "$EWT" && printf '%s' "$2" | env -u APEX_DISPATCH_ENFORCE bash "$PLUGIN_ROOT/hooks/$1.sh" 2>"$WORK/hr.err") )" || HRC=$?; }
eh pre-agent "$(pl agent "$EWT" apex-dispatch:builder sonnet)"; [ "$HOUT" = "{}" ] || fail "e2e: the builder spawn was denied: $HOUT"
eh subagent-start "$(pj agent_id=eb1 agent_type=apex-dispatch:builder "cwd=$EWT")"
mkdir -p "$EWT/src"; echo 'def helper(): pass' >"$EWT/src/h.py"; git -C "$EWT" add -A; git -C "$EWT" commit -qm "rename helper"
eh subagent-stop "$(pj agent_id=eb1 agent_type=apex-dispatch:builder last_assistant_message=done "cwd=$EWT")"
eh post-agent "$(pj tool_name=Agent hook_event_name=PostToolUse tool_use_id=eu1 tool_input.subagent_type=apex-dispatch:builder tool_input.model=sonnet \
  tool_response.agentId=eb1 tool_response.status=completed tool_response.resolvedModel=claude-sonnet-5-5 tool_response.usage.input_tokens=1000 "cwd=$EWT")"
(cd "$EX" && APEX_GATE_TEST=true bash "$EXS/green-gate.sh" plans/p.md check >/dev/null 2>&1) || fail "e2e: green-gate check did not pass"
[ "$(jget "$EX/.dev-plan-state/ACTIVE/owner.json" stage)" = GATE ] || fail "a passing green-gate check did not move the stage to GATE"
eh pre-bash "$(pl bash "$EWT" 'git commit --allow-empty -m late')"; [ "$(printf '%s\n' "$HOUT" | one)" = deny ] || fail "e2e: a commit during GATE was allowed"
FORK="$(jget "$ESD/checkpoint.json" fork_sha)"
(cd "$EX" && bash "$EXS/risk-tier.sh" plans/p.md 3 --since "$FORK" >/dev/null 2>&1) || fail "e2e: risk-tier.sh failed"
eh pre-agent "$(pl agent "$EWT" apex-dispatch:reviewer '')"; [ "$HOUT" = "{}" ] || fail "e2e: the reviewer spawn was denied: $HOUT"
[ "$(jget "$EX/.dev-plan-state/ACTIVE/owner.json" stage)" = REVIEW ] || fail "e2e: the reviewer spawn did not move the stage to REVIEW"
eh subagent-start "$(pj agent_id=er1 agent_type=apex-dispatch:reviewer "cwd=$EWT")"
eh subagent-stop "$(pj agent_id=er1 agent_type=apex-dispatch:reviewer "last_assistant_message=$(printf 'Acceptance met.\nVERDICT: APPROVE')" "cwd=$EWT")"
ECK="$EXS/checkpoint.sh"; EHEAD="$(git -C "$EWT" rev-parse HEAD)"
[ "$(jget "$ESD/dispatch/reviews-raw/er1.json" head_sha)" = "$EHEAD" ] || fail "e2e: the raw record is not bound to HEAD"
O="$(cd "$EX" && bash "$ECK" plans/p.md review 3 "$EHEAD" APPROVE reviewer 2>&1)" && fail "e2e: a typed verdict was accepted in provenance mode"
(cd "$EX" && bash "$ECK" plans/p.md review 3 "$EHEAD" APPROVE apex-dispatch:reviewer --agent-id er1 >/dev/null 2>&1) || fail "e2e: checkpoint.sh review refused the hook-written record"
O="$(cd "$EX" && bash "$ECK" plans/p.md review 3 "$EHEAD" APPROVE apex-dispatch:reviewer --agent-id er1 2>&1)" && fail "e2e: a raw record was used twice"
grep -q 'already recorded' <<<"$O" || fail "e2e: the second use was refused for the wrong reason: $O"
O="$(cd "$EX" && bash "$ECK" plans/p.md complete 3 "reviewed" 2>&1)" || fail "e2e: checkpoint.sh complete refused: $O"
[ "$(jget "$EX/.dev-plan-state/ACTIVE/owner.json" stage)" = DONE ] && grep -q '^- \[x\] \*\*Phase 1.1' "$EX/plans/p.md" || fail "e2e: complete did not tick the task and move the stage to DONE"
bash "$LEDGER" evidence --state "$ESD" --line 3 --head "$EHEAD" >/dev/null 2>&1 && bash "$LEDGER" verify --state "$ESD" >/dev/null 2>&1 || fail "e2e: ledger evidence/verify failed after complete"
python3 - "$ESD/dispatch/ledger.jsonl" "$ERID" <<'PY' || fail "e2e: the ledger lacks the hook rows of the flow"
import json, sys
r = [json.loads(l) for l in open(sys.argv[1])]
ev = [(x["event"], x["source"]) for x in r if x.get("route_id") == sys.argv[2]]
for want in [("route", "cli"), ("spawn_request", "hook"), ("spawn", "hook"), ("worker_run", "hook"), ("verdict", "hook")]:
    assert want in ev, (want, ev)
PY
pass "end to end, enforced by default: route (dispatch/) -> pre-agent/subagent-start/stop/post-agent rows -> green-gate PASS = GATE -> reviewer = REVIEW -> raw record -> review --agent-id (once) -> complete with ledger evidence -> DONE"

# 59. review round 1: one second-family rule (available AND a shipped bin/worker-*.sh shim) in doctor and checkpoint;
#     foreground stops recorded by post-agent; audits judge the agent's own identity; canonical lenses;
#     live background builders never spend a stop-gate block; GATE denials say how to return to BUILD;
#     ad-hoc reviewers need a committed, clean HEAD
python3 - "$PLUGIN_ROOT/scripts/lib" "$WORK/sf" <<'PY' || fail "ledger.second_families does not require an available provider with a shipped shim"
import os, sys
sys.path.insert(0, sys.argv[1]); import ledger
root = sys.argv[2]; os.makedirs(os.path.join(root, "bin"), exist_ok=True)
doc = {"claude_p_auth": "available", "providers": {"codex": {"enabled": True, "available": True},
       "claude-p": {"enabled": True, "available": True}, "claude-session": {"enabled": True, "available": True}}}
assert ledger.second_families(doc, root) == [], "counted a provider without a shim"
assert ledger.second_families(doc) == [] or os.path.isdir(os.path.join(ledger.plugin_root(), "bin")), "this plugin ships no shims yet"
for p in ("codex", "claude-p"):
    f = os.path.join(root, "bin", "worker-%s.sh" % p); open(f, "w").write("#!/bin/sh\n"); os.chmod(f, 0o755)
assert ledger.second_families(doc, root) == ["claude-p", "codex"], ledger.second_families(doc, root)
doc["claude_p_auth"] = "unavailable"; doc["providers"]["codex"]["available"] = False
assert ledger.second_families(doc, root) == [], "claude-p without auth or codex unavailable still counted"
PY
grep -q 'second_families' "$PLUGIN_ROOT/scripts/lib/doctor.py" && grep -q 'second_families' "$MARKET_ROOT/plugins/apex-scope-loop/skills/apex-execute/scripts/checkpoint.sh" \
  || fail "doctor.py and checkpoint.sh do not share ledger.second_families"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["tier_c_diversity"].startswith("warn") and d["second_families"] == []' "$WORK/ds/dispatch-shadow/doctor.json" \
  || fail "doctor.json claims a Tier C second family although no worker shim ships"
# Canonical lenses and emphasis
python3 - "$PLUGIN_ROOT/scripts/lib" <<'PY' || fail "LENS/VERDICT parsing is not normalised"
import sys; sys.path.insert(0, sys.argv[1]); import hooks
assert hooks.parse_review("x\n**LENS:** Consent / PII\n**VERDICT:** APPROVE") == ("APPROVE", "consent-pii")
assert hooks.parse_review("LENS: `Security`\nVERDICT: REQUEST_CHANGES.") == ("REQUEST_CHANGES", "security")
assert hooks.parse_review("LENS: vibes\nVERDICT: APPROVE") == ("APPROVE", None)
assert hooks.parse_review("_LENS: Maintainability_\nVERDICT: APPROVE") == ("APPROVE", "maintainability")
PY
start l1 apex-dispatch:reviewer; stopa l1 apex-dispatch:reviewer "$(printf '**LENS:** Consent / PII\n**VERDICT:** APPROVE')"
[ "$(jget "$UD/reviews-raw/l1.json" role)" = lens:consent-pii ] || fail "an emphasised Consent / PII lens did not become lens:consent-pii"
start l2 apex-dispatch:reviewer; stopa l2 apex-dispatch:reviewer "$(printf 'LENS: vibes\nVERDICT: APPROVE')"
[ "$(jget "$UD/reviews-raw/l2.json" role)" = reviewer ] || fail "an unknown lens counted as a lens"
# Audits judge the agent as live pre-bash did
tr_write "$TR/g3.jsonl" Bash '{"command": "git commit -am gibson-at-build"}' 0
start g3 apex-scope-loop:gibson-reviewer; stopa g3 apex-scope-loop:gibson-reviewer 'VERDICT: APPROVE' false "$TR/g3.jsonl"
[ "$HRC" = 0 ] && [ "$(jget "$UD/reviews-raw/g3.json" verdict)" = APPROVE ] || fail "gibson-reviewer's record was refused for a command pre-bash allowed it (rc=$HRC)"
tr_write "$TR/p1.jsonl" Bash "{\"command\": \"bash $PLUGIN_ROOT/bin/worker-codex.sh --route r --role reviewer --mode readonly\"}" 0
start p1 apex-dispatch:provider-runner; stopa p1 apex-dispatch:provider-runner 'done' false "$TR/p1.jsonl"
[ "$HRC" = 0 ] && [ "$(rowsin "$UL" policy_violation agent_id=p1)" = 0 ] || fail "provider-runner running a worker shim was audited as a violation (rc=$HRC)"
# Foreground stops from post-agent; the live-agent denial says how to clear it
O="$(cd "$UX" && bash "$ROUTE" plan plans/p.md --line 3 2>&1)"; URID3="$(val ROUTE_ID "$O")"; git -C "$UX" commit -q --allow-empty -m r3
printf '{"result":"PASS","head_sha":"%s"}\n' "$(git -C "$UX" rev-parse HEAD)" >"$USD_/gate/last.json"
start f1 apex-dispatch:builder; start f2 apex-dispatch:builder
O="$(ua "$(pl agent "$UX" apex-dispatch:reviewer '')")"; grep -q 're-route' <<<"$O" || fail "the live-agent denial does not say how to clear a stuck registration: $O"
pa x1 PostToolUseFailure tool_response.agentId=f1 error=interrupted
pa x2 PostToolUse tool_response.agentId=f2 tool_response.status=interrupted
[ "$(jget "$UD/agents/f1.json" stopped_by)" = post-agent-failure ] && [ "$(jget "$UD/agents/f2.json" stopped_by)" = post-agent ] || fail "post-agent did not record foreground stops"
[ "$(ua "$(pl agent "$UX" apex-dispatch:reviewer '')" | one)" = "{}" ] || fail "review stayed blocked after the foreground builders ended"; ustage BUILD
# Live background builders never spend a block; a dirty worktree with no live builder does
start bg1 apex-dispatch:builder; echo wip >"$UX/src/wip.py"; NB="$(rowsin "$UL" hook_advisory blocked=True)"
sg; [ "$HRC" = 0 ] && [ "$(rowsin "$UL" hook_advisory blocked=True)" = "$NB" ] || fail "stop-gate spent a block on a live background builder (rc=$HRC)"
stopa bg1 apex-dispatch:builder done; sg; [ "$HRC" = 2 ] && grep -q 'uncommitted' "$WORK/hr.err" || fail "stop-gate did not block on a dirty worktree once the builder stopped (rc=$HRC)"
rm -f "$UX/src/wip.py"
# GATE/REVIEW denials name the way back to BUILD
ustage GATE
for c in 'git commit -m fix' 'echo x > src/a.py'; do
  hk2o="$(cd "$UX" && printf '%s' "$(pl bash "$UX" "$c")" | bash "$PLUGIN_ROOT/hooks/pre-bash.sh" 2>/dev/null)"
  grep -q 'route.sh plan / iterate.sh' <<<"$hk2o" || fail "the GATE denial of '$c' does not say how to return to BUILD: $hk2o"
done
grep -q 'route.sh plan / iterate.sh' <<<"$(cd "$UX" && printf '%s' "$(pl edit "$UX" src/a.py)" | bash "$PLUGIN_ROOT/hooks/pre-edit.sh" 2>/dev/null)" \
  || fail "the GATE edit denial does not say how to return to BUILD"
ustage BUILD
# Ad-hoc reviewers: a committed, clean HEAD instead of a gate result
AX="$WORK/ax"; mkdir -p "$AX"; git init -q -b main "$AX"; printf '.dev-plan-state/\n' >"$AX/.gitignore"; echo a >"$AX/a.md"; git -C "$AX" add -A; git -C "$AX" commit -qm ax
O="$(cd "$AX" && bash "$ROUTE" adhoc --tags docs --acceptance 'true' 2>&1)"; [ "$(val ROUTE_STATUS "$O")" = READY ] || fail "ad-hoc fixture route is not READY: $O"
ax() { (cd "$AX" && printf '%s' "$1" | bash "$PLUGIN_ROOT/hooks/pre-agent.sh" 2>/dev/null); }
echo b >>"$AX/a.md"
grep -q 'committed, clean HEAD' <<<"$(ax "$(pl agent "$AX" apex-dispatch:reviewer '')")" || fail "an ad-hoc reviewer spawn on a dirty worktree was allowed"
git -C "$AX" commit -qam b
[ "$(ax "$(pl agent "$AX" apex-dispatch:reviewer '')" | one)" = "{}" ] || fail "an ad-hoc reviewer spawn on a committed, clean HEAD was denied (no gate result exists for ad-hoc routes)"
pass "round 1: second family = available + shipped shim (doctor and checkpoint share it); canonical lenses and emphasised VERDICT; audits judge the agent's own identity; post-agent records foreground stops; stuck registrations explained; live background builders spend no stop-gate block; GATE denials name re-route; ad-hoc reviewers need a clean committed HEAD"

echo ""
echo "smoke passed: $N/$N checks"
