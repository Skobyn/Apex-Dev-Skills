# Swarm Topologies — Phase Tag → Agent Mapping

The orchestrator selects topology and agent roster based on a task's tags. All swarms run **hierarchical-mesh** with a queen coordinator and Raft consensus, so a leader maintains authoritative state. Workers run in parallel via the Agent tool with `run_in_background: true`.

## Spawning rule (CLAUDE.md compliance)

- **One message** spawns ALL agents (parallel execution)
- All agents marked `run_in_background: true`
- After spawning, **stop** — do not poll status
- Trust agents to return verdicts; review all results when they arrive

```bash
npx @claude-flow/cli@latest swarm init --topology hierarchical --max-agents 8 --strategy specialized
```

## Tag → Roster

| Tag(s) | Coordinator | Workers | Memory namespace |
|--------|-------------|---------|------------------|
| `[backend]` | hierarchical-coordinator | coder, reviewer, tester | `dev-plan-loop` |
| `[frontend]` | hierarchical-coordinator | coder, reviewer, tester | `dev-plan-loop` |
| `[backend][security]` | hierarchical-coordinator | coder, security-architect, security-auditor, reviewer, tester | `dev-plan-loop`, `security` |
| `[security]` | hierarchical-coordinator | security-architect, security-auditor, reviewer | `security` |
| `[perf]` | hierarchical-coordinator | performance-engineer, perf-analyzer, tester | `dev-plan-loop`, `performance` |
| `[ml-serving]` | hierarchical-coordinator | ml-developer, performance-engineer, tester | `ml-serving` |
| `[infra]` | hierarchical-coordinator | cicd-engineer, system-architect, reviewer | `dev-plan-loop` |
| `[research]` | mesh-coordinator | researcher (×2), analyst, reviewer | `dev-plan-loop` |
| `[docs]` | (no swarm — single Agent) | api-docs OR base-template-generator | `dev-plan-loop` |
| `[tests]` | hierarchical-coordinator | tester, tdd-london-swarm, reviewer | `dev-plan-loop` |
| `[refactor]` | hierarchical-coordinator | coder, reviewer, code-analyzer, tester | `dev-plan-loop` |

Multiple tags → union of rosters (capped at 8 workers per CLAUDE.md).

## Orchestrator brief template

When `iterate.sh` returns `STATUS: READY`, the orchestrator constructs **one** message containing all Agent calls:

```
For each agent in the roster, in ONE message:

Agent({
  description: "<3-5 word>",
  subagent_type: "<role>",
  prompt: "<self-contained brief — see below>",
  run_in_background: true
})

Brief should include:
- The plan path and the specific task line
- The acceptance criteria (verbatim)
- Any blocked-by dependencies (already-complete predecessors)
- Memory namespace to read for prior patterns: dev-plan-loop
- Memory namespace to write outcome to: dev-plan-loop
- Bound: complete in 30 minutes; report verdict + trajectory
- Constraint: do NOT modify the plan file itself; orchestrator handles that via checkpoint.sh
```

## Verdict gate

After agents return, the orchestrator runs the acceptance criteria as a shell command:

```bash
# If acceptance: "pytest tests/unit/auth/ passes"
pytest tests/unit/auth/ && VERDICT=pass || VERDICT=fail

# If acceptance: "file X exists with Y"
[[ -f X ]] && grep -q "Y" X && VERDICT=pass || VERDICT=fail
```

Then:
- `pass` → `checkpoint.sh complete LINE_NO "$reason"` and `ScheduleWakeup`
- `fail` → store failure pattern in memory, surface to user, **omit ScheduleWakeup**

## Anti-patterns

- **Spawning agents one-at-a-time across messages** — kills parallelism, doubles latency.
- **Adding more than 8 agents** — coordination overhead exceeds work output (CLAUDE.md cap).
- **Mesh for code-writing tasks** — peer-to-peer drifts; use hierarchical for clear authority.
- **Skipping the verdict gate** — without it, the loop has no termination signal and will check off failed tasks.
