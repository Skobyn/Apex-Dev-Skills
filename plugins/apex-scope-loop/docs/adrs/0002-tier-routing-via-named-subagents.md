# ADR-0002: Tier routing via named subagents

- **Status:** Proposed
- **Date:** 2026-06-10
- **Author:** solutions@getapexinsights.com
- **Plugin:** apex-scope-loop v0.2.0
- **References:** [ADR-0001](0001-apex-scope-loop-contract.md) §"Namespace coordination"

## Context

A promoted plan was a complete work contract but not an economic one. Every phase
dispatched at whatever model the session happened to run, even though phases vary from
single-file edits to multi-hour autonomous runs and model cost varies roughly 30x
between tiers. Routing every phase to the heavy tier wastes budget; routing heavy
phases to light tiers produces failed gates and rework. The cost decision was
improvised mid-loop by the orchestrator instead of being made once, with the user,
at planning time.

## Decision

A plan is a complete economic contract: when it is promoted, it already knows what
each phase costs, which model earns that cost, and what evidence closes the phase.
The loop becomes self-routing — `iterate.sh` reads the phase's tier and the
orchestrator dispatches the matching subagent; the only decisions that return to the
user are gate approvals and escalations.

### Tier vocabulary

Three phase-worker subagents ship with the plugin in `agents/`, alongside
`plan-author`. They — not plans, not ADRs — own the model bindings, so a model
upgrade is a one-file change touching zero plans and zero project ADRs.

| Tier     | Subagent              | Model binding   | Use when                                            |
|----------|-----------------------|-----------------|-----------------------------------------------------|
| light    | `phase-worker-light`    | haiku           | Bounded, mechanical, <=2 files, no judgment         |
| standard | `phase-worker-standard` | sonnet          | Feature work within one module (DEFAULT)            |
| heavy    | `phase-worker-heavy`    | claude-fable-5  | Cross-module, migrations, autonomous /loop sessions |

The heavy tier's model string is pinned to a full model ID, not an alias.
`plan-author` itself stays on Sonnet; authoring never needs the heavy tier.

### Authoring surface (apex-plan)

- SCOPE gains round 7: the project's default tier (light / standard / heavy).
- The ADR template gains a mandatory **"Decision: Compute Tiers per Phase"** section —
  same status as Open Questions — with a per-phase assignment table resolved during
  OPTIMIZE. Heavy assignments require a one-line Rationale in that table.
- The plan compiler emits a `Tier:` line on every Phase task naming one of the three
  subagents. Plans reference subagents by name, never model strings. Gates carry no
  tier; the orchestrator evaluates gates itself.

### Promote-time enforcement (promote-to-loop.sh)

Two new checks, same class as "no `Default:` lines":

10. Every Phase task carries a `Tier:` line naming one of the three subagents.
11. Every `phase-worker-heavy` task is backed by a Rationale row in the ADR's tier
    table. No rationale, no promotion.

### Execution surface (apex-execute)

- `iterate.sh` parses the task's `Tier:` line and emits a `TIER:` field on the brief
  (defaulting missing tiers on Phase tasks to `phase-worker-standard`, erroring on
  unknown values). The orchestrator passes the named subagent to the dispatch.
- `iterate.sh`, `audit.sh`, `architecture-review.sh`, and `promote-to-loop.sh` guard
  fatally against `CLAUDE_CODE_SUBAGENT_MODEL`: that variable silently overrides every
  subagent model field and flattens tier routing to one model. No plugin script may
  set it, and no `/schedule` environment should either.
- **`escalate` is a halt type, not a retry.** Light and standard workers report
  `escalate: needs <tier>` (or `escalate: ADR conflict`) rather than silently
  attempting work above their tier. The orchestrator writes the verdict to
  `apex-scope-loop:outcomes/<slug>/<phase>`, halts via `checkpoint.sh` with
  `halt_reason: "escalate: ..."`, and stops. An escalation reopens the ADR's tier
  Decision with the user; it never auto-bumps the tier mid-loop.

### Cost feedback loop (audit.sh)

The orchestrator writes a per-phase outcome file
`.dev-plan-state/<plan-hash>/outcomes/<phase>.json` with the shape
`{"phase", "tier", "verdict", "tokens"}`, mirroring the memory key below. The nightly
audit aggregates tokens per phase per tier into its audit JSON (`"cost"`) and
briefing, so after a few plans there is real data on whether tier assignments were
right — feeding the next ADR's rationale lines. That closes the loop on the loop.

### Namespace impact (extends ADR-0001)

ADR-0001 claims `apex-scope-loop:outcomes/<slug>/<phase>` for "per-phase verdict +
trajectory pattern". This ADR adds a sub-key shape to that same prefix: the stored
outcome now also carries `tier`, `tokens`, and the `escalate` verdict variant. No new
namespace prefix is claimed; no other plugin's keys are touched.

### Smoke contract additions

`scripts/smoke.sh` grows from 10 to 13 checks:

11. The three phase-worker agent files exist with parseable frontmatter (kebab-case
    `name:` matching the filename, a `model:` binding present).
12. Every Phase task in `plan-template.md` and `sample-plan.md` carries a `Tier:`
    line naming one of the three subagents.
13. No `*.sh` under `skills/` or `scripts/` assigns `CLAUDE_CODE_SUBAGENT_MODEL`.

## Consequences

### Positive

- Cost is decided once at OPTIMIZE, with the user, not improvised mid-loop. The user
  stops being the dispatcher and becomes the gatekeeper.
- Model upgrades touch one agent file — zero plans, zero project ADRs.
- Escalations are explicit and auditable instead of silent over-reach.
- The nightly cost line turns tier assignment from guesswork into a measured choice.

### Negative

- Plans authored before v0.2.0 lack `Tier:` lines; `iterate.sh` defaults their phases
  to `phase-worker-standard`, but they will not pass a re-promotion until tiers are
  added.
- Three more agent definitions to keep in sync with the host platform's model names
  (mitigated: the binding lives in exactly one file per tier).

### Neutral

- The `Swarm:` topology directive is unchanged and orthogonal: `Tier:` decides what
  model executes; `Swarm:` decides how many agents and in what shape.

## Status changes

- 2026-06-10 — Proposed (tier routing, escalate halt type, cost audit, smoke 11–13).
