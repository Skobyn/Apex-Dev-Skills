# ADR-0001: apex-plan-loop plugin contract

- **Status:** Proposed
- **Date:** 2026-05-22
- **Author:** solutions@getapexinsights.com
- **Plugin:** apex-plan-loop v0.1.0

## Context

The apex repo already had two tightly-coupled skills at `.claude/skills/decide-plan-loop/` and `.claude/skills/dev-plan-loop/`. They form a single workflow: decide produces ADR + plan; dev iterates the plan via `/loop` with bounded swarms. Shipping them as project-only skills hides them from other consumers and couples the workflow to the repo's `.claude/` discovery path. Packaging both as a versioned plugin gives them a distributable, pin-able surface.

## Decision

Bundle both skills into a single plugin `apex-plan-loop` with this contract:

### Layout

```
plugins/apex-plan-loop/
├── .claude-plugin/plugin.json           # name, version, description, author
├── skills/
│   ├── decide-plan-loop/SKILL.md        # ADR + plan authoring (5-stage flow)
│   └── dev-plan-loop/SKILL.md           # /loop iteration over phased plans
├── commands/
│   ├── start.md                         # /apex-plan-loop:start <slug>
│   └── iterate.md                       # /apex-plan-loop:iterate <plan>
├── agents/
│   └── plan-author.md                   # Sonnet subagent for DISCOVER/DRAFT/REFINE
├── scripts/smoke.sh                     # structural contract checks
├── docs/adrs/0001-apex-plan-loop-contract.md
└── README.md
```

### Skill names

Both SKILL.md files use lowercase kebab-case `name:` matching their directory (`decide-plan-loop`, `dev-plan-loop`). Original dev-plan-loop had `name: "Dev Plan Loop Orchestrator"` which is fixed here for plugin compatibility.

### Surface

- **2 skills** — auto-discovered from `skills/` subtree, not enumerated in plugin.json
- **2 slash commands** — `/apex-plan-loop:start`, `/apex-plan-loop:iterate`
- **1 agent** — `plan-author` (Sonnet, single-purpose, delegated from main thread)

### Compatibility

- Claude Code: 2.0+
- Pins to `@claude-flow/cli` v3.6.major.minor when the dev-plan-loop iteration touches claude-flow swarm tools (`swarm_init`, `agent_spawn`, `swarm_status`). The plugin itself does not declare a `@claude-flow/cli` dependency in plugin.json (claude-flow is consumed via npx at runtime by `iterate.sh`).
- Python 3.11+ (matches apex repo's overall toolchain — `decide-plan-loop` `start.sh` and `promote-to-loop.sh` shell out to scripts that may invoke `uv run` in apex contexts).

### Namespace coordination

The plugin reserves a single AgentDB / memory namespace: **`apex-plan-loop`**. Sub-keys:

- `apex-plan-loop:adrs/<slug>` — ADR metadata + status
- `apex-plan-loop:plans/<slug>` — plan checkpoint + completion %
- `apex-plan-loop:outcomes/<slug>/<phase>` — per-phase verdict + trajectory pattern

This follows the namespace convention from ruflo-agentdb ADR-0001 §"Namespace convention" (kebab-case `<plugin-stem>-<intent>`, scoped sub-keys with colons). Coordination expectation: any future plugin that wants to read/write these keys must claim a non-overlapping prefix and reference this ADR.

### MCP tool surface

The plugin does **not** ship its own MCP server. All MCP usage flows through tools the host environment already provides (claude-flow's `swarm_*` and `memory_*`, ruflo's `hooks_*`, etc.). `allowed-tools` lines in SKILL.md/command/agent files are kept conservative — Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion, Agent, ScheduleWakeup — no wildcards, no MCP tools listed (MCP availability is environmental).

### Smoke contract

`scripts/smoke.sh` verifies at minimum 10 structural checks:

1. `plugin.json` exists with `name`, `version`, `description`, `author`, `keywords`
2. `plugin.json` does **not** enumerate `skills`/`commands`/`agents` arrays
3. `skills/decide-plan-loop/SKILL.md` has valid frontmatter with kebab-case `name:`
4. `skills/dev-plan-loop/SKILL.md` has valid frontmatter with kebab-case `name:`
5. Neither SKILL.md uses wildcard tools (`*`, `mcp__*`)
6. `commands/start.md` and `commands/iterate.md` exist with valid frontmatter
7. `agents/plan-author.md` exists with valid frontmatter including `model: sonnet`
8. `README.md` exists with "Compatibility", "Namespace coordination", "Verification", "Architecture Decisions" sections
9. This ADR-0001 exists with `Status: Proposed`
10. All `*.sh` scripts in `skills/*/scripts/` and `scripts/` are executable

The smoke script exits non-zero on any failing check and names the first failure.

## Consequences

### Positive

- Two cohesive skills now travel together — no risk of one shipping without the other, no surface-parity drift between the ADR template and the plan parser
- Versioned: bump `plugin.json` `version:` field to coordinate breaking changes (e.g., new gate types in the plan parser)
- Discoverable via `claude --plugin-dir ./plugins/apex-plan-loop` for testing, and via marketplace publish for distribution

### Negative

- Two copies of the skill content exist: `.claude/skills/<name>/` and `plugins/apex-plan-loop/skills/<name>/`. Until the originals are removed, drift is possible. **Mitigation:** remove `.claude/skills/decide-plan-loop` and `.claude/skills/dev-plan-loop` once the plugin is verified to work (and document this in the README's "Migration" section).
- The plugin assumes the host has `/loop`, `/schedule`, and either claude-flow or the host's built-in swarm machinery. Documented in Compatibility but not enforced at install time.

### Neutral

- `start.sh` in decide-plan-loop references paths like `.claude/tasks/` and `.claude/plans/` — those are project-level conventions that exist outside the plugin. The plugin is opinionated about where ADRs/plans live (apex's existing locations); a future ADR can parameterize this if other repos adopt the plugin.

## Status changes

- 2026-05-22 — Proposed (initial scaffold)
