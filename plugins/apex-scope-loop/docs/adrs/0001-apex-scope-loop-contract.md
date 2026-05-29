# ADR-0001: apex-scope-loop plugin contract

- **Status:** Proposed
- **Date:** 2026-05-22
- **Author:** solutions@getapexinsights.com
- **Plugin:** apex-scope-loop v0.1.0

## Context

The apex repo already had two tightly-coupled skills at `.claude/skills/apex-plan/` and `.claude/skills/apex-execute/`. They form a single workflow: decide produces ADR + plan; dev iterates the plan via `/loop` with bounded swarms. Shipping them as project-only skills hides them from other consumers and couples the workflow to the repo's `.claude/` discovery path. Packaging both as a versioned plugin gives them a distributable, pin-able surface.

## Decision

Bundle both skills into a single plugin `apex-scope-loop` with this contract:

### Layout

```
plugins/apex-scope-loop/
├── .claude-plugin/plugin.json           # name, version, description, author
├── skills/
│   ├── apex-plan/SKILL.md        # ADR + plan authoring (5-stage flow)
│   └── apex-execute/SKILL.md           # /loop iteration over phased plans
├── commands/
│   ├── start.md                         # /apex-scope-loop:start <slug>
│   └── iterate.md                       # /apex-scope-loop:iterate <plan>
├── agents/
│   └── plan-author.md                   # Sonnet subagent for SCOPE/COMPOSE/OPTIMIZE
├── scripts/smoke.sh                     # structural contract checks
├── docs/adrs/0001-apex-scope-loop-contract.md
└── README.md
```

### Skill names

Both SKILL.md files use lowercase kebab-case `name:` matching their directory (`apex-plan`, `apex-execute`). The skill now named `apex-execute` originally carried `name: "Dev Plan Loop Orchestrator"`, fixed to kebab-case here for plugin compatibility.

### Surface

- **2 skills** — auto-discovered from `skills/` subtree, not enumerated in plugin.json
- **2 slash commands** — `/apex-scope-loop:start`, `/apex-scope-loop:iterate`
- **1 agent** — `plan-author` (Sonnet, single-purpose, delegated from main thread)

### Worktree-bound execution

The execution stage (`apex-execute`) is **worktree-bound by contract**. `init.sh` provisions a single git worktree at `.dev-plan-state/<plan-hash>/worktree` on a dedicated branch `apex-scope-loop/<slug>`, forked from a base branch (`APEX_BASE_BRANCH`, default `main` → `master` → current HEAD). The whole plan — every phase — runs inside that one worktree; no phase work touches the base branch's working tree. The checkpoint records `worktree_path`, `worktree_branch`, `base_branch`, and `landed`.

- `iterate.sh` emits `WORKTREE:` / `BRANCH:` on every brief and refuses to proceed (`STATUS: ERROR`) if the recorded worktree has gone missing.
- The orchestrator dispatches all swarm agents scoped to the worktree path.
- When the final gate passes (plan fully checked), `land.sh` merges `apex-scope-loop/<slug>` into the base branch with `--no-ff` and removes the worktree. That merge is the only point at which generated code reaches the base branch.

`.dev-plan-state/` is gitignored, so the worktree lives outside tracked content. An escape hatch (`APEX_NO_WORKTREE=1`) runs execution in the base checkout for environments without git, but it is off the supported path.

### Compatibility

- Claude Code: 2.0+
- Pins to `@claude-flow/cli` v3.6.major.minor when the apex-execute iteration touches claude-flow swarm tools (`swarm_init`, `agent_spawn`, `swarm_status`). The plugin itself does not declare a `@claude-flow/cli` dependency in plugin.json (claude-flow is consumed via npx at runtime by `iterate.sh`).
- Python 3.11+ (matches apex repo's overall toolchain — `apex-plan` `start.sh` and `promote-to-loop.sh` shell out to scripts that may invoke `uv run` in apex contexts).

### Namespace coordination

The plugin reserves a single AgentDB / memory namespace: **`apex-scope-loop`**. Sub-keys:

- `apex-scope-loop:adrs/<slug>` — ADR metadata + status
- `apex-scope-loop:plans/<slug>` — plan checkpoint + completion %
- `apex-scope-loop:outcomes/<slug>/<phase>` — per-phase verdict + trajectory pattern

This follows the namespace convention from ruflo-agentdb ADR-0001 §"Namespace convention" (kebab-case `<plugin-stem>-<intent>`, scoped sub-keys with colons). Coordination expectation: any future plugin that wants to read/write these keys must claim a non-overlapping prefix and reference this ADR.

### MCP tool surface

The plugin does **not** ship its own MCP server. All MCP usage flows through tools the host environment already provides (claude-flow's `swarm_*` and `memory_*`, ruflo's `hooks_*`, etc.). `allowed-tools` lines in SKILL.md/command/agent files are kept conservative — Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion, Agent, ScheduleWakeup — no wildcards, no MCP tools listed (MCP availability is environmental).

### Smoke contract

`scripts/smoke.sh` verifies at minimum 10 structural checks:

1. `plugin.json` exists with `name`, `version`, `description`, `author`, `keywords`
2. `plugin.json` does **not** enumerate `skills`/`commands`/`agents` arrays
3. `skills/apex-plan/SKILL.md` has valid frontmatter with kebab-case `name:`
4. `skills/apex-execute/SKILL.md` has valid frontmatter with kebab-case `name:`
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
- Discoverable via `claude --plugin-dir ./plugins/apex-scope-loop` for testing, and via marketplace publish for distribution

### Negative

- Two copies of the skill content exist: `.claude/skills/<name>/` and `plugins/apex-scope-loop/skills/<name>/`. Until the originals are removed, drift is possible. **Mitigation:** remove `.claude/skills/apex-plan` and `.claude/skills/apex-execute` once the plugin is verified to work (and document this in the README's "Migration" section).
- The plugin assumes the host has `/loop`, `/schedule`, and either claude-flow or the host's built-in swarm machinery. Documented in Compatibility but not enforced at install time.

### Neutral

- `start.sh` in apex-plan references paths like `.claude/tasks/` and `.claude/plans/` — those are project-level conventions that exist outside the plugin. The plugin is opinionated about where ADRs/plans live (apex's existing locations); a future ADR can parameterize this if other repos adopt the plugin.

## Status changes

- 2026-05-22 — Proposed (initial scaffold)
- 2026-05-29 — Renamed plugin `apex-plan-loop` → `apex-scope-loop`; relabeled the authoring stages to spell **SCOPE** (Scope, Compose, Optimize, Plan, Execute).
- 2026-05-29 — Renamed the two skills: `decide-plan-loop` → `apex-plan`, `dev-plan-loop` → `apex-execute` (directories, frontmatter `name:`, the execution memory namespace, and all cross-references). The `promote-to-loop.sh` handoff mechanism is unchanged.
- 2026-05-29 — Made execution worktree-bound: `init.sh` provisions an isolated worktree + branch per plan, `iterate.sh` reports/enforces it, and new `land.sh` merges the branch into the base branch after the final gate. Added `worktree_path`/`worktree_branch`/`base_branch`/`landed` to the checkpoint schema.
