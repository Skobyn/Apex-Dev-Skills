#!/usr/bin/env bash
# apex-guardrails — B1 GuardRail: hard-block writes/edits to sensitive paths.
#
# Reads a PreToolUse hook event on stdin (Claude Code hook protocol) and emits a
# permissionDecision. Denies any Write/Edit/MultiEdit/NotebookEdit whose target
# file matches a sensitive-path pattern (.env, **/secrets/**, **/*credential*,
# infra/prod config). This is ENFORCEMENT, not advice: a denied tool call never runs.
set -euo pipefail

EVENT="$(cat)"

# Extract the target file path from the tool input. Covers file_path (Write/Edit),
# notebook_path (NotebookEdit). Pure-shell JSON value grab — no jq dependency.
extract() {
  printf '%s' "$EVENT" \
    | tr -d '\n' \
    | { grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" || true; } \
    | head -n1 \
    | sed -E "s/.*:[[:space:]]*\"([^\"]*)\".*/\1/"
}

TARGET="$(extract file_path)"
[ -n "$TARGET" ] || TARGET="$(extract notebook_path)"

# No path resolved → nothing for this hook to guard; allow and let other hooks run.
if [ -z "$TARGET" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
  exit 0
fi

deny() {
  local reason="$1"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"apex-guardrails: %s"}}\n' "$reason"
  exit 0
}

base="${TARGET##*/}"

# Sensitive-path ruleset (case-insensitive). Each is a hard block.
shopt -s nocasematch || true

case "$TARGET" in
  *.env|*.env.*|*/.env|*/.env.*)
    deny "blocked edit to env file '$TARGET' (secrets live in .env; edit via a secret manager)" ;;
esac

case "$TARGET" in
  */secrets/*|secrets/*)
    deny "blocked edit under a secrets/ directory: '$TARGET'" ;;
esac

case "$base" in
  *credential*|*credentials*)
    deny "blocked edit to a credentials file: '$TARGET'" ;;
esac

case "$base" in
  id_rsa|id_dsa|id_ecdsa|id_ed25519|*.pem|*.key|*.pfx|*.p12)
    deny "blocked edit to a private-key/keystore file: '$TARGET'" ;;
esac

# Production infra config — fail closed on prod manifests/terraform/k8s prod overlays.
case "$TARGET" in
  */infra/prod/*|infra/prod/*|*/prod.tfvars|*.prod.tfvars|*/terraform.tfstate|*/overlays/prod/*)
    deny "blocked edit to production infra config: '$TARGET'" ;;
esac

# Nothing matched → allow.
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
exit 0
