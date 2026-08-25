# [Project / Feature Name] — Development Plan

> **Goal**: One sentence describing the end state this plan delivers.
> **Owner**: [name]
> **Started**: YYYY-MM-DD
> **Target**: YYYY-MM-DD

## Design Intent

2–4 paragraphs describing the architecture, the bounded contexts, and the
non-negotiable constraints. The weekly architecture-review swarm reads this
section to detect drift in the code.

---

## Phases

> **Task format** (the orchestrator parses these):
> ```
> - [ ] **Phase X.Y** [tag1][tag2] Short imperative task title
>   - Acceptance: <runnable check the swarm verdicts against>
>   - Blocked-by: phase-X.Y   (optional)
> ```
>
> **Tags** route the swarm topology — see `docs/SWARM_TOPOLOGIES.md`:
> `[backend]` `[frontend]` `[security]` `[perf]` `[ml-serving]` `[infra]`
> `[research]` `[docs]` `[tests]` `[refactor]`

### Phase 1 — Foundation

- [ ] **Phase 1.1** [research] Survey existing patterns in `src/` and write findings to `docs/research/foundation.md`
  - Acceptance: file exists, contains "Findings:" and "Recommendations:" sections, ≥ 500 words

- [ ] **Phase 1.2** [backend][refactor] Extract shared validation into `src/core/validation/`
  - Acceptance: `pytest tests/unit/core/validation/` passes; ≥ 3 modules import from new path
  - Blocked-by: phase-1.1

### Phase 2 — Core Implementation

- [ ] **Phase 2.1** [backend] Implement primary domain service
  - Acceptance: `pytest tests/unit/domain/` passes 100%
  - Blocked-by: phase-1.2

- [ ] **Phase 2.2** [backend][security] Wire authn/authz boundary
  - Acceptance: integration test rejects unauthorized requests with 401/403
  - Blocked-by: phase-2.1

- [ ] **Phase 2.3** [perf] Add benchmarks for hot paths
  - Acceptance: `python scripts/benchmarks/run.py` produces baseline.json and shows p99 < 100ms
  - Blocked-by: phase-2.1

### Phase 3 — Integration & Polish

- [ ] **Phase 3.1** [tests][refactor] Property-based tests for domain invariants
  - Acceptance: `pytest tests/property/` passes with ≥ 1000 examples
  - Blocked-by: phase-2.1

- [ ] **Phase 3.2** [docs] Update CLAUDE.md and ADRs to reflect final shape
  - Acceptance: ADR-NNN exists; `grep -q "phase-2.1" CLAUDE.md`
  - Blocked-by: phase-2.2, phase-2.3

- [ ] **Phase 3.3** [infra] CI gate enforces all of the above on PRs
  - Acceptance: `.github/workflows/*.yml` runs tests + benchmarks; fails when p99 regresses > 10%
  - Blocked-by: phase-3.1

---

## Out-of-scope

- (List things explicitly NOT in this plan, so the swarm doesn't drift)

## Open questions

- (Things that need a human decision; flag with `@OWNER` to surface in audits)
