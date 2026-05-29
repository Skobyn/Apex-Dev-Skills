---
name: apex-execute
description: Iterate over a multi-phase development plan using /loop (sense layer), /schedule (continuity layer), and advanced hierarchical-mesh swarms. Use when executing long-running dev plans, automating phase-by-phase implementation, monitoring continuous tasks, or building self-directed agent workflows that persist across sessions. Combines bounded reasoning, memory accumulation, and guardrails for autonomous development cycles.
allowed-tools: Bash Read Write Edit Glob Grep ScheduleWakeup Agent
---

# apex-execute — Phased Plan Execution Loop

## What This Skill Does

Turns a structured development plan (markdown checklist of phases) into an autonomous, self-directing execution system using three layers:

1. **Sense layer** (`/loop`) — Active-session iteration: dispatches the next plan phase to a swarm, watches results, advances or replans
2. **Continuity layer** (`/schedule`) — Cross-session persistence: nightly progress audits, daily summaries, weekly architecture reviews
3. **Execution layer** (advanced swarms) — Hierarchical-mesh topology spawns specialized agents per phase with bounded reasoning, memory accumulation, and guardrails

The result is a system that thinks alongside you: it watches reality, persists knowledge, and adjusts strategy across days and weeks — not just a single conversation.

## Prerequisites

- Claude Code 2.0+ with `/loop` and `/schedule` skills enabled
- RuFlo / claude-flow CLI installed (`npx @claude-flow/cli@latest doctor --fix`)
- A development plan in markdown checklist format (see `resources/templates/dev-plan.md`)
- Project-level memory namespace configured (default: `apex-execute`)

## Quick Start

```bash
# 1. Author your dev plan from the template
cp .claude/skills/apex-execute/resources/templates/dev-plan.md docs/plans/my-plan.md
$EDITOR docs/plans/my-plan.md

# 2. Initialize state and the orchestrator swarm
./.claude/skills/apex-execute/scripts/init.sh docs/plans/my-plan.md

# 3. Start the active sense loop (self-paced)
/loop ./.claude/skills/apex-execute/scripts/iterate.sh docs/plans/my-plan.md

# 4. (Separately) schedule the continuity layer
/schedule "nightly @ 02:00" ./.claude/skills/apex-execute/scripts/audit.sh docs/plans/my-plan.md
/schedule "weekly @ Mon 09:00" ./.claude/skills/apex-execute/scripts/architecture-review.sh docs/plans/my-plan.md
```

Inside an active session, prefer the slash form so the model self-paces with `ScheduleWakeup`:

```
/loop iterate the next phase of docs/plans/my-plan.md
```

## The Three Layers

### Layer 1: Sense (`/loop`)

Active-session, fast cadence (60s–30min). Watches reality; doesn't persist past the session. Use for:

| Pattern | Cadence | Purpose |
|---------|---------|---------|
| **Phase advance** | self-paced | Dispatch next plan checkbox to swarm, capture verdict |
| **Test watch** | 120–270s | Re-run failing tests until green, then advance |
| **Deploy monitor** | 60–270s | Poll deploy/job status, escalate on failure |
| **Drift detect** | 600–1800s | Compare current metrics vs. baseline; flag regressions |
| **Swarm health** | 300–1200s | `swarm_status` + `swarm_health`; restart dead workers |

See [docs/LOOP_PATTERNS.md](docs/LOOP_PATTERNS.md) for delay-tuning rules (cache-window awareness).

### Layer 2: Continuity (`/schedule`)

Background, slow cadence (hours–weeks). Persists across sessions, accumulates memory. Use for:

| Pattern | Cadence | Purpose |
|---------|---------|---------|
| **Nightly audit** | daily 02:00 | Diff plan progress vs. yesterday; append to `MEMORY.md` |
| **Daily summary** | daily 17:00 | One-paragraph state-of-the-plan; surface blockers |
| **Weekly architecture review** | Mon 09:00 | Re-read code; flag drift from plan's design intent |
| **Monthly retrospective** | 1st of month | Distill patterns: what worked, what stalled, why |
| **Cleanup follow-up** | 1-shot, +14d | After flag/experiment ships, open the removal PR |

See [docs/SCHEDULE_PATTERNS.md](docs/SCHEDULE_PATTERNS.md) for cron syntax and one-shot vs. recurring.

### Layer 3: Execution (Advanced Swarms)

Each plan phase is dispatched to a fresh hierarchical-mesh swarm (queen-led, 6–8 specialized workers, Raft consensus). The orchestrator:

1. Reads the next unchecked task from the plan
2. Selects swarm topology + agent roles based on task tags (e.g., `[security]` → security-architect + security-auditor)
3. Spawns all agents in **one message** with `run_in_background: true`
4. Waits for verdicts; never polls
5. Stores trajectory + outcome in AgentDB via `memory_store` with namespace `apex-execute`
6. Marks the task complete in the plan; commits via hook

See [docs/SWARM_TOPOLOGIES.md](docs/SWARM_TOPOLOGIES.md) for topology-per-phase mapping.

## Step-by-Step Guide

### 1. Author a Bounded Plan

Use `resources/templates/dev-plan.md`. Each task **must** have:

- A clear goal (one sentence)
- Tags for swarm routing: `[backend]`, `[frontend]`, `[security]`, `[perf]`, `[ml-serving]`, `[infra]`
- Acceptance criteria (the exit condition the swarm verdicts against)
- Optional `[blocked-by: phase-N.M]` cross-reference

Example task line:
```markdown
- [ ] **Phase 2.3** [backend][security] Wire JWT refresh-token rotation
  - Acceptance: integration test asserts old refresh token rejected after rotation
  - Blocked-by: phase-2.1
```

### 2. Initialize

```bash
./.claude/skills/apex-execute/scripts/init.sh docs/plans/my-plan.md
```

This creates `.dev-plan-state/<plan-hash>/checkpoint.json` and seeds the `apex-execute` memory namespace with plan metadata.

### 3. Start the Sense Loop

In an active Claude Code session:

```
/loop iterate the next phase of docs/plans/my-plan.md
```

The model will:
1. Read `checkpoint.json` to find the next unchecked task
2. Spawn the appropriate swarm via Agent tool (hierarchical, 6–8 agents, all in one message)
3. Wait for swarm verdicts (no polling)
4. Run acceptance criteria as the verdict gate
5. On pass: check the box, write summary to memory, advance
6. On fail: store failure pattern, surface to user, halt
7. Use `ScheduleWakeup` to self-pace (default 1200–1800s between iterations for non-urgent work)

### 4. Schedule the Continuity Layer

In a separate command (one-time setup):

```bash
# Nightly progress audit
/schedule "0 2 * * *" ./.claude/skills/apex-execute/scripts/audit.sh docs/plans/my-plan.md

# Weekly architecture review
/schedule "0 9 * * 1" ./.claude/skills/apex-execute/scripts/architecture-review.sh docs/plans/my-plan.md
```

These persist across sessions and write findings to the memory namespace.

### 5. Inspect State Anytime

```bash
./.claude/skills/apex-execute/scripts/status.sh docs/plans/my-plan.md
```

Prints: completed phases, current phase, last verdict, next scheduled run, memory namespace size.

## The Three Methods (Bounded · Memory · Guardrails)

### Bounded Reasoning

Every iteration has:
- **One task** from the plan (not "make progress" — a specific checkbox)
- **A verdict gate** (acceptance criteria as a runnable check)
- **A timeout** (default 30min per phase; orchestrator halts and surfaces if exceeded)

This prevents runaway loops.

### Memory Accumulation

After each phase, the orchestrator stores:
- **Outcome**: pass/fail + verdict reason
- **Trajectory**: which agents ran, what tools, what files changed
- **Pattern**: distilled insight ("JWT rotation needed both server-side blacklist AND client cache invalidation")

Stored via `memory_store` with namespace `apex-execute` and embedded with ONNX vectors for `memory_search` recall on future related phases.

### Guardrails

Enforced via Claude Code hooks (`settings.json`):
- **Pre-edit**: refuse writes to `/src/security/**` without security-auditor in the swarm
- **Post-edit**: run linters/formatters; reject on failure
- **Pre-task**: AIDefense scan on inputs
- **Post-task**: persist outcome to memory, commit if passing

See `resources/templates/hooks-snippet.json` for a starter config.

## Available Scripts

| Script | Purpose |
|--------|---------|
| `scripts/init.sh PLAN.md` | Create state dir, seed memory namespace |
| `scripts/iterate.sh PLAN.md` | Run one phase iteration (called by `/loop`) |
| `scripts/audit.sh PLAN.md` | Nightly diff + memory append (called by `/schedule`) |
| `scripts/architecture-review.sh PLAN.md` | Weekly drift check vs. plan intent |
| `scripts/status.sh PLAN.md` | Print current state |
| `scripts/checkpoint.sh PLAN.md` | Manually advance/rewind state |

## Resources

- `resources/templates/dev-plan.md` — Authoring template
- `resources/templates/checkpoint.json` — State schema
- `resources/templates/hooks-snippet.json` — Guardrail hooks
- `resources/examples/sample-plan.md` — Worked example (auth refactor)

## Advanced Topics

- [LOOP_PATTERNS.md](docs/LOOP_PATTERNS.md) — Sense-layer recipes with delay tuning
- [SCHEDULE_PATTERNS.md](docs/SCHEDULE_PATTERNS.md) — Continuity-layer recipes with cron
- [SWARM_TOPOLOGIES.md](docs/SWARM_TOPOLOGIES.md) — Phase-tag → topology mapping

## Troubleshooting

### Issue: Loop fires but no progress
**Cause**: All tasks checked, or all remaining tasks `[blocked-by:]` an unchecked predecessor
**Solution**: `./scripts/status.sh PLAN.md` — surfaces the blocking graph

### Issue: Swarm verdicts always fail
**Cause**: Acceptance criteria are not runnable (e.g., "improve UX" — no gate)
**Solution**: Rewrite the task with a check the orchestrator can execute (`pytest path/`, `curl /health`, file-exists, regex-match)

### Issue: Memory namespace grows unbounded
**Cause**: No consolidation
**Solution**: Schedule monthly: `/schedule "0 3 1 * *" memory consolidate --namespace apex-execute`

### Issue: `/loop` keeps running after plan complete
**Cause**: ScheduleWakeup not omitted on completion
**Solution**: `iterate.sh` exits with code 0 + writes `COMPLETE` marker; the model should recognize this and not call ScheduleWakeup
