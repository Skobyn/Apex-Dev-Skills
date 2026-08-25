#!/usr/bin/env bash
# apex-agent-team :: ContextBudget (E2)
# SessionStart + PreCompact hook. Reads the hook JSON event on stdin and emits a
# heuristic context-budget warning so an agent-team run persists critical state
# BEFORE compaction silently drops it.
#
# Dependency-free: bash + standard tools only. Never hard-fails the session — on any
# parse trouble it degrades to a generic reminder and exits 0.
set -euo pipefail

# --- read the event payload (Claude Code pipes hook JSON on stdin) ----------
PAYLOAD="$(cat 2>/dev/null || true)"

# Extract a JSON string field without jq: best-effort grep/sed. Returns "" if absent.
# Must never fail under set -e/pipefail — a missing field is normal.
json_str() {
  # $1 = field name
  local match
  match="$(printf '%s' "$PAYLOAD" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 || true)"
  [ -z "$match" ] && { printf ''; return 0; }
  printf '%s' "$match" | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/'
}

EVENT="$(json_str hook_event_name)"
[ -z "$EVENT" ] && EVENT="$(json_str hookEventName)"
TRIGGER="$(json_str trigger)"            # PreCompact: "manual" | "auto"
TRANSCRIPT="$(json_str transcript_path)"

# --- heuristic budget estimate from the transcript, if reachable ------------
# Rough token estimate ~= bytes / 4. Soft ceiling is a heuristic, not the real
# context window — we only need a "getting full" signal, not an exact count.
EST_TOKENS=0
SOFT_CEILING=160000   # heuristic warn threshold (~80% of a 200k window)
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  BYTES="$(wc -c < "$TRANSCRIPT" 2>/dev/null | tr -d ' ' || echo 0)"
  EST_TOKENS=$(( BYTES / 4 ))
fi

PCT=0
if [ "$SOFT_CEILING" -gt 0 ]; then
  PCT=$(( EST_TOKENS * 100 / SOFT_CEILING ))
fi

# --- build the reminder message (single line; JSON string must contain no raw newlines) ---
REMINDER="[apex-agent-team/ContextBudget] Compaction can SILENTLY drop critical agent-team state. Before continuing, persist: active plan/phase and per-agent task ownership; decisions already made (so they are not re-litigated); in-flight tool results, IDs, and file paths the swarm depends on; agreed spawn caps / fan-out limits. Write these to a durable note (task file or memory_store), not just context."

# PreCompact is the high-value moment: state is about to be discarded.
if [ "$EVENT" = "PreCompact" ] || [ -n "$TRIGGER" ]; then
  TRIG_NOTE=""
  [ -n "$TRIGGER" ] && TRIG_NOTE=" (trigger: $TRIGGER)"
  BUDGET_NOTE=""
  if [ "$EST_TOKENS" -gt 0 ]; then
    BUDGET_NOTE="Estimated transcript size ~${EST_TOKENS} tokens (~${PCT}% of a ~${SOFT_CEILING}-token soft budget). "
  fi
  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreCompact",
    "additionalContext": "${BUDGET_NOTE}${REMINDER}${TRIG_NOTE}"
  }
}
EOF
  exit 0
fi

# SessionStart: surface the budget posture and the persistence reminder as context.
BUDGET_LINE="ContextBudget active. "
if [ "$EST_TOKENS" -gt 0 ]; then
  if [ "$PCT" -ge 100 ]; then
    BUDGET_LINE="ContextBudget WARNING: estimated ~${EST_TOKENS} tokens already exceeds the ~${SOFT_CEILING}-token soft budget — persist critical state now. "
  else
    BUDGET_LINE="ContextBudget active (~${EST_TOKENS} tokens, ~${PCT}% of soft budget). "
  fi
fi

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "${BUDGET_LINE}Before a multi-agent run, persist plan/phase, ownership, decisions, and any fan-out caps to durable storage so compaction cannot silently drop them."
  }
}
EOF
exit 0
