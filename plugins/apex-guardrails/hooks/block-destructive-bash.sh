#!/usr/bin/env bash
# apex-guardrails — B1 GuardRail: deny destructive Bash commands before they run.
#
# Reads a PreToolUse hook event on stdin and inspects the Bash tool's `command`
# string. Denies a curated set of irreversible / dangerous patterns:
#   - rm -rf /  and  rm -rf ~   (and $HOME variants)
#   - force-push to main/master
#   - git reset --hard on a protected branch context
#   - curl|wget piped straight into a shell (remote-code-execution vector)
# Enforcement: a denied command is never executed by Claude Code.
set -euo pipefail

EVENT="$(cat)"

# Grab the Bash command. It may contain escaped quotes; we widen the match and
# unescape the common JSON escapes so the regexes below see the real command.
CMD="$(printf '%s' "$EVENT" \
  | tr -d '\n' \
  | { grep -oE "\"command\"[[:space:]]*:[[:space:]]*\"(\\\\.|[^\"\\\\])*\"" || true; } \
  | head -n1 \
  | sed -E 's/^"command"[[:space:]]*:[[:space:]]*"//; s/"$//')"
# Unescape \" \\ and \/ so patterns match plainly.
CMD="$(printf '%s' "$CMD" | sed -E 's/\\"/"/g; s/\\\\/\\/g; s/\\\//\//g')"

if [ -z "$CMD" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
  exit 0
fi

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"apex-guardrails: %s"}}\n' "$1"
  exit 0
}

# 1. Recursive force-delete of root or home.
if printf '%s' "$CMD" | grep -qE 'rm[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+)?-?[a-zA-Z]*f?[a-zA-Z]*[[:space:]]+(/|~|\$HOME|\$\{HOME\})([[:space:]]|$)'; then
  deny "refused destructive 'rm' targeting / or \$HOME — this is irreversible"
fi
# Broader, simpler catch for the canonical forms regardless of flag order.
if printf '%s' "$CMD" | grep -qE 'rm[[:space:]]+-[a-zA-Z]*(rf|fr)[a-zA-Z]*[[:space:]]+(/|~|\$HOME|\$\{HOME\})([[:space:]]|;|&|\||$)'; then
  deny "refused 'rm -rf' on / or \$HOME — this is irreversible"
fi

# 2. Force-push to a protected branch (main/master), any push/force-with-lease form.
if printf '%s' "$CMD" | grep -qE 'git[[:space:]]+push[[:space:]].*(-f|--force|--force-with-lease)'; then
  if printf '%s' "$CMD" | grep -qE '(main|master|HEAD:main|HEAD:master)([[:space:]]|$|:)'; then
    deny "refused force-push to a protected branch (main/master) — coordinate via PR instead"
  fi
fi

# 3. git reset --hard against a protected branch ref.
if printf '%s' "$CMD" | grep -qE 'git[[:space:]]+reset[[:space:]]+--hard'; then
  if printf '%s' "$CMD" | grep -qE '(origin/)?(main|master)([[:space:]]|$)'; then
    deny "refused 'git reset --hard' onto main/master — would discard committed work"
  fi
fi

# 4. Curl/wget piped into a shell — remote code execution.
if printf '%s' "$CMD" | grep -qE '(curl|wget)[[:space:]].*\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|dash|ksh)([[:space:]]|$)'; then
  deny "refused curl/wget piped into a shell — fetch, inspect, then run instead"
fi

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
exit 0
