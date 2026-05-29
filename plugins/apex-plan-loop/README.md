# apex-plan-loop

**Decide → Plan → Loop** as a Claude Code plugin.

Bundles two tightly-coupled skills into one shippable surface:

- **`decide-plan-loop`** — Co-author a SPARC-shaped ADR + phased dev plan with the user via 4–6 structured AskUserQuestion rounds. Produces `.claude/tasks/<slug>-adr.md` (the rationale) and `.claude/plans/<slug>-plan.md` (the executable checklist, dev-plan-loop compatible).
- **`dev-plan-loop`** — Iterate a phased plan autonomously via `/loop` (sense layer) and `/schedule` (continuity layer), dispatching per-phase swarms with bounded reasoning, memory accumulation, and guardrails.

## Install

```bash
# Test locally against this repo
claude --plugin-dir ./plugins/apex-plan-loop

# Or install from a marketplace once published
/plugin install apex/apex-plan-loop
```

## What you get

| Surface | Name | Trigger |
|---|---|---|
| Skill | `decide-plan-loop` | Auto-triggered on "decide and plan", "design this with me", "let's plan together" |
| Skill | `dev-plan-loop` | Auto-triggered on "iterate plan", "autonomous loop", `/loop` invocations referencing a plan |
| Command | `/apex-plan-loop:start <slug>` | Begin a new decide-plan-loop session |
| Command | `/apex-plan-loop:iterate <plan>` | Run one phase of a promoted plan |
| Agent | `plan-author` | Delegate the DISCOVER/DRAFT/REFINE rounds to a Sonnet subagent (saves main-thread context) |

## Quick start

```bash
# 1. Author the ADR + plan with the user (4–6 AskUserQuestion rounds)
/apex-plan-loop:start my-feature

# Walks you through: scope → constraints → success criteria → ownership → swarm pref → gate pref
# Produces: .claude/tasks/my-feature-adr.md + .claude/plans/my-feature-plan.md
# Promotes to dev-plan-loop state if validation passes

# 2. Iterate the plan one phase at a time
/apex-plan-loop:iterate .claude/plans/my-feature-plan.md

# Or hand it to /loop for self-paced execution:
/loop /apex-plan-loop:iterate .claude/plans/my-feature-plan.md
```

## How the two skills compose

```
┌──────────────────────────────────────────────────────────────┐
│  decide-plan-loop                                            │
│  ┌────────┐   ┌───────┐   ┌────────┐   ┌──────┐   ┌────────┐ │
│  │DISCOVER│ → │DRAFT  │ → │REFINE  │ → │PLAN  │ → │PROMOTE │ │
│  └────────┘   └───────┘   └────────┘   └──────┘   └────┬───┘ │
│                                                        │     │
└────────────────────────────────────────────────────────┼─────┘
                                                         │
                            init.sh + checkpoint.json    │
                                                         ▼
┌──────────────────────────────────────────────────────────────┐
│  dev-plan-loop                                               │
│  ┌──────────┐   ┌──────────┐   ┌─────────┐   ┌─────────────┐ │
│  │/loop     │ → │swarm     │ → │acceptance│→ │advance / halt│ │
│  │next task │   │dispatch  │   │check     │  │              │ │
│  └──────────┘   └──────────┘   └─────────┘   └─────────────┘ │
│        ↑                                                     │
│        └── /schedule audit.sh, architecture-review.sh        │
└──────────────────────────────────────────────────────────────┘
```

## Compatibility

- **Claude Code:** 2.0+ (requires `/loop`, `/schedule`, AskUserQuestion, ScheduleWakeup, Agent)
- **`@claude-flow/cli`:** v3.6 major+minor when `iterate.sh` dispatches via claude-flow's `swarm_init`/`agent_spawn` (consumed at runtime via `npx`; not declared as a plugin dependency)
- **Python:** 3.11+ (matches the apex repo's overall toolchain; `start.sh` and `promote-to-loop.sh` are bash but the surrounding apex project uses `uv run`)
- **Host MCP tools (optional, for richer dispatch):** `memory_store`, `memory_search`, `swarm_init`, `agent_spawn`, `hooks_route`

## Namespace coordination

This plugin claims the AgentDB / memory namespace **`apex-plan-loop`**, following the kebab-case `<plugin-stem>-<intent>` convention from ruflo-agentdb ADR-0001 §"Namespace convention". Sub-keys:

| Key prefix | Holds |
|---|---|
| `apex-plan-loop:adrs/<slug>` | ADR metadata + status |
| `apex-plan-loop:plans/<slug>` | Plan checkpoint + completion % |
| `apex-plan-loop:outcomes/<slug>/<phase>` | Per-phase verdict + trajectory pattern |

Any future plugin that wants to read/write these keys must claim a non-overlapping prefix and reference this plugin's ADR-0001.

## Verification

```bash
bash plugins/apex-plan-loop/scripts/smoke.sh
```

The smoke script runs 10 structural checks (frontmatter, namespace declaration, ADR status, script executability, README sections). It exits non-zero on the first failing check and names what's wrong.

## Architecture Decisions

- [ADR-0001 — apex-plan-loop plugin contract](docs/adrs/0001-apex-plan-loop-contract.md) — Status: **Proposed**. Defines surface, namespace, compatibility, and smoke contract.

## Migration from `.claude/skills/`

This plugin was extracted from `.claude/skills/decide-plan-loop/` and `.claude/skills/dev-plan-loop/`. Both source skills are still present in the apex repo for backwards compatibility, but the plugin is the canonical version.

To remove the duplicate skill copies once you've verified the plugin works:

```bash
rm -rf .claude/skills/decide-plan-loop .claude/skills/dev-plan-loop
```

After that, the only source of truth lives under `plugins/apex-plan-loop/skills/`.

## Anti-patterns

The skills' own SKILL.md files document anti-patterns at length. The most important ones, in plugin terms:

1. **Drafting before discovering.** Stage 1 of decide-plan-loop is non-negotiable.
2. **Vague acceptance criteria.** "Improve UX" is not a runnable check. Either it's `pytest`/`curl`/`grep` or it's an explicit `[gate:human]` with a literal approval phrase.
3. **Skipping surface parity.** When the work is user-facing, enumerate every surface in the ADR — don't let it default to "obvious."
4. **One mega-phase.** > 6 tasks or > 1 day of work in one phase → split it. Gates between small phases are cheaper than rollbacks of giant ones.
5. **Promoting with `Default:` lines.** Every Open Question must resolve to a `Decision:` before the plan can be promoted.

## License

MIT — see the repo-level LICENSE.
