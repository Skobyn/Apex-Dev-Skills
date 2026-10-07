# ADR-{{NNNN}}: {{TITLE}}

**Status**: Proposed
**Date**: {{DATE}}
**Slug**: `{{SLUG}}`
**Author**: {{AUTHOR_EMAIL}}
**Reviewer**: {{REVIEWER_EMAIL}}
**Implementor**: {{IMPLEMENTOR_EMAIL}}
**Companion Plan**: [`.claude/plans/{{SLUG}}-plan.md`](../plans/{{SLUG}}-plan.md)

> Status transitions: `Proposed` → `Accepted` → `Implemented` → (optional) `Superseded by ADR-MMMM`.
> `promote-to-loop.sh` refuses to run until status is `Accepted`.

---

## TL;DR

3–5 bullets. A reader should be able to predict whether they'll approve or push back after reading just this section.

- [ TODO ]
- [ TODO ]
- [ TODO ]

---

## Context (SPARC: Specification)

### Why this matters

Concrete pain points this decision solves. Incident references where available. Without this section, the "why" rots six months from now.

[ TODO ]

### Requirements

Functional + non-functional, with priority labels.

| ID | Priority | Requirement |
|----|----------|-------------|
| R1 | MUST | [ TODO ] |
| R2 | MUST | [ TODO ] |
| R3 | SHOULD | [ TODO ] |
| R4 | MAY | [ TODO ] |

### Constraints

Non-negotiables imposed by the platform, partners, compliance, or existing architecture.

- [ TODO — e.g. "must not change the persisted data format without a migration and a read of real production data first" ]
- [ TODO — e.g. "must keep every user-facing surface listed in the Surface Matrix in parity" ]
- [ TODO — e.g. "public API contract `v1` stays backward compatible" ]

### Success criteria

How we'll know this shipped correctly. Each criterion should be runnable (a test, a metric threshold, a deploy event).

- [ TODO ] — runnable: [ test command or metric ]
- [ TODO ] — runnable: [ test command or metric ]

---

## Decision

### Pseudocode (SPARC)

High-level algorithm or data flow that captures the decision shape. Use plain pseudocode, not a specific language. The companion plan's Phase 2 (Pseudocode) tasks translate this into concrete module structure.

```
ALGORITHM {{algorithm_name}}:
  INPUT:
    - [ TODO ]
  PRECONDITIONS:
    - [ TODO ]
  STEPS:
    1. [ TODO ]
    2. [ TODO ]
       IF [condition] THEN
         [branch A]
       ELSE
         [branch B]
       END IF
    3. [ TODO ]
  POSTCONDITIONS:
    - [ TODO ]
  OUTPUT:
    - [ TODO ]

ERROR PATHS:
    - [ when ... return ... ]
```

### Architecture (SPARC)

ASCII diagram + module breakdown. Specific enough that implementation could start from this section.

```
[ ASCII diagram here — boxes, arrows, dependencies ]
```

**Modules**:

| Module | Responsibility | Depends on |
|--------|----------------|------------|
| [ TODO ] | [ TODO ] | [ TODO ] |

**Bounded contexts touched**:

- [ TODO — e.g. "backend/app/services/foo (owned by X)", "ui/src/pages/Bar (owned by Y)" ]

### Data Model

Schemas, tables / collection paths, indexes. Name the exact table or collection path each change touches.

```
[ TODO — collection/table layout, key fields, indexes ]
```

### API Surface

New or modified endpoints, RPC contracts, event shapes.

| Verb | Path | Purpose | Auth |
|------|------|---------|------|
| [ TODO ] | [ TODO ] | [ TODO ] | [ TODO ] |

---

## What changes / What stays

| Area | Today | After this decision |
|------|-------|---------------------|
| [ TODO ] | [ TODO ] | [ TODO ] |
| [ TODO ] | [ TODO ] | [ TODO ] |

**Stays untouched** (load-bearing reassurance for partners):

- [ TODO — e.g. "all existing rows in the `accounts` table" ]
- [ TODO — e.g. "the public URL contract `/docs/{slug}`" ]

### Surface Matrix

> Every user-facing surface and role this decision could touch. **Do not delete this section.** Replace the example rows with the project's real surfaces (see its `CLAUDE.md` if it defines them). If a row truly doesn't apply, write "N/A — reason."

| Surface | Affected? | Notes |
|---------|-----------|-------|
| Web desktop | [yes/no] | [ TODO ] |
| Web mobile | [yes/no] | [ TODO ] |
| Native / CLI clients (if any) | [yes/no] | [ TODO ] |
| Public API consumers | [yes/no] | [ TODO ] |
| Background jobs / workers | [yes/no] | [ TODO ] |
| Admin / operator role | [yes/no] | [ TODO ] |
| End-user role(s) | [yes/no] | [ TODO ] |

### Tenant / Environment Impact

If this decision is scoped to particular tenants, customers, or deployments, list them here. Otherwise: "N/A — applies everywhere, no per-tenant divergence."

- [ TODO ]

---

## Operator workflows

One paragraph per major user goal under the proposed model. Include preview + publish semantics where applicable.

### Workflow A: [ TODO — e.g. "Operator creates a new X" ]

1. [ TODO ]
2. [ TODO ]

### Workflow B: [ TODO ]

1. [ TODO ]
2. [ TODO ]

---

## Open Questions

Numbered. Each starts with a `Default:` line. During REFINE, the user resolves each to a `Decision:` line — the `Default:` is replaced or struck through.

**Q1.** [ TODO question ]
- **Default**: [ TODO proposed answer with brief reasoning ]
- **Decision**: _(filled in during refinement)_

**Q2.** [ TODO ]
- **Default**: [ TODO ]
- **Decision**: _(filled in during refinement)_

**Q3.** [ TODO ]
- **Default**: [ TODO ]
- **Decision**: _(filled in during refinement)_

> Cap at ~5. If you have more, the scope is too big — split into two ADRs.

---

## Risks & Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| [ TODO ] | high/med/low | [ TODO ] |
| [ TODO ] | high/med/low | [ TODO ] |

**Debugging guarantees** (plus any Debugging Rules in the project's `CLAUDE.md`):

- Before any change to a save/load/publish flow, we will inspect the actual persisted data first
- We will reproduce a failure with a test or a script before changing code
- We will compare a working case side-by-side with a broken one before code changes

**Rollback story**: [ TODO — how do we undo if Phase N goes sideways? ]

---

## Consequences

### Positive

- [ TODO ]

### Negative

- [ TODO ]

### Neutral / Worth noting

- [ TODO ]

---

## Methodology

What was done to arrive at this decision (for reproducibility / archeology).

- **Sub-agents invoked**: [ TODO — e.g. "researcher for industry evidence (Section: Industry evidence)", "Plan agent for build-order sketch" ]
- **Sources consulted**: [ TODO ]
- **Comparable platforms surveyed**: [ TODO ]
- **Counter-evidence considered**: [ TODO — every decision has trade-offs; if you found none, look harder ]

---

## Industry evidence (optional)

If decision crosses an ownership boundary or affects compose-ability of multiple primitives, include 2–5 references from comparable platforms. Inline citations only — no footnotes. Drop the researcher sub-agent's findings here verbatim.

| Platform | What they do | Source (URL + date) |
|----------|--------------|---------------------|
| [ TODO ] | [ TODO ] | [ TODO ] |

---

## Approval

When this ADR's status flips to **Accepted**:

1. The companion plan is the source of truth for execution
2. `promote-to-loop.sh {{SLUG}}` initializes apex-execute state
3. `/loop iterate the next phase of .claude/plans/{{SLUG}}-plan.md` starts execution

If reviewed by a partner, their approval is recorded here (name, date, link to the review) before the status flips. Partner gates in the plan notify through `$APEX_PARTNER_NOTIFY_CMD` when it is set, and otherwise wait for the approval phrase like a `[gate:human]` gate.

---

## Changelog

- {{DATE}} — Drafted by {{AUTHOR_EMAIL}} via `apex-plan` skill
