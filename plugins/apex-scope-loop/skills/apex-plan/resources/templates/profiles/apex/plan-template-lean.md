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

## Monitor

> Optional. Draft checks here from the success criteria in the PLAN stage and agree them in OPTIMIZE.
> One fenced json block, nothing else fenced. `checks: []` means this plan is not watched.
> A check is `{"id", "metric", "op", "threshold", "severity", "probe"}`: `op` is one of `<` `<=` `>` `>=` `==` and is the
> expected (healthy) condition: the check passes while `value op threshold` holds and is breached when it does not.
> "p99 must stay under 2000 ms" is `"op": "<", "threshold": 2000`. A success criterion is a pass condition, so it
> maps directly onto a check. `severity` is high, medium or low, and `probe` is
> `{"kind": "http", "url", "measure": "status" or "latency_ms", "expect_status"}` (GET only; `latency_ms` requires `expect_status`, since a fast error page is not a healthy latency), `{"kind": "cmd", "command", "value": "stdout" or "exit"}` (`stdout` is the default: the number on the last stdout line, and empty stdout or a non-zero exit is `unmeasured`, never 0), or `{"kind": "runner", "metrics"}` (`$APEX_MONITOR_CMD` prints one JSON object keyed by metric, each value a number or `{"value": number, "note": "..."}`; `note` is optional and is the only runner text kept). `window_days` is 1-90 (default 14). Ids and metrics match `[A-Za-z0-9][A-Za-z0-9_.:-]*`.

```json
{"window_days": 14, "checks": []}
```

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
  - Acceptance: `grep -qF '**Status**: Implemented' .claude/tasks/{{SLUG}}-adr.md`
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
