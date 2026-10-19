#!/usr/bin/env bash
# promote-to-loop.sh — Validate the ADR + plan are ready, then hand off to
# apex-execute by calling its init.sh on the plan.
#
# Usage:
#   ./promote-to-loop.sh <slug>
#
# Exit codes:
#   0  — Promoted; apex-execute state initialized
#   1  — Validation failed (error message names the first failing item)
#   2  — Bad args or missing files
#
# Validation checklist (must all pass):
#   1. ADR exists at .claude/tasks/<slug>-adr.md
#   2. Plan exists at .claude/plans/<slug>-plan.md
#   3. ADR has no remaining [ TODO ] markers
#   4. Every Open Question has a Decision line (no lingering Default: only)
#   5. ADR status is "Accepted"
#   6. Plan has >= 1 unchecked phase task
#   7. Every plan task has an Acceptance line
#   8. Every gate task has a runnable Acceptance OR human-ack phrase
#   9. apex-execute's init.sh exists and is executable
#   Scope (7b, only when the ADR/plan declare `Scope: bugfix|poc|feature`): phase
#   limit per scope; see the comment at 7b. No Scope line = no extra check.

set -euo pipefail

SLUG="${1:-}"
if [[ -z "$SLUG" ]]; then
  echo "Usage: $0 <slug>" >&2
  exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ADR_PATH="$REPO_ROOT/.claude/tasks/${SLUG}-adr.md"
PLAN_PATH="$REPO_ROOT/.claude/plans/${SLUG}-plan.md"
# apex-execute ships in the same plugin; resolve it next to this script so a
# marketplace install works without a repo-local .claude/skills copy.
EXEC_SCRIPTS="${APEX_EXECUTE_SCRIPTS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../apex-execute/scripts" && pwd)}"
DPL_INIT="$EXEC_SCRIPTS/init.sh"

fail() {
  echo "VALIDATION FAILED: $1" >&2
  exit 1
}

# 1. ADR exists
[[ -f "$ADR_PATH" ]] || fail "ADR not found at $ADR_PATH (run start.sh first)"

# 2. Plan exists
[[ -f "$PLAN_PATH" ]] || fail "Plan not found at $PLAN_PATH (run start.sh first)"

# 3. No [ TODO ] in ADR
if grep -qE '\[ TODO[^]]*\]' "$ADR_PATH"; then
  FIRST_TODO_LINE="$(grep -nE '\[ TODO[^]]*\]' "$ADR_PATH" | head -1)"
  fail "ADR has unresolved [ TODO ] — first at line: $FIRST_TODO_LINE"
fi

# 4. Every Open Question has Decision: filled (not just placeholder)
# Find "**Q" lines and verify a non-placeholder Decision: line follows before next **Q
if grep -qE '^\*\*Q[0-9]+\.' "$ADR_PATH"; then
  awk '
    /^\*\*Q[0-9]+\./       { q=$0; have_decision=0; next }
    /\*\*Decision\*\*:.*_\(filled in during refinement\)_/ { unresolved=q; exit }
    /\*\*Decision\*\*:/    { have_decision=1 }
    /^---$/                { if (q != "" && !have_decision) { unresolved=q; exit } }
    END { if (unresolved != "") { print unresolved; exit 1 } }
  ' "$ADR_PATH" || fail "ADR has unresolved Open Question (Decision line missing or still placeholder)"
fi

# 5. ADR status is Accepted
if ! grep -qE '^\*\*Status\*\*: Accepted' "$ADR_PATH"; then
  CURRENT_STATUS="$(grep -E '^\*\*Status\*\*:' "$ADR_PATH" | head -1 || echo '(missing)')"
  fail "ADR status is not 'Accepted'. Current: $CURRENT_STATUS — flip it after refinement is done."
fi

# 6-7. The plan parses under the same rules iterate.sh and land.sh use
#      (planlib.py validate: the plan dialect, every unchecked task has an
#      Acceptance, Route/Paths/Budget directives are well formed, Paths are
#      given for lanes, Blocked-by names real tasks, no cycles), and it has
#      at least one unchecked task.
if ! PLAN_ERRORS="$(python3 "$EXEC_SCRIPTS/planlib.py" validate "$PLAN_PATH" 2>&1)"; then
  echo "Plan validation errors (planlib.py validate):" >&2
  printf '%s\n' "$PLAN_ERRORS" | sed 's/^/  /' >&2
  fail "plan is invalid — fix the lines above"
fi
REMAINING="$(python3 "$EXEC_SCRIPTS/planlib.py" remaining "$PLAN_PATH")"
[[ "$REMAINING" -gt 0 ]] || fail "Plan has no unchecked tasks (- [ ] ...). Either all tasks are checked or the plan is empty."

# 7b. Per-scope validation (ADR R2). Scope is read from the ADR header line
#     `**Scope**: X` and the plan header line `> **Scope**: X` (start.sh --scope
#     writes both). Rules:
#       - neither file declares a Scope  -> nothing here runs: exactly the rules
#         above and below, byte-for-byte (output included).
#       - only one file declares it, the two disagree, a Scope-looking header line
#         is malformed (wrong case, no colon, empty, {{SCOPE}} left in), the value
#         is not bugfix|poc|feature, or a file has two Scope lines -> refuse. A
#         malformed line never silently means feature.
#       - bugfix allows at most 2 phases, poc at most 3, feature is unlimited.
#     "Phase" here means a distinct major number N among the plan's `**Phase N.M**`
#     task ids (planlib's ID_RE; checked or unchecked). That is the unit the rest of
#     the plan dialect uses: headings `### Phase N` group exactly those tasks, and
#     `Gate a→b` tasks are not phases.
#     Required ADR sections: this script has never required the Pseudocode,
#     Architecture, Data Model or API sections (checks 3-5 are the only ADR checks),
#     so for every scope the required-section set is empty and a bugfix/poc ADR that
#     keeps those sections still promotes. Nothing else changes with scope: gate
#     checks, Acceptance checks, the Accepted status and the route dry-run below
#     run identically. A `[tier:c]` task under bugfix/poc only prints a warning.
#     Scope is read only from the header (before the first `---` or `## ` line).
# (the program is held in a variable: a heredoc inside $( ) breaks old bash parsers)
IFS= read -r -d '' SCOPE_PY <<'PY' || true
import re, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1]); import planlib
LIMITS = {"bugfix": 2, "poc": 3, "feature": None}
STRICT = re.compile(r"^(?:>[ \t]?)?\*\*Scope\*\*:[ \t]*(.*?)[ \t]*$")
LOOSE = re.compile(r"^(?:>[ \t]*)?\*\*[ \t]*scope\b", re.I)

def declared(path, label):
    vals = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\r\n")
            if n > 1 and (line.strip() == "---" or line.startswith("## ")):
                break
            if not LOOSE.match(line):
                continue
            m = STRICT.match(line)
            if not m:
                print(f"malformed Scope line in {label} (line {n}): {line.strip()} -- expected exactly '{'> ' if label == 'plan' else ''}**Scope**: bugfix|poc|feature'")
                sys.exit(1)
            vals.append((n, m.group(1)))
    if len(vals) > 1:
        print(f"{label} declares Scope more than once (lines {', '.join(str(n) for n, _ in vals)})")
        sys.exit(1)
    return vals[0][1] if vals else None

adr, plan = declared(sys.argv[2], "ADR"), declared(sys.argv[3], "plan")
if adr is None and plan is None:
    sys.exit(0)
if adr is None or plan is None:
    where, missing = ("plan", "ADR") if adr is None else ("ADR", "plan")
    print(f"Scope is declared in the {where} but not in the {missing}; both need the same Scope line (start.sh --scope writes both)")
    sys.exit(1)
if adr != plan:
    print(f"Scope disagrees: ADR says '{adr}', plan says '{plan}'; make them match")
    sys.exit(1)
scope = adr
if scope not in LIMITS:
    print(f"unknown Scope '{scope}' (allowed: bugfix, poc, feature)")
    sys.exit(1)
tasks = planlib.parse(sys.argv[3])
phases = set()
for t in tasks:
    m = re.match(r"Phase\s+([0-9]+)", t["id"] or "")
    if m:
        phases.add(int(m.group(1)))
limit = LIMITS[scope]
if limit is not None and len(phases) > limit:
    print(f"{scope} allows at most {limit} phases; this plan has {len(phases)}")
    sys.exit(1)
print(f"Scope: {scope}" + (f" ({len(phases)} of at most {limit} phases)" if limit is not None else ""))
if scope != "feature":
    for t in tasks:
        if re.search(r"\[tier:c\b", re.sub(r"`[^`]*`", "", t["line"])):
            print(f"WARNING: line {t['line_no']} is tagged [tier:c]; {scope} scope does not loosen enforcement: the green gate, independent review, risk tier and G12 apply as for feature")
PY
SCOPE_OUT="$(python3 -c "$SCOPE_PY" "$EXEC_SCRIPTS" "$ADR_PATH" "$PLAN_PATH")" || fail "$SCOPE_OUT"
if [[ -n "$SCOPE_OUT" ]]; then
  printf '%s\n' "$SCOPE_OUT"
fi

# 8. Every gate task has a clear approval mechanism
# [gate:auto]   → Acceptance must look runnable (no "human-ack" or "approve" phrase)
# [gate:human]  → Acceptance must mention "approve" or "user types"
# [gate:partner:email] → Acceptance must mention "inbox" or be partner-resolved
python3 - "$EXEC_SCRIPTS" "$PLAN_PATH" <<'PY' || fail "Gate task has ambiguous Acceptance criteria"
import re, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1]); import planlib
errors = []
for t in planlib.parse(sys.argv[2]):
    kinds = [g for g in t["tags"] if g.startswith("gate:")]
    if not kinds:
        continue
    kind, acc, where = kinds[0][5:], t["acceptance"], f"line {t['line_no']}"
    if kind == "auto":
        # Should look runnable: contains a command-like token
        if not re.search(r'(pytest|npm|curl|grep|python|bash|node|cargo|go |make|uv |cd |&&|\|\||\.sh|\.py|\.js|\.ts)', acc):
            errors.append(f"  {where}: [gate:auto] should be runnable but Acceptance reads: {acc[:80]}")
    elif kind == "human":
        if "approve" not in acc.lower() and "user types" not in acc.lower():
            errors.append(f"  {where}: [gate:human] should require approval phrase, got: {acc[:80]}")
    elif kind.startswith("partner:"):
        if "inbox" not in acc.lower() and "consumed" not in acc.lower() and "approve" not in acc.lower():
            errors.append(f"  {where}: [gate:partner:...] should reference the partner's approval or inbox item, got: {acc[:80]}")
    else:
        errors.append(f"  {where}: unknown gate kind [gate:{kind}] (auto, human, partner:<who>)")
if errors:
    print("Gate validation issues:", file=sys.stderr)
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)
PY

# 8b. With apex-dispatch installed, every unchecked task must route: a task
#     route.sh would answer NEEDS_SPEC fails promotion (spec §6), so no model
#     tokens are spent discovering it later.
# shellcheck source=../../apex-execute/scripts/_lib.sh
APEX_RESOLVE_MODE=read source "$EXEC_SCRIPTS/_lib.sh"
DISPATCH="$(apex_dispatch_root)"
if [[ -n "$DISPATCH" ]]; then
  for LN in $(python3 -c 'import sys; sys.dont_write_bytecode=True; sys.path.insert(0, sys.argv[1]); import planlib; print(" ".join(str(t["line_no"]) for t in planlib.parse(sys.argv[2]) if not t["checked"]))' "$EXEC_SCRIPTS" "$PLAN_PATH"); do
    OUT="$("$DISPATCH/scripts/route.sh" plan "$PLAN_PATH" --line "$LN" --dry-run 2>&1)" || fail "route.sh --dry-run failed for line $LN: $(printf '%s' "$OUT" | tail -1)"
    if printf '%s\n' "$OUT" | grep -q '^ROUTE_STATUS: NEEDS_SPEC'; then
      fail "line $LN would route to NEEDS_SPEC: $(printf '%s\n' "$OUT" | sed -n 's/^ROUTE_MISSING: //p' | head -1)"
    fi
  done
  echo "Route dry-run: every unchecked task routes."
else
  echo "Route dry-run: skipped (apex-dispatch not installed beside apex-scope-loop)."
fi

# 9. apex-execute init.sh exists
[[ -x "$DPL_INIT" ]] || fail "apex-execute init.sh not found or not executable at $DPL_INIT"

# All checks pass — hand off
echo "Validation passed."
echo
echo "Handing off to apex-execute..."
echo "  $ $DPL_INIT $PLAN_PATH"
echo
"$DPL_INIT" "$PLAN_PATH"

echo
echo "Execution is worktree-bound: init.sh created an isolated git worktree and"
echo "branch for this plan. ALL phase work happens there; nothing touches the base"
echo "branch until the final gate passes and you land it."
echo
echo "READY. Start execution with:"
echo
echo "    /loop /apex-scope-loop:iterate $PLAN_PATH"
echo
echo "When the final gate passes, land the worktree into the base branch:"
echo
echo "    $EXEC_SCRIPTS/land.sh $PLAN_PATH"
echo
echo "Optionally schedule continuity layer:"
echo
echo "    /schedule \"0 2 * * *\" $EXEC_SCRIPTS/audit.sh $PLAN_PATH"
echo "    /schedule \"0 9 * * 1\" $EXEC_SCRIPTS/architecture-review.sh $PLAN_PATH"
