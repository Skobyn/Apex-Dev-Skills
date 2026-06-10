#!/usr/bin/env bash
# apex-scope-loop structural smoke test
# Verifies the plugin contract from ADR-0001. Exits non-zero on first failure.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "smoke FAIL: $1" >&2; exit 1; }
ok()   { echo "smoke OK:   $1"; }

# 1. plugin.json exists and has required fields
PJ="$PLUGIN_ROOT/.claude-plugin/plugin.json"
[ -f "$PJ" ] || fail "missing $PJ"
for k in name version description author keywords; do
  grep -q "\"$k\"" "$PJ" || fail "plugin.json missing key: $k"
done
ok "plugin.json has name/version/description/author/keywords"

# 2. plugin.json does NOT enumerate skills/commands/agents arrays
for forbidden in '"skills"' '"commands"' '"agents"'; do
  if grep -q "$forbidden[[:space:]]*:[[:space:]]*\[" "$PJ"; then
    fail "plugin.json enumerates $forbidden array (must be auto-discovered)"
  fi
done
ok "plugin.json does not enumerate skills/commands/agents"

# 3 & 4. Both SKILL.md files have valid kebab-case name
for skill in apex-plan apex-execute; do
  S="$PLUGIN_ROOT/skills/$skill/SKILL.md"
  [ -f "$S" ] || fail "missing skill: $S"
  # Extract name: line from frontmatter (must be unquoted kebab-case)
  name_line=$(awk '/^---$/{c++; next} c==1 && /^name:/{print; exit}' "$S")
  [ -n "$name_line" ] || fail "$skill SKILL.md missing name: frontmatter"
  echo "$name_line" | grep -qE "^name:[[:space:]]+$skill[[:space:]]*$" \
    || fail "$skill SKILL.md name: must be kebab-case '$skill' (got: $name_line)"
  ok "$skill SKILL.md frontmatter is valid"
done

# 5. No wildcard tools in any SKILL.md
for s in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
  if grep -qE "allowed-tools:.*(\\*|mcp__\\*)" "$s"; then
    fail "$s has wildcard in allowed-tools"
  fi
done
ok "no wildcard tools in skills"

# 6. Both commands present with valid frontmatter
for cmd in start iterate; do
  C="$PLUGIN_ROOT/commands/$cmd.md"
  [ -f "$C" ] || fail "missing command: $C"
  grep -qE "^name:[[:space:]]+$cmd[[:space:]]*$" "$C" \
    || fail "$cmd command frontmatter missing or invalid name:"
  grep -q "^description:" "$C" || fail "$cmd command missing description"
done
ok "commands start + iterate present with valid frontmatter"

# 7. plan-author agent present with model: sonnet
A="$PLUGIN_ROOT/agents/plan-author.md"
[ -f "$A" ] || fail "missing agent: $A"
grep -qE "^name:[[:space:]]+plan-author[[:space:]]*$" "$A" || fail "plan-author missing name"
grep -qE "^model:[[:space:]]+sonnet[[:space:]]*$" "$A" || fail "plan-author missing model: sonnet"
ok "plan-author agent present with model: sonnet"

# 8. README has required sections
R="$PLUGIN_ROOT/README.md"
[ -f "$R" ] || fail "missing README.md"
for section in "Compatibility" "Namespace coordination" "Verification" "Architecture Decisions"; do
  grep -q "## $section" "$R" || fail "README missing section: $section"
done
ok "README has Compatibility/Namespace/Verification/ADR sections"

# 9. ADR-0001 exists with Status: Proposed
ADR="$PLUGIN_ROOT/docs/adrs/0001-apex-scope-loop-contract.md"
[ -f "$ADR" ] || fail "missing ADR-0001"
grep -qE "^- \*\*Status:\*\* Proposed" "$ADR" || fail "ADR-0001 not in Proposed status"
ok "ADR-0001 exists with Status: Proposed"

# 10. All .sh scripts in skills/ and scripts/ are executable
non_exec=$(find "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/scripts" -name "*.sh" \! -perm -u+x 2>/dev/null || true)
if [ -n "$non_exec" ]; then
  fail "non-executable .sh files found: $non_exec"
fi
ok "all .sh scripts are executable"

# 11. Tier routing (ADR-0002): three phase-worker agents exist with parseable frontmatter
for worker in phase-worker-light phase-worker-standard phase-worker-heavy; do
  W="$PLUGIN_ROOT/agents/$worker.md"
  [ -f "$W" ] || fail "missing tier agent: $W"
  name_line=$(awk '/^---$/{c++; next} c==1 && /^name:/{print; exit}' "$W")
  echo "$name_line" | grep -qE "^name:[[:space:]]+$worker[[:space:]]*$" \
    || fail "$worker frontmatter name: must be '$worker' (got: $name_line)"
  awk '/^---$/{c++; next} c==1 && /^model:/{found=1} END{exit !found}' "$W" \
    || fail "$worker frontmatter missing model: binding"
done
ok "three phase-worker tier agents present with valid frontmatter"

# 12. Every Phase task in the plan template + sample plan names one of the three tiers
for plan in "$PLUGIN_ROOT/skills/apex-plan/resources/templates/plan-template.md" \
            "$PLUGIN_ROOT/skills/apex-execute/resources/examples/sample-plan.md"; do
  [ -f "$plan" ] || fail "missing plan file: $plan"
  awk '
    /^- \[[ x]\] \*\*Phase / { if (pending) { print pending; bad=1 }; pending=FILENAME ": " $0; next }
    /^- \[[ x]\]/            { if (pending) { print pending; bad=1 }; pending=""; next }
    /- Tier: phase-worker-(light|standard|heavy)$/ { pending="" }
    END { if (pending) { print pending; bad=1 }; exit bad }
  ' "$plan" || fail "phase task without a valid Tier: line (printed above)"
done
ok "every Phase task in plan template + sample plan carries a valid tier"

# 13. No plugin script sets CLAUDE_CODE_SUBAGENT_MODEL (it would flatten tier routing)
if grep -RnE 'CLAUDE_CODE_SUBAGENT_MODEL[=]' "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/scripts" --include="*.sh" 2>/dev/null; then
  fail "a script assigns CLAUDE_CODE_SUBAGENT_MODEL (flattens tier routing — ADR-0002)"
fi
ok "no script sets CLAUDE_CODE_SUBAGENT_MODEL"

echo ""
echo "smoke passed: 13/13 checks"
