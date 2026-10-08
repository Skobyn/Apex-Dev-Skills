#!/usr/bin/env bash
# apex-agent-observability — AgentTrace event recorder (A1)
#
# Invoked by hooks/hooks.json for SubagentStart, SubagentStop, PreToolUse,
# PostToolUse. Reads the hook payload as JSON on stdin and appends ONE
# JSON line per event to a run-local JSONL trace.
#
# Design constraints:
#   - Pure shell + optional python3 for robust JSON. No third-party deps.
#   - Never block the agent: any failure exits 0 so a hook error can't
#     stall the host run. Observability must be non-fatal.
#   - One file per session, keyed off the payload's `session_id` (every hook
#     event carries it), then $APEX_TRACE_SESSION, then "local". Claude Code
#     does not export a session id to hook processes, so the payload is the
#     only reliable key. The key is reduced to [A-Za-z0-9._-] for the filename.
set -euo pipefail

EVENT="${1:-Unknown}"

# Read the hook JSON payload from stdin (may be empty for some events).
PAYLOAD="$(cat 2>/dev/null || true)"

# Trace directory: project-local, overridable. Defaults to .claude/traces.
TRACE_DIR="${APEX_TRACE_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}/.claude/traces}"
mkdir -p "$TRACE_DIR" 2>/dev/null || true

# One trace file per session: payload session_id, then APEX_TRACE_SESSION, then "local".
SESSION=""
if command -v python3 >/dev/null 2>&1; then
  SESSION="$(printf '%s' "$PAYLOAD" | python3 -I "$(dirname "${BASH_SOURCE[0]}")/_emit.py" --session 2>/dev/null || true)"
else
  SESSION="$(printf '%s' "$PAYLOAD" | tr -d '\n' \
    | { grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' || true; } \
    | head -n1 | sed -E 's/.*"([^"]*)"$/\1/')"
fi
[ -n "$SESSION" ] || SESSION="${APEX_TRACE_SESSION:-}"
[ -n "$SESSION" ] || SESSION="local"
SESSION="$(printf '%s' "$SESSION" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-128)"
case "$SESSION" in .|..) SESSION="local" ;; esac
TRACE_FILE="$TRACE_DIR/run-${SESSION}.jsonl"

# Whole-second UTC ISO-8601. Portable across GNU and BSD/macOS date (which
# lacks %N). Second precision is sufficient to order trace events; the
# emitter/scripts only require a parseable ISO timestamp.
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Prefer python3 for correct JSON parsing/emission; fall back to a minimal
# hand-rolled line if python3 is unavailable. The MCP server and the replay
# / token-lens scripts only require valid JSONL, which both paths produce.
if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$PAYLOAD" | python3 "$(dirname "${BASH_SOURCE[0]}")/_emit.py" \
    "$EVENT" "$TS" "$SESSION" >> "$TRACE_FILE" 2>/dev/null || true
else
  # Minimal fallback: no token estimate, no parsed tool name.
  printf '{"ts":"%s","event":"%s","session":"%s","subagent_id":null,"parent_id":null,"agent_type":null,"agent_transcript_path":null,"tool":null,"token_estimate":0,"edge":null}\n' \
    "$TS" "$EVENT" "$SESSION" >> "$TRACE_FILE" 2>/dev/null || true
fi

exit 0
