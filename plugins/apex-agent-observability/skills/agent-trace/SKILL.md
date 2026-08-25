---
name: agent-trace
description: Read and interpret an AgentTrace timeline to reconstruct WHERE a multi-agent or subagent run went wrong. Use when a swarm / subagent orchestration produced a bad or confusing result and you need to see the execution-order edges (which agent spawned which, in what order) and the per-agent tool sequence. Trigger on "why did the swarm fail", "trace the subagents", "what order did the agents run", "the multi-agent run went sideways", or when debugging any run that fanned out into Agent/subagent calls. The trace is captured automatically by this plugin's hooks as JSONL — no setup needed beyond installing the plugin.
allowed-tools: Bash Read Glob Grep
---

# AgentTrace — read the multi-agent timeline

This plugin's hooks (`SubagentStart`, `SubagentStop`, `PreToolUse`,
`PostToolUse`) append **one JSON line per event** to a run-local trace at
`.claude/traces/run-<session>.jsonl`. This skill explains how to read that
timeline and pinpoint where a multi-agent run derailed.

## What gets recorded

Each line is a JSON object:

| Field | Meaning |
|---|---|
| `ts` | ISO-8601 UTC timestamp (orders the timeline) |
| `event` | `SubagentStart` / `SubagentStop` / `PreToolUse` / `PostToolUse` |
| `session` | the Claude Code session id |
| `subagent_id` | which subagent the event belongs to (or `null` for root) |
| `parent_id` | the agent that spawned this one |
| `tool` | tool name for tool-use events |
| `token_estimate` | rough token count (~chars/4) for the payload |
| `edge` | `parent->child` for `SubagentStart`, the execution-order edge |

## How to read it

1. **Find the trace.** Default location is
   `${CLAUDE_PROJECT_DIR:-$PWD}/.claude/traces/`. List them:

   ```bash
   ls -1t .claude/traces/*.jsonl
   ```

   Pick the most recent (or the session that misbehaved).

2. **Reconstruct the spawn tree from the edges.** Every `SubagentStart`
   carries an `edge` like `root->agent-7`. Read them in `ts` order and you
   have the decomposition: who spawned whom, when. A subtree that never
   appears is a branch the orchestrator *decided not to take* — often the
   bug ("it never spawned the reviewer").

   ```bash
   grep '"event":"SubagentStart"' .claude/traces/run-*.jsonl
   ```

3. **Walk each subagent's tool sequence.** Filter `PreToolUse` lines for a
   given `subagent_id`; the ordered `tool` values are exactly what that
   agent did. A subagent that goes `Read -> Read -> Read` and never
   `Edit`s is stuck in analysis; one that `Edit`s before it `Read`s is
   acting on stale assumptions.

4. **Find the stall.** The **last** line in the file is where the run
   stopped making progress. If it's a `PreToolUse` with no matching
   `PostToolUse`, a tool call hung or errored.

For a structured rebuild of steps 2–4, hand the trace to the
**orchestration-replay** skill / `scripts/replay.sh`. For token blame, use
**token-lens** / `scripts/token-lens.sh`.

## Worked diagnosis pattern

> Symptom: "the swarm returned an answer but ignored half the task."

- Count `SubagentStart` edges. Fewer children than the plan called for →
  the orchestrator under-decomposed. The trace proves it spawned 2 agents
  for a 4-part task.
- For each child, check whether its tool sequence touched the files /
  resources its slice required. A child that only ran `Glob` and stopped
  never actually did its slice.

## Notes

- The hooks are **non-fatal**: if recording fails the host run is never
  blocked, so an empty/partial trace just means less signal, never a crash.
- The optional MCP server (see the README's "MCP (optional)" section) can
  surface the same JSONL to an external dashboard, but everything here
  works with plain `ls` / `grep` / `cat` on the files.
- Override the trace location with `APEX_TRACE_DIR` if you keep traces
  outside `.claude/traces`.
