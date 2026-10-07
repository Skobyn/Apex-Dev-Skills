#!/usr/bin/env bash
# apex-guardrails — B1 GuardRail: deny destructive Bash commands before they run.
#
# Reads a PreToolUse hook event on stdin and inspects tool_input.command (only
# that field). Always denies permission-bypass flags (--dangerously-*, --yolo,
# --always-approve, --full-auto), then a curated set of irreversible /
# dangerous patterns:
#   - rm -rf /  and  rm -rf ~   (and $HOME variants)
#   - force-push to main/master
#   - git reset --hard on a protected branch context
#   - curl|wget piped straight into a shell (remote-code-execution vector)
# Enforcement: a denied command is never executed by Claude Code.
set -euo pipefail

EVENT="$(cat)"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# --bypass-only: the policy declares no destructive_bash family, so only the
# always-on bypass-flag denial below runs (compile-policy.sh passes it).
BYPASS_ONLY=false
[ "${1:-}" = "--bypass-only" ] && BYPASS_ONLY=true

allow() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
  exit 0
}
deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"apex-guardrails: %s"}}\n' "$1"
  exit 0
}

# The Bash command is tool_input.command and nothing else: a "command" key
# elsewhere in the event must not hide or replace it. python3 reads exactly that
# field; without python3 we take the first "command" after "tool_input".
HAVE_PY=false
command -v python3 >/dev/null 2>&1 && HAVE_PY=true
if $HAVE_PY; then
  CMD="$(printf '%s' "$EVENT" | python3 -I "$HOOK_DIR/bash_scope.py" command 2>/dev/null || true)"
else
  SCOPED="$(printf '%s' "$EVENT" | tr -d '\n' | sed -n 's/.*"tool_input"[[:space:]]*:[[:space:]]*{//p')"
  CMD="$(printf '%s' "$SCOPED" \
    | { grep -oE "\"command\"[[:space:]]*:[[:space:]]*\"(\\\\.|[^\"\\\\])*\"" || true; } \
    | head -n1 \
    | sed -E 's/^"command"[[:space:]]*:[[:space:]]*"//; s/"$//')"
  # Unescape \" \\ and \/ so patterns match plainly.
  CMD="$(printf '%s' "$CMD" | sed -E 's/\\"/"/g; s/\\\\/\\/g; s/\\\//\//g')"
fi

[ -n "$CMD" ] || allow

# 0. Always on: permission-bypass flags (--dangerously-*, --yolo,
#    --always-approve, --full-auto) passed to any program. Text tools (echo,
#    grep, git commit -m, ...) only mention them, so they are not denied.
if $HAVE_PY; then
  FLAG="$(printf '%s' "$CMD" | python3 -I "$HOOK_DIR/bash_scope.py" bypass 2>/dev/null || true)"
else
  FLAG=""
  first="$(printf '%s' "$CMD" | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//' | awk '{print $1}')"
  first="${first##*/}"
  case "$first" in
    echo|printf|grep|egrep|fgrep|rg|ag|sed|awk|cat|head|tail|less|wc|jq|cut|sort)
      # A text tool alone only mentions the flag; anything chained after it is checked.
      printf '%s' "$CMD" | grep -qE '[;&|`<]|\$\(' || first="__text__" ;;
    git)
      # git can execute (rebase -x, bisect run, aliases): only its message/log forms count as text.
      if printf '%s' "$CMD" | grep -qE '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:]]*/)?git[[:space:]]+(commit|log|tag|notes|show)[[:space:]]' \
         && ! printf '%s' "$CMD" | grep -qE '[;&|`<]|\$\(|(^|[[:space:]])-(x|-exec)([[:space:]=]|$)'; then
        first="__text__"
      fi ;;
  esac
  if [ "$first" != "__text__" ]; then
    FLAG="$(printf '%s' "$CMD" | { grep -oE '(^|[[:space:]=;&|(])--(dangerously-[A-Za-z0-9-]*|yolo|always-approve|full-auto)' || true; } \
      | head -n1 | sed -E 's/^[^-]*//')"
  fi
fi
[ -z "$FLAG" ] || deny "refused permission-bypass flag '$FLAG' — bypass flags are never allowed (always-on rule)"

$BYPASS_ONLY && allow

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

allow
