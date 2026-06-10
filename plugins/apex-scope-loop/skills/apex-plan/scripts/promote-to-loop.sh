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
#  10. Every Phase task has a Tier: line naming a phase-worker subagent (ADR-0002)
#  11. Every heavy-tier task has a Rationale row in the ADR's tier table

set -euo pipefail

# Tier routing guard (ADR-0002)
if [ -n "${CLAUDE_CODE_SUBAGENT_MODEL:-}" ]; then
  echo "FATAL: CLAUDE_CODE_SUBAGENT_MODEL set; tier routing void" >&2
  exit 1
fi

SLUG="${1:-}"
if [[ -z "$SLUG" ]]; then
  echo "Usage: $0 <slug>" >&2
  exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ADR_PATH="$REPO_ROOT/.claude/tasks/${SLUG}-adr.md"
PLAN_PATH="$REPO_ROOT/.claude/plans/${SLUG}-plan.md"
DPL_INIT="$REPO_ROOT/.claude/skills/apex-execute/scripts/init.sh"

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

# 6. Plan has >= 1 unchecked task
if ! grep -qE '^- \[ \]' "$PLAN_PATH"; then
  fail "Plan has no unchecked tasks (- [ ] ...). Either all tasks are checked or the plan is empty."
fi

# 7. Every checkbox task has an Acceptance line within next ~6 lines
python3 - "$PLAN_PATH" <<'PY' || fail "Plan has tasks missing Acceptance lines (see python output above)"
import re, sys, pathlib
plan = pathlib.Path(sys.argv[1]).read_text().splitlines()
errors = []
for i, line in enumerate(plan):
    if re.match(r'^- \[[ x]\] \*\*(Phase|Gate)', line):
        window = plan[i+1:i+9]
        if not any('Acceptance:' in l for l in window):
            errors.append(f"  line {i+1}: {line.strip()[:80]}")
if errors:
    print("Tasks missing Acceptance:", file=sys.stderr)
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)
PY

# 8. Every gate task has a clear approval mechanism
# [gate:auto]   → Acceptance must look runnable (no "human-ack" or "approve" phrase)
# [gate:human]  → Acceptance must mention "approve" or "user types"
# [gate:partner:email] → Acceptance must mention "inbox" or be partner-resolved
GATE_ISSUES="$(grep -nE '\[gate:' "$PLAN_PATH" || true)"
if [[ -n "$GATE_ISSUES" ]]; then
  python3 - "$PLAN_PATH" <<'PY' || fail "Gate task has ambiguous Acceptance criteria"
import re, sys, pathlib
plan = pathlib.Path(sys.argv[1]).read_text().splitlines()
errors = []
for i, line in enumerate(plan):
    m = re.search(r'\[gate:(auto|human|partner:[^\]]+)\]', line)
    if not m:
        continue
    kind = m.group(1)
    window = plan[i+1:i+9]
    acc_line = next((l for l in window if 'Acceptance:' in l), None)
    if not acc_line:
        errors.append(f"  line {i+1}: gate has no Acceptance: {line.strip()[:80]}")
        continue
    acc = acc_line.split('Acceptance:', 1)[1].strip()
    if kind == 'auto':
        # Should look runnable: contains a command-like token
        if not re.search(r'(pytest|npm|curl|grep|python|bash|node|cargo|cd |&&|\|\||\.sh|\.py|\.js|\.ts)', acc):
            errors.append(f"  line {i+1}: [gate:auto] should be runnable but Acceptance reads: {acc[:80]}")
    elif kind == 'human':
        if 'approve' not in acc.lower() and 'user types' not in acc.lower():
            errors.append(f"  line {i+1}: [gate:human] should require approval phrase, got: {acc[:80]}")
    elif kind.startswith('partner:'):
        if 'inbox' not in acc.lower() and 'consumed' not in acc.lower():
            errors.append(f"  line {i+1}: [gate:partner:...] should reference inbox item, got: {acc[:80]}")
if errors:
    print("Gate validation issues:", file=sys.stderr)
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)
PY
fi

# 10 & 11. Tier routing (ADR-0002): every Phase task carries a valid Tier line
# (gates are exempt — the orchestrator evaluates those itself), and every
# heavy-tier task is backed by a Rationale row in the ADR's tier table.
# No tier, no promotion — same class of check as "no Default: lines."
python3 - "$PLAN_PATH" "$ADR_PATH" <<'PY' || fail "Tier routing validation failed (see python output above)"
import re, sys, pathlib
plan = pathlib.Path(sys.argv[1]).read_text().splitlines()
adr  = pathlib.Path(sys.argv[2]).read_text()
VALID = {"phase-worker-light", "phase-worker-standard", "phase-worker-heavy"}
errors, heavy_tasks = [], []
for i, line in enumerate(plan):
    m = re.match(r'^- \[[ x]\] \*\*(Phase [0-9.]+)\*\*', line)
    if not m:
        continue
    window = []
    for l in plan[i+1:i+9]:
        if re.match(r'^- \[', l):          # next task — stop before its lines
            break
        window.append(l)
    tier_line = next((l for l in window if re.match(r'\s*- Tier:', l)), None)
    if tier_line is None:
        errors.append(f"  line {i+1}: {m.group(1)} has no Tier: line")
        continue
    tier = tier_line.split('Tier:', 1)[1].strip()
    if tier not in VALID:
        errors.append(f"  line {i+1}: {m.group(1)} has unknown tier '{tier}'")
    elif tier == "phase-worker-heavy":
        heavy_tasks.append((i + 1, m.group(1)))
if heavy_tasks:
    # ADR tier table rows: | <phase> | heavy | <rationale> |
    rows = {}
    for rm in re.finditer(r'^\|\s*([0-9.]+)\s*\|\s*heavy\s*\|\s*([^|]*)\|', adr, re.M):
        rows[rm.group(1)] = rm.group(2).strip()
    for line_no, phase in heavy_tasks:
        num = phase.split()[1]                # "3.1"
        rationale = rows.get(num) or rows.get(num.split('.')[0])
        if not rationale or 'TODO' in rationale:
            errors.append(
                f"  line {line_no}: {phase} is phase-worker-heavy but the ADR tier "
                f"table has no Rationale row for phase {num} (heavy requires a rationale)")
if errors:
    print("Tier routing issues:", file=sys.stderr)
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)
PY

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
echo "    /loop iterate the next phase of $PLAN_PATH"
echo
echo "When the final gate passes, land the worktree into the base branch:"
echo
echo "    .claude/skills/apex-execute/scripts/land.sh $PLAN_PATH"
echo
echo "Optionally schedule continuity layer:"
echo
echo "    /schedule \"0 2 * * *\" .claude/skills/apex-execute/scripts/audit.sh $PLAN_PATH"
echo "    /schedule \"0 9 * * 1\" .claude/skills/apex-execute/scripts/architecture-review.sh $PLAN_PATH"
