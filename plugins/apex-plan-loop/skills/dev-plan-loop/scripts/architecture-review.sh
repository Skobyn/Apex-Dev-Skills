#!/usr/bin/env bash
# architecture-review.sh — Weekly architecture drift check (called by /schedule).
# Surfaces a brief for the model to spawn a reviewer/architect swarm and
# write findings to dev-plan-loop memory.
#
# Usage: ./architecture-review.sh path/to/plan.md
set -euo pipefail

PLAN="${1:?usage: architecture-review.sh PLAN.md}"
[[ -f "$PLAN" ]] || { echo "ERROR: plan not found"; exit 1; }

PLAN_ABS="$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")"
PLAN_HASH="$(printf '%s' "$PLAN_ABS" | shasum -a 256 | cut -c1-12)"
STATE_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.dev-plan-state/$PLAN_HASH"

WEEK_TAG="$(date -u +%G-W%V)"
REVIEW_FILE="$STATE_DIR/architecture-reviews/$WEEK_TAG.md"
mkdir -p "$(dirname "$REVIEW_FILE")"

# Files changed in last 7 days (relative to plan repo)
REPO="$(git -C "$(dirname "$PLAN_ABS")" rev-parse --show-toplevel 2>/dev/null || pwd)"
CHANGED=$(git -C "$REPO" log --since='7 days ago' --pretty=format: --name-only 2>/dev/null | sort -u | grep -v '^$' || true)
COMMITS=$(git -C "$REPO" log --since='7 days ago' --pretty=format:'%h %s (%an)' 2>/dev/null || true)

cat <<EOF
==== weekly architecture review ($WEEK_TAG) ====
Plan        : $PLAN
Repo        : $REPO
Output      : $REVIEW_FILE

Briefing for review swarm (spawn: reviewer + system-architect + security-architect):

GOAL: Read the design intent in $PLAN, then check the last 7 days of code
changes against it. Flag drift in three buckets:
  1. STRUCTURAL — files moved outside their bounded context, layering violations
  2. INTENT     — code does not match the plan's stated acceptance criteria
  3. RISK       — security, performance, or coupling regressions vs. the plan

INPUTS:
- Plan: $PLAN
- Files changed (7d):
$(echo "$CHANGED" | head -40 | sed 's/^/  /')
$([ "$(echo "$CHANGED" | wc -l)" -gt 40 ] && echo "  ... ($(echo "$CHANGED" | wc -l) total)")

- Commits (7d):
$(echo "$COMMITS" | head -20 | sed 's/^/  /')

OUTPUT:
- Write findings to $REVIEW_FILE (one bullet per finding, tagged S/I/R)
- Store summary in memory namespace dev-plan-loop, key=arch-review-$WEEK_TAG
- If any RISK findings: append to MEMORY.md as a project memory
EOF
