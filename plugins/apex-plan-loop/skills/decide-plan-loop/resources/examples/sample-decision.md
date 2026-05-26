# Worked example — Per-venue rate limiting

A walkthrough of the `decide-plan-loop` skill end-to-end for a small but non-trivial feature: adding per-venue rate limits to the backend API.

## Session transcript (abbreviated)

### Stage 1: DISCOVER (six rounds)

**Round 1 — Scope**:
- User picks "Standard v1" — "Core flow + obvious extensions"
- Out-of-scope captured: distributed rate limit (single-instance only for v1)

**Round 2 — Constraints**:
- Multi-select: ["Surface parity", "Auth boundary unchanged", "Per-venue isolation"]
- Captured into ADR Context > Constraints verbatim.

**Round 3 — Success criteria**:
- User: "429 returned for venues exceeding 100 req/min; venues stay isolated; p99 not worse than +5ms"
- All three captured as runnable: `pytest tests/rate_limit/test_429.py`, `pytest tests/rate_limit/test_isolation.py`, `python scripts/benchmarks/run_rate_limit.py`.

**Round 4 — Ownership**:
- User: "Just me, but ping Chris before I ship"
- Reviewer: solutions@getapexinsights.com
- Implementor: solutions@getapexinsights.com
- Partner-gate at phase 4→5 for Chris (chris@getapexinsights.com)

**Round 5 — Execution preference**:
- "Multi-agent default" — work is well-bounded

**Round 6 — Gate preference**:
- "Partner-gated where it matters"
- Auto gates: 1→2, 2→3, 3→4
- Partner gate: 4→5 (Chris before ship)
- Human gate: 5→done (user types `approve ship`)

### Stage 2: DRAFT

```bash
.claude/skills/decide-plan-loop/scripts/start.sh per-venue-rate-limit "Per-Venue Rate Limiting"
# → wrote .claude/tasks/per-venue-rate-limit-adr.md
# → wrote .claude/plans/per-venue-rate-limit-plan.md
```

ADR sections seeded with Stage 1 answers. Plan template stub created.

### Stage 3: REFINE

Walked the user through each ADR section:

- **Context** — confirmed, no changes
- **Pseudocode** — user requested a branch for the super-admin bypass case; added it
- **Architecture** — added a "Modules" row for the Redis-less in-memory backing (since v1 is single-instance)
- **Data Model** — none (in-memory only for v1; explicit `Out-of-scope: Firestore-backed limits`)
- **API Surface** — added a debug endpoint `/api/_internal/rate-limit/state` (super-admin only)
- **Surface Matrix** — only backend changes; all UI rows marked "N/A — backend-only feature"
- **Open Questions** — Q1: "key by user OR venue?" → Decision: "by `(venue, user)` tuple"; Q2: "burst window?" → Decision: "60s sliding window"; Q3: "what about webhook endpoints?" → Decision: "exempt — flagged in `RATE_LIMIT_EXEMPT_PREFIXES`"

ADR status flipped to **Accepted**.

### Stage 4: PLAN

Plan generated with five SPARC phases. Highlights:

- **Phase 2.1**: Swarm directive = `Swarm: multi 2 [architect, coder]` (light scaffolding)
- **Phase 3.1**: Swarm directive = `Swarm: hierarchical 4 [security-architect, security-auditor, coder, tester]` (auth boundary work)
- **Phase 4.4**: Swarm directive = `Swarm: hierarchical 3 [performance-engineer, perf-analyzer, tester]` (benchmark)
- **Gate 3→4**: `[gate:auto]` — runs full test suite + Phase 3 contract tests
- **Gate 4→5**: `[gate:partner:chris@getapexinsights.com]` — writes inbox item, halts
- **Gate 5→done**: `[gate:human]` — user types `approve ship`

### Stage 5: PROMOTE

```bash
.claude/skills/decide-plan-loop/scripts/promote-to-loop.sh per-venue-rate-limit

# Validation checklist:
# [x] ADR has every section filled
# [x] Every Open Question has Decision
# [x] ADR status is Accepted
# [x] Plan has 5 phases
# [x] Every task has Acceptance
# [x] Every Acceptance is runnable
# [x] Every gate has a clear approver
# [x] Surface parity section enumerated (all N/A — backend-only)
# [x] Blocked-by graph: no cycles
# [x] Per-phase Swarm directive present
#
# → Initialized dev-plan-loop state at .dev-plan-state/8a7c2d3e9f1b/
# → Ready: /loop iterate the next phase of .claude/plans/per-venue-rate-limit-plan.md
```

## Files produced

- `.claude/tasks/per-venue-rate-limit-adr.md` — the ADR (durable; lives forever)
- `.claude/plans/per-venue-rate-limit-plan.md` — the plan (consumed by `/loop`)
- `.dev-plan-state/<hash>/checkpoint.json` — state managed by dev-plan-loop

## What happens next

User runs:

```
/loop iterate the next phase of .claude/plans/per-venue-rate-limit-plan.md
```

dev-plan-loop owns execution. When the loop reaches Gate 4→5, the orchestrator:

1. Posts to `/api/agent-coordination/inbox` with `forUser: chris@getapexinsights.com`, `kind: phase-gate-approval`, `actionPrompt: "Review per-venue rate limiting before ship"`
2. Sets `halted: true` in checkpoint with `halt_reason: "awaiting partner gate 4-5"`
3. Exits

Chris's next session: SessionStart hook surfaces the inbox item. Chris reviews, marks the inbox item consumed (`POST /api/agent-coordination/inbox/<id>/consume`). User can then resume with `/loop`.

When the loop reaches Gate 5→done, it halts and prompts the user. User types `approve ship` in chat. The orchestrator reads that, advances, and the loop exits at `STATUS: COMPLETE`.

## Total elapsed time

- Stage 1 (DISCOVER): ~5 min (six AskUserQuestion rounds)
- Stage 2 (DRAFT): ~30 sec (script runs)
- Stage 3 (REFINE): ~20 min (walking ADR sections with user)
- Stage 4 (PLAN): ~5 min (auto-generated from ADR; user reviews)
- Stage 5 (PROMOTE): ~30 sec (validation + init.sh)

**Total**: ~30 min of human attention to produce a co-authored ADR + plan that an agent swarm can execute autonomously over hours/days.
