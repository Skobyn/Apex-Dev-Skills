#!/usr/bin/env bash
# risk-tier.sh — Classify a task's diff into The Gibson's risk tiers (A/B/C)
# and record the result in the checkpoint. Adapted from The Gibson's Law 7
# ("Tier C is sacred") — see docs/GIBSON_HARNESS.md.
#
#   A  routine: docs, tests, isolated components
#   B  elevated: shared modules / API routes, >150 changed lines or >6 files
#   C  money, auth, consent/PII, security boundaries, schema, incident
#      alerting, production data → fan-out + adversarial review AND a human
#      approval (G12) before the task can be checked off
#
# Usage: ./risk-tier.sh PLAN.md LINE_NO [--since SHA] [--tags t1,t2]
#   --since  diff base for this task (the HEAD_SHA from iterate.sh's brief).
#            Default: merge-base of the worktree branch and the base branch.
#   --tags   the task's tags; [security] or [tier:c] force Tier C.
#
# Tier only ratchets upward: a line already recorded as C stays C.
#
# Emits: TIER: A|B|C, then one REASON: line per trigger.
set -euo pipefail

PLAN="${1:?usage: risk-tier.sh PLAN.md LINE_NO [--since SHA] [--tags t1,t2]}"
LINE_NO="${2:?line_no required}"
shift 2
SINCE=""; TAGS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="${2:?}"; shift 2 ;;
    --tags)  TAGS="${2-}"; shift 2 ;;
    *) echo "ERROR: unknown arg $1" >&2; exit 2 ;;
  esac
done
[[ -f "$PLAN" ]] || { echo "ERROR: plan not found: $PLAN" >&2; exit 2; }

# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
apex_resolve "$PLAN"
[[ -f "$CHECKPOINT" ]] || { echo "ERROR: not initialized — run init.sh first" >&2; exit 2; }

WT="$(read_field worktree_path)"; WT="${WT:-$REPO_ROOT}"
BASE_BRANCH="$(read_field base_branch)"

if [[ -z "$SINCE" ]]; then
  SINCE="$(git -C "$WT" merge-base HEAD "$BASE_BRANCH" 2>/dev/null || git -C "$WT" rev-parse HEAD)"
fi

# Committed changes since SINCE plus anything still uncommitted.
FILES="$( { git -C "$WT" diff --name-only "$SINCE" HEAD; git -C "$WT" diff --name-only HEAD; \
            git -C "$WT" ls-files --others --exclude-standard; } 2>/dev/null | sort -u | sed '/^$/d')"
LINES="$( { git -C "$WT" diff --numstat "$SINCE" HEAD; git -C "$WT" diff --numstat HEAD; } 2>/dev/null \
          | awk '$1 ~ /^[0-9]+$/ {s += $1 + $2} END {print s + 0}')"
NFILES="$(printf '%s\n' "$FILES" | sed '/^$/d' | wc -l | tr -d ' ')"

TIER="A"
REASONS=()
raise() { # raise <tier> <reason>
  case "$1$TIER" in C*|BA) TIER="$1" ;; esac
  REASONS+=("$2")
}

# Tier C: path signals (case-insensitive).
C_PATHS='(auth|login|logout|session|oauth|saml|sso|jwt|password|passwd|credential|permission|rbac|acl|role|billing|payment|stripe|paypal|invoice|pricing|checkout|subscription|refund|ledger|wallet|consent|gdpr|ccpa|pii|privacy|personal|migration|migrate|schema|\.sql$|prisma|secret|crypto|encrypt|security|csp|cors|middleware|rate.?limit|webhook|alert|pagerduty|oncall|incident|prod(uction)?[-_.]?(data|db|config))'
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if printf '%s' "$f" | grep -qiE "$C_PATHS"; then
    raise C "tier-c path: $f"
  fi
done <<<"$FILES"

# Tier C: content signals in added lines (catches risk in innocuously named files).
C_CONTENT='(stripe|charge\(|amount_cents|price|currency|bcrypt|argon2|jwt\.|verify_?token|set-cookie|httponly|samesite|csrf|consent|date_of_birth|ssn|social_security|DROP (TABLE|COLUMN)|ALTER TABLE|DELETE FROM|TRUNCATE)'
ADDED="$( { git -C "$WT" diff -U0 "$SINCE" HEAD; git -C "$WT" diff -U0 HEAD; } 2>/dev/null | grep -E '^\+[^+]' || true)"
if [[ -n "$ADDED" ]] && printf '%s' "$ADDED" | grep -qiE "$C_CONTENT"; then
  hit="$(printf '%s' "$ADDED" | grep -oiE "$C_CONTENT" | head -1)"
  raise C "tier-c content signal in diff: '$hit'"
fi

# Tier C: explicit tags.
case ",$TAGS," in
  *,security,*|*,tier:c,*|*,tier-c,*) raise C "task tagged [${TAGS}]" ;;
esac

# Tier B: size and shared-surface signals.
[[ "$LINES" -gt 150 ]] && raise B "diff size: $LINES changed lines (>150)"
[[ "$NFILES" -gt 6 ]] && raise B "diff breadth: $NFILES files (>6)"
if printf '%s\n' "$FILES" | grep -qiE '(^|/)(api|routes?|shared|common|core|lib)/'; then
  raise B "touches a shared module or API route"
fi

# Persist (tier only ratchets upward — diffs may drift into C, never out).
TIER="$(python3 - "$CHECKPOINT" "$LINE_NO" "$TIER" "$SINCE" <<'PY'
import json, sys
path, line_no, tier, since = sys.argv[1:]
s = json.load(open(path))
tiers = s.setdefault("tiers", {})
prev = (tiers.get(line_no) or {}).get("tier", "A")
order = {"A": 0, "B": 1, "C": 2}
final = tier if order[tier] >= order.get(prev, 0) else prev
tiers[line_no] = {"tier": final, "since": since}
json.dump(s, open(path, "w"), indent=2)
print(final)
PY
)"

echo "TIER: $TIER"
echo "DIFF: $NFILES file(s), $LINES line(s) since ${SINCE:0:12}"
if [[ ${#REASONS[@]} -eq 0 ]]; then
  echo "REASON: no elevated-risk signals"
else
  printf 'REASON: %s\n' "${REASONS[@]}" | awk '!seen[$0]++' | head -20
fi
case "$TIER" in
  C) echo "REQUIRES: fan-out review (six lenses) + adversarial refutation + human approval G12 before check-off" ;;
  B) echo "REQUIRES: full six-lens independent review" ;;
  A) echo "REQUIRES: solo independent review" ;;
esac
