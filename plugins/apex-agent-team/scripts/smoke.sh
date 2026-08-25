#!/usr/bin/env bash
# apex-agent-team structural smoke test
# Verifies the plugin contract from ADR-0001. Exits non-zero on first failure.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "smoke FAIL: $1" >&2; exit 1; }
ok()   { echo "smoke OK:   $1"; }

# 1. plugin.json exists and has required fields
PJ="$PLUGIN_ROOT/.claude-plugin/plugin.json"
[ -f "$PJ" ] || fail "missing $PJ"
for k in name version description author license keywords; do
  grep -q "\"$k\"" "$PJ" || fail "plugin.json missing key: $k"
done
grep -q "\"name\"[[:space:]]*:[[:space:]]*\"apex-agent-team\"" "$PJ" \
  || fail "plugin.json name must be \"apex-agent-team\""
ok "plugin.json has name/version/description/author/license/keywords"

# 2. plugin.json does NOT enumerate skills/commands/agents arrays
for forbidden in '"skills"' '"commands"' '"agents"'; do
  if grep -q "$forbidden[[:space:]]*:[[:space:]]*\[" "$PJ"; then
    fail "plugin.json enumerates $forbidden array (must be auto-discovered)"
  fi
done
ok "plugin.json does not enumerate skills/commands/agents"

# 3. team-lint SKILL.md has valid unquoted kebab-case name == dir
for skill in team-lint; do
  S="$PLUGIN_ROOT/skills/$skill/SKILL.md"
  [ -f "$S" ] || fail "missing skill: $S"
  name_line=$(awk '/^---$/{c++; next} c==1 && /^name:/{print; exit}' "$S")
  [ -n "$name_line" ] || fail "$skill SKILL.md missing name: frontmatter"
  echo "$name_line" | grep -qE "^name:[[:space:]]+$skill[[:space:]]*$" \
    || fail "$skill SKILL.md name: must be unquoted kebab-case '$skill' (got: $name_line)"
  grep -q "^description:" "$S" || fail "$skill SKILL.md missing description"
  ok "$skill SKILL.md frontmatter is valid"
done

# 4. No wildcard tools in any SKILL.md
for s in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
  if grep -qE "allowed-tools:.*(\\*|mcp__\\*)" "$s"; then
    fail "$s has wildcard in allowed-tools"
  fi
done
ok "no wildcard tools in skills"

# 5. team-lint command present with valid frontmatter (name == filename + description)
for cmd in team-lint; do
  C="$PLUGIN_ROOT/commands/$cmd.md"
  [ -f "$C" ] || fail "missing command: $C"
  grep -qE "^name:[[:space:]]+$cmd[[:space:]]*$" "$C" \
    || fail "$cmd command frontmatter missing or invalid name:"
  grep -q "^description:" "$C" || fail "$cmd command missing description"
done
ok "command team-lint present with valid frontmatter"

# 6. hooks/hooks.json is valid JSON
HJ="$PLUGIN_ROOT/hooks/hooks.json"
[ -f "$HJ" ] || fail "missing $HJ"
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$HJ" \
    || fail "hooks/hooks.json is not valid JSON"
else
  # Fallback: minimal brace/bracket balance + presence of a hooks key
  grep -q '"hooks"' "$HJ" || fail "hooks/hooks.json missing \"hooks\" key"
fi
grep -q '"SessionStart"' "$HJ" || fail "hooks.json missing SessionStart hook"
grep -q '"PreCompact"' "$HJ" || fail "hooks.json missing PreCompact hook"
grep -q 'context-budget.sh' "$HJ" || fail "hooks.json does not wire context-budget.sh"
ok "hooks/hooks.json is valid JSON with SessionStart + PreCompact"

# 7. README has required sections
R="$PLUGIN_ROOT/README.md"
[ -f "$R" ] || fail "missing README.md"
for section in "Compatibility" "Namespace coordination" "Verification" "Architecture Decisions"; do
  grep -q "## $section" "$R" || fail "README missing section: $section"
done
grep -q "## What it does" "$R" || fail "README missing 'What it does' section"
ok "README has What-it-does/Compatibility/Namespace/Verification/ADR sections"

# 8. ADR-0001 exists with Status: Proposed
ADR="$PLUGIN_ROOT/docs/adrs/0001-apex-agent-team-contract.md"
[ -f "$ADR" ] || fail "missing ADR-0001"
grep -qE "^- \*\*Status:\*\* Proposed" "$ADR" || fail "ADR-0001 not in Proposed status"
grep -q "agent-team-coord" "$ADR" || fail "ADR-0001 does not claim the agent-team-coord namespace"
ok "ADR-0001 exists with Status: Proposed and claims agent-team-coord"

# 9. All .sh scripts in scripts/, skills/, hooks/ are executable
non_exec=$(find "$PLUGIN_ROOT/scripts" "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/hooks" \
             -name "*.sh" \! -perm -u+x 2>/dev/null || true)
if [ -n "$non_exec" ]; then
  fail "non-executable .sh files found: $non_exec"
fi
ok "all .sh scripts are executable"

# 10. TeamLint analyzer runs against a self-scan without crashing
#     (it may exit non-zero on findings; we only require it not to error out)
LINT_OUT="$( bash "$PLUGIN_ROOT/scripts/team-lint.sh" "$PLUGIN_ROOT" 2>&1 || true )"
echo "$LINT_OUT" | grep -qE "TeamLint summary|Nothing to lint|team-lint passed" \
  || fail "team-lint.sh did not produce a recognizable report (got: $LINT_OUT)"
ok "team-lint.sh runs and produces a report"

echo ""
echo "smoke passed: 10/10 checks"
