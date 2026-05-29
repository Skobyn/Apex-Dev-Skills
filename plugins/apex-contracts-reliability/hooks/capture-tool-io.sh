#!/usr/bin/env bash
# apex-contracts-reliability — capture-tool-io
#
# A single hook bound to BOTH PreToolUse and PostToolUse for every tool ("*").
# It reads the hook event JSON on stdin and appends one normalized record per
# call to a local JSONL ledger. The ledger is the shared substrate for the two
# features this plugin ships:
#
#   F1 ToolContractCheck — infers a lightweight schema per tool from the shape
#      of recorded inputs, then flags CONTRACT DRIFT when a later call diverges
#      (new field, missing field, type change).
#   F2 FlakeGuard — detects NON-DETERMINISTIC behavior (retries, partial tool
#      failures, a call that succeeds then later fails) from the same ledger.
#
# Design constraints:
#   - NEVER block a tool call. This hook is observational only; on any error it
#     emits an allow/continue verdict and exits 0 so the agent is never wedged.
#   - Dependency-free: bash + python3 stdlib only. python3 does the JSON shape
#     inference; if python3 is absent we degrade to a raw-line append.
#   - Append-only JSONL. One line per event. Analysis (scripts/analyze-ledger.sh)
#     reads it after the fact — the hot path stays cheap.
set -euo pipefail

EVENT="$(cat)"

# Ledger location. Respect an override; otherwise keep it project-local under
# .claude/contracts-reliability/ so it travels with the repo and is easy to gitignore.
LEDGER_DIR="${APEX_CR_LEDGER_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}/.claude/contracts-reliability}"
LEDGER="${LEDGER_DIR}/ledger.jsonl"

# Emit a non-blocking verdict and exit. PreToolUse expects an allow decision;
# PostToolUse has no decision surface, so a bare exit 0 is correct there. We
# print the allow envelope unconditionally — Claude Code ignores the
# permissionDecision field on PostToolUse, and it keeps PreToolUse non-blocking.
pass() {
  printf '{"hookSpecificOutput":{"hookEventName":"%s","permissionDecision":"allow"}}\n' "${1:-PreToolUse}" 2>/dev/null || true
  exit 0
}

mkdir -p "$LEDGER_DIR" 2>/dev/null || pass "PreToolUse"

# Best path: python3 normalizes the event into a compact ledger record and
# captures the *shape* (field name -> JSON type) of the tool input + output,
# which is exactly what schema-drift inference needs.
if command -v python3 >/dev/null 2>&1; then
  # NOTE: the event is passed via the APEX_CR_EVENT env var, NOT stdin — the
  # heredoc below already occupies python3's stdin, so reading sys.stdin here
  # would yield the script body, not the hook event.
  APEX_CR_EVENT="$EVENT" APEX_CR_LEDGER="$LEDGER" python3 - <<'PY' 2>/dev/null || {
import json, os, time

raw = os.environ.get("APEX_CR_EVENT", "")
try:
    ev = json.loads(raw)
except Exception:
    ev = {}

def shape(v, depth=0):
    """Return a JSON-type shape for a value. Objects map field -> type
    (one level deep, then collapse to 'object'); everything else is its type."""
    if isinstance(v, dict):
        if depth >= 1:
            return "object"
        return {k: shape(val, depth + 1) for k, val in v.items()}
    if isinstance(v, list):
        return "array"
    if isinstance(v, bool):
        return "boolean"
    if isinstance(v, (int, float)):
        return "number"
    if v is None:
        return "null"
    return "string"

phase = ev.get("hook_event_name") or ev.get("hookEventName") or "Unknown"
tool = ev.get("tool_name") or ev.get("toolName") or "unknown"
tool_input = ev.get("tool_input") or ev.get("toolInput") or {}
tool_resp = ev.get("tool_response")
if tool_resp is None:
    tool_resp = ev.get("toolResponse")

# Infer success/failure from the response envelope where present.
ok = None
err = None
if isinstance(tool_resp, dict):
    if "error" in tool_resp and tool_resp["error"]:
        ok, err = False, str(tool_resp["error"])[:240]
    elif tool_resp.get("is_error") or tool_resp.get("isError"):
        ok, err = False, "is_error flag set"
    elif "success" in tool_resp:
        ok = bool(tool_resp["success"])
    else:
        ok = True
elif isinstance(tool_resp, str):
    low = tool_resp.lower()
    if low.startswith("error") or "traceback (most recent" in low:
        ok, err = False, tool_resp[:240]
    else:
        ok = True

rec = {
    "ts": round(time.time(), 3),
    "phase": phase,                 # PreToolUse | PostToolUse
    "tool": tool,
    "input_shape": shape(tool_input),
    "session": ev.get("session_id") or ev.get("sessionId") or "",
}
if phase in ("PostToolUse",):
    rec["output_shape"] = shape(tool_resp) if tool_resp is not None else "null"
    rec["ok"] = ok
    if err:
        rec["error"] = err

with open(os.environ["APEX_CR_LEDGER"], "a", encoding="utf-8") as fh:
    fh.write(json.dumps(rec, separators=(",", ":")) + "\n")
PY
    # python3 present but the heredoc failed — fall through to raw append.
    printf '%s\n' "$EVENT" >> "$LEDGER" 2>/dev/null || true
  }
else
  # Degraded mode: no python3. Persist the raw event so nothing is lost; the
  # analyzer tolerates raw lines (it skips anything it cannot parse as a record).
  printf '%s\n' "$EVENT" >> "$LEDGER" 2>/dev/null || true
fi

# Determine which phase we're in for the verdict envelope.
PHASE="$(printf '%s' "$EVENT" | tr -d '\n' \
  | grep -oE '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -n1 | sed -E 's/.*:"([^"]*)"/\1/')"
pass "${PHASE:-PreToolUse}"
