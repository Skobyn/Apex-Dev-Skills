#!/usr/bin/env python3
"""apex-agent-observability — trace line emitter.

Reads a Claude Code hook JSON payload on stdin and prints exactly one
normalized JSONL trace record on stdout. Pure stdlib; never raises out to
the caller (the hook treats any failure as non-fatal).

Record schema (one JSON object per line):
    ts             ISO-8601 UTC timestamp (passed in by the hook)
    event          SubagentStart | SubagentStop | PreToolUse | PostToolUse
    session        session id
    subagent_id    id of the subagent this event belongs to (or null)
    parent_id      id of the spawning agent, for the execution-order edge
    tool           tool name for *ToolUse events (or null)
    token_estimate rough token count (~chars/4) for attribution
    edge           "parent_id->subagent_id" for Start events, else null
"""
import json
import sys


def estimate_tokens(*chunks):
    """Cheap, dependency-free token estimate: ~4 chars per token."""
    total = 0
    for c in chunks:
        if c is None:
            continue
        if not isinstance(c, str):
            try:
                c = json.dumps(c, separators=(",", ":"))
            except Exception:
                c = str(c)
        total += len(c)
    return total // 4


def main():
    event = sys.argv[1] if len(sys.argv) > 1 else "Unknown"
    ts = sys.argv[2] if len(sys.argv) > 2 else ""
    session = sys.argv[3] if len(sys.argv) > 3 else "local"

    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        payload = {}

    # Field names vary across Claude Code hook versions; probe several.
    def first(*keys):
        for k in keys:
            v = payload.get(k)
            if v not in (None, ""):
                return v
        return None

    subagent_id = first("subagent_id", "subagentId", "agent_id", "agentId")
    parent_id = first("parent_id", "parentId", "parent_agent_id")
    tool = first("tool_name", "toolName", "tool")

    tool_input = payload.get("tool_input") or payload.get("toolInput")
    tool_response = (
        payload.get("tool_response")
        or payload.get("toolResponse")
        or payload.get("tool_result")
    )

    token_estimate = estimate_tokens(tool, tool_input, tool_response,
                                     payload.get("prompt"),
                                     payload.get("transcript"))

    edge = None
    if event == "SubagentStart" and subagent_id is not None:
        edge = "{}->{}".format(parent_id if parent_id is not None else "root",
                               subagent_id)

    record = {
        "ts": ts,
        "event": event,
        "session": session,
        "subagent_id": subagent_id,
        "parent_id": parent_id,
        "tool": tool,
        "token_estimate": token_estimate,
        "edge": edge,
    }
    sys.stdout.write(json.dumps(record, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Non-fatal: emit nothing rather than break the host run.
        pass
