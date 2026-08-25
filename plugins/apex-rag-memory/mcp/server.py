#!/usr/bin/env python3
"""apex-rag-memory OPTIONAL MCP server (stdlib-only, JSON-RPC 2.0 over stdio).

This server is the ONLY component that reaches a live vector store. It is
deliberately optional: the memory-doctor and eval-harness skills give full
value from the repo alone. When configured, this server adds *live* checks
that cannot be done from on-disk artifacts:

  - rag_stats:  report the live index's dimension, vector count, and the
                embedder id recorded at build time (drift confirmation).
  - rag_search: run a query against the live store and return ranked doc ids,
                producing the `retrieved` lines that measure-recall.sh consumes.

No third-party dependencies. The actual store binding is intentionally a thin,
configurable shim: point RAG_STORE_CMD at a command that speaks the simple line
protocol below, or rely on the built-in stub that degrades gracefully (returns
an explicit "no live store configured" result instead of crashing).

Store shim protocol (optional external command via env RAG_STORE_CMD):
  - stats:  RAG_STORE_CMD prints one JSON object: {"dimension":..,"count":..,"embedder":..}
  - search: RAG_STORE_CMD reads a query on argv and prints a JSON array of doc ids.

Run standalone:  python3 mcp/server.py
"""
import json
import os
import subprocess
import sys

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "apex-rag-memory"
SERVER_VERSION = "0.1.0"

TOOLS = [
    {
        "name": "rag_stats",
        "description": (
            "Report the live vector index's dimension, vector count, and "
            "build-time embedder id. Use to CONFIRM embedding drift that "
            "memory-doctor flagged from config alone."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
    },
    {
        "name": "rag_search",
        "description": (
            "Query the live vector store and return ranked doc ids. Output is "
            "shaped for eval-harness measure-recall.sh "
            '({"id": <qid>, "retrieved": [...]}).'
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "The query text."},
                "id": {"type": "string", "description": "Optional question id to echo back."},
                "k": {"type": "integer", "description": "Top-k to return (default 5)."},
            },
            "required": ["query"],
            "additionalProperties": False,
        },
    },
]


def _store_cmd():
    return os.environ.get("RAG_STORE_CMD", "").strip()


def do_stats():
    cmd = _store_cmd()
    if not cmd:
        return {
            "live": False,
            "note": "no live store configured (set RAG_STORE_CMD); findings remain repo-only",
        }
    try:
        out = subprocess.run(
            cmd.split() + ["stats"],
            capture_output=True, text=True, timeout=30, check=True,
        ).stdout.strip()
        data = json.loads(out)
        data["live"] = True
        return data
    except Exception as exc:  # noqa: BLE001 - report, never crash the server
        return {"live": False, "error": f"store stats failed: {exc}"}


def do_search(args):
    query = args.get("query", "")
    qid = args.get("id", "")
    k = int(args.get("k", 5))
    cmd = _store_cmd()
    if not cmd:
        return {
            "id": qid,
            "retrieved": [],
            "live": False,
            "note": "no live store configured (set RAG_STORE_CMD); supply results JSONL manually",
        }
    try:
        out = subprocess.run(
            cmd.split() + ["search", query, str(k)],
            capture_output=True, text=True, timeout=30, check=True,
        ).stdout.strip()
        ids = json.loads(out)
        if not isinstance(ids, list):
            raise ValueError("store search must return a JSON array of doc ids")
        return {"id": qid, "retrieved": ids[:k], "live": True}
    except Exception as exc:  # noqa: BLE001
        return {"id": qid, "retrieved": [], "live": False, "error": f"store search failed: {exc}"}


def handle(req):
    method = req.get("method")
    rid = req.get("id")
    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": rid,
            "result": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            },
        }
    if method in ("notifications/initialized", "initialized"):
        return None  # notification, no response
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}}
    if method == "tools/call":
        params = req.get("params", {})
        name = params.get("name")
        args = params.get("arguments", {}) or {}
        if name == "rag_stats":
            payload = do_stats()
        elif name == "rag_search":
            payload = do_search(args)
        else:
            return {
                "jsonrpc": "2.0", "id": rid,
                "error": {"code": -32601, "message": f"unknown tool: {name}"},
            }
        return {
            "jsonrpc": "2.0", "id": rid,
            "result": {"content": [{"type": "text", "text": json.dumps(payload)}]},
        }
    return {
        "jsonrpc": "2.0", "id": rid,
        "error": {"code": -32601, "message": f"method not found: {method}"},
    }


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        resp = handle(req)
        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
