# ADR-0001: apex-agent-team plugin contract

- **Status:** Proposed
- **Date:** 2026-05-29
- **Author:** solutions@getapexinsights.com
- **Plugin:** apex-agent-team v0.1.0

This ADR realizes theme **E (agent-team coordination)** from the novel-plugins suite ADR at
`.claude/tasks/novel-plugins-suite-adr.md` (suite row: `apex-agent-team | E | E1 TeamLint,
E2 ContextBudget`).

## Context

Multi-agent / subagent runs fail in characteristic, *structural* ways that are invisible until
the run is already underway and expensive to unwind:

- An agent is defined but never wired up, so it never fires (**dead agent**).
- Two agents have near-identical mandates and contend for or duplicate the same work
  (**overlapping responsibility**).
- An agent's prompt assumes a capability its `allowed-tools` does not grant, so it stalls on a
  permission wall (**missing tool grant**).
- An orchestrator spawns agents in parallel with no cap, melting the token budget and tripping
  rate limits (**unbounded fan-out**).

Separately, long agent-team runs hit **context compaction**, which can silently discard the very
state a team depends on — the active phase, who owns what, decisions already made, agreed fan-out
caps — with no warning, causing the team to re-litigate or drift after compaction.

Neither failure mode is addressed by the saturated code-review / test-gen / security-scan plugin
categories. They are specifically about *agent-team configuration and run hygiene*.

## Decision

Ship a single plugin `apex-agent-team` bundling two sub-features:

- **E1 TeamLint** — a `team-lint` skill + `/apex-agent-team:team-lint` command backed by
  `scripts/team-lint.sh`, which **statically** scans `agents/**/*.md` and `.claude/agents/**/*.md`
  before a run and reports the four finding classes above. High-severity findings (missing tool
  grant, unbounded fan-out) cause a non-zero exit so a pre-run gate can block the launch.
- **E2 ContextBudget** — `SessionStart` + `PreCompact` hooks (`hooks/context-budget.sh`) that read
  the hook event on stdin and emit `additionalContext` reminding the team to persist critical
  state before compaction can drop it, plus a heuristic, dependency-free token-budget estimate.

### Layout

```
plugins/apex-agent-team/
├── .claude-plugin/plugin.json              # name, version, description, author, license, keywords
├── skills/
│   └── team-lint/SKILL.md                  # E1 static agent-team audit
├── commands/
│   └── team-lint.md                        # /apex-agent-team:team-lint <path>
├── hooks/
│   ├── hooks.json                          # SessionStart + PreCompact wiring
│   └── context-budget.sh                   # E2 budget/persistence warning
├── scripts/
│   ├── team-lint.sh                        # E1 analyzer
│   └── smoke.sh                            # structural contract checks
├── docs/adrs/0001-apex-agent-team-contract.md
└── README.md
```

### Surface

- **1 skill** — `team-lint`, auto-discovered from `skills/`, not enumerated in plugin.json.
- **1 slash command** — `/apex-agent-team:team-lint [path]`.
- **2 hooks** — `SessionStart`, `PreCompact`, both invoking `context-budget.sh`.
- **0 agents** — this plugin lints agent-team config; it does not ship agents of its own.

### Compatibility

- Claude Code: 2.0+ (requires the `SessionStart` / `PreCompact` hook events and
  `${CLAUDE_PLUGIN_ROOT}` substitution).
- Dependency-free: `team-lint.sh` and `context-budget.sh` use only bash + coreutils
  (`find`, `grep`, `awk`, `sed`, `wc`). No `jq`, no `npx`, no network.
- ruflo is optional: ContextBudget *suggests* persisting via `memory_store` when available, but
  works without it.

### MCP tool surface

The plugin ships **no** MCP server. `allowed-tools` in `team-lint`'s SKILL.md is the explicit
conservative list `Bash Read Glob Grep` — no `*`, no `mcp__*`. The command file inherits the
session's tools but constrains itself to the same surface.

### Namespace coordination

The plugin claims the AgentDB / memory namespace **`agent-team-coord`**, following the kebab-case
`<plugin-stem>-<intent>` convention from the suite ADR (`.claude/tasks/novel-plugins-suite-adr.md`
Q3 decision) and ruflo-agentdb ADR-0001 §"Namespace convention". Sub-keys:

- `agent-team-coord:lint/<scan-path-hash>` — last TeamLint findings + severity counts.
- `agent-team-coord:budget/<session-id>` — last observed budget estimate + persisted-state notes.

Any future plugin reading/writing these keys must claim a non-overlapping prefix and reference
this ADR.

### Smoke contract

`scripts/smoke.sh` verifies these structural checks and prints `smoke passed: N/N checks`:

1. `plugin.json` exists with `name` (== `apex-agent-team`), `version`, `description`, `author`,
   `license`, `keywords`.
2. `plugin.json` does **not** enumerate `skills` / `commands` / `agents` arrays.
3. `skills/team-lint/SKILL.md` has unquoted kebab-case `name:` matching its directory.
4. No SKILL.md uses a wildcard (`*` / `mcp__*`) in `allowed-tools`.
5. `commands/team-lint.md` exists with frontmatter `name:` (== filename) + `description:`.
6. `hooks/hooks.json` is valid JSON.
7. `README.md` has `## Compatibility`, `## Namespace coordination`, `## Verification`,
   `## Architecture Decisions` sections.
8. This ADR-0001 exists with `Status: Proposed`.
9. All `*.sh` under `scripts/`, `skills/`, and `hooks/` are executable.
10. The TeamLint analyzer runs against a self-scan without crashing.

It exits non-zero on the first failing check and names the failure.

## Consequences

### Positive

- Structural agent-team failures surface **before** a run, when they are cheap to fix.
- Compaction can no longer silently erase team state without at least a warning.
- Entirely static / dependency-free, so it runs anywhere bash does and adds no supply chain.

### Negative

- TeamLint is heuristic: implied-capability and overlap detection can false-positive (deliberate
  redundancy) or miss dynamically-named agents. Mitigation: only two checks gate (exit non-zero);
  the rest are advisory.
- The token-budget estimate is bytes/4 against the transcript, not the host's real context
  accounting. It is a "getting full" signal, not a precise meter. Mitigation: documented as
  heuristic; thresholds are conservative.

### Neutral

- The plugin ships no agents of its own by design — adding one later would extend, not break, the
  smoke contract (which asserts the *absence* of an enumerated `agents` array, not the absence of
  agent files).

## Status changes

- 2026-05-29 — Proposed (initial scaffold).
