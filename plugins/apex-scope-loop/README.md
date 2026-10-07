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
| **E**xecute | The plan is promoted into an autonomous `/loop` that dispatches swarms inside an isolated worktree and advances on green | choosing auto / human / partner gates |

The result is a system that **thinks alongside you**: it watches reality, persists knowledge, and adjusts strategy across days and weeks — not just a single chat.

## Why you'll want it

- **No more abandoned plans.** The plan *is* the execution engine — checked off as work lands, not a stale to-do list.
- **Decisions survive the session.** Every choice is captured as an ADR with rationale, so future-you (and your teammates) inherit the *why*, not just the *what*.
- **Guardrails by default.** Phases close behind runnable checks or explicit human/partner approval. Bad work can't quietly cascade into the next phase.
- **Autonomy you can trust.** `/loop` drives active sessions; `/schedule` runs nightly audits and weekly architecture reviews so progress continues while you sleep.
- **Right-sized compute.** Each phase declares its own swarm — a single agent for trivial work, a full hierarchical-mesh for the heavy lifting.
- **A harness with teeth.** Execution runs under disciplines adapted from [The Gibson](https://github.com/The-AIE/the-gibson). Each task must pass a green gate measured against the fork-point baseline, then get an independent review of its exact commit from an agent that didn't write it. Anything touching money, auth, PII, security, schema, or prod data stops for your approval. Repeated failures become permanent lessons. See [The Gibson harness](#the-gibson-harness).
- **Isolated by default.** The whole plan runs in a dedicated git worktree on its own branch. `main` stays clean until the final gate passes and the branch is landed — a half-finished or abandoned plan never leaks partial code into your base branch.

## Prerequisites

| Requirement | Why |
|---|---|
| **Claude Code 2.0+** *(required)* | Needs `/loop`, `/schedule`, `AskUserQuestion`, `ScheduleWakeup`, and `Agent`. |
| Python 3.11+ *(optional)* | Matches the surrounding apex toolchain; plugin scripts themselves are bash. |
| A memory store *(optional, via `APEX_MEMORY_CMD`)* | Seeds a plan record into the `apex-scope-loop` namespace. Unset means the seed is skipped quietly. |

The loop runs on plain Claude Code subagents. Nothing else needs installing.

Memory seeding is optional and happens only when `APEX_MEMORY_CMD` is set. `init.sh` runs it with `APEX_MEMORY_NAMESPACE`, `APEX_MEMORY_KEY` and `APEX_MEMORY_VALUE` in its environment. With the optional [ruflo](https://github.com/ruvnet/ruflo) CLI, for example (APEX_MEMORY_CMD):

```bash
export APEX_MEMORY_CMD='npx -y @claude-flow/cli@latest memory store --namespace "$APEX_MEMORY_NAMESPACE" --key "$APEX_MEMORY_KEY" --value "$APEX_MEMORY_VALUE"'
```

`Swarm:` directives in a plan are advisory (optional ruflo/claude-flow swarms, or apex-dispatch `fanout` once available). Without them, each task runs as a single subagent.

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
# Promotes to apex-execute state if validation passes

# 2. Execute the plan one phase at a time (all work happens in an isolated worktree)
/apex-scope-loop:iterate .claude/plans/my-feature-plan.md

# …or hand it to /loop for self-paced, autonomous execution:
/loop /apex-scope-loop:iterate .claude/plans/my-feature-plan.md

# 3. When the final gate passes, land the worktree branch onto main:
.claude/skills/apex-execute/scripts/land.sh .claude/plans/my-feature-plan.md
```

## What you get

| Surface | Name | Trigger |
|---|---|---|
| Skill | `apex-plan` | Auto-triggered on "decide and plan", "design this with me", "let's plan together" |
| Skill | `apex-execute` | Auto-triggered on "iterate plan", "autonomous loop", `/loop` invocations referencing a plan |
| Command | `/apex-scope-loop:start <slug>` | Begin a new SCOPE authoring session |
| Command | `/apex-scope-loop:iterate <plan>` | Run one phase of a promoted plan |
| Agent | `gibson-reviewer` | Independent, read-only six-lens reviewer of one task's exact head SHA (Opus). Dispatched by the iterate loop; never reviews its own work |
| Agent | `plan-author` | Delegate the SCOPE/COMPOSE/OPTIMIZE rounds to a Sonnet subagent (saves main-thread context) |

## How the two skills compose

```
apex-plan  (authoring — the five phases spell SCOPE)

   SCOPE → COMPOSE → OPTIMIZE → PLAN → EXECUTE
                                          │
                                          │  init.sh + checkpoint.json
                                          ▼
apex-execute  (execution — the loop, inside an isolated worktree)

   init.sh ──► git worktree add apex-scope-loop/<slug>  (forked from main)

   /loop next task → swarm dispatch (in worktree) → acceptance check → advance / halt
        ▲                                                                │
        └── /schedule audit.sh, architecture-review.sh                   ▼
                                              final gate passed → land.sh
                                              (merge branch → main, remove worktree)
```

## The Gibson harness

apex-execute adopts the portable core of [The Gibson](https://github.com/The-AIE/the-gibson), an open source SDLC harness for agent fleets (Apache-2.0, Mark Hinkle). It's **on by default**. Set `APEX_GIBSON=0` to opt out.

Per task, inside the worktree:

```
build swarm → commit → green-gate.sh check → risk-tier.sh → gibson-reviewer (exact head SHA)
           → [Tier C: 6-lens fan-out + adversarial pass + your G12 approval] → acceptance → checkpoint complete
```

| Gibson law | What you get |
|---|---|
| Green gate vs. baseline (Law 4) | `init.sh` snapshots generate/typecheck/lint/test/build at the fork. A task fails only on *new* red. Commands come from `.agents/gate.json` (Gibson format), `APEX_GATE_*`, or `package.json` |
| Never grade your own homework (Law 5) | The `gibson-reviewer` agent reviews in a fresh context and fails closed. Check-off is refused without an `APPROVE` on the current head |
| Tier C is sacred (Law 7) | `risk-tier.sh` flags money/auth/PII/security/schema/prod-data diffs. They halt for your approval, asked in plain language (the Ask Contract) |
| The ratchet (Law 9) | A failure seen twice must be filed in `.claude/apex-scope-loop/LESSONS.md`, and lessons are recalled by tag before each task |
| Kill switch + error budget | `touch .dev-plan-state/HALT` (or `gibson/HALT`, or `APEX_HALT=1`) stops the loop. Two failures in a row buy a second opinion. Three stalled failures halt the plan, and so do six in a row of any kind (a failure that closed findings and moved the head is not a stall) |

### Review-loop calibration (v0.4.0, ADR-0004)

- **Threat model first.** A plan's `## Threat model` section (or a task's `- Threat:` line, else a stated default: trusted agents, accidents and realistic misuse in scope, deliberate tampering and obfuscated inputs out) is printed in the brief and handed to every reviewer verbatim.
- **A fixed bar.** `[blocking]` means a realistic actor under that model can cause it in an ordinary flow, or Acceptance is unmet, or tests were weakened. At most `APEX_ADVERSARY_BUDGET` (3) blocking findings per pass. Everything else goes to the hardening backlog (`backlog.sh`, `.claude/apex-scope-loop/BACKLOG.md`), which a later docs task consumes.
- **Verify-only re-reviews.** Round 1 is the full review (and the attempt's one full adversarial pass); later rounds check the prior findings and the fixes since `LAST_REVIEWED`.
- **Ask the human sooner.** After REQUEST_CHANGES in 2 rounds, `checkpoint.sh review` prints `ASK_HUMAN:`. The human can accept the residual risk at that exact head with `checkpoint.sh waive`; the gate, the tier, G12 and Acceptance still apply, and the completion is recorded as waived, not approved.
- **Calibrated tiers.** Content signals in tests, fixtures, smoke files, examples and docs no longer raise Tier C (their paths still do), and an explicit `[tier:a]`/`[tier:b]` tag decides over size and content signals, never over Tier C paths or `[security]`/`[tier:c]`.

Full mapping, and what was deliberately left out (cross-vendor routing, GitHub claims, CI templates): [skills/apex-execute/docs/GIBSON_HARNESS.md](skills/apex-execute/docs/GIBSON_HARNESS.md). For repo-level setup (CI gates, branch protection, labels), run The Gibson's own `gibson-setup` skill against the target repo.

## Compatibility

- **Claude Code:** 2.0+ (requires `/loop`, `/schedule`, AskUserQuestion, ScheduleWakeup, Agent)
- **git:** 2.40+ (the clean-worktree check builds its comparison checkout with `--attr-source=HEAD`; older git makes the gate fail closed on files git converts on checkout)
- **bash** 4+ and **python3** 3.8+ (stdlib only)
- **ruflo / `@claude-flow/cli`:** optional — used only when `APEX_MEMORY_CMD` seeds memory or a plan's advisory `Swarm:` directive is run through it

## Namespace coordination

This plugin claims the AgentDB / memory namespace **`apex-scope-loop`**, following the kebab-case `<plugin-stem>-<intent>` convention (borrowed from the optional ruflo-agentdb ADR-0001 §"Namespace convention"). Sub-keys:

| Key prefix | Holds |
|---|---|
| `apex-scope-loop:adrs/<slug>` | ADR metadata + status |
| `apex-scope-loop:plans/<slug>` | Plan checkpoint + completion % |
| `apex-scope-loop:outcomes/<slug>/<phase>` | Per-phase verdict + trajectory pattern |
| `apex-scope-loop:lessons/<tag>` | Ratchet lessons (mirror of the tracked `.claude/apex-scope-loop/LESSONS.md`, per ADR-0002) |

The hardening backlog (ADR-0004) is a tracked file beside the ledger, `.claude/apex-scope-loop/BACKLOG.md`, not a memory key.

Any future plugin that wants to read/write these keys must claim a non-overlapping prefix and reference this plugin's ADR-0001.

## Verification

```bash
bash plugins/apex-scope-loop/scripts/smoke.sh
```

The smoke script runs 50 checks: the structural contract (frontmatter, namespace declaration, ADR status, script executability, README sections) plus behavioural fixtures for the harness (plan dialect, checkpoint provenance, risk tiers, the chain, land, the clean-worktree inventory, and the review-loop calibration of ADR-0004). It exits non-zero on the first failing check and names what's wrong.

## Architecture Decisions

- [ADR-0001 — apex-scope-loop plugin contract](docs/adrs/0001-apex-scope-loop-contract.md) — Status: **Proposed**. Defines surface, namespace, compatibility, and smoke contract.
- [ADR-0002 — Adopt The Gibson's harness disciplines](docs/adrs/0002-gibson-harness.md) — Status: **Proposed**. Green gate, independent review, Tier C / G12, ratchet, kill switch.
- [ADR-0003 — Portability, the per-run guarantee, and apex-dispatch as a consumer](docs/adrs/0003-portability-and-dispatch-consumer.md) — Status: **Proposed**. ruflo optional, template profiles, the chain and epochs, landing without merge machinery, the clean-worktree contract and what lies outside it.
- [ADR-0004 — Review-loop calibration](docs/adrs/0004-review-loop-calibration.md) — Status: **Accepted**. Threat model before review, severity bar, verify-only re-reviews, adversary budget, human waiver, progress-aware halts, hardening backlog, classifier calibration; what it loosens and why that is safe.

## Migration from `.claude/skills/`

This plugin was extracted from `.claude/skills/apex-plan/` and `.claude/skills/apex-execute/`. Both source skills are still present in the apex repo for backwards compatibility, but the plugin is the canonical version.

To remove the duplicate skill copies once you've verified the plugin works:

```bash
rm -rf .claude/skills/apex-plan .claude/skills/apex-execute
```

After that, the only source of truth lives under `plugins/apex-scope-loop/skills/`.

## Anti-patterns

The skills' own SKILL.md files document anti-patterns at length. The most important ones, in plugin terms:

1. **Composing before scoping.** Stage 1 (SCOPE) of apex-plan is non-negotiable.
2. **Vague acceptance criteria.** "Improve UX" is not a runnable check. Either it's `pytest`/`curl`/`grep` or it's an explicit `[gate:human]` with a literal approval phrase.
3. **Skipping surface parity.** When the work is user-facing, enumerate every surface in the ADR — don't let it default to "obvious."
4. **One mega-phase.** > 6 tasks or > 1 day of work in one phase → split it. Gates between small phases are cheaper than rollbacks of giant ones.
5. **Promoting with `Default:` lines.** Every Open Question must resolve to a `Decision:` before the plan can be promoted.

## License

MIT — see the repo-level LICENSE. The execution harness adapts concepts from The Gibson (Apache-2.0); see [NOTICE](NOTICE).
