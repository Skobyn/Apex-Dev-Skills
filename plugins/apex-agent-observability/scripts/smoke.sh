#!/usr/bin/env bash
# apex-agent-observability smoke test (EXTENDED — 13 checks)
# Verifies the plugin contract from ADR-0001. Exits non-zero on first failure.
# The two extra checks (11, 12) cover the OPTIONAL MCP server; 13 is the
# trace hook's behaviour on fixture payloads.
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

# 3. Each SKILL.md has unquoted kebab-case name: matching its directory
shopt -s nullglob
skill_count=0
for S in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
  skill_count=$((skill_count + 1))
  dir="$(basename "$(dirname "$S")")"
  name_line=$(awk '/^---$/{c++; next} c==1 && /^name:/{print; exit}' "$S")
  [ -n "$name_line" ] || fail "$dir SKILL.md missing name: frontmatter"
  echo "$name_line" | grep -qE "^name:[[:space:]]+$dir[[:space:]]*$" \
    || fail "$dir SKILL.md name: must be kebab-case '$dir' (got: $name_line)"
done
[ "$skill_count" -ge 3 ] || fail "expected >=3 skills, found $skill_count"
ok "all $skill_count SKILL.md files have valid kebab-case name:"

# 4. No wildcard (*) tools in any SKILL.md allowed-tools
for S in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
  if grep -E "^allowed-tools:" "$S" | grep -qE '(\*)'; then
    fail "$S has wildcard '*' in allowed-tools"
  fi
done
ok "no wildcard '*' in any skill allowed-tools"

# 5. trace-report command present with valid frontmatter
C="$PLUGIN_ROOT/commands/trace-report.md"
[ -f "$C" ] || fail "missing command: $C"
grep -qE "^name:[[:space:]]+trace-report[[:space:]]*$" "$C" \
  || fail "trace-report command missing or invalid name:"
grep -q "^description:" "$C" || fail "trace-report command missing description"
ok "command trace-report present with valid frontmatter"

# 6. hooks/hooks.json exists and is valid JSON
HJ="$PLUGIN_ROOT/hooks/hooks.json"
[ -f "$HJ" ] || fail "missing hooks/hooks.json"
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$HJ" \
  || fail "hooks/hooks.json is not valid JSON"
ok "hooks/hooks.json exists and is valid JSON"

# 7. README has required sections, including MCP (optional)
R="$PLUGIN_ROOT/README.md"
[ -f "$R" ] || fail "missing README.md"
for section in "Compatibility" "Namespace coordination" "Verification" \
               "Architecture Decisions" "MCP (optional)"; do
  grep -q "## $section" "$R" || fail "README missing section: $section"
done
ok "README has Compatibility/Namespace/Verification/ADR/MCP(optional) sections"

# 8. ADR-0001 exists with Status: Proposed
ADR="$PLUGIN_ROOT/docs/adrs/0001-apex-agent-observability-contract.md"
[ -f "$ADR" ] || fail "missing ADR-0001"
grep -qE "^- \*\*Status:\*\* Proposed" "$ADR" || fail "ADR-0001 not in Proposed status"
ok "ADR-0001 exists with Status: Proposed"

# 9. All .sh scripts in the plugin are executable
non_exec=$(find "$PLUGIN_ROOT" -name "*.sh" \! -perm -u+x 2>/dev/null || true)
if [ -n "$non_exec" ]; then
  fail "non-executable .sh files found: $non_exec"
fi
ok "all .sh scripts are executable"

# 10. Expected surfaces present (hooks script, both engines, three skills)
[ -f "$PLUGIN_ROOT/hooks/trace-event.sh" ] || fail "missing hooks/trace-event.sh"
[ -f "$PLUGIN_ROOT/scripts/replay.sh" ]     || fail "missing scripts/replay.sh"
[ -f "$PLUGIN_ROOT/scripts/token-lens.sh" ] || fail "missing scripts/token-lens.sh"
for skill in agent-trace orchestration-replay token-lens; do
  [ -f "$PLUGIN_ROOT/skills/$skill/SKILL.md" ] || fail "missing skill: $skill"
done
ok "expected surfaces present (hooks + replay + token-lens + 3 skills)"

# 11. .mcp.json is valid JSON and its referenced server script exists
MCP="$PLUGIN_ROOT/.mcp.json"
[ -f "$MCP" ] || fail "missing .mcp.json"
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$MCP" \
  || fail ".mcp.json is not valid JSON"
# Resolve the referenced server script (strip ${CLAUDE_PLUGIN_ROOT}/) and confirm it exists.
server_rel=$(python3 - "$MCP" <<'PY'
import json, sys, re
cfg = json.load(open(sys.argv[1]))
servers = cfg.get("mcpServers", {})
for name, s in servers.items():
    for a in s.get("args", []):
        if a.endswith(".py"):
            print(re.sub(r"\$\{CLAUDE_PLUGIN_ROOT\}/?", "", a))
            sys.exit(0)
sys.exit(1)
PY
) || fail ".mcp.json declares no python server script"
[ -f "$PLUGIN_ROOT/$server_rel" ] || fail "MCP server script not found: $server_rel"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" \
  "$PLUGIN_ROOT/$server_rel" || fail "MCP server script is not valid python3"
ok ".mcp.json valid JSON; server script exists and parses ($server_rel)"

# 12. No SKILL.md allowed-tools contains mcp__* (MCP is optional/environmental)
for S in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
  if grep -E "^allowed-tools:" "$S" | grep -q "mcp__"; then
    fail "$S lists an mcp__ tool in allowed-tools (MCP server is optional)"
  fi
done
ok "no SKILL.md allowed-tools contains mcp__*"

# 13. trace-event.sh: the file is keyed on the payload's session_id (not the
#     never-exported CLAUDE_SESSION_ID), then APEX_TRACE_SESSION, then "local";
#     the key is filename-safe; records carry agent_type and agent_transcript_path;
#     the hook is observational (exit 0, nothing on stdout).
SMOKE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/apex-obs-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_TMP"' EXIT
TE="$PLUGIN_ROOT/hooks/trace-event.sh"
TD="$SMOKE_TMP/traces"
printf '{"session_id":"sess-abc","hook_event_name":"SubagentStop","agent_id":"ag-1","agent_type":"apex-dispatch:builder","agent_transcript_path":"/tmp/t/ag-1.jsonl"}' >"$SMOKE_TMP/stop.json"
printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' >"$SMOKE_TMP/nosession.json"
printf '{"session_id":"../../evil/x","hook_event_name":"PreToolUse","tool_name":"Read"}' >"$SMOKE_TMP/badsession.json"
out="$(CLAUDE_SESSION_ID=wrong APEX_TRACE_DIR="$TD" bash "$TE" SubagentStop <"$SMOKE_TMP/stop.json")" \
  || fail "trace-event.sh exited non-zero"
[ -z "$out" ] || fail "trace-event.sh printed to stdout (observational hooks print nothing): $out"
[ -f "$TD/run-sess-abc.jsonl" ] || fail "trace not keyed on payload session_id (files: $(ls "$TD" 2>/dev/null | tr '\n' ' '))"
[ ! -e "$TD/run-wrong.jsonl" ] || fail "trace keyed on CLAUDE_SESSION_ID instead of the payload"
python3 - "$TD/run-sess-abc.jsonl" <<'PY' || fail "SubagentStop record lacks agent_type / agent_transcript_path / session"
import json, sys
r = json.loads(open(sys.argv[1]).read().splitlines()[-1])
assert r["session"] == "sess-abc" and r["subagent_id"] == "ag-1", r
assert r["agent_type"] == "apex-dispatch:builder" and r["agent_transcript_path"] == "/tmp/t/ag-1.jsonl", r
PY
APEX_TRACE_SESSION=fallback-1 APEX_TRACE_DIR="$TD" bash "$TE" PreToolUse <"$SMOKE_TMP/nosession.json" >/dev/null
[ -f "$TD/run-fallback-1.jsonl" ] || fail "no session_id in the payload did not fall back to APEX_TRACE_SESSION"
( unset APEX_TRACE_SESSION; APEX_TRACE_DIR="$TD" bash "$TE" PreToolUse <"$SMOKE_TMP/nosession.json" >/dev/null )
[ -f "$TD/run-local.jsonl" ] || fail "no session_id and no APEX_TRACE_SESSION did not fall back to run-local.jsonl"
APEX_TRACE_DIR="$TD" bash "$TE" PreToolUse <"$SMOKE_TMP/badsession.json" >/dev/null
[ -z "$(find "$SMOKE_TMP" -path "$TD" -prune -o -name '*.jsonl' -print)" ] && [ "$(find "$TD" -type f | wc -l | tr -d ' ')" = 4 ] \
  || fail "a session_id with path characters escaped the trace dir or was not sanitised: $(find "$SMOKE_TMP" -type f)"
ok "trace file keyed on payload session_id > APEX_TRACE_SESSION > local (filename-safe); agent_type + agent_transcript_path recorded; no stdout"

echo ""
echo "smoke passed: 13/13 checks"
