---
name: token-lens
description: Aggregate per-subagent token and latency attribution from a captured multi-agent trace into a cost report. Use when you need to know WHICH subagent or branch of a swarm burned the token budget or the wall-clock time, when a multi-agent run felt expensive or slow, or when comparing the cost of two orchestration strategies. Trigger on "which agent used the most tokens", "token cost of the swarm", "why was the multi-agent run so expensive", "latency per subagent", "attribute the cost", or any per-subagent cost/latency breakdown of an orchestration from its AgentTrace.
allowed-tools: Bash Read Glob Grep
---

# TokenLens — per-subagent cost attribution

This skill aggregates a captured AgentTrace (see **agent-trace**) into a
per-subagent **cost report**: event counts, tool calls, estimated tokens,
each agent's share of the total, and wall-clock latency. It answers
*"which part of the swarm cost the most?"*

## When to use

- A multi-agent run felt expensive or slow and you want the breakdown.
- You're comparing two orchestration strategies (e.g. flat fan-out vs.
  hierarchical) on token/latency cost.
- You want to spot a runaway subagent that looped and burned budget.

## How to run it

```bash
# Most recent trace
bash "${CLAUDE_PLUGIN_ROOT}/scripts/token-lens.sh"

# …or a specific run
bash "${CLAUDE_PLUGIN_ROOT}/scripts/token-lens.sh" .claude/traces/run-<session>.jsonl
```

It reads the JSONL trace directly (no MCP server required) and prints a
table sorted by token estimate, descending:

| Column | Meaning |
|---|---|
| `subagent` | the agent id (`root` for the main thread) |
| `events` | total recorded hook events for that agent |
| `tools` | number of tool calls (Pre/PostToolUse) |
| `tokens~` | estimated tokens (~4 chars/token of the hook payloads) |
| `share` | that agent's percentage of total estimated tokens |
| `latency_s` | wall-clock span between its first and last event |

A `TOTAL` row closes the table.

## Reading the report

- **The top row is your budget hog.** If one subagent holds 60%+ of the
  tokens, that branch is where optimization pays off — tighten its prompt,
  cap its tool calls, or split it.
- **High `tools` with low `tokens~`** = lots of small calls (chatty agent);
  consider batching. **Low `tools` with high `tokens~`** = a few huge
  payloads (big reads/responses); consider scoping its inputs.
- **`latency_s` vs `tokens~` mismatch** — high latency with low tokens
  points at waiting (slow tool, external call), not generation cost.

## Caveats

- Token counts are **estimates** derived from hook-visible payload sizes
  (~4 chars/token). Use them for *relative* attribution between subagents,
  not for billing — actual model accounting lives in your provider's usage
  API.
- Latency is the first→last event span per agent, so overlapping subagents'
  spans can sum to more than the run's wall clock.
- Override the trace directory with `APEX_TRACE_DIR`.
