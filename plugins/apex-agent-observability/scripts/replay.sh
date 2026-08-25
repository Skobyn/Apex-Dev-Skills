#!/usr/bin/env bash
# apex-agent-observability — OrchestrationReplay (A2)
#
# Reads a captured AgentTrace JSONL file and reconstructs the
# decomposition / tool sequence of a multi-agent run so a failed run can
# be analyzed and re-run deterministically.
#
# Usage:
#   scripts/replay.sh [TRACE_FILE]
#       TRACE_FILE  path to a run-*.jsonl trace. If omitted, the most
#                   recent trace in the trace dir is used.
#
# Output (stdout): a human-readable, deterministically-ordered replay:
#   1. the spawn tree (parent -> child edges, in execution order)
#   2. the per-subagent tool call sequence
#   3. the point where the run last made progress (last event)
#
# Pure shell + python3 (stdlib). No third-party deps. The MCP server is
# NOT required — this reads the JSONL directly.
set -euo pipefail

TRACE_DIR="${APEX_TRACE_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}/.claude/traces}"

trace_file="${1:-}"
if [ -z "$trace_file" ]; then
  trace_file="$(ls -1t "$TRACE_DIR"/*.jsonl 2>/dev/null | head -n1 || true)"
fi

if [ -z "$trace_file" ] || [ ! -f "$trace_file" ]; then
  echo "replay: no trace file found (looked in: $TRACE_DIR)" >&2
  echo "        run a multi-agent task first so the hooks capture a trace," >&2
  echo "        or pass a trace path explicitly: scripts/replay.sh <file>" >&2
  exit 1
fi

python3 - "$trace_file" <<'PY'
import json, sys

path = sys.argv[1]
records = []
with open(path, encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except Exception:
            continue

print("OrchestrationReplay for: {}".format(path))
print("=" * 60)
if not records:
    print("(trace is empty — no events were captured)")
    sys.exit(0)

# 1. Spawn tree, in execution order.
print("\n[1] Decomposition / spawn tree (execution order)")
edges = [r for r in records if r.get("edge")]
if edges:
    for r in edges:
        print("    {}  ({})".format(r["edge"], r.get("ts", "")))
else:
    print("    (no SubagentStart edges recorded — single-agent run)")

# 2. Per-subagent tool sequence.
print("\n[2] Per-subagent tool call sequence")
seq = {}
order = []
for r in records:
    sid = r.get("subagent_id") or "root"
    if sid not in seq:
        seq[sid] = []
        order.append(sid)
    if r.get("event") == "PreToolUse" and r.get("tool"):
        seq[sid].append(r["tool"])
for sid in order:
    tools = seq[sid]
    label = "root agent" if sid == "root" else "subagent {}".format(sid)
    if tools:
        print("    {}: {}".format(label, " -> ".join(tools)))
    else:
        print("    {}: (no tool calls)".format(label))

# 3. Last point of progress.
print("\n[3] Last recorded event (where the run stopped advancing)")
last = records[-1]
print("    event={event} subagent={sid} tool={tool} ts={ts}".format(
    event=last.get("event"),
    sid=last.get("subagent_id"),
    tool=last.get("tool"),
    ts=last.get("ts"),
))

print("\nTo re-run deterministically: replay the spawn tree in [1] and feed")
print("each subagent the tool sequence in [2]. Inspect [3] for the failure.")
PY
