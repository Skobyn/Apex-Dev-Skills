#!/usr/bin/env bash
# apex-agent-observability — TokenLens (A3)
#
# Aggregates per-subagent token + latency attribution from a captured
# AgentTrace JSONL file into a cost report. Answers "which subagent burned
# the budget" for a multi-agent run.
#
# Usage:
#   scripts/token-lens.sh [TRACE_FILE]
#       TRACE_FILE  path to a run-*.jsonl trace. If omitted, the most
#                   recent trace in the trace dir is used.
#
# Output (stdout): a per-subagent table of event count, tool calls,
# estimated tokens, share of total tokens, and wall-clock span (latency)
# derived from first/last event timestamps.
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
  echo "token-lens: no trace file found (looked in: $TRACE_DIR)" >&2
  echo "            run a multi-agent task first, or pass a path:" >&2
  echo "            scripts/token-lens.sh <file>" >&2
  exit 1
fi

python3 - "$trace_file" <<'PY'
import json, sys
from datetime import datetime

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

def parse_ts(s):
    if not s:
        return None
    s = s.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(s)
    except Exception:
        return None

agg = {}
for r in records:
    sid = r.get("subagent_id") or "root"
    a = agg.setdefault(sid, {"events": 0, "tools": 0, "tokens": 0,
                             "first": None, "last": None})
    a["events"] += 1
    a["tokens"] += int(r.get("token_estimate") or 0)
    if r.get("event") in ("PreToolUse", "PostToolUse"):
        a["tools"] += 1
    ts = parse_ts(r.get("ts"))
    if ts:
        if a["first"] is None or ts < a["first"]:
            a["first"] = ts
        if a["last"] is None or ts > a["last"]:
            a["last"] = ts

total_tokens = sum(a["tokens"] for a in agg.values()) or 1

print("TokenLens cost report for: {}".format(path))
print("=" * 72)
if not records:
    print("(trace is empty — no events were captured)")
    sys.exit(0)

hdr = "{:<22} {:>7} {:>7} {:>9} {:>7} {:>10}".format(
    "subagent", "events", "tools", "tokens~", "share", "latency_s")
print(hdr)
print("-" * 72)

def latency(a):
    if a["first"] and a["last"]:
        return (a["last"] - a["first"]).total_seconds()
    return 0.0

for sid, a in sorted(agg.items(), key=lambda kv: kv[1]["tokens"], reverse=True):
    share = 100.0 * a["tokens"] / total_tokens
    label = "root" if sid == "root" else str(sid)
    print("{:<22} {:>7} {:>7} {:>9} {:>6.1f}% {:>10.3f}".format(
        label[:22], a["events"], a["tools"], a["tokens"], share, latency(a)))

print("-" * 72)
print("{:<22} {:>7} {:>7} {:>9}".format(
    "TOTAL", sum(a["events"] for a in agg.values()),
    sum(a["tools"] for a in agg.values()), total_tokens))
print("\nToken counts are estimates (~4 chars/token) derived from hook")
print("payloads. Use them for relative attribution, not billing.")
PY
