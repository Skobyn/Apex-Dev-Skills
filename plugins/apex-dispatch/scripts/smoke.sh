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

# 9. no platform coupling in engine sources
if grep -rIl 'apex-app\|getapexinsights\.com/api\|claude-flow' "$PLUGIN_ROOT/scripts" "$PLUGIN_ROOT/bin" "$PLUGIN_ROOT/hooks" 2>/dev/null | grep -v '/scripts/smoke.sh$' | grep -q .; then
  fail "engine sources reference apex-app/claude-flow"
fi
pass "no apex-app/claude-flow coupling in engine sources"

# 10. version is semver
python3 -c "import json,re,sys; v=json.load(open(sys.argv[1]))['version']; assert re.fullmatch(r'\d+\.\d+\.\d+', v)" "$PJ" || fail "version is not semver"
pass "version is semver"

echo ""
echo "smoke passed: $N/$N checks"
