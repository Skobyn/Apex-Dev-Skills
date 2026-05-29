---
name: start
description: Begin a new decide-plan-loop session — author an ADR + phased plan with the user via structured feedback rounds. Pass a slug as $ARGUMENTS.
argument-hint: "<kebab-slug>"
---

You are starting a `decide-plan-loop` session for slug `$ARGUMENTS`.

Invoke the `decide-plan-loop` skill and run its five-stage flow:

1. **DISCOVER** — Use AskUserQuestion for the 6 feedback-interview rounds defined in `skills/decide-plan-loop/resources/templates/feedback-interview.md` (scope, constraints, success criteria, ownership, execution preference, gating preference). Capture each answer in working memory.

2. **DRAFT** — Run `skills/decide-plan-loop/scripts/start.sh $ARGUMENTS "<Title>"` to scaffold:
   - `.claude/tasks/$ARGUMENTS-adr.md`
   - `.claude/plans/$ARGUMENTS-plan.md`
   Seed both with the Stage 1 answers.

3. **REFINE** — Walk the ADR section-by-section with the user. For every Open Question, replace `Default:` with `Decision:` based on user input. Don't skip the surface-parity matrix.

4. **PLAN** — Convert resolved ADR into the phased plan. Each task line must include: imperative title, `Acceptance:`, `Swarm:` directive, optional `Blocked-by:`. Place `[gate:auto]`, `[gate:human]`, or `[gate:partner:<email>]` checkboxes between phases.

5. **PROMOTE** — Run `skills/decide-plan-loop/scripts/promote-to-loop.sh $ARGUMENTS`. On success, print the exact `/loop` command the user should run next (which corresponds to this plugin's `/apex-plan-loop:iterate` command).

Refuse to promote if:
- Any Open Question still shows `Default:` (not `Decision:`)
- Any task has no runnable acceptance criterion
- ADR status is still `Proposed` (not `Accepted`)
- Surface parity section is missing for user-facing work

If the user pushes back on a foundational assumption mid-refinement, walk back to Stage 2 and rewrite — don't patch.
