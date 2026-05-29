# apex-agent-team

> Agent-team coordination tooling: TeamLint statically audits subagent/agent-team config before a run, and ContextBudget hooks warn before compaction silently drops critical state.

> **Catch the broken team before it runs — and don't let compaction eat its memory.**
> Two pre-flight safety nets for multi-agent work: a static linter for your agent-team
> configuration, and a budget watchdog that warns before context compaction silently drops the
> state your swarm depends on.

Multi-agent runs rarely fail because the model is dumb. They fail because an agent was defined but
never wired up, two agents quietly did the same job, an agent's prompt assumed a tool it was never
granted, or an orchestrator fanned out with no cap and torched the budget — and then, hours in,
compaction throws away the plan, the ownership map, and the decisions already made.
**apex-agent-team** addresses both: lint the team *before* you launch it, and get warned *before*
compaction erases what the team can't afford to forget.

## What it does

The plugin bundles two cohesive sub-features:

- **E1 — TeamLint** (`team-lint` skill + `/apex-agent-team:team-lint` command + `scripts/team-lint.sh`).
  A static analyzer that scans `agents/**/*.md` and `.claude/agents/**/*.md` and reports four
  finding classes:

  | Finding | Severity | Meaning |
  |---|---|---|
  | Dead agent | medium | Defined but never referenced — it will never spawn. |
  | Overlapping responsibility | medium | Two agents' descriptions are near-duplicates — they'll contend or duplicate work. |
  | Missing tool grant | high | The prompt implies a tool absent from `allowed-tools` — the agent will stall. |
  | Unbounded fan-out | high | Parallel spawn with no cap — budget blowout / rate-limit storm. |

  High-severity findings exit non-zero, so it can gate a launch.

- **E2 — ContextBudget** (`SessionStart` + `PreCompact` hooks → `hooks/context-budget.sh`).
  A dependency-free hook that emits `additionalContext` reminding the team to persist the active
  phase, task ownership, decisions, and fan-out caps before compaction runs, plus a heuristic
  token-budget estimate so you know how close to the edge you are.

## Install

```bash
# From the Apex marketplace
/plugin marketplace add Skobyn/Apex-Dev-Skills
/plugin install apex-agent-team@apex-dev-skills

# …or test locally against this repo
claude --plugin-dir ./plugins/apex-agent-team
```

Then `/reload-plugins` (or restart Claude Code) to activate.

## Quick start

```bash
# Lint the agent-team config before launching a run (default: repo root)
/apex-agent-team:team-lint

# …or point it at a specific project
/apex-agent-team:team-lint path/to/project

# Run the analyzer directly
bash plugins/apex-agent-team/scripts/team-lint.sh .
```

ContextBudget needs no invocation — its hooks fire automatically on `SessionStart` and
`PreCompact` once the plugin is installed.

## Compatibility

- **Claude Code:** 2.0+ (requires the `SessionStart` / `PreCompact` hook events and
  `${CLAUDE_PLUGIN_ROOT}` path substitution).
- **Dependencies:** none. Both scripts use only bash + coreutils (`find`, `grep`, `awk`, `sed`,
  `wc`). No `jq`, no `npx`, no network access.
- **ruflo plugin suite:** optional — ContextBudget *suggests* persisting state via `memory_store`
  when those MCP tools are present, but the plugin is fully functional without ruflo.

## Namespace coordination

This plugin claims the AgentDB / memory namespace **`agent-team-coord`**, following the kebab-case
`<plugin-stem>-<intent>` convention from the novel-plugins suite ADR
(`.claude/tasks/novel-plugins-suite-adr.md`, Q3 decision) and ruflo-agentdb ADR-0001
§"Namespace convention". Sub-keys:

| Key prefix | Holds |
|---|---|
| `agent-team-coord:lint/<scan-path-hash>` | Last TeamLint findings + severity counts |
| `agent-team-coord:budget/<session-id>` | Last observed budget estimate + persisted-state notes |

Any future plugin that wants to read/write these keys must claim a non-overlapping prefix and
reference this plugin's ADR-0001.

## Verification

```bash
bash plugins/apex-agent-team/scripts/smoke.sh
```

The smoke script runs 10 structural checks (plugin.json keys, no enumerated surface arrays,
kebab-case skill name, no wildcard tools, command frontmatter, valid `hooks/hooks.json`, README
sections, ADR status, script executability, and a TeamLint self-scan). It exits non-zero on the
first failing check and names what's wrong.

## Architecture Decisions

- [ADR-0001 — apex-agent-team plugin contract](docs/adrs/0001-apex-agent-team-contract.md) —
  Status: **Proposed**. Defines surface, namespace (`agent-team-coord`), compatibility, and the
  smoke contract. Realizes theme E of the novel-plugins suite ADR.

## License

MIT — see the repo-level LICENSE.
