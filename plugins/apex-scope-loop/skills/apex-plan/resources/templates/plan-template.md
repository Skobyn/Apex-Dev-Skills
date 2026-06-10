# {{TITLE}} — Development Plan

> **ADR**: [`.claude/tasks/{{SLUG}}-adr.md`](../tasks/{{SLUG}}-adr.md)
> **Goal**: {{GOAL_ONE_SENTENCE}}
> **Owner**: {{AUTHOR_EMAIL}}
> **Started**: {{DATE}}
> **Target**: {{TARGET_DATE}}

## Design Intent

Copy the ADR's "Architecture (SPARC)" + "Constraints" sections here so the weekly
architecture-review swarm (run by `apex-execute` continuity layer) can detect
drift between code and intent without having to read the full ADR.

**Bounded contexts**: {{BOUNDED_CONTEXTS}}

**Non-negotiable constraints**:

- [ TODO ]
- [ TODO ]

---

## Execution Strategy

> **Default per phase**: hierarchical-mesh, 6 agents (queen + 5 specialists)
> **Override per task** via the `Swarm:` line on each checkbox.

### Swarm directives (per task)

| Directive | Meaning |
|-----------|---------|
| `Swarm: single [<agent-type>]` | One `Agent` tool invocation; orchestrator picks subagent_type |
| `Swarm: multi <count> [<t1>, <t2>, ...]` | N parallel `Agent` calls **in one message** |
| `Swarm: hierarchical <count> [<t1>, <t2>, ...]` | `mcp__claude-flow__swarm_init` + N spawns, queen-led |
| `Swarm: mesh <count> [<t1>, <t2>, ...]` | Peer-to-peer mesh topology, no queen |

If `Swarm:` is omitted, the orchestrator uses **hierarchical 6 [architect, coder, tester, reviewer, researcher, analyst]**.

### Tier routing (per task)

Every **Phase** task carries a `Tier:` line naming one of the three phase-worker
subagents shipped by the plugin (ADR-0002). The subagent owns the model binding —
plans never name models, so a model upgrade is a one-file change. Gates carry no tier;
the orchestrator evaluates them itself.

| Tier line | Use when |
|-----------|----------|
| `Tier: phase-worker-light` | Bounded, mechanical, <=2 files, no judgment |
| `Tier: phase-worker-standard` | Feature work within one module (DEFAULT) |
| `Tier: phase-worker-heavy` | Cross-module, migrations, autonomous /loop sessions — requires a Rationale row in the ADR's tier table |

A worker that finds itself above its tier reports `escalate` — the orchestrator halts
and reopens the ADR's "Compute Tiers per Phase" Decision. Escalation never auto-bumps.

### Approval gates (between phases)

| Gate tag | Behavior |
|----------|----------|
| `[gate:auto]` | Orchestrator runs the Acceptance check; advances on pass, halts on fail |
| `[gate:human]` | Orchestrator halts; user must type the approval phrase from Acceptance |
| `[gate:partner:<email>]` | Orchestrator writes inbox item to `<email>`, halts until consumed |

Gates are checkbox tasks, just like phases. The line between Phase N and Phase N+1 is a Gate task that blocks Phase N+1 via `Blocked-by:`.

---

## Phases

> **Task format** (the apex-execute `iterate.sh` parses these):
> ```
> - [ ] **Phase X.Y** [tag1][tag2] Imperative task title
>   - Acceptance: <runnable check>
>   - Tier: phase-worker-<light|standard|heavy>   (required on Phase tasks)
>   - Swarm: <directive>            (optional — defaults to hierarchical 6)
>   - Blocked-by: phase-X.Y         (optional)
> ```
>
> **Tags route topology** (see `apex-execute/docs/SWARM_TOPOLOGIES.md`):
> `[backend]` `[frontend]` `[security]` `[perf]` `[ml-serving]` `[infra]`
> `[research]` `[docs]` `[tests]` `[refactor]` `[gate:auto]` `[gate:human]` `[gate:partner:<email>]`

---

### Phase 1 — Specification (SPARC)

Translate the ADR's requirements, constraints, and success criteria into concrete deliverables. No code yet — this phase produces the artifacts the rest of the plan executes against.

- [ ] **Phase 1.1** [research][docs] Survey existing code and write findings
  - Acceptance: `docs/research/{{SLUG}}.md` exists with `Findings:` and `Recommendations:` sections, ≥ 500 words
  - Tier: phase-worker-standard
  - Swarm: single [researcher]

- [ ] **Phase 1.2** [docs] Lock success metrics
  - Acceptance: `docs/{{SLUG}}/success-metrics.md` committed; grep matches every metric named in ADR R1–RN
  - Tier: phase-worker-light
  - Swarm: single [analyst]
  - Blocked-by: phase-1.1

- [ ] **Phase 1.3** [docs] Confirm ADR is `Accepted`, not `Proposed`
  - Acceptance: `grep -q '^**Status**: Accepted' .claude/tasks/{{SLUG}}-adr.md`
  - Tier: phase-worker-light
  - Swarm: single [reviewer]

- [ ] **Gate 1→2** [gate:human] Specification sign-off
  - Acceptance: user types `approve gate-1-2` OR the ADR PR is merged with label `phase-1-approved`
  - Blocked-by: phase-1.3

---

### Phase 2 — Pseudocode (SPARC)

Translate the ADR's pseudocode section into module stubs, type signatures, and interfaces. Still no business logic — just the shape.

- [ ] **Phase 2.1** [backend][architect] Scaffold module structure from ADR Architecture diagram
  - Acceptance: every Module row in the ADR has a corresponding directory/file under `src/{{slug}}/`; `find src/{{slug}} -name "*.py" | wc -l` matches expected count
  - Tier: phase-worker-standard
  - Swarm: hierarchical 3 [architect, coder, reviewer]
  - Blocked-by: gate-1-2

- [ ] **Phase 2.2** [backend][tests] Write type signatures + failing tests for every public function in the pseudocode
  - Acceptance: `pytest tests/{{slug}}/ --collect-only` lists ≥ N tests where N = count of pseudocode steps; `pytest tests/{{slug}}/` reports all failing (red phase of TDD)
  - Tier: phase-worker-standard
  - Swarm: multi 2 [tester, coder]
  - Blocked-by: phase-2.1

- [ ] **Phase 2.3** [frontend][architect] Scaffold UI component tree (if user-facing)
  - Acceptance: every Surface Matrix row marked "yes" in the ADR has a stub component at `ui/src/...`; `npm run typecheck` passes
  - Tier: phase-worker-standard
  - Swarm: hierarchical 3 [architect, coder, reviewer]
  - Blocked-by: phase-2.1

- [ ] **Gate 2→3** [gate:auto] Phase 2 build green
  - Acceptance: `cd backend && python -m pytest tests/{{slug}}/ --collect-only -q && cd .. && cd ui && npm run typecheck`
  - Blocked-by: phase-2.2, phase-2.3

---

### Phase 3 — Architecture (SPARC)

Wire the modules together. Data model migrations, API contracts, and integration points come online. Tests still failing (or in the case of contract tests, now passing against stubs).

- [ ] **Phase 3.1** [backend][security] Wire authn/authz boundary
  - Acceptance: integration test rejects unauthorized requests with 401/403; `pytest tests/{{slug}}/security/` passes
  - Tier: phase-worker-heavy
  - Swarm: hierarchical 4 [security-architect, security-auditor, coder, tester]
  - Blocked-by: gate-2-3

- [ ] **Phase 3.2** [backend][infra] Apply Firestore/BigQuery/migration changes
  - Acceptance: `python backend/scripts/migrate_{{slug}}.py --dry-run` succeeds; data shapes match ADR Data Model table
  - Tier: phase-worker-heavy
  - Swarm: hierarchical 3 [architect, coder, reviewer]
  - Blocked-by: gate-2-3

- [ ] **Phase 3.3** [backend] Implement API endpoints from ADR API Surface table
  - Acceptance: contract tests pass for every row in ADR API Surface; `curl` smoke matches expected response shape
  - Tier: phase-worker-standard
  - Swarm: hierarchical 4 [architect, coder, tester, reviewer]
  - Blocked-by: phase-3.1, phase-3.2

- [ ] **Gate 3→4** [gate:partner:{{REVIEWER_EMAIL}}] Architecture review
  - Acceptance: inbox item `kind=phase-gate-approval gate=3-4` consumed by {{REVIEWER_EMAIL}}
  - Blocked-by: phase-3.3

---

### Phase 4 — Refinement (SPARC, TDD)

Red → green → refactor per feature slice. Make every test from Phase 2 pass. This is where business logic lives.

- [ ] **Phase 4.1** [backend][tests][refactor] TDD slice A
  - Acceptance: `pytest tests/{{slug}}/slice_a/ -v` passes 100%; coverage ≥ 90% on touched files
  - Tier: phase-worker-standard
  - Swarm: hierarchical 5 [coder, tester, reviewer, debugger, refinement]
  - Blocked-by: gate-3-4

- [ ] **Phase 4.2** [backend][tests][refactor] TDD slice B
  - Acceptance: `pytest tests/{{slug}}/slice_b/ -v` passes 100%; coverage ≥ 90% on touched files
  - Tier: phase-worker-standard
  - Swarm: hierarchical 5 [coder, tester, reviewer, debugger, refinement]
  - Blocked-by: gate-3-4

- [ ] **Phase 4.3** [frontend][tests] Wire UI to API; mobile + desktop branches
  - Acceptance: Playwright suite passes for both viewport breakpoints; surface parity grep confirms desktop + mobile both updated
  - Tier: phase-worker-standard
  - Swarm: hierarchical 4 [coder, tester, reviewer, designer]
  - Blocked-by: phase-3.3

- [ ] **Phase 4.4** [perf] Benchmark hot paths against ADR success metrics
  - Acceptance: `python scripts/benchmarks/run_{{slug}}.py` produces baseline.json showing p99 within ADR target
  - Tier: phase-worker-standard
  - Swarm: hierarchical 3 [performance-engineer, perf-analyzer, tester]
  - Blocked-by: phase-4.1, phase-4.2

- [ ] **Gate 4→5** [gate:auto] Phase 4 green build + benchmark
  - Acceptance: full test suite passes; benchmark within ADR target; lint clean
  - Blocked-by: phase-4.3, phase-4.4

---

### Phase 5 — Completion (SPARC)

Integration, deployment, monitoring, docs. The "make it real" phase.

- [ ] **Phase 5.1** [tests] End-to-end smoke
  - Acceptance: `pytest tests/{{slug}}/e2e/ -v` passes against staging
  - Tier: phase-worker-standard
  - Swarm: hierarchical 3 [tester, debugger, reviewer]
  - Blocked-by: gate-4-5

- [ ] **Phase 5.2** [infra] CI gate enforces all of the above on PRs
  - Acceptance: `.github/workflows/{{slug}}.yml` runs full test suite + benchmark; CI red on regression > 10%
  - Tier: phase-worker-standard
  - Swarm: hierarchical 3 [cicd-engineer, infra, reviewer]
  - Blocked-by: phase-5.1

- [ ] **Phase 5.3** [docs] Update `CLAUDE.md`, `MEMORY.md`, and developer guides
  - Acceptance: `grep -q '{{SLUG}}' CLAUDE.md`; new entry in `ui/src/developer/data/guides/` registered in `guide-registry.js`
  - Tier: phase-worker-light
  - Swarm: single [docs-writer]
  - Blocked-by: phase-5.1

- [ ] **Phase 5.4** [docs] Flip ADR status to `Implemented`
  - Acceptance: `grep -q '^**Status**: Implemented' .claude/tasks/{{SLUG}}-adr.md`
  - Tier: phase-worker-light
  - Swarm: single [coder]
  - Blocked-by: phase-5.1, phase-5.2, phase-5.3

- [ ] **Gate 5→done** [gate:human] Ship sign-off
  - Acceptance: user types `approve ship` OR PR merged to main with label `ready-to-ship`
  - Blocked-by: phase-5.4

---

## Out-of-scope

> List explicitly NOT-in-this-plan items so the swarm doesn't drift.

- [ TODO ]
- [ TODO ]

## Open questions (escalations)

> If anything during execution requires a human decision, write it here with `@OWNER` tag so the
> nightly audit (`apex-execute/scripts/audit.sh`) surfaces it.

- (none yet)

---

## Continuity layer suggestions

Run alongside `/loop`:

```bash
# Nightly progress audit
/schedule "0 2 * * *" .claude/skills/apex-execute/scripts/audit.sh .claude/plans/{{SLUG}}-plan.md

# Weekly architecture drift review
/schedule "0 9 * * 1" .claude/skills/apex-execute/scripts/architecture-review.sh .claude/plans/{{SLUG}}-plan.md
```

---

## Status checks

```bash
# Current state
.claude/skills/apex-plan/scripts/status.sh {{SLUG}}

# Evaluate a single gate without /loop running
.claude/skills/apex-plan/scripts/gate.sh .claude/plans/{{SLUG}}-plan.md gate-3-4
```
