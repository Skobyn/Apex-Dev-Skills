---
description: Orient, decide, execute and gate a piece of apex-app work end to end.
---

Run the full apex build lifecycle for: **$ARGUMENTS**

## 1. ORIENT

Route the ask before designing anything:

!`node ${CLAUDE_PLUGIN_ROOT}/engine/bin/apex.js route "$ARGUMENTS"`

If the ask names a surface rather than a path, route the most likely path too. Report the lane, the surface status, and the skills the verdict named. Check the agent-coordination preamble for a partner already working this surface — if one exists, surface the overlap before touching code.

## 2. DECIDE

Judge triviality by the `decide-plan-loop` skill's own criteria: three or more phases, **a day or more of effort**, or touching more than one bounded context — plus the durability test of whether someone will ask "why did we do it this way" in six months.

- **Non-trivial** → invoke the `decide-plan-loop` skill. It produces an ADR at `.claude/tasks/<slug>-adr.md` and a phased plan at `.claude/plans/<slug>-plan.md`.
- **Bounded** → skip to step 3, and say why you judged it bounded.

## 3. EXECUTE

Work the plan one phase at a time via the `dev-plan-loop` skill. Do not start a phase before its predecessor has passed step 4.

## 4. GATE — every phase, no exceptions

!`node ${CLAUDE_PLUGIN_ROOT}/engine/bin/apex.js gate --message "phase complete"`

A phase closes when its obligations pass, never because the work feels finished. If the gate says `NOT DONE`, the phase is open.

## 5. DONE

Enumerate the parity surfaces the router named and confirm each one, or state explicitly why a surface diverges. Then run the gate once more over the whole change.
