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

## Execution is worktree-bound

By contract, the **whole plan executes inside a single isolated git worktree** on a dedicated branch (`apex-scope-loop/<slug>`), forked from the base branch (default `main`). Nothing touches the base branch's working tree while phases run. `init.sh` creates the worktree; `iterate.sh` reports it on the `WORKTREE:` / `BRANCH:` lines of every brief; every swarm agent must `cd` into that worktree and make all code edits there. When the **final gate passes** (plan fully checked), `land.sh` merges the worktree branch into the base branch and removes the worktree — that merge is the only moment code reaches `main`.

This gives the loop a clean blast radius: a half-finished plan never leaves partial code on `main`, and an abandoned plan is discarded by deleting one worktree + branch. (Escape hatch: set `APEX_NO_WORKTREE=1` before `init.sh` to run in the base checkout — not recommended.)

## The Gibson harness (on by default)

Every task runs under harness disciplines adapted from [The Gibson](https://github.com/The-AIE/the-gibson) (Apache-2.0). They're enforced by scripts, not left to prose:

1. **Kill switch.** `iterate.sh` halts before dispatch if `APEX_HALT=1` or a `HALT` file exists (`.dev-plan-state/HALT`, `<state-dir>/HALT`, or `gibson/HALT`).
2. **Green gate vs. baseline.** `init.sh` snapshots generate → typecheck → lint → test → build at the fork point. `green-gate.sh check` fails only on *new* red, and it reports pre-existing red instead of hiding it.
3. **Risk tier.** `risk-tier.sh` classifies each task's diff as A, B, or C. Tier C covers money, auth, consent/PII, security boundaries, schema, alerting, and prod data.
4. **Independent review.** The `gibson-reviewer` agent reviews the exact head SHA in a fresh context, never a builder's own. Tier C gets a six-lens fan-out plus an adversarial pass.
5. **Human gate G12 for Tier C.** The loop halts and asks in Ask Contract form (what / what it does / why / risks).
6. **Enforced check-off.** `checkpoint.sh complete` refuses unless the gate, the review, and (for Tier C) the approval all bind to the current head SHA.
7. **Error budget + ratchet.** Two consecutive failures trigger `ESCALATE` (a second opinion), three halt the plan. A failure signature seen twice triggers `RATCHET: FILE_LESSON` into the tracked `LESSONS.md`, which is recalled by tag at task start.

Mapping, rationale, and what was deliberately left out: [docs/GIBSON_HARNESS.md](docs/GIBSON_HARNESS.md). Set `APEX_GIBSON=0` to opt out.

## Prerequisites

- Claude Code 2.0+ with `/loop` and `/schedule` skills enabled
- Optional: a memory store wired through `APEX_MEMORY_CMD` (for example the ruflo / claude-flow CLI). Unset means memory seeding is skipped
- A development plan in markdown checklist format (see `resources/templates/dev-plan.md`)
- Project-level memory namespace configured (default: `apex-execute`)

## Quick Start

```bash
# 1. Author your dev plan from the template
cp ${CLAUDE_SKILL_DIR}/resources/templates/dev-plan.md docs/plans/my-plan.md
$EDITOR docs/plans/my-plan.md

# 2. Initialize state + the isolated execution worktree
${CLAUDE_SKILL_DIR}/scripts/init.sh docs/plans/my-plan.md

# 3. Start the active sense loop (self-paced) — all work lands in the worktree
/loop ${CLAUDE_SKILL_DIR}/scripts/iterate.sh docs/plans/my-plan.md

# 4. (Separately) schedule the continuity layer
/schedule "nightly @ 02:00" ${CLAUDE_SKILL_DIR}/scripts/audit.sh docs/plans/my-plan.md
/schedule "weekly @ Mon 09:00" ${CLAUDE_SKILL_DIR}/scripts/architecture-review.sh docs/plans/my-plan.md

# 5. After the final gate passes, merge the worktree into the base branch
${CLAUDE_SKILL_DIR}/scripts/land.sh docs/plans/my-plan.md
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

See [docs/legacy/LOOP_PATTERNS.md](docs/legacy/LOOP_PATTERNS.md) for delay-tuning rules (cache-window awareness).

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
3. Spawns all agents in **one message** with `run_in_background: true`, each scoped to the plan's worktree (`cd` into `worktree_path`)
4. Waits for verdicts; never polls
5. Runs the harness: green gate → risk tier → independent `gibson-reviewer` on the exact head SHA → G12 human approval for Tier C (see "The Gibson harness" above)
6. Stores trajectory + outcome in AgentDB via `memory_store` with namespace `apex-execute`
7. Marks the task complete in the plan (`checkpoint.sh complete` refuses if the harness evidence doesn't match the head SHA); commits the code to the worktree branch via hook (the base branch is untouched until `land.sh`)

See [docs/legacy/SWARM_TOPOLOGIES.md](docs/legacy/SWARM_TOPOLOGIES.md) for the legacy topology-per-phase mapping (optional swarms; plain subagents work without it).

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
${CLAUDE_SKILL_DIR}/scripts/init.sh docs/plans/my-plan.md
```

This creates `.dev-plan-state/<plan-hash>/checkpoint.json`, provisions the isolated worktree at `.dev-plan-state/<plan-hash>/worktree` on branch `apex-scope-loop/<slug>`, and seeds the `apex-execute` memory namespace with plan metadata. The checkpoint records `worktree_path`, `worktree_branch`, and `base_branch`.

### 3. Start the Sense Loop

In an active Claude Code session:

```
/loop iterate the next phase of docs/plans/my-plan.md
```

The model will:
1. Read `checkpoint.json` to find the next unchecked task and the bound worktree
2. Spawn the appropriate swarm via Agent tool (hierarchical, 6–8 agents, all in one message), each operating inside `worktree_path`
3. Wait for swarm verdicts (no polling)
4. Run acceptance criteria as the verdict gate (inside the worktree)
5. On pass: check the box, write summary to memory, advance
6. On fail: store failure pattern, surface to user, halt
7. Use `ScheduleWakeup` to self-pace (default 1200–1800s between iterations for non-urgent work)
8. When the plan is complete, run `land.sh` to merge the worktree branch into the base branch and exit without rescheduling

### 4. Schedule the Continuity Layer

In a separate command (one-time setup):

```bash
# Nightly progress audit
/schedule "0 2 * * *" ${CLAUDE_SKILL_DIR}/scripts/audit.sh docs/plans/my-plan.md

# Weekly architecture review
/schedule "0 9 * * 1" ${CLAUDE_SKILL_DIR}/scripts/architecture-review.sh docs/plans/my-plan.md
```

These persist across sessions and write findings to the memory namespace.

### 5. Inspect State Anytime

```bash
${CLAUDE_SKILL_DIR}/scripts/status.sh docs/plans/my-plan.md
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

The per-task harness (green gate, risk tier, independent review, G12, error budget, ratchet) is enforced by the scripts. See "The Gibson harness" above.

Additional guardrails can be enforced via Claude Code hooks (`settings.json`):
- **Pre-edit**: refuse writes to `/src/security/**` without security-auditor in the swarm
- **Post-edit**: run linters/formatters; reject on failure
- **Pre-task**: AIDefense scan on inputs
- **Post-task**: persist outcome to memory, commit if passing

Enforced hook governance ships in the `apex-guardrails` and `apex-dispatch` plugins; this skill no longer carries a hooks snippet.

## Operate

`operate.sh` runs after `land.sh` on a plan that has landed (`checkpoint.json` `landed: true`). Anything else exits 3. The slash command is `/apex-scope-loop:operate`.

```bash
${CLAUDE_SKILL_DIR}/scripts/operate.sh PLAN.md deploy            # human-only, see below
${CLAUDE_SKILL_DIR}/scripts/operate.sh PLAN.md status            # deploys, the watch window, declared checks and their last values
${CLAUDE_SKILL_DIR}/scripts/operate.sh PLAN.md monitor           # measure the declared checks while the window is open
${CLAUDE_SKILL_DIR}/scripts/operate.sh PLAN.md ingest            # file the measured breaches to lessons / backlog
${CLAUDE_SKILL_DIR}/scripts/operate.sh --all status              # the same for every landed plan, plus the repo-level checks
${CLAUDE_SKILL_DIR}/scripts/operate.sh --all monitor [--ingest]  # every open window plus the repo checks; what a daily /schedule runs
```

`--all ingest` is refused; ingest runs through `monitor --ingest` only.

### Deploy is human-only

- `operate.sh PLAN deploy` runs `$APEX_DEPLOY_CMD` from the checkout with `PLAN_SLUG` and `LANDED_SHA` in its environment. `APEX_DEPLOY_CMD` is required; operate never holds or reads deploy credentials.
- apex-dispatch's pre-bash hook denies every agent Bash call whose text names `operate.sh` and the word `deploy`, at every stage. An agent must not work around it (for example by writing a script that calls it).
- The ack is read from the controlling terminal (`/dev/tty`) only, and must equal `<slug>@<landed sha>` (the full 40-hex sha shown in the Ask Contract). `APEX_OPERATE_ACK` never authorizes a deploy. With no terminal, the deploy is refused (exit 5).
- Exit 0 opens the watch window. A non-zero exit is recorded and opens no window (exit 1). A deploy that cannot be recorded exits 6.

### The Monitor section

The plan declares its checks in a `## Monitor` section with one fenced `json` block (see the plan template):

```json
{"window_days": 14,
 "checks": [{"id": "csv-p99", "metric": "export_p99_ms", "op": "<", "threshold": 2000, "severity": "high",
             "probe": {"kind": "http", "url": "https://app.example/api/export?event=big", "measure": "latency_ms", "expect_status": 200}}]}
```

- `window_days` is 1 to 90, default 14. The window starts at the last successful deploy.
- Each check is `{id, metric, op, threshold, severity, probe}`. `op` is the EXPECTED (healthy) condition: a check passes while `value op threshold` holds, and it is breached when it does not. `op` is one of `<`, `<=`, `>`, `>=`, `==`. "p99 must stay under 2000 ms" is `"op": "<", "threshold": 2000`.
- `severity` is `high`, `medium` or `low`. A `## Monitor` section with `checks: []` (or no section) is not watched. A malformed section is refused (exit 2), never read as "not watched".
- Probes:
  - `http`: one GET, `measure` is `status` or `latency_ms`. `latency_ms` requires `expect_status`, because a fast error page is not a healthy latency; a status other than `expect_status` is `unmeasured`. 10 s timeout, no credentials or headers, no redirects followed.
  - `cmd`: `command` runs under `/bin/sh -c`. `value` is `stdout` (the default: the number on the last non-empty stdout line; empty stdout or a non-zero exit is `unmeasured`, never 0) or `exit` (the exit code). A command naming `operate.sh`, the word deploy or `APEX_DEPLOY_CMD` is refused.
  - `runner`: `$APEX_MONITOR_CMD <metric>...` is run once per runner check and must print one JSON object with exactly the requested metrics as keys. Each value is a number, `null` (unmeasured), or `{"value": number|null, "note": "..."}`; `note` is optional, sanitised and capped at 120 characters. Its stderr is never stored. `APEX_MONITOR_CMD` is required only when a runner check is declared.
- An unmeasured check is recorded as `unmeasured` with a reason. It is never a pass and never 0.

### Breaches, lessons and backlog

- The first breach of a (plan, check) is filed once. `severity: high` goes to `lessons.sh PLAN add` with tags `operate:<slug>,<metric>`. Any other severity goes to `backlog.sh PLAN add 0 "[operate:<slug>] ..." --from operate`.
- Later breaches of a filed check only increment its count (`counted`). Filed-once holds for the plan's lifetime, across windows and redeploys.
- Repo-level checks in `.claude/apex-scope-loop/monitor.json` (same shape, no `window_days`) file only to the backlog as `[operate:repo]`, never to a lesson. They never expire.
- A breach that cannot be filed stays pending and exits 7; the next ingest retries it.

### Window close

When `window.end` has passed, the next monitor run closes the window and stops measuring the plan. Outcomes:

- `operated-clean`: every declared check was measured at least once in the window and none is open at close.
- `closed-with-breaches`: the window saw a breach, or some check is open at close.
- `open-at-close`: a check whose last measured status in the window was a breach, or a check never measured in the window. Both make the outcome `closed-with-breaches`. A check is never silently expired.
- The close records `measured_runs` (the runs that measured at least one check) and `unmeasured_at_close` (the checks never measured plus those unmeasured on the last run), and appends an `operate_window_closed` ledger row. A window closed with 0 measured runs is reported as never measured.

### Naming and tagging

- Metric names are `lower_snake_case` in the form `<area>_<measure>[_<unit>]`, for example `export_p99_ms` or `webhook_delivery_rate`. Metric names are unique per plan.
- A runner metric is shared across plans, so prefix it with the plan slug or the area (for example `export_p99_ms`, not `p99_ms`), so two plans never read the same value by accident.
- Tags follow the slug: `operate:<slug>` for a plan's signals and `operate:repo` for the repo-level checks. Use them to find the lessons and backlog items an operate run filed.

### Daily schedule

Schedule the monitor once a day with a `/schedule` routine. It only measures and files; it never runs deploy:

```bash
/schedule "0 9 * * *" ${CLAUDE_SKILL_DIR}/scripts/operate.sh --all monitor --ingest
```

Check the state with `operate.sh --all status`, or the console's Watched plans view.

## Available Scripts

| Script | Purpose |
|--------|---------|
| `scripts/init.sh PLAN.md` | Create state dir + isolated worktree, seed memory namespace |
| `scripts/iterate.sh PLAN.md` | Run one phase iteration (called by `/loop`) |
| `scripts/land.sh PLAN.md` | Merge the worktree branch into base after the final gate |
| `scripts/audit.sh PLAN.md` | Nightly diff + memory append (called by `/schedule`) |
| `scripts/architecture-review.sh PLAN.md` | Weekly drift check vs. plan intent |
| `scripts/status.sh PLAN.md` | Print current state |
| `scripts/operate.sh PLAN.md status\|monitor\|ingest` (or `--all status\|monitor [--ingest]`) | Operate a landed plan: watch its declared Monitor checks and file breaches; `deploy` is human-only (see Operate) |
| `scripts/checkpoint.sh PLAN.md ACTION` | `complete` / `fail` / `review` / `approve` / `halt` / `rewind` — records verdicts and enforces the harness on check-off |
| `scripts/green-gate.sh PLAN.md baseline\|check` | Baseline-relative green gate (zero new failures vs. the fork point) |
| `scripts/risk-tier.sh PLAN.md LINE_NO` | Classify a task diff as Tier A/B/C and record it |
| `scripts/lessons.sh PLAN.md fail\|add\|recall` | The ratchet: count repeat failures, file and recall lessons |

## Resources

- `resources/templates/dev-plan.md` — Authoring template
- `resources/templates/checkpoint.json` — State schema
- `resources/examples/sample-plan.md` — Worked example (auth refactor)

## Advanced Topics

- [LOOP_PATTERNS.md](docs/legacy/LOOP_PATTERNS.md) — Sense-layer recipes with delay tuning (legacy)
- [SCHEDULE_PATTERNS.md](docs/SCHEDULE_PATTERNS.md) — Continuity-layer recipes with cron
- [GIBSON_HARNESS.md](docs/GIBSON_HARNESS.md) — Harness laws adopted from The Gibson and how each is enforced
- [SWARM_TOPOLOGIES.md](docs/legacy/SWARM_TOPOLOGIES.md) — Phase-tag → topology mapping (legacy)

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

### Issue: `checkpoint.sh complete` refuses
**Cause**: The harness evidence doesn't bind to the worktree's current head SHA: the gate or review is missing, stale, or failing, or a Tier C approval is missing
**Solution**: Follow the listed reasons. Any new commit invalidates the previous gate and review, so re-run `green-gate.sh check` and re-review the new head

### Issue: Gate reports `SKIPPED`
**Cause**: No gate commands resolved (no `APEX_GATE_*`, `.agents/gate.json`, or matching `package.json` scripts)
**Solution**: Add `.agents/gate.json` to the repo (see [GIBSON_HARNESS.md](docs/GIBSON_HARNESS.md)), then delete `.dev-plan-state/<hash>/gate/baseline.json` and re-run `init.sh`

### Issue: `/loop` keeps running after plan complete
**Cause**: ScheduleWakeup not omitted on completion
**Solution**: `iterate.sh` exits with code 0 + writes `COMPLETE` marker; the model should recognize this and not call ScheduleWakeup
