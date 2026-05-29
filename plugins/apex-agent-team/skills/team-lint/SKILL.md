---
name: team-lint
description: Statically lint a project's subagent / agent-team configuration BEFORE a multi-agent run. Scans agents/*.md across the repo and .claude config and reports dead agents (defined but never referenced), overlapping responsibilities (near-duplicate descriptions), missing tool grants (a prompt implies a tool absent from allowed-tools), and unbounded fan-out (parallel spawn with no cap). Use when about to launch a swarm or subagent team, when adding/editing agent definitions, when a previous run misbehaved (idle agents, duplicated work, permission-denied tool calls, runaway parallel spawns), or when auditing an inherited agent-team config. NOT a general code/security linter — it only inspects agent-team configuration.
allowed-tools: Bash Read Glob Grep
---

# TeamLint — static audit of agent-team configuration

TeamLint inspects how your subagents/agent-team are *configured* — not your application code.
It runs **before** you launch a run so structural problems surface while they are cheap to fix,
instead of mid-swarm when an agent sits idle, two agents stomp the same work, a tool call gets
denied, or an unbounded fan-out melts the budget.

## When to use this skill

Trigger it when **any** of these hold:

- You are about to dispatch a swarm or a team of subagents and want a pre-flight check.
- You just added or edited files under `agents/`, `.claude/agents/`, or a plugin's `agents/`.
- A prior run misbehaved: an agent never fired, two agents did the same thing, a tool call was
  denied, or parallel spawns ran away.
- You inherited an agent-team config and want to know what is actually wired up.

Do NOT use it for: linting application source, security scanning, or reviewing a PR diff. It
reasons about *agent definitions and how they reference each other*, nothing else.

## What it checks

| Check | Severity | What it means |
|---|---|---|
| **Dead agent** | medium | An agent is defined but its `name:` is never referenced by another agent, command, skill, or orchestrator file. It will never be spawned. |
| **Overlapping responsibility** | medium | Two agents have near-duplicate `description:` text (high token overlap). They will likely contend for the same work or duplicate effort. |
| **Missing tool grant** | high | The agent's prompt body implies a capability (e.g. it says "edit the file", "run the tests", "search the web") but the corresponding tool is absent from its `allowed-tools`. The agent will hit a wall mid-run. |
| **Unbounded fan-out** | high | An agent/orchestrator spawns agents in parallel (mentions `agent_spawn`, `Task`, "in parallel", "fan out") with no explicit cap (no number, no "at most N", no `maxAgents`/`concurrency`). Risks budget blowout and rate-limit storms. |

High-severity findings (missing tool grant, unbounded fan-out) cause a non-zero exit so a
pre-run gate can block the launch.

## How to run it

```bash
# Default: scan the current repo root
bash ${CLAUDE_PLUGIN_ROOT}/scripts/team-lint.sh

# Or scan a specific path
bash ${CLAUDE_PLUGIN_ROOT}/scripts/team-lint.sh path/to/project
```

The slash command `/apex-agent-team:team-lint <path>` is a thin wrapper that invokes this skill
against `<path>` (default: repo root) and summarizes the findings.

### What the scan covers

- `agents/**/*.md` and `.claude/agents/**/*.md` (project + plugin agent definitions)
- Each agent's YAML frontmatter (`name:`, `description:`, `allowed-tools:` / `tools:`)
- Each agent's prompt body (for implied-capability detection)
- Reference sites in `commands/**/*.md`, `skills/**/SKILL.md`, and other `agents/**/*.md`
  (to decide whether an agent is dead)

## Interpreting the report

The script prints one block per agent file plus a findings list grouped by severity, then a
summary line. Typical fixes:

- **Dead agent** → either reference it from a command/orchestrator, or delete it.
- **Overlapping responsibility** → merge the two agents, or sharpen each `description:` so their
  scopes are disjoint.
- **Missing tool grant** → add the implied tool to `allowed-tools` (keep it explicit — never use a
  `*` or `mcp__*` wildcard), or remove the capability claim from the prompt.
- **Unbounded fan-out** → add an explicit cap: a number in the prompt, an "at most N agents"
  clause, or a `maxAgents` / `concurrency` directive the orchestrator honors.

## Heuristic boundaries (be honest about these)

TeamLint is static and dependency-free (bash + grep/awk). It cannot:

- Resolve dynamic agent names built at runtime — it matches literal `name:` strings.
- Prove a tool is *truly* unused — it only flags a prompt that *implies* a tool the grant lacks.
- Understand intent — an "overlap" may be deliberate redundancy. Treat findings as prompts for a
  human decision, not hard errors (except the two high-severity gates).

## Anti-patterns

1. **Running it after the swarm, not before.** The whole point is a pre-flight gate.
2. **Suppressing high-severity findings by widening `allowed-tools` to `*`.** That defeats both the
   lint and the plugin contract. Grant the *specific* tool.
3. **"Fixing" a dead agent by referencing it from a comment.** A reference inside a fenced code
   block or comment still counts as wiring only if the orchestrator actually reads it — prefer a
   real spawn site.
