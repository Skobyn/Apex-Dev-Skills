#!/usr/bin/env bash
# lessons.sh — The ratchet. Adapted from The Gibson's Law 9 ("a failure that
# happens twice is a harness bug, not a model bug") — see docs/GIBSON_HARNESS.md.
#
# The ledger is a tracked, append-only markdown file so lessons outlive the
# plan, the worktree, and the session:
#   default: <repo-root>/.claude/apex-scope-loop/LESSONS.md  (override: APEX_LESSONS_FILE)
#
# Usage:
#   ./lessons.sh PLAN.md fail SIGNATURE
#       Count a failure signature (short, stable text, e.g. "pytest:test_refresh_rotation").
#       Prints RATCHET: FILE_LESSON on the second occurrence — the orchestrator
#       must then file a lesson (and, where possible, the guide/sensor that
#       prevents a third) before advancing.
#   ./lessons.sh PLAN.md add TITLE WHAT ROOT_CAUSE FIX TAGS
#       Append a lesson. TAGS are comma-separated (e.g. "backend,auth,tests").
#   ./lessons.sh PLAN.md recall TAGS
#       Print lessons matching any of the comma-separated tags (read at task start).
set -euo pipefail

PLAN="${1:?usage: lessons.sh PLAN.md fail|add|recall ...}"
ACTION="${2:?action: fail|add|recall}"
shift 2
[[ -f "$PLAN" ]] || { echo "ERROR: plan not found: $PLAN" >&2; exit 2; }

# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
apex_resolve "$PLAN"
# The ledger belongs to the plan's checkout (ADR-0003), not the caller's.
LEDGER="${APEX_LESSONS_FILE:-${PLAN_TOP:-$REPO_ROOT}/.claude/apex-scope-loop/LESSONS.md}"

case "$ACTION" in
  fail)
    SIG="${1:?signature required}"
    mkdir -p "$STATE_DIR"
    COUNT="$(python3 - "$STATE_DIR/failures.json" "$SIG" <<'PY'
import json, os, sys
path, sig = sys.argv[1:]
d = json.load(open(path)) if os.path.isfile(path) else {}
d[sig] = d.get(sig, 0) + 1
json.dump(d, open(path, "w"), indent=2)
print(d[sig])
PY
)"
    echo "FAILURE_COUNT: $COUNT ($SIG)"
    if [[ "$COUNT" -ge 2 ]]; then
      echo "RATCHET: FILE_LESSON — '$SIG' has failed $COUNT times. This is a harness gap:"
      echo "         file it with 'lessons.sh $PLAN add ...' and add the guide or sensor that prevents it."
    fi
    ;;

  add)
    TITLE="${1:?title}"; WHAT="${2:?what happened}"; ROOT="${3:?root cause}"; FIX="${4:?harness fix}"; TAGS="${5:-}"
    mkdir -p "$(dirname "$LEDGER")"
    if [[ ! -f "$LEDGER" ]]; then
      cat >"$LEDGER" <<'EOF'
# apex-scope-loop Lessons (append-only)

Filed by the apex-execute loop when a failure repeats (the ratchet — adapted
from The Gibson, Law 9). Newest last. Never rewrite another entry; supersede it
with a new one.
EOF
    fi
    N="$(grep -cE '^## L-[0-9]+' "$LEDGER" || true)"
    ID="$(printf 'L-%03d' $((N + 1)))"
    SLUG="$(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g' | cut -c1-60)"
    TAGLINE="$(printf '%s' "$TAGS" | tr ',' '\n' | sed '/^$/d; s/^ *//; s/ *$//; s/^/#/' | paste -sd' ' -)"
    cat >>"$LEDGER" <<EOF

## $ID · $(date -u +%F) · $SLUG
**What happened:** $WHAT
**Root cause:** $ROOT
**Harness fix:** $FIX
**Plan:** $(basename "$PLAN")
**Tags:** $TAGLINE
EOF
    echo "LESSON: $ID filed -> $LEDGER"
    ;;

  recall)
    TAGS="${1:-}"
    [[ -f "$LEDGER" ]] || { echo "LESSONS: 0 (no ledger yet at $LEDGER)"; exit 0; }
    python3 - "$LEDGER" "$TAGS" <<'PY'
import re, sys
path, tags = sys.argv[1:]
want = {t.strip().lower() for t in tags.split(",") if t.strip()}
blocks = re.split(r"\n(?=## L-\d+)", open(path).read())
hits = []
for b in blocks:
    if not b.startswith("## L-"):
        continue
    m = re.search(r"^\*\*Tags:\*\*(.*)$", b, re.M)
    have = {t.lstrip("#").lower() for t in (m.group(1).split() if m else [])}
    if not want or want & have:
        hits.append(b.strip())
print(f"LESSONS: {len(hits)} matching [{','.join(sorted(want)) or 'all'}]")
for h in hits:
    print()
    print(h)
PY
    ;;

  *) echo "ERROR: unknown action $ACTION" >&2; exit 2 ;;
esac
