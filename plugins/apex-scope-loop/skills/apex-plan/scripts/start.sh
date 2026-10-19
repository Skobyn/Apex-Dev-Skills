#!/usr/bin/env bash
# start.sh — Bootstrap a new apex-plan ADR + plan from templates.
#
# Usage:
#   ./start.sh <kebab-slug> "<Title>" [--scope bugfix|poc|feature] [--force]
#
# Creates:
#   .claude/tasks/<slug>-adr.md   (from resources/templates/profiles/<profile>/adr-template.md)
#   .claude/plans/<slug>-plan.md  (from resources/templates/profiles/<profile>/plan-template.md)
#
# Template profile (resources/templates/profiles/{generic,apex}/):
#   APEX_PLAN_PROFILE=generic|apex  → use that profile (explicit override)
#   unset, .claude/agent-coord-config.json exists in the repo root → apex
#   otherwise                       → generic
#   Any other APEX_PLAN_PROFILE value is an error.
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
#   {{SCOPE}}             → bugfix | poc | feature (default feature)
#
# Scope: bugfix and poc use the lean templates (adr-template-lean.md, plan-template-lean.md);
# feature uses the full templates. An unknown scope exits non-zero and writes nothing.
#
# Refuses to overwrite existing files. Use `--force` to overwrite.

set -euo pipefail

usage() { echo "Usage: $0 <kebab-slug> \"<Title>\" [--scope bugfix|poc|feature] [--force]" >&2; }

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

SLUG="$1"
TITLE="$2"
shift 2
FORCE=""
SCOPE="feature"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE="--force"; shift ;;
    --scope)
      if [[ $# -lt 2 ]]; then echo "Error: --scope needs a value (bugfix|poc|feature)" >&2; exit 1; fi
      SCOPE="$2"; shift 2 ;;
    --scope=*) SCOPE="${1#--scope=}"; shift ;;
    *) echo "Error: unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done
case "$SCOPE" in
  bugfix|poc|feature) ;;
  *)
    echo "Error: unknown scope '$SCOPE'. Use bugfix, poc or feature. Nothing was written." >&2
    exit 1
    ;;
esac

# Validate slug
if ! [[ "$SLUG" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
  echo "Error: slug must be kebab-case (lowercase letters, digits, hyphens). Got: $SLUG" >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Select the template profile.
PROFILE="${APEX_PLAN_PROFILE:-}"
if [[ -z "$PROFILE" ]]; then
  if [[ -f "$REPO_ROOT/.claude/agent-coord-config.json" ]]; then
    PROFILE="apex"
  else
    PROFILE="generic"
  fi
fi
case "$PROFILE" in
  generic|apex) ;;
  *)
    echo "Error: APEX_PLAN_PROFILE must be 'generic' or 'apex'. Got: $PROFILE" >&2
    exit 1
    ;;
esac
TEMPLATES="$SKILL_DIR/resources/templates/profiles/$PROFILE"
SUFFIX=""
[[ "$SCOPE" == "feature" ]] || SUFFIX="-lean"
ADR_TEMPLATE="$TEMPLATES/adr-template${SUFFIX}.md"
PLAN_TEMPLATE="$TEMPLATES/plan-template${SUFFIX}.md"
if [[ ! -f "$ADR_TEMPLATE" || ! -f "$PLAN_TEMPLATE" ]]; then
  echo "Error: templates missing for profile '$PROFILE' under $TEMPLATES" >&2
  exit 1
fi

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
export SLUG TITLE SCOPE DATE AUTHOR_EMAIL NNNN
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
    "{{SCOPE}}":             os.environ["SCOPE"],
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

substitute "$ADR_TEMPLATE" "$ADR_PATH"
substitute "$PLAN_TEMPLATE" "$PLAN_PATH"

echo "PROFILE: $PROFILE"
echo "SCOPE: $SCOPE"
echo "ADR:  $ADR_PATH"
echo "PLAN: $PLAN_PATH"
echo
echo "Next steps:"
echo "  1. Walk through Stage 3 (REFINE) with the user — fill every [ TODO ] and resolve every Open Question"
echo "  2. Flip ADR status from 'Proposed' to 'Accepted' when refinement is complete"
echo "  3. Run: $SKILL_DIR/scripts/promote-to-loop.sh $SLUG"
