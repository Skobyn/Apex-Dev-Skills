---
name: decide-plan-loop
description: Author an architecture decision (ADR) with SPARC-style spec + pseudocode, interactively refine it with the user via structured feedback rounds, then emit a phased development plan that's directly executable by the dev-plan-loop skill — with per-phase swarm directives (single agent, multi-agent, or full hierarchical-mesh swarm) and automated/human approval gates that close each phase before the next begins. Use when starting a non-trivial feature that needs both a durable decision record AND an actionable build plan, when the user expects to be involved in design choices ("design this with me," "let's plan this together," "decide and then build"), when the plan should launch agents at well-defined checkpoints, or when phasing + gating matters because work crosses ownership boundaries.
allowed-tools: Bash Read Write Edit Glob Grep AskUserQuestion Agent
---

# Decide → Plan → Loop

This skill is the upstream bookend for [dev-plan-loop](../dev-plan-loop/SKILL.md). It turns a fuzzy "we should build X" into:

1. A SPARC-shaped **ADR** at `.claude/tasks/<slug>-adr.md` (the durable rationale)
2. A phased **plan** at `.claude/plans/<slug>-plan.md` (the executable checklist, dev-plan-loop compatible)
3. **Approval gates** between phases (auto-verifiable or human-required)

Both docs are co-authored with the user through 4–6 structured feedback rounds, so by the time the plan is ready to `/loop`, the user has signed off on every meaningful choice.

## When to use this skill

Trigger this when **two or more** of these are true:

- The work is non-trivial (≥ 3 phases, ≥ a day of effort, or touches more than one bounded context)
- The user wants involvement in design choices (says "let's plan," "design this with me," "I want to be involved")
- A durable decision record will outlive the build (someone will ask "why did we do it this way" in six months)
- Execution will be handed to agents — single, multi, or swarm — and needs clear checkpoints
- Phases need gates (test gates, human gates, partner-approval gates) before advancing

Do NOT use this skill for:

- Single-file bug fixes
- One-shot prototypes the user is iterating on live with you in the same session
- Routine implementation choices ("which library should I use here?")
- Cases where `architecture-decision-propose` alone suffices (no build plan yet, just the decision)

## How it relates to neighboring skills

| Skill | Role |
|---|---|
| **decide-plan-loop** (this) | Produces ADR **+** dev-plan-loop-ready plan in one collaborative session |
| `architecture-decision-propose` | ADR only, opens a draft PR for partner review (use when a partner must sign off before any plan) |
| `architecture-decision-approve` | Reviewer-side of the propose flow |
| `dev-plan-loop` | Executes a plan; this skill emits plans for it |
| `sparc-methodology` | The vocabulary for spec/pseudocode/architecture/refinement/completion sections inside the ADR |

If a partner must sign off, prefer `architecture-decision-propose` first, then return here to build the plan after merge.

## The five-stage flow (SCOPE)

```
1. SCOPE     — 4–6 AskUserQuestion rounds: scope, constraints, success criteria, partners,
              swarm preferences, gate preferences
   ↓
2. COMPOSE   — Write ADR (SPARC sections) + plan stub from templates
   ↓
3. OPTIMIZE  — Walk the user through each ADR section, capture inline edits,
              resolve every "Open Question" to a concrete decision
   ↓
4. PLAN      — Convert resolved ADR into phased plan: per-phase swarm directive,
              acceptance criteria, blocked-by graph, and a gate task between phases
   ↓
5. EXECUTE   — Run `scripts/promote-to-loop.sh <slug>` to promote into dev-plan-loop
              state; print the `/loop` command for the user to start
```

Stages 1–4 are interactive. Stage 5 hands off to dev-plan-loop.

## Stage 1: SCOPE

Use `AskUserQuestion` to surface scope and constraints **before drafting anything**. Round-by-round, ask:

1. **Scope** — what's in, what's out, deadline if any
2. **Constraints** — must-haves, non-negotiables (auth, perf budget, compliance, surface parity)
3. **Success criteria** — how we know we're done (runnable checks where possible)
4. **Ownership** — who reviews, who implements, which partners are affected
5. **Execution preference** — should phases dispatch a single agent, multiple parallel agents, or a full hierarchical-mesh swarm? Default is hierarchical-mesh for substantial phases, single agent for trivial ones
6. **Gating preference** — for each phase boundary: auto-gate (runnable check), human-gate (user types "approved phase N"), or partner-gate (inbox item to a specific email)

Capture answers in working memory; surface them back to the user in Stage 2 as the ADR draft so they see their words on the page.

## Stage 2: COMPOSE

Create both docs from the templates:

```bash
.claude/skills/decide-plan-loop/scripts/start.sh <kebab-slug> "<Title>"
# Creates:
#   .claude/tasks/<slug>-adr.md   (from resources/templates/adr-template.md)
#   .claude/plans/<slug>-plan.md  (from resources/templates/plan-template.md)
```

`start.sh` substitutes slug, title, date, author email (from `git config user.email`), and seeds the ADR with the answers captured in Stage 1.

The ADR template has SPARC-shaped sections — see [resources/templates/adr-template.md](resources/templates/adr-template.md):

- **Context (SPARC: Specification)** — requirements, constraints, success metrics
- **Decision** — broken into **Pseudocode (SPARC)**, **Architecture (SPARC)**, **Data Model**, **API Surface**
- **Open Questions** — numbered, each with a default; reviewer/user fills in
- **Risks & Mitigations**
- **Consequences** — positive / negative / neutral

The plan template (see [resources/templates/plan-template.md](resources/templates/plan-template.md)) maps SPARC phases to dev-plan-loop format with per-phase swarm directives and inter-phase gates.

## Stage 3: OPTIMIZE

Walk the ADR section-by-section. For each section:

1. Show the current draft (or the relevant slice) to the user
2. Ask focused `AskUserQuestion`: "Anything to add to the constraints?" or "Is the pseudocode missing a branch?"
3. Edit the doc inline based on their response
4. Move to the next section

**Every "Open Question" must resolve to a decision before promoting.** Default proposals are starting points, not endings. The user (or partner, if cross-boundary) signs off on each. Replace the `Default:` line with `Decision:` once resolved.

**Surface parity check** (per the project's `CLAUDE.md`): if the feature touches user-facing UI, explicitly enumerate the surfaces (admin desktop/mobile, portal desktop/mobile, roles) in the ADR's "What changes / What stays" section. Don't let this default to "obvious" — write it down.

## Stage 4: PLAN

Convert the resolved ADR into the phased plan. The plan template uses SPARC as the phase backbone:

| SPARC Phase | Plan Section | Typical tasks |
|---|---|---|
| Specification | Phase 1 | Research, success-metric finalization, ADR cross-link |
| Pseudocode | Phase 2 | Translate pseudocode into module stubs, type signatures, interfaces |
| Architecture | Phase 3 | Wire components, data model migrations, API contracts |
| Refinement | Phase 4+ | TDD cycle: red → green → refactor per feature slice |
| Completion | Final phase | Integration, deployment, docs, monitoring |

Each task line uses the dev-plan-loop format (parsed by `iterate.sh`):

```markdown
- [ ] **Phase X.Y** [tag1][tag2] Imperative task title
  - Acceptance: <runnable check the swarm verdicts against>
  - Swarm: <topology> <count> [<agent-types>]
  - Blocked-by: phase-X.Y   (optional)
```

The **Swarm:** line is read by the orchestrator (the model running `/loop`) when dispatching agents. Three modes:

- `Swarm: single [<agent-type>]` — one Agent tool invocation with the named subagent
- `Swarm: multi <count> [<type1>, <type2>, ...]` — N parallel Agents in one message
- `Swarm: hierarchical <count> [<type1>, <type2>, ...]` — queen-led swarm via `mcp__claude-flow__swarm_init` + spawns

**Gates** are themselves checkbox tasks placed between phases:

```markdown
- [ ] **Gate 1→2** [gate:auto] Phase 1 acceptance
  - Acceptance: pytest tests/phase-1/ passes && lint clean
  - Blocked-by: phase-1.N

- [ ] **Gate 2→3** [gate:human] Phase 2 review
  - Acceptance: user types "approve phase-2" OR PR merged with label phase-2-approved
  - Blocked-by: phase-2.N

- [ ] **Gate 3→4** [gate:partner:partner@example.com] Architecture sign-off
  - Acceptance: inbox item consumed by partner@example.com
  - Blocked-by: phase-3.N
```

How gates interact with `/loop iterate`:

- **`[gate:auto]`** — iterate.sh treats this like any other task; the model runs the Acceptance check and advances on pass
- **`[gate:human]`** — the model recognizes the tag, halts (sets `halted: true` in checkpoint with `halt_reason: "awaiting human gate <id>"`), prints "Awaiting human approval — reply 'approve <gate-id>' to continue," and exits the loop
- **`[gate:partner:<email>]`** — the model writes a durable inbox item via `POST /api/agent-coordination/inbox` (`kind: "phase-gate-approval"`, `forUser: <email>`), then halts with `halt_reason: "awaiting partner gate <id>"`

Use `scripts/gate.sh <plan-path> <gate-id>` for explicit gate evaluation outside the loop (e.g., a human running it to check what's blocking).

See [resources/templates/plan-template.md](resources/templates/plan-template.md) for the full structure with all SPARC phases and example gates.

## Stage 5: EXECUTE

Once the user confirms the plan:

```bash
.claude/skills/decide-plan-loop/scripts/promote-to-loop.sh <slug>
```

This:

1. Validates ADR status is **Accepted** (not Proposed)
2. Validates plan exists and has at least one unchecked task
3. Calls `.claude/skills/dev-plan-loop/scripts/init.sh .claude/plans/<slug>-plan.md` to seed state
4. Prints the `/loop` command the user should run next, e.g.:
   ```
   /loop iterate the next phase of .claude/plans/<slug>-plan.md
   ```

From here on, dev-plan-loop owns execution. This skill's job is done.

## Surface-parity, debugging, and venue-specific guidance

This project's `CLAUDE.md` has hard rules about surface parity, debugging order, and venue conventions. The ADR template includes prompts for each:

- A **Surface Matrix** subsection under "What changes / What stays" that forces enumeration of admin / portal / mobile / desktop / role surfaces
- A **Debugging guarantees** line in the Risks section ("we will check Firestore data before touching save/load flows")
- A **Venue impact** subsection if `venue_slug` shows up anywhere in the ADR scope

If you're authoring an ADR that touches the site builder, also reference the `apex-site-builder-tasks` skill's decision tree before locking in the architecture.

## Validation checklist

Before promoting, the skill verifies:

- [ ] ADR has every section filled (no `[ TODO ]` placeholders)
- [ ] Every Open Question has a `Decision:` line (no lingering `Default:`)
- [ ] ADR status is `Accepted`
- [ ] Plan has ≥ 1 phase
- [ ] Every task has Acceptance criteria
- [ ] Every Acceptance criterion is runnable (a check, a grep, a test, OR an explicit `human-ack` for gates)
- [ ] Every gate has a clear approver (auto / human / partner-email)
- [ ] Surface parity section enumerates affected surfaces (if user-facing)
- [ ] Blocked-by graph has no cycles
- [ ] Per-phase Swarm directive is present (or default hierarchical-mesh is acceptable)

`scripts/promote-to-loop.sh` runs this checklist and refuses to initialize state if it fails. The error message names the first failing item.

## Available scripts

| Script | Purpose |
|--------|---------|
| `scripts/start.sh <slug> "<Title>"` | Bootstrap ADR + plan from templates with author/date/slug substitutions |
| `scripts/promote-to-loop.sh <slug>` | Run validation checklist, hand off to dev-plan-loop's init.sh |
| `scripts/gate.sh <plan> <gate-id>` | Evaluate a single gate (auto/human/partner) outside the loop |
| `scripts/status.sh <slug>` | Print ADR status, plan completion %, current gate, next phase |

## Resources

- `resources/templates/adr-template.md` — SPARC-shaped ADR with spec + pseudocode + architecture sections
- `resources/templates/plan-template.md` — Phased plan with per-phase Swarm directives and inter-phase gates
- `resources/templates/feedback-interview.md` — The 4–6 question prompts for Stage 1 (SCOPE)
- `resources/examples/sample-decision.md` — Worked example: a small feature decision + plan end-to-end

## Anti-patterns

1. **Composing before scoping.** If you write the ADR before asking the user questions, you've made the decisions for them. Stage 1 (SCOPE) is non-negotiable.
2. **Vague acceptance criteria.** "Improve UX" is not runnable. Either it's a check (`pytest`, `curl`, `grep -q`) or it's a human-gate with a literal approval phrase the user will say.
3. **Skipping the surface parity check.** This project's `CLAUDE.md` is explicit: most features live on multiple surfaces. The ADR template asks for it; don't delete the section because "it doesn't apply" without verifying.
4. **One mega-phase.** If a phase has > 6 tasks or > 1 day of work, split it. Gates between small phases are cheaper than rollbacks of giant phases.
5. **Promoting with unresolved open questions.** The whole point of the refinement stage is to convert defaults into decisions. If you leave a `Default:` line in, you're handing an ambiguity to the implementing agent — they'll either freeze or guess.

## Failure modes

- **User pushes back mid-refinement on a foundational assumption** → walk the ADR back to Stage 2, rewrite the affected sections, re-run remaining refinement rounds. Don't paper over a fundamental change in a single edit.
- **Open questions multiply during refinement** → that's a signal the scope is too big. Offer to split into two ADRs and two plans.
- **Plan won't promote because no acceptance is runnable** → either rewrite the acceptance, or convert that task to a human gate with an explicit approval phrase.

## Skill ownership

Owned by the Apex Insights platform team. Updates should be PR'd; non-trivial changes to the templates or the gate semantics are themselves architecture decisions and should follow `architecture-decision-propose` (recursive, but it's the right shape).
