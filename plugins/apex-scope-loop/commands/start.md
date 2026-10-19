---
name: start
description: Begin a new apex-plan session — author an ADR + phased plan with the user via structured feedback rounds. Pass a slug as $ARGUMENTS.
argument-hint: "<kebab-slug>"
---

You are starting an `apex-plan` session for the slug given in `$ARGUMENTS`.

**Arguments.** `$ARGUMENTS` is `<slug> [--scope <scope>]`. `<slug>` is its first word. The scope is the value after `--scope` in `$ARGUMENTS` if present, else the suggestion the user confirms, else `feature`.

**Scope.** The plan has one of three scopes: `bugfix`, `poc` or `feature`. Pass it with `--scope` (for example, `/apex-scope-loop:start fix-x --scope bugfix`), or let the skill suggest one and confirm it with the user. Nothing is auto-detected silently. With no `--scope`, the scope is `feature`, which behaves as it always has.

| Scope | Interview rounds | Templates | Max phases |
|---|---|---|---|
| `bugfix` | 2: scope+done (one combined question), then gate | lean | 2 |
| `poc` | 4: scope, constraints, done, gate | lean | 3 |
| `feature` | 6: scope, constraints, done, ownership, swarm, gate | full | unlimited |

**Round 0, intent.** Before the numbered rounds, `poc` and `feature` ask an intent question (problem, who it's for, why now, non-goals); `bugfix` asks it only if the user wants it. It is not one of the 2/4/6 rounds in the table. Write the answers to `.claude/tasks/<slug>-intent.md` (template: `intent-template.md` beside the feedback-interview file) before running `start.sh`. `start.sh` seeds the `## Problem` text into the ADR's "Why this matters" section and never overwrites the intent file; a bugfix with no intent file is scaffolded as before.

Scope changes authoring only. The green gate, independent review, risk tier and G12, the ratchet, kill switches and ledger evidence apply the same way to every scope.

Invoke the `apex-plan` skill and run its five-stage flow:

1. **SCOPE** — Start with Round 0 (intent) when the scope runs it, and write `.claude/tasks/<slug>-intent.md`. Then use AskUserQuestion for the feedback-interview rounds that the chosen scope runs, defined in `${CLAUDE_PLUGIN_ROOT}/skills/apex-plan/resources/templates/profiles/<profile>/feedback-interview.md` (profile `apex` when `.claude/agent-coord-config.json` exists or `APEX_PLAN_PROFILE=apex`, else `generic`). The numbered rounds do not include Round 0. `feature` runs all six: scope, constraints, success criteria, ownership, execution preference, gating preference. `poc` runs scope, constraints, success criteria and gating. `bugfix` runs one combined scope+success-criteria question, then gating. Capture each answer in working memory.

2. **COMPOSE** — Run `${CLAUDE_PLUGIN_ROOT}/skills/apex-plan/scripts/start.sh <slug> "<Title>" --scope <scope>` to scaffold, where `<scope>` is the resolved scope (`bugfix`, `poc` or `feature`). `--scope` may be omitted for `feature`:
   - `.claude/tasks/<slug>-adr.md` (header: `**Scope**: <scope>`)
   - `.claude/plans/<slug>-plan.md` (header: `> **Scope**: <scope>`)
   `bugfix` and `poc` use the lean templates; `feature` uses the full ones. An unknown scope is refused and nothing is written. Seed both with the Stage 1 answers.

3. **OPTIMIZE** — Walk the ADR section-by-section with the user. For every Open Question, replace `Default:` with `Decision:` based on user input. Don't skip the surface-parity matrix.

4. **PLAN** — Convert resolved ADR into the phased plan. Each task line must include: imperative title, `Acceptance:`, `Swarm:` directive, optional `Blocked-by:`. Place `[gate:auto]`, `[gate:human]`, or `[gate:partner:<email>]` checkboxes between phases.

5. **EXECUTE** — Run `${CLAUDE_PLUGIN_ROOT}/skills/apex-plan/scripts/promote-to-loop.sh <slug>` to promote the validated plan into the apex-execute loop. It checks that the ADR and plan declare the same Scope, and that the phase count fits the scope (bugfix ≤ 2, poc ≤ 3). A plan with no Scope line promotes as before. On success, print the exact `/loop` command the user should run next (which corresponds to this plugin's `/apex-scope-loop:iterate` command).

Refuse to promote if:
- Any Open Question still shows `Default:` (not `Decision:`)
- Any task has no runnable acceptance criterion
- ADR status is still `Proposed` (not `Accepted`)
- Surface parity section is missing for user-facing work. This holds for every scope. A lean ADR (bugfix or poc) has no Surface Matrix, so add a short one by hand when the work is user-facing

If the user pushes back on a foundational assumption mid-refinement, walk back to Stage 2 and rewrite — don't patch.
