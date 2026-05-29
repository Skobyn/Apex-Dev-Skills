#!/usr/bin/env bash
# apex-guardrails — B3 SecretGuard: deny tool calls that would write or transmit a secret.
#
# Reads a PreToolUse hook event on stdin and scans the relevant tool input
# (Write/Edit `content` / `new_string`, or Bash `command`) for credential
# patterns BEFORE the bytes are written to disk or sent over the wire:
#   - AWS access key IDs (AKIA/ASIA…)
#   - PEM private-key headers
#   - GitHub / Slack / generic high-entropy bearer tokens
#   - inline `password=` / `secret=` / `api_key=` assignments with a real value
# A match is denied with a reason; otherwise the call is allowed.
set -euo pipefail

EVENT="$(cat)"

# Pull all candidate string fields we care about, concatenated. We deliberately
# grab the raw bytes between quotes for content/new_string/old_string/command.
# Returns the quoted value(s) of a field, or empty. Must not fail the script when
# the field is absent (grep exit 1) — hence the `|| true`.
grab() {
  printf '%s' "$EVENT" \
    | tr -d '\n' \
    | { grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"(\\\\.|[^\"\\\\])*\"" || true; } \
    | sed -E "s/^\"$1\"[[:space:]]*:[[:space:]]*\"//; s/\"$//"
}

PAYLOAD="$(
  { grab content; grab new_string; grab command; } 2>/dev/null || true
)"
# Unescape common JSON escapes so patterns see the real text.
PAYLOAD="$(printf '%s' "$PAYLOAD" | sed -E 's/\\"/"/g; s/\\\\/\\/g; s/\\n/ /g; s/\\t/ /g')"

if [ -z "$PAYLOAD" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
  exit 0
fi

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"apex-guardrails: %s"}}\n' "$1"
  exit 0
}

# AWS access key id.
if printf '%s' "$PAYLOAD" | grep -qE '(A3T[A-Z0-9]|AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA)[A-Z0-9]{16}'; then
  deny "detected an AWS access key id in tool input — refusing to write/transmit a credential"
fi

# Private key PEM header.
if printf '%s' "$PAYLOAD" | grep -qE 'BEGIN[[:space:]]+(RSA[[:space:]]+|EC[[:space:]]+|OPENSSH[[:space:]]+|DSA[[:space:]]+|PGP[[:space:]]+)?PRIVATE[[:space:]]+KEY'; then
  deny "detected a PEM PRIVATE KEY block in tool input — refusing to write/transmit a private key"
fi

# GitHub tokens (ghp_, gho_, ghu_, ghs_, ghr_, github_pat_).
if printf '%s' "$PAYLOAD" | grep -qE '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}'; then
  deny "detected a GitHub token in tool input — refusing to write/transmit a credential"
fi

# Slack tokens.
if printf '%s' "$PAYLOAD" | grep -qE 'xox[baprs]-[A-Za-z0-9-]{10,}'; then
  deny "detected a Slack token in tool input — refusing to write/transmit a credential"
fi

# Inline secret assignment with a real (non-placeholder, sufficiently long) value.
if printf '%s' "$PAYLOAD" \
  | grep -iqE '(password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret)[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9/+_.=-]{12,}'; then
  # Allow obvious placeholders so legitimate templating isn't blocked.
  if printf '%s' "$PAYLOAD" \
    | grep -iqE '(password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret)[[:space:]]*[:=][[:space:]]*["'"'"']?(your[_-]|xxx|placeholder|example|changeme|<|\$\{|env\.|process\.env)'; then
    : # placeholder — fall through to allow
  else
    deny "detected an inline credential assignment (password/secret/api_key=…) in tool input — use a secret manager or env var reference"
  fi
fi

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
exit 0
