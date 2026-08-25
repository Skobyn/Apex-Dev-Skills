# ADR-0001: apex-agent-observability plugin contract

- **Status:** Proposed
- **Date:** 2026-05-29
- **Author:** solutions@getapexinsights.com
- **Plugin:** apex-agent-observability v0.1.0

## Context

Multi-agent / subagent orchestration is the strongest researched gap in the
Claude Code plugin ecosystem (see `.claude/tasks/novel-plugins-suite-adr.md`).
When a run fans out into subagents, the operator loses the thread: which
agent spawned which, in what order, what tools each one called, where the
run stalled, and which branch burned the token budget. The transcript shows
the *narrative* but not the *execution graph*, and once the session ends the
signal is gone.

**Prior art.** The most visible existing project here is
`disler/claude-code-hooks-multi-agent-observability`, a hooks-based observer
that streams agent events to a separate Bun/Vue server + SQLite dashboard
for live visualization. It is excellent for a live wall-board but requires
standing up and running an external service, and it centers on *streaming to
a UI* rather than producing a durable, on-disk artifact you can replay.

**How this plugin differs.** `apex-agent-observability` is a **pure-artifact,
zero-service** install that bundles three cohesive sub-features the prior art
does not ship together:

- **AgentTrace (A1)** — hooks append one JSON line per event to a run-local
  JSONL file on disk. No server, no database, no network. The artifact *is*
  the product.
- **OrchestrationReplay (A2)** — a skill + script that reconstructs the
  decomposition and per-subagent tool sequence from the trace so a failed
  run can be analyzed and re-run deterministically. (The prior art
  visualizes; this *replays*.)
- **TokenLens (A3)** — a skill + script that aggregates per-subagent
  token/latency attribution into a cost report.

The MCP server is **optional** and **read-only**: it only exposes the
already-captured JSONL to an external dashboard. Everything — capture,
replay, cost attribution — works with `ls`/`grep`/`cat` and the bundled
scripts if no MCP server is configured. This keeps the install a pure
artifact (markdown + shell + one stdlib python script) with no third-party
dependencies and no required running process.

## Decision

Ship one plugin, `apex-agent-observability`, with this contract.

### Layout

```
plugins/apex-agent-observability/
├── .claude-plugin/plugin.json            # name, version, description, author, keywords
├── .mcp.json                             # OPTIONAL read-only MCP server (python3, stdlib)
├── mcp/server.py                         # stdlib-only JSON-RPC/MCP stdio server
├── hooks/
│   ├── hooks.json                        # SubagentStart/Stop, Pre/PostToolUse
│   ├── trace-event.sh                    # appends one JSONL line per event
│   └── _emit.py                          # stdlib JSON normalizer for trace-event.sh
├── skills/
│   ├── agent-trace/SKILL.md              # A1 — read the timeline
│   ├── orchestration-replay/SKILL.md     # A2 — reconstruct + re-run
│   └── token-lens/SKILL.md               # A3 — cost attribution
├── commands/trace-report.md              # /apex-agent-observability:trace-report
├── scripts/
│   ├── replay.sh                         # A2 engine
│   ├── token-lens.sh                     # A3 engine
│   └── smoke.sh                          # extended 12-check structural contract
├── docs/adrs/0001-apex-agent-observability-contract.md
└── README.md
```

### Surface

- **3 skills** — `agent-trace`, `orchestration-replay`, `token-lens`,
  auto-discovered from `skills/`, not enumerated in plugin.json.
- **1 command** — `/apex-agent-observability:trace-report [trace]`.
- **4 hooks** — `SubagentStart`, `SubagentStop`, `PreToolUse`,
  `PostToolUse`, all routed to `hooks/trace-event.sh`.
- **1 optional MCP server** — `apex-agent-observability`, `command: python3`
  running `mcp/server.py` (read-only: `list_traces`, `read_trace`,
  `trace_summary`).

### Trace schema

One JSON object per line at
`${APEX_TRACE_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}/.claude/traces}/run-<session>.jsonl`:
`ts`, `event`, `session`, `subagent_id`, `parent_id`, `tool`,
`token_estimate`, `edge` (the `parent->child` execution-order edge for
`SubagentStart`).

### MCP tool surface

The plugin ships an **optional** read-only MCP server. `allowed-tools` in
the SKILL.md files **never** list `mcp__*` tools — MCP availability is
environmental and the server is optional; the skills must work without it.
The hooks and scripts depend only on Bash + python3 stdlib. No third-party
packages.

### Compatibility

- Claude Code: 2.0+ (requires hook events `SubagentStart`, `SubagentStop`,
  `PreToolUse`, `PostToolUse`, `${CLAUDE_PLUGIN_ROOT}` expansion in hook
  commands, and `.mcp.json` plugin MCP discovery for the optional server).
- python3 3.8+ on `PATH` — used by the hook emitter, the replay/token-lens
  scripts, and the optional MCP server. If python3 is absent, the hook
  degrades to a minimal fallback line and the run is never blocked.
- No `@claude-flow/cli` or ruflo dependency; the plugin observes whatever
  subagent machinery the host uses.

### Namespace coordination

This plugin claims the AgentDB / memory + on-disk-artifact namespace
**`agent-observability`**, following the kebab-case `<plugin-stem>-<intent>`
convention from ruflo-agentdb ADR-0001 §"Namespace convention" and the
suite plan in `.claude/tasks/novel-plugins-suite-adr.md`. Sub-keys:

- `agent-observability:traces/<session>` — the JSONL trace artifact
- `agent-observability:replay/<session>` — reconstructed orchestration
- `agent-observability:cost/<session>` — TokenLens cost report

Any future plugin reading/writing these keys must claim a non-overlapping
prefix and reference this ADR.

### Smoke contract (extended — 12 checks)

`scripts/smoke.sh` verifies, exiting non-zero on the first failure with a
named reason and printing `smoke passed: 12/12 checks` on success:

1. `plugin.json` exists with `name`, `version`, `description`, `author`,
   `keywords`.
2. `plugin.json` does **not** enumerate `skills`/`commands`/`agents` arrays.
3. Each `skills/*/SKILL.md` has unquoted kebab-case `name:` matching its dir.
4. No SKILL.md `allowed-tools` uses a wildcard (`*`).
5. `commands/trace-report.md` has `name:` + `description:` frontmatter.
6. `hooks/hooks.json` exists and is valid JSON.
7. `README.md` has the required sections including "MCP (optional)".
8. This ADR-0001 exists with `Status: Proposed`.
9. All `*.sh` scripts are executable.
10. The four expected skill dirs / surfaces are present.
11. `.mcp.json` is valid JSON and its referenced server script exists.
12. No SKILL.md `allowed-tools` contains `mcp__*`.

## Consequences

### Positive

- **Zero-service install.** Trace, replay, and cost attribution all work
  from on-disk JSONL with no running process and no third-party deps.
- **Durable artifact.** The trace outlives the session and is replayable —
  postmortems and deterministic re-runs become possible.
- **Cohesive bundle.** Capture + replay + cost ship together, so there's no
  drift between the trace schema the hooks write and what the tools read.
- **Optional, decoupled UI path.** Teams that want a live dashboard can wire
  in the read-only MCP server without changing how capture works.

### Negative

- Token figures are **estimates** (~4 chars/token from hook payloads), not
  provider-accurate billing. Documented as relative-attribution-only.
- Hook payload field names vary across Claude Code versions; `_emit.py`
  probes several aliases but a future event-shape change could blank a
  field. Mitigated by the non-fatal design (missing fields → `null`, never
  a crash).
- The optional MCP server is stdlib-only and hand-rolls a minimal subset of
  the MCP JSON-RPC surface; it is intentionally read-only and not a general
  MCP host.

### Neutral

- Traces live under `.claude/traces/` by project convention, overridable via
  `APEX_TRACE_DIR`. A future ADR can parameterize retention/rotation.

## Status changes

- 2026-05-29 — Proposed (initial scaffold).
