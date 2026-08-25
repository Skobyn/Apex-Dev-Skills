---
name: orchestration-replay
description: Reconstruct the decomposition and tool sequence of a captured multi-agent run so a failed orchestration can be analyzed and re-run deterministically. Use after a swarm / subagent run failed and you want to replay exactly what happened — the spawn tree, each subagent's ordered tool calls, and the point where progress stopped — rather than re-prompting blind. Trigger on "replay the run", "reconstruct the orchestration", "re-run the swarm the same way", "what exactly did the agents do step by step", or when preparing a deterministic re-run of a failed multi-agent task from its AgentTrace.
allowed-tools: Bash Read Glob Grep
---

# OrchestrationReplay — rebuild and re-run a multi-agent run

This skill turns a captured AgentTrace (see the **agent-trace** skill) into
a deterministic reconstruction of *what the orchestration did*, so a failed
run can be analyzed and replayed step-by-step instead of re-prompted from
scratch.

## When to use

- A swarm/subagent run failed or produced a wrong result and you want the
  exact sequence, not a vague recollection.
- You want to re-run the *same* decomposition deterministically (same spawn
  tree, same per-agent tool order) to confirm a fix.
- You're writing a postmortem and need the ground-truth call graph.

## How to run it

```bash
# Most recent trace in .claude/traces/
bash "${CLAUDE_PLUGIN_ROOT}/scripts/replay.sh"

# …or a specific run
bash "${CLAUDE_PLUGIN_ROOT}/scripts/replay.sh" .claude/traces/run-<session>.jsonl
```

The script reads the JSONL trace directly (no MCP server required) and
prints three deterministically-ordered sections:

1. **Decomposition / spawn tree** — every `parent->child` edge in execution
   order. This is the orchestrator's decomposition, recovered from the
   `SubagentStart` events.
2. **Per-subagent tool sequence** — for each agent (root + children), the
   ordered list of tools it invoked.
3. **Last recorded event** — where the run stopped advancing (the failure
   locus).

## Turning the reconstruction into a deterministic re-run

The output is the recipe:

1. **Re-spawn the tree from section 1.** Launch the same subagents in the
   same order. If section 1 shows fewer children than the task needed, the
   *decomposition itself* was the bug — fix the orchestration prompt before
   replaying.
2. **Feed each subagent its tool sequence from section 2.** Replaying the
   same ordered tool calls against the same inputs reproduces the run; the
   first place behavior diverges is your regression point.
3. **Inspect section 3.** The last event tells you whether the run died
   mid-tool-call (hung/errored tool) or simply stopped (premature
   `SubagentStop`).

## Tips

- Replay is read-only and side-effect free — it only reads the trace file.
- For *cost* of the run rather than its shape, use the **token-lens** skill.
- If the trace is empty, the hooks captured nothing: confirm the plugin's
  hooks are active and that the failed run actually used subagents.
- Override the trace directory with `APEX_TRACE_DIR`.
