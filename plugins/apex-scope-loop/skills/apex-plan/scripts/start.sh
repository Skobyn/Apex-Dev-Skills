#!/usr/bin/env bash
# start.sh — Bootstrap a new apex-plan ADR + plan from templates.
#
# Usage:
#   ./start.sh <kebab-slug> "<Title>"
#
# Creates:
#   .claude/tasks/<slug>-adr.md   (from resources/templates/adr-template.md)
#   .claude/plans/<slug>-plan.md  (from resources/templates/plan-template.md)
#
# Substitutions performed:
#   {{SLUG}}              → <slug>
#   {{TITLE}}             → <Title>
#   {{DATE}}              → YYYY-MM-DD (today, UTC)
#   {{AUTHOR_EMAIL}}      → git config user.email
#   {{REVIEWER_EMAIL}}    → AUTHOR_EMAIL (override in ADR after DISCOVER round 4)
#   {{IMPLEMENTOR_EMAIL}} → AUTHOR_EMAIL (override in ADR after DISCOVER round 4)
#   {{NNNN}}              → next ADR number (max of existing ADRs + 1, zero-padded)
#   {{TARGET_DATE}}       → "TBD" (override during refinement)
#   {{GOAL_ONE_SENTENCE}} → "TBD — fill during refinement"
#   {{BOUNDED_CONTEXTS}}  → "TBD — fill during refinement"
#
# Refuses to overwrite existing files. Use `--force` to overwrite.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <kebab-slug> \"<Title>\" [--force]" >&2
  exit 1
fi

SLUG="$1"
TITLE="$2"
FORCE="${3:-}"

# Validate slug
if ! [[ "$SLUG" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
  echo "Error: slug must be kebab-case (lowercase letters, digits, hyphens). Got: $SLUG" >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATES="$SKILL_DIR/resources/templates"

TASKS_DIR="$REPO_ROOT/.claude/tasks"
PLANS_DIR="$REPO_ROOT/.claude/plans"

mkdir -p "$TASKS_DIR" "$PLANS_DIR"

ADR_PATH="$TASKS_DIR/${SLUG}-adr.md"
PLAN_PATH="$PLANS_DIR/${SLUG}-plan.md"

if [[ -e "$ADR_PATH" && "$FORCE" != "--force" ]]; then
  echo "Error: $ADR_PATH already exists. Pass --force to overwrite." >&2
  exit 1
fi
if [[ -e "$PLAN_PATH" && "$FORCE" != "--force" ]]; then
  echo "Error: $PLAN_PATH already exists. Pass --force to overwrite." >&2
  exit 1
fi

# Gather substitution values
DATE="$(date -u +%Y-%m-%d)"
AUTHOR_EMAIL="$(git config user.email 2>/dev/null || echo 'unknown@local')"

# Compute next ADR number: highest existing ADR-NNNN in .claude/tasks/, +1
NEXT_N=1
if compgen -G "$TASKS_DIR/*-adr.md" > /dev/null; then
  HIGHEST="$(grep -hE '^# ADR-[0-9]+' "$TASKS_DIR"/*-adr.md 2>/dev/null \
    | grep -oE 'ADR-[0-9]+' | grep -oE '[0-9]+' \
    | sort -n | tail -1 || echo 0)"
  NEXT_N=$((HIGHEST + 1))
fi
NNNN="$(printf '%04d' "$NEXT_N")"

# Use Python for safe in-place substitution. Bash/perl substitution corrupts
# strings containing '@', '$', '\', etc. — and ADR templates contain email
# addresses, so this matters.
export SLUG TITLE DATE AUTHOR_EMAIL NNNN
substitute() {
  local src="$1"
  local dst="$2"
  python3 - "$src" "$dst" <<'PY'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
mapping = {
    "{{SLUG}}":              os.environ["SLUG"],
    "{{slug}}":              os.environ["SLUG"],
    "{{TITLE}}":             os.environ["TITLE"],
    "{{DATE}}":              os.environ["DATE"],
    "{{AUTHOR_EMAIL}}":      os.environ["AUTHOR_EMAIL"],
    "{{REVIEWER_EMAIL}}":    os.environ["AUTHOR_EMAIL"],
    "{{IMPLEMENTOR_EMAIL}}": os.environ["AUTHOR_EMAIL"],
    "{{NNNN}}":              os.environ["NNNN"],
    "{{TARGET_DATE}}":       "TBD",
    "{{GOAL_ONE_SENTENCE}}": "TBD - fill during refinement",
    "{{BOUNDED_CONTEXTS}}":  "TBD - fill during refinement",
}
text = open(src).read()
for placeholder, value in mapping.items():
    text = text.replace(placeholder, value)
open(dst, "w").write(text)
PY
}

substitute "$TEMPLATES/adr-template.md" "$ADR_PATH"
substitute "$TEMPLATES/plan-template.md" "$PLAN_PATH"

echo "ADR:  $ADR_PATH"
echo "PLAN: $PLAN_PATH"
echo
echo "Next steps:"
echo "  1. Walk through Stage 3 (REFINE) with the user — fill every [ TODO ] and resolve every Open Question"
echo "  2. Flip ADR status from 'Proposed' to 'Accepted' when refinement is complete"
echo "  3. Run: $SKILL_DIR/scripts/promote-to-loop.sh $SLUG"
