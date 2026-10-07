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

SMOKE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/apex-cr-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_TMP"' EXIT
printf '{"session_id":"s-1","hook_event_name":"PreToolUse","tool_name":"Read","tool_use_id":"toolu_01ABC","tool_input":{"file_path":"/tmp/x"}}' >"$SMOKE_TMP/pre.json"
printf '{"session_id":"s-1","hook_event_name":"PostToolUse","tool_name":"Read","tool_use_id":"toolu_01ABC","tool_input":{"file_path":"/tmp/x"},"tool_response":{"content":"hi"}}' >"$SMOKE_TMP/post.json"

# 11. capture-tool-io.sh is observational: exit 0, NOTHING on stdout (no
#     permissionDecision at all), and each record carries tool_use_id
CAP="$PLUGIN_ROOT/hooks/capture-tool-io.sh"
for ph in pre post; do
  out="$(APEX_CR_LEDGER_DIR="$SMOKE_TMP/ledger" bash "$CAP" <"$SMOKE_TMP/$ph.json")" || fail "capture-tool-io.sh exited non-zero on a $ph event"
  [ -z "$out" ] || fail "capture-tool-io.sh printed output on a $ph event (observational hooks print nothing): $out"
done
out="$(printf 'not json' | APEX_CR_LEDGER_DIR="$SMOKE_TMP/ledger" bash "$CAP")" || fail "capture-tool-io.sh exited non-zero on garbage input"
[ -z "$out" ] || fail "capture-tool-io.sh printed output on garbage input: $out"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$SMOKE_TMP/ledger/ledger.jsonl" <<'PY' || fail "ledger records lack tool_use_id or the Pre/Post phases"
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
recs = [r for r in recs if isinstance(r, dict) and r.get("tool") == "Read"]
assert [r["phase"] for r in recs] == ["PreToolUse", "PostToolUse"], recs
assert all(r.get("tool_use_id") == "toolu_01ABC" for r in recs), recs
PY
fi
pass_check "capture-tool-io.sh is observational (exit 0, no stdout, no decision) and records tool_use_id"

# 12. Marketplace-wide: no hook outside apex-guardrails / apex-dispatch emits a
#     permissionDecision "allow". Observational hooks exit 0 with no JSON; only
#     the two enforcement plugins decide. (a) static: no such literal in any
#     non-doc file of another plugin; (b) runtime: every bash hook command those
#     plugins register prints no allow for Pre/PostToolUse fixtures.
PLUGINS_DIR="$(cd "$PLUGIN_ROOT/.." && pwd)"
ALLOW_RE='permissionDecision["'"'"'\\]*[[:space:]]*:[[:space:]]*["'"'"'\\]*allow'
hits=""
for d in "$PLUGINS_DIR"/*/; do
  name="$(basename "$d")"
  case "$name" in apex-guardrails|apex-dispatch) continue ;; esac
  h="$(grep -rlE "$ALLOW_RE" "$d" --exclude='*.md' 2>/dev/null || true)"
  [ -z "$h" ] || hits="$hits $h"
done
[ -z "$hits" ] || fail "a hook outside apex-guardrails/apex-dispatch emits permissionDecision allow:$hits"
if command -v python3 >/dev/null 2>&1; then
  hook_cmds="$(python3 - "$PLUGINS_DIR" <<'PY'
import glob, json, os, sys
for hj in sorted(glob.glob(os.path.join(sys.argv[1], "*", "hooks", "hooks.json"))):
    root = os.path.dirname(os.path.dirname(hj))
    if os.path.basename(root) in ("apex-guardrails", "apex-dispatch"):
        continue
    seen = set()
    for groups in (json.load(open(hj)).get("hooks") or {}).values():
        for g in groups:
            for h in g.get("hooks", []):
                c = h.get("command", "")
                if h.get("type") == "command" and c.startswith("bash ") and c not in seen:
                    seen.add(c)
                    print(root + "\t" + c)
PY
)"
  ran=0
  while IFS="$(printf '\t')" read -r root cmd; do
    [ -n "$cmd" ] || continue
    for ph in pre post; do
      out="$(cd "$SMOKE_TMP" && CLAUDE_PLUGIN_ROOT="$root" CLAUDE_PROJECT_DIR="$SMOKE_TMP/proj" \
             APEX_TRACE_DIR="$SMOKE_TMP/traces" APEX_CR_LEDGER_DIR="$SMOKE_TMP/ledger2" \
             bash -c "$cmd" <"$SMOKE_TMP/$ph.json" 2>/dev/null || true)"
      if printf '%s' "$out" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"allow"'; then
        fail "hook '$cmd' ($(basename "$root")) printed an allow decision: $out"
      fi
      ran=$((ran + 1))
    done
  done <<<"$hook_cmds"
  [ "$ran" -gt 0 ] || fail "found no bash hook commands to exercise outside apex-guardrails/apex-dispatch"
fi
pass_check "no hook outside apex-guardrails/apex-dispatch emits an allow decision (static scan + runtime fixtures)"

echo ""
echo "smoke passed: $CHECKS/$CHECKS checks"
