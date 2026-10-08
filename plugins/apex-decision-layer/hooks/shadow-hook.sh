#!/usr/bin/env bash
# apex-decision-layer shadow hooks (seeded rubrics, spec §14 Phase 5; operator-approved 2026-10-08).
#
#   Stop                 -> done-claim@1  (does the final "done" message cite a passing check?)
#   PreToolUse (Bash)    -> tool-risk@1   (what would this command do?)
#
# Observational only (CLAUDE.md, hook composition): prints nothing, always exits 0, never emits an
# allow or deny decision. The decision call runs in a detached child (hooks/shadow_hook.py), so the hook
# returns in milliseconds and a slow or absent backend cannot delay or fail the session. Answers go
# only to the decision log; a seeded rubric is never calibrated and nothing acts on it.
#
# Off unless the repository's .claude/apex-decision-layer/config.json names the rubric (for example
# "primary": {"done-claim@1": "jev"}); without that, no python starts.
KIND="${1:-}"
case "$KIND" in
  done-claim) RUBRIC="done-claim@1" ;;
  tool-risk) RUBRIC="tool-risk@1" ;;
  *) exit 0 ;;
esac
PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"
CFG="$PROJ/.claude/apex-decision-layer/config.json"
if [ ! -f "$CFG" ] || ! grep -q "\"$RUBRIC\"" "$CFG" 2>/dev/null || ! command -v python3 >/dev/null 2>&1; then
  cat >/dev/null 2>&1 || true
  exit 0
fi
python3 -I -B "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shadow_hook.py" "$KIND" "$PROJ" >/dev/null 2>&1 || true
exit 0
