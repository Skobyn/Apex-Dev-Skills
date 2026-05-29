# Loop Patterns — Sense Layer

`/loop` runs inside an active session. It's fast, temporary, focused on **what's happening now**. The model self-paces with `ScheduleWakeup`.

## Cache-Window Rule

The Anthropic prompt cache has a 5-minute TTL. Sleeping past 300s reads your conversation context uncached.

| Range | Mode | Use for |
|-------|------|---------|
| 60–270s | cache stays warm | active work — checking a build, watching a deploy |
| 300s | **AVOID** — worst-of-both | (don't pick this) |
| 300–3600s | one-cache-miss-per-wake | genuinely idle waits |

**Default for plan iteration**: 1200–1800s (20–30min). Long enough to amortize the cache miss; short enough to feel responsive.

## Recipes

### 1. Phase advance (the main loop)

```
/loop iterate the next phase of docs/plans/my-plan.md
```

**Cadence**: self-paced; default 1200s between iterations.
**Behavior**: The model runs `iterate.sh`, parses the brief, spawns the swarm via Agent tool (one message, all agents `run_in_background: true`), waits for results, runs the acceptance check, calls `checkpoint.sh complete LINE`, then `ScheduleWakeup`.

### 2. Test watch (gate-then-advance)

```
/loop wait until tests/integration/auth/ passes, then advance the plan
```

**Cadence**: 120–270s while tests are running.
**Behavior**: Polls test status; only spawns the next swarm after green.

### 3. Deploy monitor

```
/loop watch the staging deploy at gs://my-project/deploys/active and report when stable
```

**Cadence**: 60–270s during deploy; 1200s after success.
**Behavior**: Hits status endpoint, escalates to user on failure.

### 4. Drift detect (subtle regressions)

```
/loop run scripts/benchmarks/run.py and flag if p99 drifts > 5% from baseline
```

**Cadence**: 1800s.
**Behavior**: Compares current to baseline; on drift, halts the plan loop (`checkpoint.sh halt "perf regression"`) and surfaces.

### 5. Swarm health (self-healing)

```
/loop call swarm_health and restart any dead workers
```

**Cadence**: 600s.
**Behavior**: `mcp__claude-flow__swarm_health` → if degraded, `swarm_init --topology hierarchical --strategy specialized`.

## Termination Conditions

A `/loop` should stop when:

- `iterate.sh` returns `STATUS: COMPLETE` (plan done — touch `STATE_DIR/COMPLETE`)
- `iterate.sh` returns `STATUS: HALTED` (manual halt or guardrail trip)
- The user's stated condition is met (test green, deploy stable)
- The user interrupts

The model omits the `ScheduleWakeup` call in any of these cases.

## Anti-patterns

- **Polling MCP status repeatedly** — agents return when done, trust them. CLAUDE.md says: never poll.
- **Sleeping 60s in a tight loop while waiting hours for a build** — you'll burn the cache 60+ times. Sleep 1800s twice instead.
- **Running multiple unrelated `/loop`s in the same session** — they'll share context and entangle. Separate sessions.
