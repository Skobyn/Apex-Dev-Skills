#!/usr/bin/env bash
# apex-legacy-comprehension structural smoke test
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
grep -q "\"apex-legacy-comprehension\"" "$PJ" || fail "plugin.json name is not apex-legacy-comprehension"
ok "plugin.json has name/version/description/author/license/keywords"

# 2. plugin.json does NOT enumerate skills/commands/agents arrays
for forbidden in '"skills"' '"commands"' '"agents"'; do
  if grep -q "$forbidden[[:space:]]*:[[:space:]]*\[" "$PJ"; then
    fail "plugin.json enumerates $forbidden array (must be auto-discovered)"
  fi
done
ok "plugin.json does not enumerate skills/commands/agents"

# 3. characterization-test SKILL.md has valid unquoted kebab-case name
for skill in characterization-test; do
  S="$PLUGIN_ROOT/skills/$skill/SKILL.md"
  [ -f "$S" ] || fail "missing skill: $S"
  name_line=$(awk '/^---$/{c++; next} c==1 && /^name:/{print; exit}' "$S")
  [ -n "$name_line" ] || fail "$skill SKILL.md missing name: frontmatter"
  echo "$name_line" | grep -qE "^name:[[:space:]]+$skill[[:space:]]*$" \
    || fail "$skill SKILL.md name: must be unquoted kebab-case '$skill' (got: $name_line)"
  ok "$skill SKILL.md frontmatter name is valid kebab-case"
done

# 4. No wildcard tools in any SKILL.md
for s in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
  if grep -qE "allowed-tools:.*(\\*|mcp__\\*)" "$s"; then
    fail "$s has wildcard in allowed-tools"
  fi
done
ok "no wildcard tools in skills"

# 5. characterization-test SKILL.md declares an explicit allowed-tools list
for s in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
  grep -qE "^allowed-tools:[[:space:]]*[A-Za-z]" "$s" \
    || fail "$s missing explicit allowed-tools list"
done
ok "skills declare explicit allowed-tools"

# 6. system-map agent present with name + model: sonnet
A="$PLUGIN_ROOT/agents/system-map.md"
[ -f "$A" ] || fail "missing agent: $A"
grep -qE "^name:[[:space:]]+system-map[[:space:]]*$" "$A" || fail "system-map agent missing name: system-map"
grep -qE "^model:[[:space:]]+sonnet[[:space:]]*$" "$A" || fail "system-map agent missing model: sonnet"
ok "system-map agent present with name + model: sonnet"

# 7. system-map command present with valid frontmatter
C="$PLUGIN_ROOT/commands/system-map.md"
[ -f "$C" ] || fail "missing command: $C"
grep -qE "^name:[[:space:]]+system-map[[:space:]]*$" "$C" \
  || fail "system-map command frontmatter missing or invalid name:"
grep -q "^description:" "$C" || fail "system-map command missing description"
ok "system-map command present with valid frontmatter"

# 8. README has required sections
R="$PLUGIN_ROOT/README.md"
[ -f "$R" ] || fail "missing README.md"
for section in "Compatibility" "Namespace coordination" "Verification" "Architecture Decisions"; do
  grep -q "## $section" "$R" || fail "README missing section: $section"
done
grep -q "## What it does" "$R" || fail "README missing 'What it does' section"
ok "README has What-it-does/Compatibility/Namespace/Verification/ADR sections"

# 9. ADR-0001 exists with Status: Proposed
ADR="$PLUGIN_ROOT/docs/adrs/0001-apex-legacy-comprehension-contract.md"
[ -f "$ADR" ] || fail "missing ADR-0001"
grep -qE "^- \*\*Status:\*\* Proposed" "$ADR" || fail "ADR-0001 not in Proposed status"
ok "ADR-0001 exists with Status: Proposed"

# 10. All .sh scripts in skills/ and scripts/ are executable
non_exec=$(find "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/scripts" -name "*.sh" \! -perm -u+x 2>/dev/null || true)
if [ -n "$non_exec" ]; then
  fail "non-executable .sh files found: $non_exec"
fi
ok "all .sh scripts are executable"

echo ""
echo "smoke passed: 10/10 checks"
