---
name: system-map
description: Dispatch the system-map subagent to explore a codebase in its own isolated context and return a concise architecture map (entry points, module boundaries, data flows, external deps, "how X talks to Y"). Pass an optional scope/question as $ARGUMENTS.
argument-hint: "[path or question, e.g. 'how does auth reach the user store?']"
---

Delegate to the `system-map` agent (via the `Agent` tool) to build an architecture map
of this codebase **in its own isolated context**, so the main thread stays clean.

Scope / question: `$ARGUMENTS`

Instruct the agent to:

1. Orient on the repo layout, language(s), framework(s), and build system.
2. Identify entry points (main, server bootstrap, CLI, handlers, jobs, consumers).
3. Map module boundaries and their dependencies (read imports, not whole files).
4. Trace the primary data flow from an entry point to persistence and back.
5. Catalog external dependencies and the module that owns each boundary.
6. If `$ARGUMENTS` names a specific interaction ("how X talks to Y"), give the concrete
   call chain with `file:symbol` references.

The agent must return a **concise Markdown report** — no raw file dumps — using the
report shape in `agents/system-map.md`. If `$ARGUMENTS` is empty, do a full cold-start
onboarding map. If it points at an existing `docs/system-map.md`, update that map in
place and return only the diff/summary.

When the agent reports back, relay its summary to the user verbatim and offer to persist
the map to `docs/system-map.md` if it isn't already.
