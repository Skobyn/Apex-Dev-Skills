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

- [ TODO — e.g. "must not modify `WebsiteBuilderPage.jsx` save/load flows without checking Firestore data first" ]
- [ TODO — e.g. "must preserve surface parity across admin desktop, admin mobile, portal desktop, portal mobile" ]
- [ TODO — e.g. "must work in both URL-as-truth and switcher-as-truth venue surfaces" ]

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

Schemas, collection paths, indexes. For Firestore work, include the exact collection path under `WEBSITE_BUILDER/{venue}/...` or similar.

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

- [ TODO — e.g. "all existing `WEBSITE_BUILDER/{venue}/globals` data" ]
- [ TODO — e.g. "the URL contract `/site-builder/{slug}/{page-slug}`" ]

### Surface Matrix

> Per the project's `CLAUDE.md` Surface Parity Rule. **Do not delete this section.** If a row truly doesn't apply, write "N/A — reason."

| Surface | Affected? | Notes |
|---------|-----------|-------|
| Admin desktop | [yes/no] | [ TODO ] |
| Admin mobile | [yes/no] | [ TODO ] |
| Portal desktop | [yes/no] | [ TODO ] |
| Portal mobile | [yes/no] | [ TODO ] |
| Published site / live URL | [yes/no] | [ TODO ] |
| Funnel pages (if applicable) | [yes/no] | [ TODO ] |
| Quiz runtime (if applicable) | [yes/no] | [ TODO ] |
| Super admin only | [yes/no] | [ TODO ] |
| Org owner / admin / member | [yes/no] | [ TODO ] |
| Venue manager / staff | [yes/no] | [ TODO ] |

### Venue Impact

If this decision is venue-scoped or affects venue starter kits, list affected venues here. Otherwise: "N/A — platform-wide, no per-venue divergence."

- [ TODO ]

---

## Operator workflows

One paragraph per major user goal under the proposed model. Include preview + publish semantics where applicable.

### Workflow A: [ TODO — e.g. "Manager creates a new X" ]

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

**Debugging guarantees** (per project's `CLAUDE.md` Debugging Rules):

- Before any save/load/publish flow change, we will inspect actual Firestore data first
- For CSS rendering issues, we will check `cssUtils.js` scoping before save/load
- We will compare a working venue side-by-side with a broken one before code changes

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
2. `promote-to-loop.sh {{SLUG}}` initializes dev-plan-loop state
3. `/loop iterate the next phase of .claude/plans/{{SLUG}}-plan.md` starts execution

If reviewed by a partner, see [`architecture-decision-approve`](../../architecture-decision-approve/SKILL.md) for the merge flow that signals the implementor via the cross-session inbox.

---

## Changelog

- {{DATE}} — Drafted by {{AUTHOR_EMAIL}} via `decide-plan-loop` skill
