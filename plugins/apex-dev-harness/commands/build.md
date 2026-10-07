---
description: Orient, decide, route, execute and gate a piece of apex-app work end to end.
---

Run the full apex build lifecycle for: **$ARGUMENTS**

## 1. ORIENT

Route the ask before designing anything:

!`node ${CLAUDE_PLUGIN_ROOT}/engine/bin/apex.js route "$ARGUMENTS"`

If the ask names a surface rather than a path, route the most likely path too. Report the lane, the surface status, and the skills the verdict named. Check the agent-coordination preamble for a partner already working this surface — if one exists, surface the overlap before touching code.

## 2. DECIDE

Judge triviality by the `apex-plan` skill's own criteria: three or more phases, **a day or more of effort**, or touching more than one bounded context — plus the durability test of whether someone will ask "why did we do it this way" in six months.

- **Non-trivial** → invoke the `apex-plan` skill from the apex-scope-loop plugin (`apex-scope-loop:apex-plan`; it is a plugin skill, not a file under the repo's `.claude/skills/`). It writes an ADR and a phased plan where apex-plan puts them (by default `.claude/tasks/<slug>-adr.md` and `.claude/plans/<slug>-plan.md`); use the paths it reports.
- **Bounded** → skip to step 3, and say why you judged it bounded.

## 3. ROUTE

Decide who does the work before anyone does it. Two different routers, not to be confused:

- `/apex:route` (step 1, this plugin) answers **which apex-app lane** the change belongs to.
- `/apex-dispatch:route` (the apex-dispatch plugin) answers **which agent, model and provider** does it, with what fan-out, budget and review shape.

If apex-dispatch is installed:

- **Plan** → drive each task with `/apex-dispatch:run <plan>` (iterate → route → dispatch exactly the route → gate → review → done). `/apex-scope-loop:iterate` also routes each task itself when apex-dispatch is present.
- **Bounded** → `/apex-dispatch:route adhoc --tags <tags> --paths <globs> --acceptance '<cmd>'`, then `/apex-dispatch:run adhoc <ROUTE_ID>`.

Dispatch only what the route names; a hook denial is the route speaking, not an error to work around. Without apex-dispatch, skip this step: apex-execute follows the plan's `Swarm:` directive.

## 4. EXECUTE

Work the plan one phase at a time via the `apex-execute` skill (`apex-scope-loop:apex-execute`), on the route from step 3. Do not start a phase before its predecessor has passed step 5.

## 5. GATE — every phase, no exceptions

!`node ${CLAUDE_PLUGIN_ROOT}/engine/bin/apex.js gate --message "phase complete"`

A phase closes when its obligations pass, never because the work feels finished. If the gate says `NOT DONE`, the phase is open.

## 6. DONE

Enumerate the parity surfaces the router named and confirm each one, or state explicitly why a surface diverges. Then run the gate once more over the whole change.
