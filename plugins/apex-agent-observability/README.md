# apex-agent-observability

> Trace, replay, and cost-attribute multi-agent runs: hook-driven JSONL AgentTrace, deterministic OrchestrationReplay, and per-subagent TokenLens — pure artifacts, with an optional read-only MCP dashboard server.

> **See what your swarm actually did.**
> Hook-captured traces, deterministic replay, and per-subagent cost
> attribution for multi-agent runs — as plain on-disk artifacts, with an
> optional read-only dashboard server.

When a Claude Code run fans out into subagents, the transcript tells you the
*story* but hides the *execution graph*: which agent spawned which, in what
order, what each one did, where it stalled, and which branch burned the
budget. **apex-agent-observability** captures every subagent and tool event
as a run-local JSONL trace, then gives you tools to reconstruct and cost it —
no server required, no third-party dependencies, nothing to stand up.

## What it does

Three cohesive sub-features, all built on one JSONL trace:

| # | Feature | Surface | What you get |
|---|---|---|---|
| A1 | **AgentTrace** | hooks + `agent-trace` skill | One JSON line per `SubagentStart`/`SubagentStop`/`PreToolUse`/`PostToolUse` event — timestamp, subagent id, tool, token estimate, and the `parent->child` execution-order edge. Read the timeline to find *where* a multi-agent run went wrong. |
| A2 | **OrchestrationReplay** | `orchestration-replay` skill + `scripts/replay.sh` | Reconstructs the spawn tree and per-subagent tool sequence so a failed run can be analyzed and re-run deterministically. |
| A3 | **TokenLens** | `token-lens` skill + `scripts/token-lens.sh` | Aggregates per-subagent token + latency attribution into a cost report — find the budget hog. |

Plus a `/apex-agent-observability:trace-report` command that runs replay +
token-lens and synthesizes a single report.

Traces land at `${CLAUDE_PROJECT_DIR:-$PWD}/.claude/traces/run-<session>.jsonl`
(override with `APEX_TRACE_DIR`). The hooks are **non-fatal** — a recording
error never blocks the host run.

## MCP (optional)

This plugin ships an **optional, read-only** MCP server at `mcp/server.py`,
declared in `.mcp.json` as `command: python3` with no third-party
dependencies (Python standard library only). **It is not required.** Every
core feature — capturing the trace via hooks, reconstructing the run with
`scripts/replay.sh`, and cost-attributing it with `scripts/token-lens.sh` —
works fully from the on-disk JSONL with no server running.

The server exists solely so an external dashboard (or the agent itself) can
*read* an already-captured trace over MCP. It exposes three read-only tools:

- `list_traces` — available trace files in the trace directory
- `read_trace` — the parsed JSONL records of one trace (defaults to latest)
- `trace_summary` — per-subagent event/token rollup + execution edges

Because the server is optional and environmental, the skills' `allowed-tools`
**never** list `mcp__*` tools. If you don't configure the server, nothing
about tracing, replay, or cost attribution changes. The server only ever
reads the trace files; it never writes them.

## Install

```bash
# From the Apex marketplace
/plugin marketplace add Skobyn/Apex-Dev-Skills
/plugin install apex-agent-observability@apex-dev-skills

# …or test locally against this repo
claude --plugin-dir ./plugins/apex-agent-observability
```

Then `/reload-plugins` (or restart Claude Code) to activate the hooks.

## Quick start

```bash
# 1. Run any multi-agent / subagent task as normal — the hooks capture it
#    to .claude/traces/run-<session>.jsonl automatically.

# 2. When something looks wrong, get the full report:
/apex-agent-observability:trace-report

# …or run the engines directly on the latest trace:
bash plugins/apex-agent-observability/scripts/replay.sh
bash plugins/apex-agent-observability/scripts/token-lens.sh
```

## Compatibility

- **Claude Code:** 2.0+ — requires the `SubagentStart`, `SubagentStop`,
  `PreToolUse`, `PostToolUse` hook events, `${CLAUDE_PLUGIN_ROOT}` expansion
  in hook commands, and (for the optional server only) `.mcp.json` plugin
  MCP discovery.
- **python3:** 3.8+ on `PATH` — used by the hook emitter, the
  replay/token-lens scripts, and the optional MCP server. If python3 is
  missing, the hook degrades to a minimal fallback line and never blocks the
  run.
- **No third-party dependencies** and **no required running service.** The
  MCP server is optional and stdlib-only.

## Namespace coordination

This plugin claims the namespace **`agent-observability`**, following the
kebab-case `<plugin-stem>-<intent>` convention from ruflo-agentdb ADR-0001
§"Namespace convention" and the suite plan in
`.claude/tasks/novel-plugins-suite-adr.md`. Sub-keys:

| Key prefix | Holds |
|---|---|
| `agent-observability:traces/<session>` | the JSONL trace artifact |
| `agent-observability:replay/<session>` | reconstructed orchestration |
| `agent-observability:cost/<session>` | TokenLens cost report |

Any future plugin that wants to read/write these keys must claim a
non-overlapping prefix and reference this plugin's ADR-0001.

## Verification

```bash
bash plugins/apex-agent-observability/scripts/smoke.sh
```

The smoke script runs **12** structural checks (the 10 core checks plus two
MCP checks): plugin.json keys, no enumerated surface arrays, kebab-case skill
names, no wildcard or `mcp__*` `allowed-tools`, command frontmatter, valid
`hooks/hooks.json`, README sections including "MCP (optional)", ADR
`Status: Proposed`, script executability, and that `.mcp.json` is valid JSON
whose referenced server script exists. It exits non-zero on the first failing
check and names what's wrong, printing `smoke passed: 12/12 checks` on
success.

## Architecture Decisions

- [ADR-0001 — apex-agent-observability plugin contract](docs/adrs/0001-apex-agent-observability-contract.md)
  — Status: **Proposed**. Defines the surface, trace schema, namespace, the
  optional read-only MCP server, prior-art comparison
  (`disler/claude-code-hooks-multi-agent-observability`), compatibility, and
  the extended 12-check smoke contract.

## License

MIT — see the repo-level LICENSE.
