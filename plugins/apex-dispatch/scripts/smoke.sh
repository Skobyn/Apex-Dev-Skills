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
HEAD_FX="$(git -C "$FX" rev-parse HEAD)"

# 32. append validates against the event schema and stamps the chain fields
LS="$WORK/ls"; mkdir -p "$LS"
RX="r-0123456789ab-L5-1"
lg append route '{"route_id":"'"$RX"'","status":"READY","origin":"plan","router":{"class":"docs","tier":"cheap","provider":"claude-session"},"line":5}' --state "$LS" --source cli --route-mode table >/dev/null || fail "a valid route row was refused"
lg append spawn_request '{"role":"builder","model":"haiku"}' --state "$LS" --source hook --route-id "$RX" >/dev/null || fail "a valid spawn_request row was refused"
lg append worker_run '{"provider":"codex","role":"builder","exit_code":0,"usage":{"input":1000,"output":100}}' --state "$LS" --source shim --route-id "$RX" >/dev/null || fail "a valid worker_run row was refused"
lg append spawn '{"agent_id":"ag-1","role":"builder","usage":{"input":1000000},"resolved_model":"claude-sonnet-5-5"}' --state "$LS" --source hook --route-id "$RX" >/dev/null || fail "a valid spawn row was refused"
lg append verdict '{"role":"reviewer","verdict":"APPROVE"}' --state "$LS" --source hook --route-id "$RX" >/dev/null || fail "a valid verdict row was refused"
lg append escalate '{"prior_route_id":"'"$RX"'","failures":1,"rung":"effort-up","action":"effort_up"}' --state "$LS" --source cli >/dev/null || fail "a valid escalate row was refused"
for bad in "bogus|{}|hook|unknown event" "verdict|{\"role\":\"reviewer\",\"verdict\":\"LGTM\"}|hook|is not one of" \
           "worker_run|{\"provider\":\"codex\",\"role\":\"builder\"}|shim|missing required field exit_code" \
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
pass "ledger append: schema-validated (event, enums, required fields, source, no caller-supplied hash); rows stamped and chained"

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
pass "verify: fails tampered, rehashed, deleted, reordered, truncated and torn ledgers naming the first bad row; append refuses a torn tail"

# 34. route.sh plan (not --dry-run) appended verifiable route rows; evidence semantics (spec §5.3 G)
lg verify --state "$SD" >/dev/null || fail "the fixture plan's ledger (route + escalate rows from route.sh) does not verify: $(lg verify --state "$SD")"
python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; ev=[x["event"] for x in r]; assert ev.count("route")>=2 and ev.count("escalate")==3, ev; assert all(x["source"]=="cli" for x in r); assert r[0]["route_mode"]=="table" and r[0]["head_sha"]==sys.argv[2], r[0]' \
  "$SD/dispatch-shadow/ledger.jsonl" "$HEAD_FX" || fail "route.sh/escalate rows are not stamped as expected"
if lg evidence --state "$SD" --line "$L_A" --head "$HEAD_FX" >"$WORK/e.out"; then fail "evidence passed with a route row but no spawn row"; fi
grep -q 'no spawn_request/spawn/worker_run row' "$WORK/e.out" || fail "evidence without spawns: $(cat "$WORK/e.out")"
lg append spawn_request '{"role":"builder","model":"sonnet"}' --state "$SD" --source hook --route-id "r-000000000000-L${L_A}-1" >/dev/null
if lg evidence --state "$SD" --line "$L_A" --head "$HEAD_FX" >/dev/null; then fail "evidence accepted a spawn row for another route"; fi
lg append spawn_request '{"role":"builder","model":"sonnet"}' --state "$SD" --source hook --route-id "$RID" >/dev/null
lg evidence --state "$SD" --line "$L_A" --head "$HEAD_FX" | grep -q '^ledger evidence: OK' || fail "evidence refused route + spawn rows at HEAD: $(lg evidence --state "$SD" --line "$L_A" --head "$HEAD_FX")"
if lg evidence --state "$SD" --line "$L_B" --head "$HEAD_FX" >"$WORK/e.out"; then fail "evidence passed for a line with no route row"; fi
grep -q "no READY route row for plan line $L_B" "$WORK/e.out" || fail "evidence for an unrouted line: $(cat "$WORK/e.out")"
git -C "$FX" commit -q --allow-empty -m next; HEAD2="$(git -C "$FX" rev-parse HEAD)"
lg evidence --state "$SD" --line "$L_A" --head "$HEAD2" >/dev/null || fail "evidence refused a HEAD that descends from the route's head"
git -C "$FX" checkout -q --orphan side; git -C "$FX" commit -q --allow-empty -m side; HSIDE="$(git -C "$FX" rev-parse HEAD)"; git -C "$FX" checkout -q main
if lg evidence --state "$SD" --line "$L_A" --head "$HSIDE" >"$WORK/e.out"; then fail "evidence passed for a HEAD whose history lacks the route's head"; fi
grep -q "on HEAD's history" "$WORK/e.out" || fail "evidence off-history: $(cat "$WORK/e.out")"
rm -rf "$WORK/lt"; cp -R "$SD" "$WORK/lt"; sed -i.bak '1s/"table"/"decision"/' "$WORK/lt/dispatch-shadow/ledger.jsonl"
if lg evidence --state "$WORK/lt" --line "$L_A" --head "$HEAD_FX" >"$WORK/e.out"; then fail "evidence passed on a tampered chain"; fi
grep -q 'chain does not verify' "$WORK/e.out" || fail "evidence on a tampered chain: $(cat "$WORK/e.out")"
[ "$(lg evidence --state "$SD" --line x --head "$HEAD_FX" >/dev/null; echo $?)" = 2 ] || fail "evidence --line x was not a usage error"
grep -qF 'at least one `spawn_request`, `spawn` or `worker_run` row carries' "$PLUGIN_ROOT/README.md" || fail "README does not define ledger evidence"
pass "route.sh appends verifiable route/escalate rows; evidence = chain + READY route for the line on HEAD's history + a spawn/worker row for that route"

# 35. enforcement switch (transitional): <state>/dispatch/ only with APEX_DISPATCH_ENFORCE=1 or hooks/subagent-stop.sh;
#     escalate --state; iterate.sh fails closed on BUSY; tier-c-floor tags
[ ! -e "$SD/dispatch" ] && [ -d "$SD/dispatch-shadow" ] || fail "route.sh created <state>/dispatch/ without enforcement"
rm -rf "$FX/.dev-plan-state/ACTIVE"
O="$(APEX_DISPATCH_ENFORCE=1 rt adhoc --tags docs --acceptance 'npm test')"
case "$(val ROUTE_FILE "$O")" in "$FX"/.dev-plan-state/adhoc/*/dispatch/active-route.json) ;; *) fail "APEX_DISPATCH_ENFORCE=1 did not write <state>/dispatch/: $O";; esac
[ "$(val ROUTE_ENFORCED "$O")" = yes ] || fail "ROUTE_ENFORCED is not yes under APEX_DISPATCH_ENFORCE=1"
lg verify --state "$(dirname "$(dirname "$(val ROUTE_FILE "$O")")")" >/dev/null || fail "the enforced ad-hoc ledger does not verify"
rm -rf "$FX/.dev-plan-state/ACTIVE"
rm -rf "$WORK/copy3"; mkdir -p "$WORK/copy3/hooks"; touch "$WORK/copy3/hooks/subagent-stop.sh"
python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import ledger; assert ledger.enforcing(sys.argv[2]) and not ledger.enforcing(sys.argv[3])' \
  "$PLUGIN_ROOT/scripts/lib" "$WORK/copy3" "$WORK" || fail "enforcing() does not follow hooks/subagent-stop.sh"
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
pass "enforcement switch: dispatch-shadow/ unless APEX_DISPATCH_ENFORCE=1 or hooks/subagent-stop.sh; escalate --state; iterate BUSY arm; [auth] → tier-c-floor"

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

echo ""
echo "smoke passed: $N/$N checks"
