# Novel Plugins Suite — Development Plan

> **ADR**: [`.claude/tasks/novel-plugins-suite-adr.md`](../tasks/novel-plugins-suite-adr.md)
> **Goal**: Add 6 themed, research-grounded plugins to the Apex-Dev-Skills marketplace, each contract-compliant and smoke-green, staged locally.
> **Owner**: skobyn@gmail.com
> **Started**: 2026-05-29
> **Target**: TBD

## Design Intent

Build six themed plugins covering 13 researched ideas in under-served niches (agent observability, deterministic guardrails, RAG/memory lifecycle, legacy comprehension, agent-team coordination, tool-contract/reliability), deliberately avoiding the saturated code-review/test-gen/scan/scaffold space. Reference exemplar for the contract: `plugins/apex-scope-loop`.

**Bounded contexts**: the marketplace repo only — `plugins/<name>/`, `.claude-plugin/marketplace.json`, root `README.md`.

**Non-negotiable constraints**:

- Every plugin conforms to the repo contract (valid `plugin.json` with no enumerated surface arrays, kebab-case unquoted skill names, explicit non-wildcard `allowed-tools`, required README sections, an `0001-*` ADR, passing `scripts/smoke.sh`).
- Single-agent-per-plugin execution — no parallel writes to `marketplace.json`.
- MCP only where genuinely needed (observability, rag-memory); core surface must function without the MCP server.
- Shell scripts: `set -euo pipefail`, mode 100755, LF endings.

---

## Execution Strategy

> **Default per phase**: single coder agent (per SCOPE decision).
> **Gating**: auto-gate via each plugin's own `smoke.sh` + `marketplace.json` validity.

### Swarm directives (per task)

| Directive | Meaning |
|-----------|---------|
| `Swarm: single [<agent-type>]` | One `Agent` tool invocation; orchestrator picks subagent_type |
| `Swarm: multi <count> [...]` | N parallel `Agent` calls in one message |

### Approval gates (between phases)

| Gate tag | Behavior |
|----------|----------|
| `gate:auto` | Orchestrator runs the Acceptance check; advances on pass, halts on fail |

---

## Phases

> **Task format** (apex-execute `iterate.sh` parses these):
> ```
> - [x] **Phase X.Y** [tag1][tag2] Imperative task title
>   - Acceptance: <runnable check>
>   - Swarm: <directive>
>   - Blocked-by: phase-X.Y
> ```

---

### Phase 1 — Specification & Shared Scaffolding (SPARC: Spec)

Establish the reusable conventions every plugin phase consumes, so each plugin build is a fill-in-the-blanks exercise against a proven skeleton.

- [x] **Phase 1.1** [research][docs] Extract the contract skeleton from `apex-scope-loop`
  - Acceptance: `docs/research/novel-plugins-suite.md` exists with `Findings:` and `Recommendations:` sections documenting the 10-check smoke shape, plugin.json keys, and required README sections, ≥ 400 words
  - Swarm: single [researcher]

- [x] **Phase 1.2** [docs] Author reusable smoke skeleton (10-check pure + 12-check MCP variant)
  - Acceptance: `docs/novel-plugins-suite/smoke-skeleton.sh` exists and `bash -n docs/novel-plugins-suite/smoke-skeleton.sh` parses clean
  - Swarm: single [coder]
  - Blocked-by: phase-1.1

- [x] **Phase 1.3** [docs] Confirm ADR is `Accepted`, not `Proposed`
  - Acceptance: `grep -q '^\*\*Status\*\*: Accepted' .claude/tasks/novel-plugins-suite-adr.md`
  - Swarm: single [reviewer]

- [x] **Gate 1→2** [gate:auto] Scaffolding ready
  - Acceptance: `bash -n docs/novel-plugins-suite/smoke-skeleton.sh && grep -q '^\*\*Status\*\*: Accepted' .claude/tasks/novel-plugins-suite-adr.md`
  - Blocked-by: phase-1.3

---

### Phase 2 — apex-guardrails (Theme B, complexity: low)

Deterministic, hook-enforced guardrails: B1 GuardRail (block edits to sensitive paths + destructive bash), B2 PolicyAsCode (YAML allow/deny compiled to hooks), B3 SecretGuard (scan tool I/O for credentials before write/send).

- [x] **Phase 2.1** [backend] Build apex-guardrails plugin (skills + PreToolUse hooks + bash, pure)
  - Acceptance: `plugins/apex-guardrails/.claude-plugin/plugin.json` is valid JSON with name/version/description/author/license/keywords and no skills/commands/agents arrays; README has `## Compatibility`, `## Namespace coordination`, `## Verification`, `## Architecture Decisions`; `docs/adrs/0001-apex-guardrails-contract.md` status `Accepted`
  - Swarm: single [coder]
  - Blocked-by: gate-1-2

- [x] **Phase 2.2** [backend] Register in marketplace.json + root README table; write scripts/smoke.sh
  - Acceptance: `python3 -c "import json;m=json.load(open('.claude-plugin/marketplace.json'));assert any(p['source']=='./plugins/apex-guardrails' for p in m['plugins'])"` and `grep -q 'apex-guardrails' README.md`
  - Swarm: single [coder]
  - Blocked-by: phase-2.1

- [x] **Gate 2→3** [gate:auto] apex-guardrails smoke green
  - Acceptance: `bash plugins/apex-guardrails/scripts/smoke.sh && python3 -c "import json;json.load(open('.claude-plugin/marketplace.json'))"`
  - Blocked-by: phase-2.2

---

### Phase 3 — apex-agent-team (Theme E, complexity: low-med)

Agent-team coordination: E1 TeamLint (static analysis of subagent/agent-team config for dead agents, overlapping roles, missing tool grants, unbounded fan-out) and E2 ContextBudget (PreCompact/SessionStart hooks that monitor + warn before compaction drops critical state).

- [x] **Phase 3.1** [backend] Build apex-agent-team plugin (TeamLint skill + ContextBudget hooks, pure)
  - Acceptance: `plugins/apex-agent-team/.claude-plugin/plugin.json` valid (no surface arrays); README has the 4 required sections; `docs/adrs/0001-apex-agent-team-contract.md` status `Accepted`; every SKILL.md `name:` is unquoted kebab-case
  - Swarm: single [coder]
  - Blocked-by: gate-2-3

- [x] **Phase 3.2** [backend] Register in marketplace.json + README; write scripts/smoke.sh
  - Acceptance: `python3 -c "import json;m=json.load(open('.claude-plugin/marketplace.json'));assert any(p['source']=='./plugins/apex-agent-team' for p in m['plugins'])"` and `grep -q 'apex-agent-team' README.md`
  - Swarm: single [coder]
  - Blocked-by: phase-3.1

- [x] **Gate 3→4** [gate:auto] apex-agent-team smoke green
  - Acceptance: `bash plugins/apex-agent-team/scripts/smoke.sh && python3 -c "import json;json.load(open('.claude-plugin/marketplace.json'))"`
  - Blocked-by: phase-3.2

---

### Phase 4 — apex-legacy-comprehension (Theme D, complexity: med)

Legacy/AI-generated code comprehension: D1 CharacterizationTest (a skill that generates pinning tests capturing CURRENT behavior before refactor — explicitly not greenfield TDD) and D2 SystemMap (a subagent that builds + maintains a living interaction/dependency summary in its own isolated context).

- [x] **Phase 4.1** [backend][docs] Build apex-legacy-comprehension plugin (skill + subagent, pure)
  - Acceptance: `plugins/apex-legacy-comprehension/.claude-plugin/plugin.json` valid (no surface arrays); the SystemMap agent has `name:` + `model:` frontmatter; CharacterizationTest SKILL.md has unquoted kebab `name:` and explicit non-wildcard `allowed-tools`; README has the 4 required sections; ADR `0001-*` status `Accepted`
  - Swarm: single [coder]
  - Blocked-by: gate-3-4

- [x] **Phase 4.2** [backend] Register in marketplace.json + README; write scripts/smoke.sh
  - Acceptance: `python3 -c "import json;m=json.load(open('.claude-plugin/marketplace.json'));assert any(p['source']=='./plugins/apex-legacy-comprehension' for p in m['plugins'])"` and `grep -q 'apex-legacy-comprehension' README.md`
  - Swarm: single [coder]
  - Blocked-by: phase-4.1

- [x] **Gate 4→5** [gate:auto] apex-legacy-comprehension smoke green
  - Acceptance: `bash plugins/apex-legacy-comprehension/scripts/smoke.sh && python3 -c "import json;json.load(open('.claude-plugin/marketplace.json'))"`
  - Blocked-by: phase-4.2

---

### Phase 5 — apex-contracts-reliability (Theme F, complexity: med)

Tool-contract + runtime reliability: F1 ToolContractCheck (Pre/PostToolUse hooks that validate MCP/tool input-output schemas against actual calls and flag contract drift) and F2 FlakeGuard (detect non-deterministic agent failures — retries, partial tool failures — and surface a reliability report).

- [x] **Phase 5.1** [backend] Build apex-contracts-reliability plugin (Pre/PostToolUse hooks + skill, pure)
  - Acceptance: `plugins/apex-contracts-reliability/.claude-plugin/plugin.json` valid (no surface arrays); hooks declared with valid JSON; README has the 4 required sections; ADR `0001-*` status `Accepted`; no wildcard tools in any `allowed-tools`
  - Swarm: single [coder]
  - Blocked-by: gate-4-5

- [x] **Phase 5.2** [backend] Register in marketplace.json + README; write scripts/smoke.sh
  - Acceptance: `python3 -c "import json;m=json.load(open('.claude-plugin/marketplace.json'));assert any(p['source']=='./plugins/apex-contracts-reliability' for p in m['plugins'])"` and `grep -q 'apex-contracts-reliability' README.md`
  - Swarm: single [coder]
  - Blocked-by: phase-5.1

- [x] **Gate 5→6** [gate:auto] apex-contracts-reliability smoke green
  - Acceptance: `bash plugins/apex-contracts-reliability/scripts/smoke.sh && python3 -c "import json;json.load(open('.claude-plugin/marketplace.json'))"`
  - Blocked-by: phase-5.2

---

### Phase 6 — apex-agent-observability (Theme A, complexity: med-high, MCP)

Multi-agent observability: A1 AgentTrace (hooks record every subagent spawn, tool call, token spend, execution-order edge into a local JSONL/SQLite timeline), A2 OrchestrationReplay (capture-and-replay a run), A3 TokenLens (per-subagent cost/latency attribution). Ships an OPTIONAL local MCP server for dashboard reads; core hooks/skills work without it.

- [x] **Phase 6.1** [backend][perf] Build apex-agent-observability plugin (hooks + datastore + optional MCP)
  - Acceptance: `plugins/apex-agent-observability/.claude-plugin/plugin.json` valid (no surface arrays); SubagentStart/Stop + Pre/PostToolUse hooks declared; optional MCP server declared as valid JSON; README has the 4 required sections + an `## MCP (optional)` note; ADR `0001-*` status `Accepted`; any MCP-referencing `allowed-tools` use explicit names, never `mcp__*` wildcards
  - Swarm: single [coder]
  - Blocked-by: gate-5-6

- [x] **Phase 6.2** [backend] Register in marketplace.json + README; write extended scripts/smoke.sh (12-check)
  - Acceptance: `python3 -c "import json;m=json.load(open('.claude-plugin/marketplace.json'));assert any(p['source']=='./plugins/apex-agent-observability' for p in m['plugins'])"` and `grep -q 'apex-agent-observability' README.md`
  - Swarm: single [coder]
  - Blocked-by: phase-6.1

- [x] **Gate 6→7** [gate:auto] apex-agent-observability extended smoke green
  - Acceptance: `bash plugins/apex-agent-observability/scripts/smoke.sh && python3 -c "import json;json.load(open('.claude-plugin/marketplace.json'))"`
  - Blocked-by: phase-6.2

---

### Phase 7 — apex-rag-memory (Theme C, complexity: med-high, MCP)

RAG/memory lifecycle: C1 MemoryDoctor (audits chunking, embedding-model/version drift, stale vectors, retrieval recall) and C2 EvalHarness (builds a golden Q/A set from the repo, measures retrieval precision/recall regression across embedding changes). Ships an OPTIONAL local MCP server for vector-store access; skill surface degrades gracefully without it.

- [x] **Phase 7.1** [backend][ml-serving] Build apex-rag-memory plugin (skill + optional MCP for vector-store access)
  - Acceptance: `plugins/apex-rag-memory/.claude-plugin/plugin.json` valid (no surface arrays); MemoryDoctor + EvalHarness skills have unquoted kebab `name:` and explicit non-wildcard `allowed-tools`; optional MCP server declared as valid JSON; README has the 4 required sections + `## MCP (optional)`; ADR `0001-*` status `Accepted`
  - Swarm: single [coder]
  - Blocked-by: gate-6-7

- [x] **Phase 7.2** [backend] Register in marketplace.json + README; write extended scripts/smoke.sh (12-check)
  - Acceptance: `python3 -c "import json;m=json.load(open('.claude-plugin/marketplace.json'));assert any(p['source']=='./plugins/apex-rag-memory' for p in m['plugins'])"` and `grep -q 'apex-rag-memory' README.md`
  - Swarm: single [coder]
  - Blocked-by: phase-7.1

- [x] **Gate 7→8** [gate:auto] apex-rag-memory extended smoke green
  - Acceptance: `bash plugins/apex-rag-memory/scripts/smoke.sh && python3 -c "import json;json.load(open('.claude-plugin/marketplace.json'))"`
  - Blocked-by: phase-7.2

---

### Phase 8 — Completion (SPARC: Completion)

Full-suite verification: every smoke test green, manifest valid, README consistent, cross-file name/description parity.

- [x] **Phase 8.1** [tests] Run all 7 smoke tests in one sweep
  - Acceptance: `for d in plugins/*/scripts/smoke.sh; do bash "$d" || exit 1; done`
  - Swarm: single [tester]
  - Blocked-by: gate-7-8

- [x] **Phase 8.2** [tests] Verify cross-file name/description consistency for all 6 new plugins
  - Acceptance: `bash docs/novel-plugins-suite/verify-consistency.sh` (asserts each plugin's name+description match across marketplace.json, plugin.json, README) exits 0
  - Swarm: single [tester]
  - Blocked-by: phase-8.1

- [x] **Phase 8.3** [docs] Flip suite ADR status to `Implemented`
  - Acceptance: `grep -q '^\*\*Status\*\*: Implemented' .claude/tasks/novel-plugins-suite-adr.md`
  - Swarm: single [coder]
  - Blocked-by: phase-8.1, phase-8.2

- [x] **Gate 8→done** [gate:auto] Suite complete, staged, not pushed
  - Acceptance: `for d in plugins/*/scripts/smoke.sh; do bash "$d" || exit 1; done && python3 -c "import json;json.load(open('.claude-plugin/marketplace.json'))" && git status --porcelain | grep -q .`
  - Blocked-by: phase-8.3

---

## Out-of-scope

- Committing or pushing to GitHub (done state is staged-locally per SCOPE; user ships manually).
- Building full production MCP servers — observability/rag-memory ship minimal OPTIONAL stubs only.
- Any of the 3 research-refuted ideas or the saturated code-review/test-gen/scan/scaffold categories.
- Per-idea standalone plugins (we bundle into 6 themes per SCOPE).

## Open questions (escalations)

- (none yet)

---

## Status checks

```bash
# Current state
.claude/skills/apex-plan/scripts/status.sh novel-plugins-suite

# Evaluate a single gate without /loop running
.claude/skills/apex-plan/scripts/gate.sh .claude/plans/novel-plugins-suite-plan.md gate-2-3
```
