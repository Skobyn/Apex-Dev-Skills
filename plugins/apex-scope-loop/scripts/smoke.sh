#!/usr/bin/env bash
# apex-scope-loop structural smoke test
# Verifies the plugin contract from ADR-0001 (checks 1-10), ADR-0002 (11-13) and ADR-0003 (14+). Exits non-zero on first failure.
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

# 11. gibson-reviewer agent (ADR-0002) present, with a model and a VERDICT contract
GR="$PLUGIN_ROOT/agents/gibson-reviewer.md"
[ -f "$GR" ] || fail "missing agent: $GR"
grep -qE "^name:[[:space:]]+gibson-reviewer[[:space:]]*$" "$GR" || fail "gibson-reviewer missing name"
grep -qE "^model:[[:space:]]+[a-z]+" "$GR" || fail "gibson-reviewer missing model:"
grep -q "VERDICT: APPROVE" "$GR" || fail "gibson-reviewer does not define the VERDICT contract"
ok "gibson-reviewer agent present with model + VERDICT contract"

# 12. Harness scripts present and The Gibson credited
for s in green-gate risk-tier lessons; do
  [ -f "$PLUGIN_ROOT/skills/apex-execute/scripts/$s.sh" ] || fail "missing harness script: $s.sh"
done
grep -q "The Gibson" "$PLUGIN_ROOT/NOTICE" 2>/dev/null || fail "NOTICE missing or does not credit The Gibson"
ok "harness scripts present; NOTICE credits The Gibson"

# 13. ADR-0002 exists with Status: Proposed
ADR2="$PLUGIN_ROOT/docs/adrs/0002-gibson-harness.md"
[ -f "$ADR2" ] || fail "missing ADR-0002"
grep -qE "^- \*\*Status:\*\* Proposed" "$ADR2" || fail "ADR-0002 not in Proposed status"
ok "ADR-0002 exists with Status: Proposed"

# 14. Portability (ADR-0003): no repo-local .claude/skills paths in commands, skills or agents
hits=$(grep -rnE '\.claude/skills/apex-(execute|plan)/' "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/agents" 2>/dev/null || true)
[ -z "$hits" ] || fail "repo-local .claude/skills path (breaks marketplace installs): $hits"
[ ! -e "$PLUGIN_ROOT/skills/apex-execute/resources/templates/hooks-snippet.json" ] || fail "hooks-snippet.json must stay deleted (it pointed at a non-existent guardrail)"
ok "no .claude/skills paths; hooks-snippet.json removed"

# 15-16. Functional: a plan promoted in a scratch repo, then resolved from the
# base checkout and from inside the plan worktree, lands on ONE state dir.
# The functional checks must not inherit the caller's loop configuration.
for v in $(compgen -e | grep '^APEX_' || true); do unset "$v"; done
SMOKE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/apex-scope-loop-smoke.XXXXXX")"
trap 'git -C "$SMOKE_TMP/repo" worktree prune >/dev/null 2>&1 || true; rm -rf "$SMOKE_TMP"' EXIT
export GIT_AUTHOR_NAME=smoke GIT_AUTHOR_EMAIL=smoke@example.invalid GIT_COMMITTER_NAME=smoke GIT_COMMITTER_EMAIL=smoke@example.invalid
R="$SMOKE_TMP/repo"; mkdir -p "$R/.claude/tasks" "$R/.claude/plans"
git -C "$R" init -q -b main
cat >"$R/.claude/tasks/demo-adr.md" <<'ADR'
# ADR: demo
**Status**: Accepted
ADR
cp "$PLUGIN_ROOT/skills/apex-execute/resources/examples/sample-plan.md" "$R/.claude/plans/demo-plan.md"
git -C "$R" add -A && git -C "$R" commit -qm init
EX="$PLUGIN_ROOT/skills/apex-execute/scripts"
( cd "$R" && APEX_GIBSON=0 APEX_MEMORY_CMD= "$PLUGIN_ROOT/skills/apex-plan/scripts/promote-to-loop.sh" demo >"$SMOKE_TMP/promote.log" 2>&1 ) \
  || fail "promote-to-loop.sh failed in a repo with no .claude/skills copy: $(tail -3 "$SMOKE_TMP/promote.log")"
ok "promote-to-loop resolves init.sh plugin-relatively (no .claude/skills copy)"

st() { # st DIR PLAN — the STATE line iterate.sh reports for PLAN when run from DIR
  ( cd "$1" && "$EX/iterate.sh" "$2" 2>&1 | sed -n 's/^STATE: //p' | head -1 ) || true
}
S_BASE="$(st "$R" .claude/plans/demo-plan.md)"
WTP="$( (cd "$R" && "$EX/iterate.sh" .claude/plans/demo-plan.md 2>&1 | sed -n 's/^WORKTREE: //p') || true)"
[ -n "$WTP" ] && [ -d "$WTP" ] || fail "iterate.sh did not report a plan worktree"
S_WT_PLAN="$(st "$WTP" "$WTP/.claude/plans/demo-plan.md")"
S_WT_CWD="$(st "$WTP" "$R/.claude/plans/demo-plan.md")"
ln -s "$R" "$SMOKE_TMP/link"
S_LINK="$(st "$SMOKE_TMP/link" .claude/plans/demo-plan.md)"
[ -n "$S_BASE" ] && [ "$S_BASE" = "$S_WT_PLAN" ] && [ "$S_BASE" = "$S_WT_CWD" ] && [ "$S_BASE" = "$S_LINK" ] \
  || fail "state dir differs: base=$S_BASE worktree-plan=$S_WT_PLAN worktree-cwd=$S_WT_CWD symlink=$S_LINK"
ok "one state dir from the base checkout, the plan worktree and a symlinked path"

# 17. Kill switches: a HALT in the checkout you run from, and a shared HALT, both stop the loop.
LW="$SMOKE_TMP/linked"; git -C "$R" worktree add -q -b linked "$LW" main
mkdir -p "$LW/gibson" && touch "$LW/gibson/HALT"
( cd "$LW" && "$EX/iterate.sh" "$R/.claude/plans/demo-plan.md" | grep -q '^STATUS: HALTED' ) \
  || fail "gibson/HALT in the linked worktree being run from was ignored"
rm -f "$LW/gibson/HALT"; touch "$R/.dev-plan-state/HALT"
( cd "$LW" && "$EX/iterate.sh" "$R/.claude/plans/demo-plan.md" | grep -q '^STATUS: HALTED' ) \
  || fail "shared .dev-plan-state/HALT was ignored from a linked worktree"
rm -f "$R/.dev-plan-state/HALT"
ok "checkout-local and shared kill switches both halt"

# 18. Outside git (APEX_NO_WORKTREE=1): init and iterate agree; same-named plans stay separate.
NG="$SMOKE_TMP/nogit"; mkdir -p "$NG/a" "$NG/b"
cp "$R/.claude/plans/demo-plan.md" "$NG/a/plan.md"; cp "$R/.claude/plans/demo-plan.md" "$NG/b/plan.md"
( cd "$NG" && APEX_NO_WORKTREE=1 APEX_GIBSON=0 "$EX/init.sh" a/plan.md >/dev/null && APEX_NO_WORKTREE=1 APEX_GIBSON=0 "$EX/init.sh" b/plan.md >/dev/null ) \
  || fail "init.sh failed outside git with APEX_NO_WORKTREE=1"
( cd "$NG" && "$EX/iterate.sh" a/plan.md | grep -q '^STATUS: READY' ) || fail "iterate.sh outside git does not find the state init.sh wrote"
[ "$(st "$NG" a/plan.md)" != "$(st "$NG" b/plan.md)" ] || fail "two plans named plan.md share one state dir outside git"
ok "non-git mode: init/iterate agree and same-named plans do not collide"

# 19. A run is never silently taken over: re-init from another checkout with a
#     different base refuses; same base keeps the run's history; a plan from
#     another repository refuses.
( cd "$LW" && APEX_BASE_BRANCH=linked "$EX/init.sh" "$R/.claude/plans/demo-plan.md" >/dev/null 2>&1 ) \
  && fail "init.sh retargeted an initialized plan to another base branch"
python3 - "$S_BASE/checkpoint.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s.setdefault("reviews", {})["99"] = {"sha": "x", "verdict": "APPROVE"}; json.dump(s, open(p, "w"))
PY
( cd "$R" && APEX_GIBSON=0 "$EX/init.sh" .claude/plans/demo-plan.md >/dev/null 2>&1 ) || fail "same-base re-init failed"
python3 -c 'import json,sys; sys.exit(0 if "99" in json.load(open(sys.argv[1])).get("reviews",{}) else 1)' "$S_BASE/checkpoint.json" \
  || fail "same-base re-init discarded the run's reviews"
O="$SMOKE_TMP/other"; git init -q -b main "$O"; git -C "$O" commit -q --allow-empty -m o
( cd "$O" && APEX_GIBSON=0 "$EX/init.sh" "$R/.claude/plans/demo-plan.md" >/dev/null 2>&1 ) \
  && fail "init.sh accepted a plan from a different repository than the caller's checkout"
ok "init refuses takeover and cross-repo plans; re-init keeps run history"

# 20. APEX_STATE_ROOT moves state only, is made absolute, and is keyed per repository.
cp "$R/.claude/plans/demo-plan.md" "$R/.claude/plans/rel-plan.md"
( cd "$R" && APEX_STATE_ROOT=rel-root APEX_GIBSON=0 "$EX/init.sh" .claude/plans/rel-plan.md >/dev/null 2>&1 ) || fail "init.sh with a relative APEX_STATE_ROOT failed"
A1="$(cd "$R" && APEX_STATE_ROOT=rel-root "$EX/iterate.sh" .claude/plans/rel-plan.md | sed -n 's/^STATE: //p')"
A2="$(cd "$R/.claude" && APEX_STATE_ROOT="$R/rel-root" "$EX/iterate.sh" plans/rel-plan.md | sed -n 's/^STATE: //p')"
case "$A1" in /*) ;; *) fail "APEX_STATE_ROOT state dir is not absolute: $A1" ;; esac
[ -n "$A1" ] && [ "$A1" = "$A2" ] || fail "relative APEX_STATE_ROOT split state: $A1 vs $A2"
ok "APEX_STATE_ROOT is absolute and stable across working directories"

echo ""
echo "smoke passed: 20/20 checks"
