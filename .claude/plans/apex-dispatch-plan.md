# apex-dispatch + apex-scope-loop 0.3.0 — Development Plan

> **ADR**: [`.claude/tasks/apex-dispatch-adr.md`](../tasks/apex-dispatch-adr.md)
> **Spec**: [`docs/superpowers/specs/2026-10-05-apex-dispatch-design.md`](../../docs/superpowers/specs/2026-10-05-apex-dispatch-design.md)
> **Goal**: Execute spec §12 Phases 0–4 (and the code part of Phase 5) through the apex-scope-loop.
> **Started**: 2026-10-05

## Design Intent

Three layers, each enforced by something a smoke test can assert: apex-scope-loop 0.3.0 stays the only execution engine; apex-dispatch routes and governs; the decision layer is consumed only through `${APEX_DECIDE_CMD}` and may be absent. No new model-judged gates. Hard rules outrank verdicts. Every route, spawn, worker run and verdict is a ledger row.

**Bounded contexts**: `plugins/apex-scope-loop/` (engine), `plugins/apex-dispatch/` (routing + governance), sibling plugins (hygiene only).

---

## Phases

### Phase 0 — Spikes

- [x] **Phase 0.1** [research][docs] Run the spec §11 Phase 0 spikes live against Claude Code and record each result
  - Acceptance: `test -f docs/research/apex-dispatch-phase0.md && grep -c '^| ' docs/research/apex-dispatch-phase0.md | awk '$1>=10{exit 0}{exit 1}'`

### Phase 1 — apex-scope-loop 0.3.0

- [x] **Phase 1.1** [backend] Plugin-relative script resolution, shared state root via --git-common-dir, optional memory seed, remove hooks-snippet.json
  - Acceptance: `bash plugins/apex-scope-loop/scripts/smoke.sh`
  - Blocked-by: Phase 0.1

- [x] **Phase 1.2** [backend] iterate.sh: widened tag regex, 8-line look-ahead, Blocked-by resolver, next-unblocked selection, ACTIVE lock, stage, Route/Paths/Budget directives, ROUTE and LANES blocks
  - Acceptance: `bash plugins/apex-scope-loop/scripts/smoke.sh`
  - Blocked-by: Phase 1.1

- [x] **Phase 1.3** [backend] promote-to-loop.sh directive validation, cycle check, route dry-run; green-gate toolchain autodetect; gate.sh partner notifier
  - Acceptance: `bash plugins/apex-scope-loop/scripts/smoke.sh`
  - Blocked-by: Phase 1.2

- [x] **Phase 1.4** [backend][tier:c] checkpoint.sh review provenance, 3-round cap, ESCALATE_ROUTE, complete evidence; risk-tier --classify; land.sh ledger verify
  - Acceptance: `bash plugins/apex-scope-loop/scripts/smoke.sh`
  - Blocked-by: Phase 1.3

- [x] **Phase 1.5** [docs] ruflo optional across docs, apex-plan generic/apex profiles, reviewer disallowedTools, ADR-0003, README, version 0.3.0
  - Acceptance: `bash plugins/apex-scope-loop/scripts/smoke.sh && grep -q '"version": "0.3.0"' plugins/apex-scope-loop/.claude-plugin/plugin.json`
  - Blocked-by: Phase 1.4

- [x] **Phase 1.6** [tests][docs] Non-apex walkthrough on a uv/pytest fixture repo with no .claude/skills copy
  - Acceptance: `test -f docs/examples/non-apex-run.md && grep -q 'land.sh' docs/examples/non-apex-run.md`
  - Blocked-by: Phase 1.5

- [x] **Gate 1→2** [gate:human] Phase 1 G12 batch approval (every Tier C task in the phase, bound to the phase-end head)
  - Acceptance: user types approve gate-1-2

### Phase 2 — apex-dispatch core

- [ ] **Phase 2.1** [infra] apex-dispatch skeleton: plugin.json, marketplace registration, README, ADR-0001 (Proposed), root README row
  - Acceptance: `python3 -c "import json;m=json.load(open('.claude-plugin/marketplace.json'));assert any(p['source']=='./plugins/apex-dispatch' for p in m['plugins'])"`
  - Blocked-by: Phase 1.6

- [ ] **Phase 2.2** [backend] Policy, overlay merge, schema validation, compile.sh with --check, generated agents and settings snippet
  - Acceptance: `bash plugins/apex-dispatch/scripts/compile.sh --check`
  - Blocked-by: Phase 2.1

- [ ] **Phase 2.3** [backend] route.sh table-only: kill switches, input gate, hard floors, class table, semantic fill seam, tiers, fan-out, escalation, review-shape, adhoc, baseline/shadow
  - Acceptance: `bash plugins/apex-dispatch/scripts/smoke.sh`
  - Blocked-by: Phase 2.2

- [ ] **Phase 2.4** [backend] ledger.sh hash chain with verify/export, report.sh, doctor.sh
  - Acceptance: `bash plugins/apex-dispatch/scripts/smoke.sh`
  - Blocked-by: Phase 2.3

- [ ] **Phase 2.5** [docs] Skills and commands (route, run, done, report, doctor, compile)
  - Acceptance: `bash plugins/apex-dispatch/scripts/smoke.sh`
  - Blocked-by: Phase 2.4

- [ ] **Gate 2→3** [gate:human] Phase 2 G12 batch approval (every Tier C task in the phase, bound to the phase-end head)
  - Acceptance: user types approve gate-2-3

### Phase 3 — Governance hooks and sibling hygiene

- [ ] **Phase 3.1** [security] PreToolUse hooks: pre-agent, pre-bash, pre-edit, pre-mcp
  - Acceptance: `bash plugins/apex-dispatch/scripts/smoke.sh`
  - Blocked-by: Phase 2.5

- [ ] **Phase 3.2** [security] post-agent, subagent-start/stop, stop-gate, post-bash-prune; checkpoint.sh consumes hook-written review records
  - Acceptance: `bash plugins/apex-dispatch/scripts/smoke.sh && bash plugins/apex-scope-loop/scripts/smoke.sh`
  - Blocked-by: Phase 3.1

- [ ] **Phase 3.3** [security] Sibling hygiene: guardrails bypass-flag denials and command scoping, observability session key, contracts-reliability no allow, dev-harness/project-start/root docs
  - Acceptance: `for s in plugins/*/scripts/smoke.sh; do bash "$s" >/dev/null || exit 1; done`
  - Blocked-by: Phase 3.2

- [ ] **Gate 3→4** [gate:human] Phase 3 G12 batch approval (every Tier C task in the phase, bound to the phase-end head)
  - Acceptance: user types approve gate-3-4

### Phase 4 — Provider workers

- [ ] **Phase 4.1** [backend][security] worker-common, worker-claude-p, worker-codex, apply.sh
  - Acceptance: `bash plugins/apex-dispatch/scripts/smoke.sh`
  - Blocked-by: Phase 3.3

- [ ] **Phase 4.2** [backend] grok/opencode/aider shims flagged off, openai-sdk stub, compile --target codex, report --compare/--decision
  - Acceptance: `bash plugins/apex-dispatch/scripts/smoke.sh`
  - Blocked-by: Phase 4.1

- [ ] **Gate 4→5** [gate:human] Phase 4 G12 batch approval (every Tier C task in the phase, bound to the phase-end head)
  - Acceptance: user types approve gate-4-5

- [ ] **Gate 4→done** [gate:auto] Every plugin smoke passes on the final head
  - Acceptance: `for s in plugins/*/scripts/smoke.sh; do bash "$s" >/dev/null || exit 1; done`
  - Blocked-by: Phase 4.2

---

## Out-of-scope

- Spec Phase 5 measurement (routed vs baseline on real plans over weeks) and Phase 6 mod adapter.
- Building apex-decision-layer itself (own spec).
