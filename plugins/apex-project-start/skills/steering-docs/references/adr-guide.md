# Architecture Decision Records (ADRs)

Capture the *why* behind significant decisions so future maintainers (human and AI) don't re-litigate them. Use the **Nygard format** (Context / Decision / Consequences), one markdown file per decision, monotonic numbering, stored in **`docs/adr/`**. Supersede (link), never edit, past decisions.

## Conventions
- Filename: `NNNN-title-with-dashes.md` (4-digit zero-padded, e.g. `0001-record-architecture-decisions.md`).
- Status: `Proposed` → `Accepted` → `Superseded by ADR-NNNN` / `Deprecated`.
- One decision per file. Keep it short — a decision record, not an essay.

## ADR-0001 (always generate when ADRs enabled)

`docs/adr/0001-record-architecture-decisions.md`:
```markdown
# 1. Record architecture decisions

Date: <YYYY-MM-DD>

## Status
Accepted

## Context
We need to record the architectural decisions made on this project, so that
the reasoning is available to future contributors (human and AI agents) and
decisions aren't silently reversed or re-litigated.

## Decision
We will use Architecture Decision Records, as described by Michael Nygard, in
the Context/Decision/Consequences format. ADRs live in `docs/adr/`, are numbered
sequentially, and are immutable once Accepted — a changed decision is a new ADR
that supersedes the old one.

## Consequences
- The "why" behind decisions is preserved and diffable like code.
- Contributors must write an ADR for significant or non-obvious choices.
- Superseded ADRs remain for historical context, marked accordingly.
```

## ADR-0002 (generate if the stack/architecture choice was non-obvious)

Record the stack decision when it wasn't the trivial default — e.g. choosing ESLint+Prettier over Biome, mypy over pyright, a specific framework, or a monorepo layout. Template:
```markdown
# 2. <Decision title in imperative, e.g. "Use uv for Python tooling">

Date: <YYYY-MM-DD>

## Status
Accepted

## Context
<What forces are at play? What constraints, requirements, or tradeoffs?>

## Decision
<What we decided, stated plainly.>

## Consequences
<What becomes easier and what becomes harder as a result. Include any follow-ups.>
```

## Tooling note (next-steps, optional)
For ongoing ADR authoring, the project can adopt `adr-tools` (Nygard CLI) or the **MADR** template (`adr.github.io`) for richer, section-oriented records. Don't install tooling at init unless asked — the markdown files are enough to start.

## What earns an ADR
- Choosing between competing technologies/frameworks/patterns with real tradeoffs.
- Decisions expensive to reverse (data model, public API shape, auth model, deployment target).
- Anything a future contributor would reasonably ask "why was it done this way?"

What does *not*: trivial defaults, reversible style choices, anything the linter encodes.
