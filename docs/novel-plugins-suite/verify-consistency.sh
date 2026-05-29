#!/usr/bin/env bash
# verify-consistency.sh — Phase 8.2 of the novel-plugins-suite plan.
# Asserts each plugin's name + description match across the three places the
# repo contract requires them to agree (CLAUDE.md "two-level manifest"):
#   1. plugins/<name>/.claude-plugin/plugin.json
#   2. .claude-plugin/marketplace.json   (the matching entry)
#   3. plugins/<name>/README.md          (description appears verbatim)
# Exits non-zero on the first divergence, naming it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

PLUGINS=(apex-guardrails apex-agent-team apex-legacy-comprehension \
         apex-contracts-reliability apex-agent-observability apex-rag-memory)

fail() { echo "consistency FAIL: $1" >&2; exit 1; }
ok()   { echo "consistency OK:   $1"; }

for name in "${PLUGINS[@]}"; do
  pj="plugins/$name/.claude-plugin/plugin.json"
  readme="plugins/$name/README.md"
  [ -f "$pj" ]     || fail "$name: missing $pj"
  [ -f "$readme" ] || fail "$name: missing $readme"

  python3 - "$name" "$pj" "$readme" .claude-plugin/marketplace.json <<'PY'
import json, sys
name, pj_path, readme_path, mp_path = sys.argv[1:5]
pj = json.load(open(pj_path))
mp = json.load(open(mp_path))
entry = next((p for p in mp["plugins"] if p["name"] == name), None)
if entry is None:
    sys.exit(f"{name}: not registered in marketplace.json")
if pj["name"] != name:
    sys.exit(f"{name}: plugin.json name '{pj['name']}' != dir name")
if entry["description"] != pj["description"]:
    sys.exit(f"{name}: marketplace description != plugin.json description")
if entry.get("source") != f"./plugins/{name}":
    sys.exit(f"{name}: marketplace source != ./plugins/{name}")
readme = open(readme_path, encoding="utf-8").read()
if pj["description"] not in readme:
    sys.exit(f"{name}: plugin README.md does not contain the verbatim description")
PY
  ok "$name: name + description consistent across plugin.json / marketplace.json / README.md"
done

echo ""
echo "consistency passed: ${#PLUGINS[@]}/${#PLUGINS[@]} plugins"
