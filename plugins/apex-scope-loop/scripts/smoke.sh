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
[ -n "${SMOKE_KEEP:-}" ] && trap - EXIT
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

# brief DIR PLAN — iterate.sh's full brief, captured before any grep (grep -q
# closing the pipe early would SIGPIPE iterate.sh under pipefail).
brief() { local o; o="$( (cd "$1" && "$EX/iterate.sh" "$2") 2>&1 || true)"; printf '%s\n' "$o"; }

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
brief "$LW" "$R/.claude/plans/demo-plan.md" | grep -q '^STATUS: HALTED' \
  || fail "gibson/HALT in the linked worktree being run from was ignored"
rm -f "$LW/gibson/HALT"; touch "$R/.dev-plan-state/HALT"
brief "$LW" "$R/.claude/plans/demo-plan.md" | grep -q '^STATUS: HALTED' \
  || fail "shared .dev-plan-state/HALT was ignored from a linked worktree"
rm -f "$R/.dev-plan-state/HALT"
ok "checkout-local and shared kill switches both halt"

# 18. Outside git (APEX_NO_WORKTREE=1): init and iterate agree; same-named plans stay separate.
NG="$SMOKE_TMP/nogit"; mkdir -p "$NG/a" "$NG/b"
cp "$R/.claude/plans/demo-plan.md" "$NG/a/plan.md"; cp "$R/.claude/plans/demo-plan.md" "$NG/b/plan.md"
( cd "$NG" && APEX_NO_WORKTREE=1 APEX_GIBSON=0 "$EX/init.sh" a/plan.md >/dev/null && APEX_NO_WORKTREE=1 APEX_GIBSON=0 "$EX/init.sh" b/plan.md >/dev/null ) \
  || fail "init.sh failed outside git with APEX_NO_WORKTREE=1"
brief "$NG" a/plan.md | grep -q '^STATUS: READY' || fail "iterate.sh outside git does not find the state init.sh wrote"
[ "$(st "$NG" a/plan.md)" != "$(st "$NG" b/plan.md)" ] || fail "two plans named plan.md share one state dir outside git"
ok "non-git mode: init/iterate agree and same-named plans do not collide"

# indir DIR CMD... — run CMD in DIR (portable stand-in for GNU `env -C`).
indir() { local d="$1"; shift; ( cd "$d" && env "$@" ); }
# expect_refusal LABEL PATTERN CMD... — CMD must fail and say PATTERN.
expect_refusal() {
  local label="$1" pat="$2" out; shift 2
  if out="$("$@" 2>&1)"; then fail "$label: expected a refusal, got success"; fi
  printf '%s' "$out" | grep -q -- "$pat" || fail "$label: refused for the wrong reason: $(printf '%s' "$out" | tail -2)"
}

# 19. A run is never silently taken over: re-init from another checkout with a
#     different base refuses; same base keeps the run's history.
expect_refusal "retarget to another base" "Refusing to retarget" \
  indir "$LW" APEX_BASE_BRANCH=linked "$EX/init.sh" "$R/.claude/plans/demo-plan.md"
python3 - "$S_BASE/checkpoint.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s.setdefault("reviews", {})["99"] = {"sha": "x", "verdict": "APPROVE"}; json.dump(s, open(p, "w"))
PY
( cd "$R" && APEX_GIBSON=0 "$EX/init.sh" .claude/plans/demo-plan.md >/dev/null 2>&1 ) || fail "same-base re-init failed"
python3 -c 'import json,sys; sys.exit(0 if "99" in json.load(open(sys.argv[1])).get("reviews",{}) else 1)' "$S_BASE/checkpoint.json" \
  || fail "same-base re-init discarded the run's reviews"
ok "init refuses takeover; re-init keeps run history"

# 20. APEX_STATE_ROOT moves state only, is made absolute, and is keyed per repository.
cp "$R/.claude/plans/demo-plan.md" "$R/.claude/plans/rel-plan.md"
( cd "$R" && APEX_STATE_ROOT=rel-root APEX_GIBSON=0 "$EX/init.sh" .claude/plans/rel-plan.md >/dev/null 2>&1 ) || fail "init.sh with a relative APEX_STATE_ROOT failed"
A1="$(APEX_STATE_ROOT=rel-root st "$R" .claude/plans/rel-plan.md)"
A2="$(APEX_STATE_ROOT="$R/rel-root" st "$R/.claude" plans/rel-plan.md)"
case "$A1" in /*) ;; *) fail "APEX_STATE_ROOT state dir is not absolute: '$A1'" ;; esac
[ "$A1" = "$A2" ] || fail "relative APEX_STATE_ROOT split state: $A1 vs $A2"
ok "APEX_STATE_ROOT is absolute and stable across working directories"

# 21. One repository, proven: every acting script refuses another repo's plan,
#     even when the caller's repo runs a same-path plan; reporting scripts warn.
O="$SMOKE_TMP/other"; git init -q -b main "$O"; mkdir -p "$O/.claude/plans"
cp "$R/.claude/plans/demo-plan.md" "$O/.claude/plans/demo-plan.md"
git -C "$O" add -A && git -C "$O" commit -qm o
( cd "$O" && APEX_GIBSON=0 "$EX/init.sh" .claude/plans/demo-plan.md >/dev/null 2>&1 ) || fail "init in the second repo failed"
O_HEAD="$(git -C "$O" rev-parse main)"
RP="$R/.claude/plans/demo-plan.md"
expect_refusal "init.sh cross-repo"       "refusing to act" indir "$O" "$EX/init.sh" "$RP"
expect_refusal "land.sh cross-repo"       "refusing to act" indir "$O" "$EX/land.sh" "$RP" --force
expect_refusal "checkpoint.sh cross-repo" "refusing to act" indir "$O" "$EX/checkpoint.sh" "$RP" halt x
expect_refusal "green-gate.sh cross-repo" "refusing to act" indir "$O" "$EX/green-gate.sh" "$RP" check
expect_refusal "risk-tier.sh cross-repo"  "refusing to act" indir "$O" "$EX/risk-tier.sh" "$RP" 1
IT_OUT="$( (cd "$O" && "$EX/iterate.sh" "$RP" 2>/dev/null) || true)"
printf '%s\n' "$IT_OUT" | grep -q '^STATUS: ERROR repository mismatch' || fail "iterate.sh cross-repo did not report STATUS: ERROR repository mismatch"
[ "$(git -C "$O" rev-parse main)" = "$O_HEAD" ] || fail "a cross-repo call moved the other repo's main"
ST_OUT="$( (cd "$O" && "$EX/status.sh" "$RP" 2>&1) || true)"
printf '%s\n' "$ST_OUT" | grep -q 'WARNING: repository mismatch' || fail "status.sh did not warn on a cross-repo plan"
ok "acting scripts refuse another repository's plan; status warns"

# 22. Branches are per plan; a foreign same-name branch is never adopted; a
#     deleted worktree is recreated by init.
B1="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["worktree_branch"])' "$S_BASE/checkpoint.json")"
mkdir -p "$R/other"; cp "$RP" "$R/other/demo-plan.md"
( cd "$R" && APEX_GIBSON=0 "$EX/init.sh" other/demo-plan.md >/dev/null 2>&1 ) || fail "init of a same-slug plan failed"
B2="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["worktree_branch"])' "$(st "$R" other/demo-plan.md)/checkpoint.json")"
[ "$B1" != "$B2" ] || fail "two same-slug plans share branch $B1"
cp "$RP" "$R/.claude/plans/fresh-plan.md"
FRESH_STATE="$(cd "$R" && source "$EX/_lib.sh" && apex_resolve .claude/plans/fresh-plan.md && echo "$STATE_DIR")"
git -C "$R" branch "apex-scope-loop/fresh-$(basename "$FRESH_STATE")" main
expect_refusal "adopt foreign branch" "refusing to adopt" indir "$R" APEX_GIBSON=0 "$EX/init.sh" .claude/plans/fresh-plan.md
WT2="$(st "$R" other/demo-plan.md)/worktree"
rm -rf "$WT2"
( cd "$R" && APEX_GIBSON=0 "$EX/init.sh" other/demo-plan.md >/dev/null 2>&1 ) || fail "re-init after deleting the worktree failed"
[ -d "$WT2" ] && [ "$(git -C "$WT2" symbolic-ref -q HEAD)" = "refs/heads/$B2" ] || fail "deleted worktree was not recreated on its branch"
ok "per-plan branches; foreign branch refused; deleted worktree recreated"

# 23. land.sh: refuses from the wrong checkout and with unrelated base changes,
#     without modifying anything; lands the exact worktree head otherwise.
L="$SMOKE_TMP/landrepo"; mkdir -p "$L/plans"; git init -q -b main "$L"
printf -- '- [x] **Phase 1.1** [docs] done\n  - Acceptance: true\n' >"$L/plans/l-plan.md"; echo base >"$L/tracked.txt"
git -C "$L" add -A && git -C "$L" commit -qm base
( cd "$L" && APEX_GIBSON=0 "$EX/init.sh" plans/l-plan.md >/dev/null 2>&1 ) || fail "init for the land test failed"
LWT="$(cd "$L" && "$EX/iterate.sh" plans/l-plan.md | sed -n 's/^WORKTREE: //p')"
[ -n "$LWT" ] || LWT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["worktree_path"])' "$(st "$L" plans/l-plan.md)/checkpoint.json")"
echo feature >"$LWT/feature.txt"; git -C "$LWT" add -A; git -C "$LWT" commit -qm feature
LH="$(git -C "$LWT" rev-parse HEAD)"; MAIN0="$(git -C "$L" rev-parse main)"
expect_refusal "land from inside the plan worktree" "run land.sh from there" indir "$LWT" APEX_GIBSON=0 "$EX/land.sh" "$L/plans/l-plan.md"
echo dirty >>"$L/tracked.txt"
expect_refusal "land with unrelated base changes" "unrelated to this plan" indir "$L" APEX_GIBSON=0 "$EX/land.sh" plans/l-plan.md
[ "$(git -C "$L" rev-parse main)" = "$MAIN0" ] && [ "$(git -C "$LWT" rev-parse HEAD)" = "$LH" ] || fail "a refused land modified a branch"
git -C "$L" checkout -q -- tracked.txt
( cd "$L" && APEX_GIBSON=0 "$EX/land.sh" plans/l-plan.md >/dev/null 2>&1 ) || fail "land.sh failed on a ready plan"
git -C "$L" merge-base --is-ancestor "$LH" main || fail "land.sh did not merge the worktree head"
ok "land.sh refuses safely and merges the exact worktree head"

# 24. Every script that sources _lib.sh resolves (and so guards) before reading state.
for f in "$EX"/*.sh "$PLUGIN_ROOT"/skills/apex-plan/scripts/*.sh; do
  grep -q '_lib.sh"' "$f" || continue
  awk '/apex_resolve "\$PLAN"/{r=1} /read_field |\$CHECKPOINT/{ if(!r){bad=1; exit} } END{exit bad}' "$f" \
    || fail "$(basename "$f") reads state before apex_resolve"
done
ok "every _lib.sh user resolves before reading state"

# 25. Plan parsing (planlib.py, the one parser): widened tags, 8-line look-ahead
#     with six directives, Blocked-by forms, next-unblocked selection, fail-closed
#     unknown references, validation (Route/Budget values, lanes need Paths, cycles).
PL="$EX/planlib.py"; P25="$SMOKE_TMP/p25.md"
cat >"$P25" <<'PLAN'
- [x] **Phase 1.1** [docs] done
  - Acceptance: true
- [ ] **Phase 1.2** [backend][gate:partner:x@y.com] waits on 1.3
  - Acceptance: true
  - Blocked-by: **Phase 1.3**
- [ ] **Phase 1.3** [tests] all six directives
  - Acceptance: `pytest -q`
  - Blocked-by: phase-1.1
  - Swarm: single [coder]
  - Route: class=tests provider=auto fanout=lanes review=solo
  - Paths: tests/a/**
  - Budget: usd=2 spawns=3 minutes=20
- [ ] **Phase 1.4** [tests] lane two
  - Acceptance: true
  - Route: fanout=lanes
  - Paths: src/b/**
- [ ] **Phase 1.5** [docs] waits on a gate that does not exist
  - Acceptance: true
  - Blocked-by: Gate 9→10
PLAN
python3 - "$PL" "$P25" <<'PY' || fail "planlib next: wrong selection or parsing"
import json, subprocess, sys
d = json.loads(subprocess.check_output([sys.executable, sys.argv[1], "next", sys.argv[2]]))
t = d["task"]
assert d["status"] == "READY" and t["id"] == "Phase 1.3", d
assert t["acceptance"] == "pytest -q" and t["swarm"] == "single [coder]", t
assert t["route"] == {"class": "tests", "provider": "auto", "fanout": "lanes", "review": "solo"}, t["route"]
assert t["paths"] == ["tests/a/**"] and t["budget"] == {"usd": "2", "spawns": "3", "minutes": "20"}, t
assert d["lanes"] == [t["line_no"], t["line_no"] + 7], d["lanes"]
blocked = {b["id"]: b for b in d["blocked"]}
assert blocked["Phase 1.2"]["open"] == ["Phase 1.3"], blocked
assert blocked["Phase 1.5"]["unknown"] == ["Gate 9→10"], blocked
tags = json.loads(subprocess.check_output([sys.executable, sys.argv[1], "task", sys.argv[2], "3"]))["tags"]
assert tags == ["backend", "gate:partner:x@y.com"], tags
PY
python3 "$PL" next "$EX/../resources/examples/sample-plan.md" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["task"]["id"]=="Phase 1.1" and any(b["id"]=="Phase 1.2" and b["open"]==["Phase 1.1"] for b in d["blocked"]), d' \
  || fail "sample-plan: **Phase 1.2** Blocked-by phase-1.1 is not resolved"
V="$(python3 "$PL" validate "$P25" || true)"
printf '%s' "$V" | grep -q "Blocked-by 'Gate 9→10' does not name a task" || fail "validate missed an unknown Blocked-by"
printf -- '- [ ] **Phase 1.1** [x] a\n  - Acceptance: true\n  - Blocked-by: phase-1.2\n  - Route: class=nope fanout=lanes\n  - Budget: usd=-1\n- [ ] **Phase 1.2** b\n  - Acceptance: true\n  - Blocked-by: phase-1.1\n' >"$SMOKE_TMP/bad.md"
V="$(python3 "$PL" validate "$SMOKE_TMP/bad.md" || true)"
for want in "Route class=nope" "fanout=lanes requires a Paths" "Budget usd=-1" "Blocked-by cycle"; do
  printf '%s' "$V" | grep -q "$want" || fail "validate missed: $want"
done
ok "planlib: tags, directives, Blocked-by, next-unblocked, lanes, validation"

# 26. iterate.sh: ACTIVE lock (a second plan is BUSY), STAGE and directive fields
#     in the brief, ROUTE: none without apex-dispatch, BLOCKED when nothing is ready.
K="$SMOKE_TMP/lockrepo"; mkdir -p "$K/plans"; git init -q -b main "$K"
cp "$P25" "$K/plans/a-plan.md"; cp "$P25" "$K/plans/b-plan.md"; git -C "$K" add -A; git -C "$K" commit -qm k
( cd "$K" && APEX_GIBSON=0 "$EX/init.sh" plans/a-plan.md >/dev/null 2>&1 && APEX_GIBSON=0 "$EX/init.sh" plans/b-plan.md >/dev/null 2>&1 ) || fail "init for the lock test failed"
OUT_A="$(cd "$K" && "$EX/iterate.sh" plans/a-plan.md)"
for want in "^STATUS: READY" "^STAGE: BUILD" "^ROUTE_DIRECTIVE: class=tests" "^PATHS: tests/a/\*\*" "^BUDGET: usd=2" "^LANES: " "^ROUTE: none"; do
  printf '%s\n' "$OUT_A" | grep -q "$want" || fail "iterate brief lacks $want"
done
brief "$K" plans/b-plan.md | grep -q '^STATUS: BUSY' || fail "a second plan was not BUSY while the first holds the ACTIVE lock"
brief "$K" plans/a-plan.md | grep -q '^STATUS: READY' || fail "the lock owner could not re-acquire"
APEX_FORCE_UNLOCK=1 brief "$K" plans/b-plan.md | grep -q '^STATUS: READY' || fail "APEX_FORCE_UNLOCK did not reclaim the lock"
printf -- '- [ ] **Phase 1.1** a\n  - Acceptance: true\n  - Blocked-by: phase-1.2\n- [ ] **Phase 1.2** b\n  - Acceptance: true\n  - Blocked-by: phase-1.1\n' >"$K/plans/c-plan.md"
( cd "$K" && APEX_GIBSON=0 "$EX/init.sh" plans/c-plan.md >/dev/null 2>&1 ) || fail "init c-plan failed"
APEX_FORCE_UNLOCK=1 brief "$K" plans/c-plan.md | grep -q '^STATUS: BLOCKED' || fail "an all-blocked plan was not BLOCKED"
ok "iterate: ACTIVE lock, brief fields, ROUTE: none, BLOCKED"

# 27. land.sh handles a plan path that git quotes (spaces).
Q="$SMOKE_TMP/quoted repo"; mkdir -p "$Q/my plans"; git init -q -b main "$Q"
printf -- '- [ ] **Phase 1.1** [docs] x\n  - Acceptance: true\n' >"$Q/my plans/q-plan.md"; git -C "$Q" add -A; git -C "$Q" commit -qm q
( cd "$Q" && APEX_GIBSON=0 "$EX/init.sh" "my plans/q-plan.md" >/dev/null 2>&1 ) || fail "init with a spaced plan path failed"
sed -i.bak 's/^- \[ \]/- [x]/' "$Q/my plans/q-plan.md" && rm -f "$Q/my plans/q-plan.md.bak"
( cd "$Q" && APEX_GIBSON=0 "$EX/land.sh" "my plans/q-plan.md" >/dev/null 2>&1 ) || fail "land.sh refused a plan path containing spaces"
ok "land.sh: quoted plan paths"

echo ""
echo "smoke passed: 27/27 checks"
