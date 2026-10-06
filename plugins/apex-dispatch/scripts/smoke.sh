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
expect_reject "bad model alias" '{"tiers":[{"id":"cheap","model":"gpt-4"}]}' 'is not one of'
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

echo ""
echo "smoke passed: $N/$N checks"
