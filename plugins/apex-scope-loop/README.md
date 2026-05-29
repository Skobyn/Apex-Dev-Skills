# apex-scope-loop

> **Plan it once. Ship it for days.**
> A co-authored decision record and a phased plan that an autonomous swarm actually executes — across `/loop` iterations and `/schedule`d sessions, with gates that stop runaway work before it starts.

Most "AI planning" ends the moment the plan is written. The doc rots, the agent drifts, and by the next session nobody remembers why a choice was made. **apex-scope-loop** closes that gap: it walks you through a structured decision, captures the *why* in an ADR, compiles it into a runnable plan, and then keeps the work moving — phase by phase, gate by gate — without you re-explaining the project every morning.

It does that through five phases that spell **SCOPE**:

| Phase | What happens | You stay in control by… |
|---|---|---|
| **S**cope | 4–6 sharp `AskUserQuestion` rounds pin down scope, constraints, success criteria, ownership | answering, not prompt-wrangling |
| **C**ompose | A SPARC-shaped ADR + plan stub are scaffolded from your answers | seeing your words on the page immediately |
| **O**ptimize | You and the agent refine the ADR section-by-section until every Open Question is a Decision | signing off on each section |
| **P**lan | The resolved ADR compiles into a phased checklist with per-phase swarm directives + gates | reviewing runnable acceptance criteria |
| **E**xecute | The plan is promoted into an autonomous `/loop` that dispatches swarms and advances on green | choosing auto / human / partner gates |

The result is a system that **thinks alongside you**: it watches reality, persists knowledge, and adjusts strategy across days and weeks — not just a single chat.

## Why you'll want it

- **No more abandoned plans.** The plan *is* the execution engine — checked off as work lands, not a stale to-do list.
- **Decisions survive the session.** Every choice is captured as an ADR with rationale, so future-you (and your teammates) inherit the *why*, not just the *what*.
- **Guardrails by default.** Phases close behind runnable checks or explicit human/partner approval. Bad work can't quietly cascade into the next phase.
- **Autonomy you can trust.** `/loop` drives active sessions; `/schedule` runs nightly audits and weekly architecture reviews so progress continues while you sleep.
- **Right-sized compute.** Each phase declares its own swarm — a single agent for trivial work, a full hierarchical-mesh for the heavy lifting.

## Prerequisites

> **apex-scope-loop builds on [ruflo](https://github.com/ruvnet/ruflo). The ruflo plugin suite is required, not optional.**

| Requirement | Why |
|---|---|
| **ruflo plugin suite** *(required)* | Provides the `memory_*`, `swarm_init`, `agent_spawn`, and `hooks_route` MCP tools that the EXECUTE loop uses to dispatch swarms and accumulate cross-session memory. Set it up with `ruflo init`. |
| **Claude Code 2.0+** *(required)* | Needs `/loop`, `/schedule`, `AskUserQuestion`, `ScheduleWakeup`, and `Agent`. |
| `@claude-flow/cli` v3.6+ *(runtime, via `npx`)* | Used by `iterate.sh` when a phase dispatches a claude-flow swarm. Consumed at runtime; not a declared dependency. |
| Python 3.11+ *(optional)* | Matches the surrounding apex toolchain; plugin scripts themselves are bash. |

Without ruflo's MCP tools the authoring phases still work, but the autonomous EXECUTE loop has nothing to dispatch to — so install ruflo first.

## Install

```bash
# From the Apex marketplace
/plugin marketplace add Skobyn/Apex-Dev-Skills
/plugin install apex-scope-loop@apex-dev-skills

# …or test locally against this repo
claude --plugin-dir ./plugins/apex-scope-loop
```

Then `/reload-plugins` (or restart Claude Code) to activate.

## Quick start

```bash
# 1. Author the ADR + plan with the user (the S-C-O-P phases)
/apex-scope-loop:start my-feature

# Walks you through: scope → constraints → success criteria → ownership → swarm pref → gate pref
# Produces: .claude/tasks/my-feature-adr.md + .claude/plans/my-feature-plan.md
# Promotes to dev-plan-loop state if validation passes

# 2. Execute the plan one phase at a time
/apex-scope-loop:iterate .claude/plans/my-feature-plan.md

# …or hand it to /loop for self-paced, autonomous execution:
/loop /apex-scope-loop:iterate .claude/plans/my-feature-plan.md
```

## What you get

| Surface | Name | Trigger |
|---|---|---|
| Skill | `decide-plan-loop` | Auto-triggered on "decide and plan", "design this with me", "let's plan together" |
| Skill | `dev-plan-loop` | Auto-triggered on "iterate plan", "autonomous loop", `/loop` invocations referencing a plan |
| Command | `/apex-scope-loop:start <slug>` | Begin a new SCOPE authoring session |
| Command | `/apex-scope-loop:iterate <plan>` | Run one phase of a promoted plan |
| Agent | `plan-author` | Delegate the SCOPE/COMPOSE/OPTIMIZE rounds to a Sonnet subagent (saves main-thread context) |

## How the two skills compose

```
decide-plan-loop  (authoring — the five phases spell SCOPE)

   SCOPE → COMPOSE → OPTIMIZE → PLAN → EXECUTE
                                          │
                                          │  init.sh + checkpoint.json
                                          ▼
dev-plan-loop  (execution — the loop)

   /loop next task → swarm dispatch → acceptance check → advance / halt
        ▲
        └── /schedule audit.sh, architecture-review.sh
```

## Compatibility

- **Claude Code:** 2.0+ (requires `/loop`, `/schedule`, AskUserQuestion, ScheduleWakeup, Agent)
- **ruflo plugin suite:** required — supplies the `memory_*`, `swarm_init`, `agent_spawn`, and `hooks_route` MCP tools the EXECUTE loop dispatches through (`ruflo init`)
- **`@claude-flow/cli`:** v3.6 major+minor when `iterate.sh` dispatches via claude-flow's `swarm_init`/`agent_spawn` (consumed at runtime via `npx`; not declared as a plugin dependency)
- **Python:** 3.11+ (matches the apex repo's overall toolchain; `start.sh` and `promote-to-loop.sh` are bash but the surrounding apex project uses `uv run`)

## Namespace coordination

This plugin claims the AgentDB / memory namespace **`apex-scope-loop`**, following the kebab-case `<plugin-stem>-<intent>` convention from ruflo-agentdb ADR-0001 §"Namespace convention". Sub-keys:

| Key prefix | Holds |
|---|---|
| `apex-scope-loop:adrs/<slug>` | ADR metadata + status |
| `apex-scope-loop:plans/<slug>` | Plan checkpoint + completion % |
| `apex-scope-loop:outcomes/<slug>/<phase>` | Per-phase verdict + trajectory pattern |

Any future plugin that wants to read/write these keys must claim a non-overlapping prefix and reference this plugin's ADR-0001.

## Verification

```bash
bash plugins/apex-scope-loop/scripts/smoke.sh
```

The smoke script runs 10 structural checks (frontmatter, namespace declaration, ADR status, script executability, README sections). It exits non-zero on the first failing check and names what's wrong.

## Architecture Decisions

- [ADR-0001 — apex-scope-loop plugin contract](docs/adrs/0001-apex-scope-loop-contract.md) — Status: **Proposed**. Defines surface, namespace, compatibility, and smoke contract.

## Migration from `.claude/skills/`

This plugin was extracted from `.claude/skills/decide-plan-loop/` and `.claude/skills/dev-plan-loop/`. Both source skills are still present in the apex repo for backwards compatibility, but the plugin is the canonical version.

To remove the duplicate skill copies once you've verified the plugin works:

```bash
rm -rf .claude/skills/decide-plan-loop .claude/skills/dev-plan-loop
```

After that, the only source of truth lives under `plugins/apex-scope-loop/skills/`.

## Anti-patterns

The skills' own SKILL.md files document anti-patterns at length. The most important ones, in plugin terms:

1. **Composing before scoping.** Stage 1 (SCOPE) of decide-plan-loop is non-negotiable.
2. **Vague acceptance criteria.** "Improve UX" is not a runnable check. Either it's `pytest`/`curl`/`grep` or it's an explicit `[gate:human]` with a literal approval phrase.
3. **Skipping surface parity.** When the work is user-facing, enumerate every surface in the ADR — don't let it default to "obvious."
4. **One mega-phase.** > 6 tasks or > 1 day of work in one phase → split it. Gates between small phases are cheaper than rollbacks of giant ones.
5. **Promoting with `Default:` lines.** Every Open Question must resolve to a `Decision:` before the plan can be promoted.

## License

MIT — see the repo-level LICENSE.
