#!/usr/bin/env python3
"""apex-agent-observability — OPTIONAL read-only MCP server.

This server is NOT required. The hooks (AgentTrace) and the skills
(OrchestrationReplay, TokenLens) work fully without it — they read and
write plain JSONL trace files on disk. This server exists only so an
external dashboard (or the agent itself) can READ a captured trace over
MCP without shelling out.

It speaks the Model Context Protocol over stdio using JSON-RPC 2.0, hand
-rolled with the Python standard library only (no `mcp`, no third-party
deps). It exposes three read-only tools:

    list_traces   -> available trace files in the trace dir
    read_trace    -> the parsed JSONL records of one trace
    trace_summary -> per-subagent event/token rollup + execution edges

Trace directory resolution (read-only — the server never writes traces):
    $APEX_TRACE_DIR, else $CLAUDE_PROJECT_DIR/.claude/traces, else
    $PWD/.claude/traces.
"""
import json
import os
import sys
import glob

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "apex-agent-observability"
SERVER_VERSION = "0.1.0"


def trace_dir():
    base = os.environ.get("APEX_TRACE_DIR")
    if base:
        return base
    proj = os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd())
    return os.path.join(proj, ".claude", "traces")


def list_trace_files():
    d = trace_dir()
    return sorted(glob.glob(os.path.join(d, "*.jsonl")))


def load_trace(path):
    records = []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    records.append(json.loads(line))
                except Exception:
                    continue
    except OSError:
        pass
    return records


def resolve_trace_path(name):
    """Map a requested name to a file inside the trace dir (no traversal)."""
    d = trace_dir()
    if not name:
        files = list_trace_files()
        return files[-1] if files else None
    safe = os.path.basename(name)
    if not safe.endswith(".jsonl"):
        safe += ".jsonl"
    candidate = os.path.join(d, safe)
    return candidate if os.path.isfile(candidate) else None


def summarize(records):
    per_agent = {}
    edges = []
    for r in records:
        sid = r.get("subagent_id") or "root"
        a = per_agent.setdefault(sid, {
            "subagent_id": sid,
            "parent_id": r.get("parent_id"),
            "events": 0,
            "tool_calls": 0,
            "token_estimate": 0,
        })
        a["events"] += 1
        a["token_estimate"] += int(r.get("token_estimate") or 0)
        if r.get("event") in ("PreToolUse", "PostToolUse"):
            a["tool_calls"] += 1
        if r.get("edge"):
            edges.append(r["edge"])
    return {
        "agents": list(per_agent.values()),
        "edges": edges,
        "total_events": len(records),
        "total_token_estimate": sum(
            int(r.get("token_estimate") or 0) for r in records
        ),
    }


# ---- MCP tool definitions -------------------------------------------------

TOOLS = [
    {
        "name": "list_traces",
        "description": "List available AgentTrace JSONL files in the trace directory.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "read_trace",
        "description": "Return the parsed JSONL records of one trace (defaults to most recent).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Trace file name, e.g. run-<session>.jsonl. Omit for latest.",
                }
            },
        },
    },
    {
        "name": "trace_summary",
        "description": "Per-subagent event/token rollup plus execution-order edges for one trace.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Trace file name. Omit for the most recent trace.",
                }
            },
        },
    },
]


def call_tool(name, args):
    args = args or {}
    if name == "list_traces":
        files = [os.path.basename(p) for p in list_trace_files()]
        return {"trace_dir": trace_dir(), "traces": files}
    if name == "read_trace":
        path = resolve_trace_path(args.get("name"))
        if not path:
            return {"error": "no matching trace", "trace_dir": trace_dir()}
        return {"trace": os.path.basename(path), "records": load_trace(path)}
    if name == "trace_summary":
        path = resolve_trace_path(args.get("name"))
        if not path:
            return {"error": "no matching trace", "trace_dir": trace_dir()}
        summary = summarize(load_trace(path))
        summary["trace"] = os.path.basename(path)
        return summary
    raise ValueError("unknown tool: {}".format(name))


# ---- JSON-RPC / MCP plumbing ---------------------------------------------

def make_result(req_id, result):
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


def make_error(req_id, code, message):
    return {"jsonrpc": "2.0", "id": req_id,
            "error": {"code": code, "message": message}}


def handle(req):
    method = req.get("method")
    req_id = req.get("id")
    params = req.get("params") or {}

    if method == "initialize":
        return make_result(req_id, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        })
    if method in ("notifications/initialized", "initialized"):
        return None  # notification: no response
    if method == "ping":
        return make_result(req_id, {})
    if method == "tools/list":
        return make_result(req_id, {"tools": TOOLS})
    if method == "tools/call":
        name = params.get("name")
        try:
            payload = call_tool(name, params.get("arguments"))
        except Exception as exc:  # noqa: BLE001
            return make_result(req_id, {
                "content": [{"type": "text", "text": "error: {}".format(exc)}],
                "isError": True,
            })
        return make_result(req_id, {
            "content": [{
                "type": "text",
                "text": json.dumps(payload, indent=2, default=str),
            }],
            "isError": False,
        })

    if req_id is not None:
        return make_error(req_id, -32601, "method not found: {}".format(method))
    return None


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception:
            continue
        resp = handle(req)
        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
