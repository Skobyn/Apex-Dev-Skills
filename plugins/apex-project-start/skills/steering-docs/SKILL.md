---
name: steering-docs
description: Author the thin, durable AI-collaboration and decision-record files for a new repo — AGENTS.md (the cross-tool source of truth), a CLAUDE.md that bridges to it, and the bootstrap ADR. Invoked by /apex-project-start:new after scaffolding; can also be used directly to add steering files to an existing repo. Keeps artifacts concise and project-specific — resists markdown bloat.
---

# steering-docs

Generates the durable governing documents for a new project. You receive the resolved choices and the file list the scaffolder created. Produce **thin, specific** documents — the documented failure mode of spec-driven tooling is artifact bloat (2,500 lines of markdown for 700 of code). Every line must earn its place.

## What to author

1. **`AGENTS.md`** (root) — the cross-tool source of truth every major coding agent reads (Codex, Cursor, Copilot, Gemini CLI, Aider, Windsurf, Zed, etc.; 60k+ repos, Linux Foundation standard). See [references/agents-and-claude-md.md](references/agents-and-claude-md.md). **AGENTS.md MUST include a "Building new features" section** (see below) so future agents implement work *within* the scaffolded frameworks.
2. **`CLAUDE.md`** (root) — a short bridge: import AGENTS.md, add only Claude-specific notes. Don't duplicate rules across the two files.
3. **`docs/adr/0001-record-architecture-decisions.md`** — the bootstrap ADR (if ADRs are enabled). If the stack choice was non-obvious, also write `0002-<topic>.md`. See [references/adr-guide.md](references/adr-guide.md).

### Required "Building new features" section (apex-plan / apex-loop)

This project is initialized with the Apex/ruflo toolchain in place. AGENTS.md must tell future agents to drive non-trivial feature work through that workflow rather than ad-hoc coding — this is how the governed foundation actually gets used. Include this section verbatim-ish (adapt commands to the project), and only when dev-environment provisioning installed the Apex suite (otherwise omit or soften to "if `apex-scope-loop` is installed"):

```markdown
## Building new features

This repo was initialized by Apex Project Start with governance, tests, CI, and the
Apex/ruflo toolchain already wired up. For any non-trivial feature or change, work
*within* those frameworks using the Apex workflow — do not freelance:

1. **Plan first — apex-plan.** Run `/apex-scope-loop:start <feature-slug>` to co-author an
   ADR + a phased, gated build plan before writing code. The plan records the decision and
   breaks the work into acceptance-gated phases.
2. **Execute — apex-loop.** Run `/apex-scope-loop:iterate <plan-path>` to advance the plan
   one phase at a time (swarm dispatch, acceptance checks, checkbox tracking).
3. **Stay inside the guardrails.** Follow the conventions in this file, keep CI green, add
   tests for every behavior change, use Conventional Commits, and write an ADR in
   `docs/adr/` for any significant or non-obvious decision.
4. **Small changes** (one-file fixes, typos) skip the ceremony — just implement and test.

ruflo provides the memory + swarm MCP tools these commands rely on.
```

Keep it tight; do not balloon it. If only ruflo (not the Apex suite) was provisioned, reference ruflo orchestration instead of the apex-scope-loop commands.

## Core rules

- **One source of truth.** AGENTS.md holds the real content; CLAUDE.md points to it via `@AGENTS.md`. Cursor/Windsurf rule files (only if the team uses them) likewise point to AGENTS.md — never maintain N copies.
- **Concise & specific.** Frontier models reliably follow ~150–200 instructions; keep AGENTS.md well under that. Include exact build/test/lint/run commands, non-obvious architecture, real gotchas. Exclude platitudes ("write clean code") and anything a linter/formatter already enforces.
- **Don't make the LLM do a linter's job.** If a rule is mechanically enforceable, it belongs in the linter/hook config, not the steering file.
- **Project-specific only.** No generic advice that would apply to any repo.

After writing, report the files created.
