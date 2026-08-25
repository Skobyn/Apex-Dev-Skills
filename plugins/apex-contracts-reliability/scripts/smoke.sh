#!/usr/bin/env bash
# apex-contracts-reliability structural smoke test
# Verifies the plugin contract from ADR-0001. Exits non-zero on first failure.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "smoke FAIL: $1" >&2; exit 1; }
ok()   { echo "smoke OK:   $1"; }

CHECKS=0
pass_check() { CHECKS=$((CHECKS + 1)); ok "$1"; }

# 1. plugin.json exists and has required keys
PJ="$PLUGIN_ROOT/.claude-plugin/plugin.json"
[ -f "$PJ" ] || fail "missing $PJ"
for k in name version description author license keywords; do
  grep -q "\"$k\"" "$PJ" || fail "plugin.json missing key: $k"
done
grep -q "\"apex-contracts-reliability\"" "$PJ" || fail "plugin.json name is not apex-contracts-reliability"
pass_check "plugin.json has name/version/description/author/license/keywords"

# 2. plugin.json does NOT enumerate skills/commands/agents arrays
for forbidden in '"skills"' '"commands"' '"agents"'; do
  if grep -qE "$forbidden[[:space:]]*:[[:space:]]*\[" "$PJ"; then
    fail "plugin.json enumerates $forbidden array (must be auto-discovered)"
  fi
done
pass_check "plugin.json does not enumerate skills/commands/agents"

# 3. Each SKILL.md has unquoted kebab-case name: matching its directory
for skill in tool-contract-check flake-guard; do
  S="$PLUGIN_ROOT/skills/$skill/SKILL.md"
  [ -f "$S" ] || fail "missing skill: $S"
  name_line=$(awk '/^---$/{c++; next} c==1 && /^name:/{print; exit}' "$S")
  [ -n "$name_line" ] || fail "$skill SKILL.md missing name: frontmatter"
  echo "$name_line" | grep -qE "^name:[[:space:]]+$skill[[:space:]]*$" \
    || fail "$skill SKILL.md name: must be kebab-case '$skill' (got: $name_line)"
  grep -q "^description:" "$S" || fail "$skill SKILL.md missing description:"
  pass_check "$skill SKILL.md frontmatter is valid kebab-case"
done

# 4. No wildcard tools in any SKILL.md
for s in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
  if grep -qE "allowed-tools:.*(\\*|mcp__\\*)" "$s"; then
    fail "$s has wildcard on allowed-tools: line"
  fi
  if awk '/^allowed-tools:/{f=1;next} f&&/^[^[:space:]-]/{f=0} f' "$s" | grep -qE "(^|[[:space:]])(-[[:space:]]*)?(\*|mcp__\*)[[:space:]]*$"; then
    fail "$s lists a wildcard tool entry"
  fi
done
pass_check "no wildcard tools in skills"

# 5. reliability-report command present with valid frontmatter
C="$PLUGIN_ROOT/commands/reliability-report.md"
[ -f "$C" ] || fail "missing command: $C"
grep -qE "^name:[[:space:]]+reliability-report[[:space:]]*$" "$C" \
  || fail "reliability-report command missing or invalid name:"
grep -q "^description:" "$C" || fail "reliability-report command missing description:"
pass_check "reliability-report command present with valid frontmatter"

# 6. hooks/hooks.json is valid JSON and wires capture-tool-io.sh
HJ="$PLUGIN_ROOT/hooks/hooks.json"
[ -f "$HJ" ] || fail "missing $HJ"
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$HJ" \
    || fail "hooks/hooks.json is not valid JSON"
fi
grep -q "PreToolUse" "$HJ"  || fail "hooks.json missing PreToolUse"
grep -q "PostToolUse" "$HJ" || fail "hooks.json missing PostToolUse"
grep -q "capture-tool-io.sh" "$HJ" || fail "hooks.json does not reference capture-tool-io.sh"
grep -q "CLAUDE_PLUGIN_ROOT" "$HJ"  || fail "hooks.json does not use \${CLAUDE_PLUGIN_ROOT}"
[ -f "$PLUGIN_ROOT/hooks/capture-tool-io.sh" ] || fail "missing hooks/capture-tool-io.sh"
pass_check "hooks/hooks.json valid JSON wiring PreToolUse+PostToolUse capture hook"

# 7. analyze-ledger.sh present
[ -f "$PLUGIN_ROOT/scripts/analyze-ledger.sh" ] || fail "missing scripts/analyze-ledger.sh"
pass_check "scripts/analyze-ledger.sh present"

# 8. README has required sections
R="$PLUGIN_ROOT/README.md"
[ -f "$R" ] || fail "missing README.md"
for section in "Compatibility" "Namespace coordination" "Verification" "Architecture Decisions" "What it does"; do
  grep -q "## $section" "$R" || fail "README missing section: $section"
done
pass_check "README has Compatibility/Namespace/Verification/ADR/What-it-does sections"

# 9. ADR-0001 exists with Status: Proposed and Context/Decision/Consequences
ADR="$PLUGIN_ROOT/docs/adrs/0001-apex-contracts-reliability-contract.md"
[ -f "$ADR" ] || fail "missing ADR-0001"
grep -qE "^- \*\*Status:\*\* Proposed" "$ADR" || fail "ADR-0001 not in Proposed status"
for sect in "## Context" "## Decision" "## Consequences"; do
  grep -q "$sect" "$ADR" || fail "ADR-0001 missing section: $sect"
done
pass_check "ADR-0001 exists with Status: Proposed and Context/Decision/Consequences"

# 10. All .sh files are executable
non_exec=$(find "$PLUGIN_ROOT" -name "*.sh" \! -perm -u+x 2>/dev/null || true)
if [ -n "$non_exec" ]; then
  fail "non-executable .sh files found: $non_exec"
fi
pass_check "all .sh scripts are executable"

echo ""
echo "smoke passed: $CHECKS/$CHECKS checks"
