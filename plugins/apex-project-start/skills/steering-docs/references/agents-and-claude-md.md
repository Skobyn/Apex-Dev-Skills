# AGENTS.md & CLAUDE.md

The 2025–2026 consensus: **AGENTS.md is the converged open standard** (stewarded under the Linux Foundation; 60k+ repos; read natively by Codex, Cursor, Copilot coding agent, Gemini CLI, Aider, Windsurf, Zed, Jules, Factory, and more). Claude Code reads **CLAUDE.md**, not AGENTS.md — so make AGENTS.md canonical and bridge CLAUDE.md to it.

## `AGENTS.md` template (keep it tight)

```markdown
# AGENTS.md

> Source of truth for AI coding agents working in this repo. Humans: see README.md.

## Project
<project-name> — <one-line purpose>. <Stack> <project-type>.

## Setup & commands
- Install:   `<install cmd>`
- Test:      `<test cmd>`
- Lint:      `<lint cmd>`
- Typecheck: `<typecheck cmd>`   <!-- omit if N/A -->
- Build:     `<build cmd>`
- Run:       `<run cmd>`         <!-- apps/services only -->

## Architecture
<2–5 bullets on layout and where things live. e.g. "src/ holds the library;
tests/ mirrors src/; cmd/<name> is the only entrypoint." Only what isn't obvious from the tree.>

## Conventions
- Commits: Conventional Commits (`type(scope): desc`).
- <project-specific convention #1>
- <project-specific convention #2 — only non-obvious ones>

## Testing
- Add/extend a test for every behavior change; CI must stay green.
- Coverage threshold: <N>% (enforced in CI).

## Building new features
This repo was initialized by Apex Project Start with governance, tests, CI, and the
Apex/ruflo toolchain wired up. For any non-trivial feature, work *within* those frameworks:
1. **Plan first — apex-plan:** `/apex-scope-loop:start <feature-slug>` → ADR + phased, gated plan before coding.
2. **Execute — apex-loop:** `/apex-scope-loop:iterate <plan-path>` → advance the plan phase-by-phase (swarm + acceptance gates).
3. Follow this file's conventions, keep CI green, add tests, and write an ADR in `docs/adr/` for significant decisions.
4. One-file/trivial fixes skip the ceremony. (ruflo provides the memory + swarm MCP tools these commands use.)

## Maintenance (periodic, tracked in `.apex/maintenance.json`)
Some hygiene runs on a cadence, not per-PR. Last-run dates live in `.apex/maintenance.json`.
- **Dead-code sweep** (~every 3 days): `scripts/dead-code-sweep.sh` runs `<vulture/knip/deadcode>`.
  Triage the ranked list by hand — delete dead code (don't comment it out), whitelist false
  positives, commit, then stamp with `scripts/dead-code-sweep.sh --done`.
- **Agents:** at the start of a working session, read `.apex/maintenance.json`. If a task's
  `last_run` is null or older than its `cadence_days`, **tell the user it's N days overdue and
  ask whether you should run it now.** If yes: run the sweep, present the ranked list, propose
  deletions for approval (never delete without confirmation), update the whitelist, then stamp
  the run. If no, leave it.

## Gotchas
- <real footgun you'd warn a new contributor about — omit the section if none yet>

## Security
- Never commit secrets; real config lives in `.env` (gitignored). See `.env.example`.
- <any project-specific security rule, e.g. "all DB access must check row ownership">
```

> Generate the **Building new features** section only when the Apex suite was provisioned. If just ruflo was installed, reference ruflo orchestration instead. If neither, omit the section.

**Monorepos:** add a nested `AGENTS.md` per package; agents read the nearest file in the tree. Don't repeat the root content — only the package-specific deltas.

## `CLAUDE.md` (the bridge — short)

```markdown
# CLAUDE.md

This project's agent guidance lives in AGENTS.md. Read it first.

@AGENTS.md

## Claude-specific notes
- For non-trivial features, use **apex-plan** (`/apex-scope-loop:start <slug>`) to plan,
  then **apex-loop** (`/apex-scope-loop:iterate <plan-path>`) to execute — see "Building
  new features" in AGENTS.md. (Omit this line if the Apex suite wasn't provisioned.)
- <any other Claude Code specifics, e.g. preferred subagents or plan-mode expectations.>
```

The `@AGENTS.md` import inlines the file into Claude's context (imports resolve up to 4 hops), so the "Building new features" workflow flows into Claude's context automatically. Single source of truth — edit AGENTS.md, CLAUDE.md follows.

## Optional: Cursor / Windsurf bridges (only if the team uses them)

- Cursor: a `.cursor/rules/000-source.mdc` whose body is "Follow the conventions in `AGENTS.md`." (Cursor also reads AGENTS.md directly in recent versions.)
- Windsurf: `.windsurf/rules/source.md` pointing to AGENTS.md.

Don't generate these unless asked — fewer files, one source of truth.

## What NOT to put in any steering file
- Generic advice ("write readable code", "add comments").
- Anything the linter/formatter/typechecker already enforces (style, import order).
- File-by-file descriptions or anything that goes stale immediately.
- Auto-generated boilerplate. Litmus test: *would removing this line cause an agent to make a mistake?* If not, cut it.
