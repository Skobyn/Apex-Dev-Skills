---
name: trace-report
description: Produce a full observability report for a captured multi-agent run — spawn tree, per-subagent tool sequence, and token/latency cost attribution. Pass an optional trace path as $ARGUMENTS (defaults to the most recent trace).
argument-hint: "[trace-file.jsonl]"
---

You are generating an **AgentTrace report** for a multi-agent run.

Target trace: `$ARGUMENTS` (if empty, use the most recent trace in the
trace directory — default `${CLAUDE_PROJECT_DIR:-$PWD}/.claude/traces/`).

Do the following:

1. **Locate the trace.** If `$ARGUMENTS` is empty, list candidates with
   `ls -1t .claude/traces/*.jsonl` and pick the newest. If none exist,
   tell the user no trace was captured yet (the hooks record one only when
   a run uses subagents) and stop.

2. **Reconstruct the orchestration** (OrchestrationReplay / A2):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/replay.sh" $ARGUMENTS
   ```

   Summarize the spawn tree and each subagent's tool sequence, and call out
   the last event (where progress stopped).

3. **Attribute the cost** (TokenLens / A3):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/token-lens.sh" $ARGUMENTS
   ```

   Surface the top token-consuming subagent and any latency/token mismatch.

4. **Synthesize.** Combine both into a short report:
   - **Shape** — did the decomposition match the task? Any missing branch?
   - **Where it went wrong** — the stall point from step 2.
   - **Where the budget went** — the cost hog from step 3.
   - **Recommendation** — one concrete next action (re-run, re-decompose,
     scope a subagent's inputs, etc.).

The scripts read the JSONL trace directly; the optional MCP server is not
required for this command. If the user wants the raw timeline semantics,
point them at the `agent-trace` skill.
