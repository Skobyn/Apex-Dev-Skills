#!/usr/bin/env bash
# smoke-skeleton.sh — REFERENCE skeleton for a marketplace plugin's structural
# smoke test (Phase 1.2 of the novel-plugins-suite plan). This is a TEMPLATE,
# not a live test: copy into plugins/<name>/scripts/smoke.sh and specialize the
# SKILLS/COMMANDS/AGENTS lists and the MCP block to the plugin's actual surface.
#
# Two variants:
#   * Pure plugin      -> 10 core checks (omit checks 11-12)
#   * MCP-bearing plugin -> 12 checks   (keep checks 11-12)
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "smoke FAIL: $1" >&2; exit 1; }
ok()   { echo "smoke OK:   $1"; }

# --- specialize these for the plugin ---------------------------------------
SKILLS=()        # e.g. (guardrail) or (agent-trace orchestration-replay token-lens)
COMMANDS=()      # e.g. (guardrails-policy)
AGENTS=()        # e.g. (system-map)  — each must declare model:
HAS_HOOKS=0      # 1 if hooks/hooks.json is shipped
IS_MCP=0         # 1 to enable checks 11-12 (.mcp.json + no mcp__* in allowed-tools)
# ---------------------------------------------------------------------------

# 1. plugin.json required keys
PJ="$PLUGIN_ROOT/.claude-plugin/plugin.json"
[ -f "$PJ" ] || fail "missing $PJ"
for k in name version description author license keywords; do
  grep -q "\"$k\"" "$PJ" || fail "plugin.json missing key: $k"
done
ok "plugin.json has required keys"

# 2. plugin.json does NOT enumerate surface arrays
for forbidden in '"skills"' '"commands"' '"agents"'; do
  grep -qE "$forbidden[[:space:]]*:[[:space:]]*\[" "$PJ" \
    && fail "plugin.json enumerates $forbidden array (must be auto-discovered)"
done
ok "plugin.json does not enumerate skills/commands/agents"

# 3. each SKILL.md has unquoted kebab-case name matching its dir
for s in "${SKILLS[@]}"; do
  S="$PLUGIN_ROOT/skills/$s/SKILL.md"
  [ -f "$S" ] || fail "missing skill: $S"
  nl=$(awk '/^---$/{c++; next} c==1 && /^name:/{print; exit}' "$S")
  echo "$nl" | grep -qE "^name:[[:space:]]+$s[[:space:]]*$" \
    || fail "$s SKILL.md name: must be kebab '$s' (got: $nl)"
done
ok "all SKILL.md frontmatter names valid"

# 4. no wildcard tools in any skill
for S in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
  [ -e "$S" ] || continue
  grep -qE "allowed-tools:.*(\\*|mcp__\\*)" "$S" && fail "$S has wildcard allowed-tools"
done
ok "no wildcard tools in skills"

# 5. each command has valid frontmatter
for c in "${COMMANDS[@]}"; do
  C="$PLUGIN_ROOT/commands/$c.md"
  [ -f "$C" ] || fail "missing command: $C"
  grep -qE "^name:[[:space:]]+$c[[:space:]]*$" "$C" || fail "$c command bad name:"
  grep -q "^description:" "$C" || fail "$c command missing description"
done
ok "commands valid"

# 6. each agent has name + model
for a in "${AGENTS[@]}"; do
  A="$PLUGIN_ROOT/agents/$a.md"
  [ -f "$A" ] || fail "missing agent: $A"
  grep -qE "^name:[[:space:]]+$a[[:space:]]*$" "$A" || fail "$a agent bad name:"
  grep -qE "^model:[[:space:]]+" "$A" || fail "$a agent missing model:"
done
ok "agents valid"

# 7. hooks.json valid JSON (if shipped)
if [ "$HAS_HOOKS" = "1" ]; then
  H="$PLUGIN_ROOT/hooks/hooks.json"
  [ -f "$H" ] || fail "HAS_HOOKS=1 but missing $H"
  python3 -c "import json,sys;json.load(open('$H'))" || fail "hooks.json is not valid JSON"
  ok "hooks/hooks.json valid"
fi

# 8. README required sections
R="$PLUGIN_ROOT/README.md"
[ -f "$R" ] || fail "missing README.md"
for sec in "Compatibility" "Namespace coordination" "Verification" "Architecture Decisions"; do
  grep -q "## $sec" "$R" || fail "README missing section: $sec"
done
[ "$IS_MCP" = "1" ] && { grep -q "## MCP (optional)" "$R" || fail "MCP plugin README missing '## MCP (optional)'"; }
ok "README has required sections"

# 9. ADR-0001 Status: Proposed
ADR=$(ls "$PLUGIN_ROOT"/docs/adrs/0001-*.md 2>/dev/null | head -1 || true)
[ -n "$ADR" ] || fail "missing docs/adrs/0001-*.md"
grep -qE "^- \*\*Status:\*\* Proposed" "$ADR" || fail "ADR-0001 not Status: Proposed"
ok "ADR-0001 Status: Proposed"

# 10. all .sh executable
ne=$(find "$PLUGIN_ROOT" -name "*.sh" \! -perm -u+x 2>/dev/null || true)
[ -z "$ne" ] || fail "non-executable .sh files: $ne"
ok "all .sh executable"

# 11-12. MCP-only checks
if [ "$IS_MCP" = "1" ]; then
  MCP="$PLUGIN_ROOT/.mcp.json"
  [ -f "$MCP" ] || fail "IS_MCP=1 but missing .mcp.json"
  python3 - "$MCP" "$PLUGIN_ROOT" <<'PY' || fail ".mcp.json invalid or server script missing"
import json, os, sys
mcp_path, root = sys.argv[1], sys.argv[2]
cfg = json.load(open(mcp_path))
servers = cfg.get("mcpServers") or cfg.get("servers") or {}
if not servers: sys.exit("no servers declared in .mcp.json")
found = False
for s in servers.values():
    for a in s.get("args", []):
        p = a.replace("${CLAUDE_PLUGIN_ROOT}", root)
        if p.endswith(".py") and os.path.exists(p): found = True
if not found: sys.exit("no existing server script referenced in .mcp.json args")
PY
  ok ".mcp.json valid + server script exists"
  for S in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
    [ -e "$S" ] || continue
    grep -qE "allowed-tools:.*mcp__" "$S" && fail "$S lists mcp__ tool (MCP is environmental)"
  done
  ok "no mcp__ tools in allowed-tools"
fi

N=$([ "$IS_MCP" = "1" ] && echo 12 || echo 10)
echo ""
echo "smoke passed: $N/$N checks"
