#!/usr/bin/env bash
# apex-rag-memory structural smoke test (EXTENDED 12-check; optional-MCP plugin).
# Verifies the plugin contract from ADR-0001. Exits non-zero on first failure.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "smoke FAIL: $1" >&2; exit 1; }
ok()   { echo "smoke OK:   $1"; }

# 1. plugin.json exists with required keys
PJ="$PLUGIN_ROOT/.claude-plugin/plugin.json"
[ -f "$PJ" ] || fail "missing $PJ"
for k in name version description author license keywords; do
  grep -q "\"$k\"" "$PJ" || fail "plugin.json missing key: $k"
done
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$PJ" \
  || fail "plugin.json is not valid JSON"
ok "plugin.json valid with name/version/description/author/license/keywords"

# 2. plugin.json does NOT enumerate skills/commands/agents arrays
for forbidden in '"skills"' '"commands"' '"agents"'; do
  if grep -qE "$forbidden[[:space:]]*:[[:space:]]*\[" "$PJ"; then
    fail "plugin.json enumerates $forbidden array (must be auto-discovered)"
  fi
done
ok "plugin.json does not enumerate skills/commands/agents"

# 3. Each SKILL.md has unquoted kebab-case name: matching its directory
shopt -s nullglob
SKILLS_FOUND=0
for S in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
  SKILLS_FOUND=$((SKILLS_FOUND+1))
  dir="$(basename "$(dirname "$S")")"
  name_line=$(awk '/^---$/{c++; next} c==1 && /^name:/{print; exit}' "$S")
  [ -n "$name_line" ] || fail "$dir SKILL.md missing name: frontmatter"
  echo "$name_line" | grep -qE "^name:[[:space:]]+$dir[[:space:]]*$" \
    || fail "$dir SKILL.md name: must be unquoted kebab-case '$dir' (got: $name_line)"
done
[ "$SKILLS_FOUND" -ge 2 ] || fail "expected >=2 skills, found $SKILLS_FOUND"
ok "all $SKILLS_FOUND SKILL.md have valid kebab-case name:"

# 4. No wildcard tools in any SKILL.md allowed-tools
for S in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
  if grep -qE "^allowed-tools:.*(\*|mcp__\*)" "$S"; then
    fail "$S has wildcard in allowed-tools"
  fi
done
ok "no wildcard tools in skills"

# 5. Each command has name: + description: frontmatter
CMDS_FOUND=0
for C in "$PLUGIN_ROOT"/commands/*.md; do
  CMDS_FOUND=$((CMDS_FOUND+1))
  cmd="$(basename "$C" .md)"
  grep -qE "^name:[[:space:]]+$cmd[[:space:]]*$" "$C" \
    || fail "$cmd command frontmatter missing or invalid name:"
  grep -q "^description:" "$C" || fail "$cmd command missing description"
done
[ "$CMDS_FOUND" -ge 1 ] || fail "expected >=1 command, found $CMDS_FOUND"
ok "$CMDS_FOUND command(s) present with valid frontmatter"

# 6. README has required sections (incl. MCP optional)
R="$PLUGIN_ROOT/README.md"
[ -f "$R" ] || fail "missing README.md"
for section in "Compatibility" "Namespace coordination" "Verification" "Architecture Decisions" "MCP (optional)"; do
  grep -q "## $section" "$R" || fail "README missing section: $section"
done
grep -q "## What it does" "$R" || fail "README missing 'What it does' section"
ok "README has Compatibility/Namespace/Verification/ADR/MCP(optional) sections"

# 7. ADR-0001 exists with Status: Proposed
ADR="$PLUGIN_ROOT/docs/adrs/0001-apex-rag-memory-contract.md"
[ -f "$ADR" ] || fail "missing ADR-0001"
grep -qE "^- \*\*Status:\*\* Proposed" "$ADR" || fail "ADR-0001 not in Proposed status"
ok "ADR-0001 exists with Status: Proposed"

# 8. All .sh scripts in the plugin are executable
non_exec=$(find "$PLUGIN_ROOT" -name "*.sh" \! -perm -u+x 2>/dev/null || true)
if [ -n "$non_exec" ]; then
  fail "non-executable .sh files found: $non_exec"
fi
ok "all .sh scripts are executable"

# 9. If a hooks/ dir exists, its hooks.json must be valid JSON (no hooks => skip)
if [ -d "$PLUGIN_ROOT/hooks" ]; then
  HJ="$PLUGIN_ROOT/hooks/hooks.json"
  [ -f "$HJ" ] || fail "hooks/ dir exists but hooks.json missing"
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$HJ" \
    || fail "hooks.json is not valid JSON"
  ok "hooks.json valid"
else
  ok "no hooks/ dir (hooks check skipped)"
fi

# 10. Core eval/audit scripts present
for sc in scripts/build-golden.sh scripts/measure-recall.sh skills/memory-doctor/scripts/audit.sh; do
  [ -f "$PLUGIN_ROOT/$sc" ] || fail "missing required script: $sc"
done
ok "build-golden.sh + measure-recall.sh + audit.sh present"

# 11. .mcp.json valid JSON and referenced server script exists
MCP="$PLUGIN_ROOT/.mcp.json"
[ -f "$MCP" ] || fail "missing .mcp.json"
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$MCP" \
  || fail ".mcp.json is not valid JSON"
# Resolve the referenced server script (strip ${CLAUDE_PLUGIN_ROOT}/ prefix)
SERVER_REF=$(python3 - "$MCP" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
srv = cfg["mcpServers"]
assert len(srv) == 1, "exactly one MCP server expected"
name = next(iter(srv))
s = srv[name]
assert s["command"] == "python3", "MCP command must be python3"
arg = s["args"][0]
print(arg.replace("${CLAUDE_PLUGIN_ROOT}/", "").replace("${CLAUDE_PLUGIN_ROOT}", ""))
PY
) || fail ".mcp.json must declare exactly one python3 server"
[ -f "$PLUGIN_ROOT/$SERVER_REF" ] || fail ".mcp.json references missing server script: $SERVER_REF"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$PLUGIN_ROOT/$SERVER_REF" \
  || fail "MCP server script is not valid python3: $SERVER_REF"
ok ".mcp.json valid; python3 server $SERVER_REF exists and parses"

# 12. No SKILL.md allowed-tools lists an mcp__ tool (MCP is environmental/optional)
for S in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
  if grep -E "^allowed-tools:" "$S" | grep -q "mcp__"; then
    fail "$S lists mcp__ tool in allowed-tools (MCP must stay optional)"
  fi
done
ok "no SKILL.md lists mcp__ tools in allowed-tools"

echo ""
echo "smoke passed: 12/12 checks"
