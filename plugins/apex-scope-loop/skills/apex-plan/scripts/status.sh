#!/usr/bin/env bash
# status.sh — Print a snapshot of a apex-plan initiative.
#
# Usage:
#   ./status.sh <slug>
#
# Reports:
#   - ADR path + status (Proposed / Accepted / Implemented / Superseded)
#   - Plan path + completion % (checked tasks / total tasks)
#   - Current phase (next unchecked task)
#   - Next gate (if any pending)
#   - Scope (ADR `**Scope**: X` and plan `> **Scope**: X`, header region only, as promote-to-loop.sh 7b
#     reads it): one value when both agree, `feature (no Scope line)` when neither declares one,
#     both values plus a note when they disagree, one is missing or a line is malformed. Never fails on Scope.
#   - Intent file (.claude/tasks/<slug>-intent.md): path and whether its Problem is filled, or `none`
#   - apex-execute checkpoint state (if initialized)

set -euo pipefail

SLUG="${1:-}"
if [[ -z "$SLUG" ]]; then
  echo "Usage: $0 <slug>" >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ADR="$REPO_ROOT/.claude/tasks/${SLUG}-adr.md"
PLAN="$REPO_ROOT/.claude/plans/${SLUG}-plan.md"

print_line() { printf '  %-20s %s\n' "$1" "$2"; }

echo "=== apex-plan status: $SLUG ==="
echo

# ADR
if [[ -f "$ADR" ]]; then
  STATUS="$(grep -E '^\*\*Status\*\*:' "$ADR" | head -1 | sed 's/^\*\*Status\*\*: //')"
  print_line "ADR:" "$ADR"
  print_line "Status:" "${STATUS:-unknown}"
else
  print_line "ADR:" "(not found — run start.sh)"
fi

# Plan
if [[ -f "$PLAN" ]]; then
  # Same parser as iterate.sh and land.sh (planlib.py).
  PL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../apex-execute/scripts" && pwd)/planlib.py"
  read -r TOTAL DONE < <(python3 "$PL" counts "$PLAN" 2>/dev/null || echo "0 0")
  TOTAL="${TOTAL:-0}"
  DONE="${DONE:-0}"
  python3 "$PL" validate "$PLAN" >/dev/null 2>&1 || print_line "Validity:" "INVALID — run planlib.py validate $PLAN"
  PCT=0
  if [[ "$TOTAL" -gt 0 ]]; then
    PCT=$(( DONE * 100 / TOTAL ))
  fi
  print_line "Plan:" "$PLAN"
  print_line "Progress:" "$DONE / $TOTAL tasks ($PCT%)"

  NEXT_LINE="$(python3 "$PL" next "$PLAN" 2>/dev/null | python3 -c 'import json,sys; print(((json.load(sys.stdin).get("task") or {}).get("line")) or "")' 2>/dev/null || true)"
  if [[ -n "$NEXT_LINE" ]]; then
    print_line "Next task:" "$(echo "$NEXT_LINE" | sed 's/^- \[ \] //' | cut -c1-80)"
  else
    print_line "Next task:" "(none — all checked OR no tasks)"
  fi

  NEXT_GATE="$(grep -nE '^- \[ \] \*\*Gate' "$PLAN" | head -1 || true)"
  if [[ -n "$NEXT_GATE" ]]; then
    GATE_LINE="${NEXT_GATE#*:}"
    print_line "Next gate:" "$(echo "$GATE_LINE" | sed 's/^- \[ \] //' | cut -c1-80)"
  fi
else
  print_line "Plan:" "(not found — run start.sh)"
fi

# Scope and intent (report only: nothing here can fail the script)
SCOPE_PY='
import re, sys
STRICT = re.compile(r"^(?:>[ \t]?)?\*\*Scope\*\*:[ \t]*(.*?)[ \t]*$")
LOOSE = re.compile(r"^(?:>[ \t]*)?\*\*[ \t]*scope\b", re.I)
def declared(path):
    # -> (value | None, problem | None); header region only (before the first --- or ## line)
    vals = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for n, line in enumerate(f, 1):
                line = line.rstrip("\r\n")
                if n > 1 and (line.strip() == "---" or line.startswith("## ")):
                    break
                if not LOOSE.match(line):
                    continue
                m = STRICT.match(line)
                if not m or not m.group(1):
                    return None, "malformed line %d" % n
                vals.append(m.group(1))
    except OSError:
        return None, None
    if len(vals) > 1:
        return None, "declared more than once"
    return (vals[0] if vals else None), None
(a, ae), (p, pe) = declared(sys.argv[1]), declared(sys.argv[2])
if ae or pe:
    print("malformed (ADR: %s; plan: %s)" % (ae or a or "no Scope line", pe or p or "no Scope line"))
elif a is None and p is None:
    print("feature (no Scope line)")
elif a == p:
    print(a if a in ("bugfix", "poc", "feature") else "%s (unknown value; allowed: bugfix, poc, feature)" % a)
else:
    print("mismatch (ADR: %s, plan: %s)" % (a or "no Scope line", p or "no Scope line"))
'
print_line "Scope:" "$(python3 -c "$SCOPE_PY" "$ADR" "$PLAN" 2>/dev/null || echo "unknown (could not read the ADR/plan headers)")"

IFS= read -r -d '' INTENT_PY <<'PY' || true
import re, sys
try:
    raw = open(sys.argv[1], "rb").read().decode("utf-8")
except (OSError, UnicodeDecodeError):
    print("Problem unreadable"); sys.exit(0)
body, found, fence = [], False, False
for ln in raw.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
    if re.match(r"^\s*(```|~~~)", ln):
        fence = not fence
    if not fence and not found and re.match(r"^## +Problem[ \t]*$", ln):
        found = True
        continue
    if found:
        if not fence and re.match(r"^## ", ln):
            break
        body.append(ln)
problem = "\n".join(body).strip()
if not found:
    print("no Problem section")
elif not problem or re.search(r"\[ TODO \]", problem):
    print("Problem not filled")
else:
    print("Problem filled")
PY
INTENT="$REPO_ROOT/.claude/tasks/${SLUG}-intent.md"
if [[ -e "$INTENT" || -L "$INTENT" ]]; then
  INTENT_STATE="$(python3 -c "$INTENT_PY" "$INTENT" 2>/dev/null || echo "Problem unreadable")"
  print_line "Intent:" "$INTENT ($INTENT_STATE)"
else
  print_line "Intent:" "none"
fi

# apex-execute checkpoint
if [[ -f "$PLAN" ]]; then
  APEX_RESOLVE_MODE=read  # reporting only: a repository mismatch warns
  # Same state resolution as apex-execute (shared state root across worktrees).
  # shellcheck source=../../apex-execute/scripts/_lib.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../apex-execute/scripts" && pwd)/_lib.sh"
  apex_resolve "$PLAN"

  echo
  if [[ -f "$CHECKPOINT" ]]; then
    print_line "Checkpoint:" "$CHECKPOINT"
    HALTED="$(python3 -c "import json; print(json.load(open('$CHECKPOINT')).get('halted', False))" 2>/dev/null || echo unknown)"
    HALT_REASON="$(python3 -c "import json; print(json.load(open('$CHECKPOINT')).get('halt_reason') or '')" 2>/dev/null || echo "")"
    print_line "Halted:" "$HALTED"
    [[ -n "$HALT_REASON" ]] && print_line "Halt reason:" "$HALT_REASON"
    if [[ -f "$STATE_DIR/COMPLETE" ]]; then
      print_line "Marker:" "COMPLETE — plan finished"
    fi
  else
    print_line "Checkpoint:" "(not initialized — run promote-to-loop.sh)"
  fi
fi

echo
