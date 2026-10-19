# {{TITLE}} — Development Plan

> **ADR**: [`.claude/tasks/{{SLUG}}-adr.md`](../tasks/{{SLUG}}-adr.md)
> **Goal**: {{GOAL_ONE_SENTENCE}}
> **Scope**: {{SCOPE}}
> **Owner**: {{AUTHOR_EMAIL}}
> **Started**: {{DATE}}
> **Target**: {{TARGET_DATE}}

## Design Intent

**Bounded contexts**: {{BOUNDED_CONTEXTS}}

**Non-negotiable constraints**:

- [ TODO ]

## Threat model

Trusted, non-malicious agents and operators. Guard against accidents and realistic misuse. Not a sandbox: deliberate tampering with state, config or the harness by the trusted agent, and obfuscated inputs, are out of scope.

> Every reviewer receives this section verbatim. Edit it before the first review: name the trust
> model, the in-scope actors and the out-of-scope classes.

---

## Phases

> Lean plan: two phases are scaffolded. A `bugfix` allows at most 2 phases, a `poc` at most 3.
> Task format: `- [ ] **Phase X.Y** [tag] Title` with a runnable `Acceptance:` line and optional
> `Swarm:`, `Blocked-by:`, `Threat:`, `Review:` lines. Gates are checkbox tasks too. The green gate,
> independent review and risk tier apply exactly as for a `feature` plan.

---

### Phase 1 — Build

- [ ] **Phase 1.1** [backend][tests] Implement the change with a failing-first test
  - Acceptance: `{test command}` passes; the new test failed before the change
  - Swarm: single [coder]

- [ ] **Gate 1→2** [gate:auto] Build green
  - Acceptance: `{test command}`
  - Blocked-by: phase-1.1

---

### Phase 2 — Complete

- [ ] **Phase 2.1** [docs] Flip ADR status to `Implemented`
  - Acceptance: `grep -q '^**Status**: Implemented' .claude/tasks/{{SLUG}}-adr.md`
  - Swarm: single [coder]
  - Blocked-by: gate-1-2

- [ ] **Gate 2→done** [gate:human] Ship sign-off
  - Acceptance: user types `approve ship`
  - Blocked-by: phase-2.1

---

## Out-of-scope

- [ TODO ]

## Open questions (escalations)

- (none yet)
