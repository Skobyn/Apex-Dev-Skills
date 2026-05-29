# Schedule Patterns — Continuity Layer

`/schedule` runs in the background, persists across sessions, and accumulates memory over time. Use cron syntax or one-shot at-time.

## Cron Quick Reference

```
┌── minute (0-59)
│ ┌── hour (0-23)
│ │ ┌── day of month (1-31)
│ │ │ ┌── month (1-12)
│ │ │ │ ┌── day of week (0-7, 0|7=Sun)
│ │ │ │ │
* * * * *   command
```

| Spec | Meaning |
|------|---------|
| `0 2 * * *` | every day at 02:00 |
| `0 17 * * 1-5` | weekdays at 17:00 |
| `0 9 * * 1` | Mondays at 09:00 |
| `0 3 1 * *` | 1st of every month at 03:00 |
| `*/30 * * * *` | every 30 minutes |

## Recipes

### 1. Nightly progress audit (recurring)

```
/schedule "0 2 * * *" run .claude/skills/dev-plan-loop/scripts/audit.sh docs/plans/my-plan.md and store the brief into AgentDB namespace dev-plan-loop
```

**Output**: `STATE_DIR/audits/$DATE.json` + memory entry `audit-$DATE` in namespace `dev-plan-loop`.
**Why nightly**: Captures progress between sessions. Diff vs. previous audit surfaces stalls.

### 2. Daily summary (recurring, end-of-day)

```
/schedule "0 17 * * 1-5" produce a one-paragraph state-of-the-plan from docs/plans/my-plan.md and append to MEMORY.md as a project memory dated today
```

**Why**: Builds a low-noise narrative of how the plan is moving. Pattern-distillation grist for monthly retro.

### 3. Weekly architecture review (recurring)

```
/schedule "0 9 * * 1" run .claude/skills/dev-plan-loop/scripts/architecture-review.sh docs/plans/my-plan.md, spawn a swarm with reviewer + system-architect + security-architect, write findings to STATE_DIR/architecture-reviews/$WEEK.md
```

**Why**: Detects drift between code and design intent before it ossifies.

### 4. Monthly retrospective (recurring)

```
/schedule "0 3 1 * *" read all entries in AgentDB namespace dev-plan-loop from the last 30 days, distill into 3-5 patterns (what worked, what stalled, why), store as pattern entries with namespace dev-plan-loop-patterns
```

**Why**: Turns a month of ephemeral telemetry into durable judgment.

### 5. Cleanup follow-up (one-shot)

```
/schedule "in 14 days" if the cortex-auth feature flag is at 100% with no error rate increase, open a PR removing the legacy session_cookie code
```

**Why**: Captures the "remove once X" condition that always rots in a TODO.

## Choosing recurring vs. one-shot

| Signal | Use |
|--------|-----|
| "every Monday", "nightly", "always check X" | recurring (cron) |
| "in 2 weeks if Y", "after the rollout", "once feature ships" | one-shot |
| Single experiment, single deadline | one-shot |
| Sweep, triage, drain that you do "again and again" | recurring |

## Listing and managing routines

```bash
/schedule list
/schedule delete <id>
/schedule update <id> "new cron spec"
```

## Anti-patterns

- **Scheduling things that should be `/loop`** — fast checks belong in the active session.
- **Running expensive swarms every 5 minutes** — credits and cognitive load. Hourly or daily is almost always enough.
- **Forgetting to end one-shots** — if the condition is unclear, the agent will fire indefinitely. Always include "stop after N runs" or a check that becomes false.
