# ADR-0001: Novel Plugins Suite — Six Themed Claude Code Plugins

**Status**: Implemented
**Date**: 2026-05-29
**Slug**: `novel-plugins-suite`
**Author**: skobyn@gmail.com
**Reviewer**: skobyn@gmail.com
**Implementor**: skobyn@gmail.com
**Companion Plan**: [`.claude/plans/novel-plugins-suite-plan.md`](../plans/novel-plugins-suite-plan.md)

> Status transitions: `Proposed` → `Accepted` → `Implemented` → (optional) `Superseded by ADR-MMMM`.
> `promote-to-loop.sh` refuses to run until status is `Accepted`.

---

## TL;DR

- Add **6 themed plugins** to the Apex-Dev-Skills marketplace, derived from a verified deep-research pass that mapped marketplace saturation against empirical developer pain (arXiv 2510.25423) and Claude Code primitive capabilities.
- Each plugin bundles 2–3 related sub-ideas (13 total) into a cohesive surface, targeting **under-served niches**: agent observability, deterministic guardrails, RAG/memory lifecycle, legacy comprehension, agent-team coordination, and tool-contract/runtime reliability — deliberately **avoiding** the oversaturated code-review/test-gen/security-scan/scaffold categories.
- Build order is **complexity-ascending** so the lowest-risk hook plugins validate the contract first; each plugin is built by a **single coder agent** and closed by an **auto-gate running its own `smoke.sh`**.
- **MCP servers are permitted only where genuine external capability is required** (observability dashboard datastore; RAG vector-store access); all other plugins stay pure markdown+shell to match the existing repo contract.
- Done state: all 6 plugins exist, registered in `marketplace.json`, README table updated, every `smoke.sh` green — **staged locally, not pushed**.

---

## Context (SPARC: Specification)

### Why this matters

The deep-research pass (109 agents, 26 sources, 22/25 claims verified) established that the Claude Code extension ecosystem is **densely saturated in the obvious categories**: across the official Anthropic marketplace (~204 plugins), `wshobson/agents` (191 agents + 155 skills + 102 commands), and `VoltAgent` (154+ subagents), code review, test generation, security scanning, scaffolding, and infra setup are heavily duplicated [3-0 verified]. Shipping another of those adds no value.

The verified opportunity sits where **empirical developer pain** (82.6% of AI-agent Stack Overflow questions unanswered; 88.4% for RAG/orchestration) intersects with **under-exploited primitives** — especially **hooks**, the only primitive offering guaranteed, deterministic enforcement (a `PreToolUse` deny is enforcement; a CLAUDE.md/skill rule is only a request) [3-0 verified]. This ADR converts that finding into a concrete, buildable suite.

### Requirements

| ID | Priority | Requirement |
|----|----------|-------------|
| R1 | MUST | Deliver 6 themed plugins covering the 13 researched ideas, each registered in `marketplace.json` and the root README table |
| R2 | MUST | Every plugin conforms to the repo contract: valid `.claude-plugin/plugin.json` (no enumerated skills/commands/agents arrays), kebab-case unquoted skill names, explicit non-wildcard `allowed-tools`, required README sections, an `0001-*` ADR, and a passing `scripts/smoke.sh` |
| R3 | MUST | Each plugin avoids the saturated categories (no generic code-reviewer / test-generator / vuln-scanner / scaffolder as its core surface) |
| R4 | SHOULD | Plugins stay pure markdown+shell unless external runtime capability is genuinely required; MCP servers permitted only for the observability datastore and RAG vector-store access |
| R5 | SHOULD | Build order is complexity-ascending; each plugin phase is gated by its own `smoke.sh` before the next begins |
| R6 | MAY | Provide a one-line value proposition per plugin in the README suitable for marketplace discovery |

### Constraints

- Must not break the existing `apex-scope-loop` plugin or the two-tier manifest sync (`marketplace.json` ↔ each `plugin.json` ↔ each `README.md`).
- Each new plugin must ship its own `scripts/smoke.sh` following the existing 10-check shape (manifest keys, kebab-case skill names, no wildcard tools, command/agent frontmatter, README sections, ADR status, script executability).
- MCP-bearing plugins (observability, rag-memory) get an **extended** smoke test that additionally validates the MCP server declaration, but must still pass the 10 core checks.
- All shell scripts use `set -euo pipefail`, are `chmod +x` (mode 100755), and LF line endings (per `.gitattributes`).
- No secrets, no network calls in smoke tests, no external runtime required to *install* a plugin.

### Success criteria

- `bash plugins/<name>/scripts/smoke.sh` exits 0 for all 6 new plugins — runnable: per-plugin smoke gate.
- `python3 -c "import json,sys; json.load(open('.claude-plugin/marketplace.json'))"` succeeds and lists all 6 new plugins with `./plugins/<name>` sources — runnable: marketplace JSON validity check.
- Root `README.md` plugins table contains a row for each of the 6 new plugins — runnable: `grep` per plugin name.
- Every plugin's `name`/`description` is identical across `marketplace.json`, its `plugin.json`, and its `README.md` — runnable: cross-file consistency grep.

---

## Decision

### Pseudocode (SPARC)

```
ALGORITHM build_novel_plugins_suite:
  INPUT:
    - 13 researched ideas grouped into 6 themes (A..F)
    - reference plugin: plugins/apex-scope-loop (the contract exemplar)
  PRECONDITIONS:
    - repo is the marketplace dev workspace, apex-scope-loop smoke passes
  STEPS:
    1. Establish shared scaffolding conventions (smoke.sh skeleton, plugin.json
       shape, README section set) once, reused by every plugin phase.
    2. FOR each theme in complexity_ascending_order(B, E, D, F, A, C):
         a. Create plugins/<theme-name>/ with .claude-plugin/plugin.json
         b. Author the 2-3 skills/commands/agents/hooks for that theme
         c. IF theme needs external capability THEN add MCP server + extended smoke
            ELSE keep pure markdown+shell
         d. Write docs/adrs/0001-<name>-contract.md (the plugin contract)
         e. Write README.md with required sections
         f. Register in marketplace.json + root README table
         g. Write scripts/smoke.sh; RUN it
         h. GATE: smoke.sh exits 0 AND marketplace.json valid -> advance, else halt
    3. Final sweep: run ALL smoke tests + marketplace validity + README consistency
  POSTCONDITIONS:
    - 7 plugins total registered (1 existing + 6 new), all smoke-green, staged
  OUTPUT:
    - staged working tree ready for user review (no commit, no push)

ERROR PATHS:
    - smoke fails for a plugin -> halt that phase, report first failing check, do not advance
    - marketplace.json invalid -> halt, do not corrupt the manifest for other plugins
    - MCP decision unclear for a plugin -> fall back to pure markdown+shell (R4 default)
```

### Architecture (SPARC)

```
                        Apex-Dev-Skills marketplace
                                   |
            .claude-plugin/marketplace.json  (registry, 1+6 entries)
                                   |
   +-------------+-------------+-------------+-------------+-------------+-------------+
   |             |             |             |             |             |             |
apex-          apex-        apex-         apex-         apex-         apex-         apex-
scope-loop   guardrails   agent-team   legacy-       contracts-    agent-        rag-
(existing)   (B,low)      (E,low-med)  comprehension reliability   observability memory
                                       (D,med)       (F,med)       (A,med-high)  (C,med-high)
   |             |             |             |             |             |             |
 [contract]  PreToolUse   PreCompact/   skill+         Pre/Post     hooks +       skill +
  exemplar    hooks +      SessionStart  subagent +    ToolUse      datastore +   MCP (vector
              bash         hooks + skill LSP-aware     hooks        MCP (dash)    store access)
                                         skill
```

**Plugins (modules)**:

| Plugin (dir) | Theme | Bundles | Primary primitive | Runtime | Complexity |
|---|---|---|---|---|---|
| `apex-guardrails` | B | B1 GuardRail, B2 PolicyAsCode, B3 SecretGuard | PreToolUse hooks + bash | pure | low |
| `apex-agent-team` | E | E1 TeamLint, E2 ContextBudget | skill + PreCompact/SessionStart hooks | pure | low-med |
| `apex-legacy-comprehension` | D | D1 CharacterizationTest, D2 SystemMap | skill + subagent (LSP-aware) | pure | med |
| `apex-contracts-reliability` | F | F1 ToolContractCheck, F2 FlakeGuard | Pre/PostToolUse hooks + skill | pure | med |
| `apex-agent-observability` | A | A1 AgentTrace, A2 OrchestrationReplay, A3 TokenLens | hooks + local datastore | **MCP** (dashboard read) | med-high |
| `apex-rag-memory` | C | C1 MemoryDoctor, C2 EvalHarness | skill | **MCP** (vector-store access) | med-high |

### Data Model

Plugin-local state only — no shared database. Observability writes append-only JSONL (and optional SQLite) under a run-local path; RAG eval writes golden Q/A sets as repo files. No global schema, no migrations.

```
apex-agent-observability:  <run-dir>/agenttrace.jsonl   (one event per line: ts, event, subagent_id, tool, tokens)
apex-rag-memory:           docs/<project>/retrieval-golden.jsonl  (q, expected_doc_ids)
```

### API Surface

No HTTP API. MCP servers (observability, rag-memory) expose read-only MCP tools over local state; tool names and schemas are defined in each plugin's own ADR-0001, not here.

---

## What changes / What stays

| Area | Today | After this decision |
|------|-------|---------------------|
| Marketplace plugins | 1 (`apex-scope-loop`) | 7 (1 existing + 6 new) |
| `marketplace.json` | 1 source entry | 7 source entries |
| Root README plugins table | 1 row | 7 rows |
| MCP usage in repo | none | 2 plugins ship optional local MCP servers |

**Stays untouched**:

- `apex-scope-loop` plugin and its contract ADR.
- The two-tier manifest discipline and the smoke-test-as-contract convention (extended, not replaced).
- `.gitattributes`, `.gitignore`, CLAUDE.md authoring rules.

---

## Open Questions

**Q1.** Should the two MCP-bearing plugins (observability, rag-memory) ship the MCP server in-repo, or document it as an optional add-on the user installs separately?
- **Default**: Ship a minimal, dependency-light MCP server stub in-repo behind an extended smoke check, but mark it OPTIONAL in the README so the plugin's skills/hooks work without it. Keeps the plugin installable as pure artifacts while honoring the "MCP where needed" decision.
- **Decision**: Adopt the default — in-repo optional MCP stub, extended smoke validates its declaration; core skill/hook surface must function without the server running.

**Q2.** What naming prefix should the new plugins use?
- **Default**: `apex-` prefix for all six (matches `apex-scope-loop`), giving a cohesive marketplace identity.
- **Decision**: Use the `apex-` prefix for all six.

**Q3.** How should each plugin claim memory/AgentDB namespaces to avoid collision (per CLAUDE.md namespace coordination)?
- **Default**: Each plugin claims `<plugin-stem>-<intent>` kebab namespaces in its own ADR-0001 (e.g. `agent-observability-trace`, `guardrails-policy`), non-overlapping by construction.
- **Decision**: Adopt the default — namespaces claimed per-plugin in each ADR-0001, referencing this ADR.

**Q4.** Does the existing `promote-to-loop.sh` → `apex-execute/init.sh` handoff work in this repo, where skills live under `plugins/...` not `.claude/skills/...`?
- **Default**: It does not, as-written (it hard-codes `.claude/skills/apex-execute/scripts/init.sh`). Resolve by creating thin symlinks `.claude/skills/apex-plan` and `.claude/skills/apex-execute` → the plugin skill dirs at promote time, OR invoke `init.sh` directly from the plugin path.
- **Decision**: At Stage 5, create the two symlinks under `.claude/skills/` pointing at the plugin skill dirs so the stock scripts resolve unmodified; fall back to direct `init.sh` invocation if symlinks are undesirable.

**Q5.** What is the smoke-test shape for MCP-bearing plugins, given the core contract forbids wildcard tools and enumerated surface arrays?
- **Default**: Extend the 10-check smoke with checks 11–12: (11) MCP server declaration is valid JSON and references an executable/command that exists; (12) any `allowed-tools` referencing the MCP server uses explicit tool names, never `mcp__*` wildcards.
- **Decision**: Adopt the default — extended smoke (12 checks) for MCP-bearing plugins; 10-check smoke for pure ones.

---

## Risks & Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| Parallel writes corrupt `marketplace.json` | med | Single-agent-per-plugin execution (no parallel manifest writes); each phase appends one entry then validates JSON before gate |
| MCP plugins break the pure-artifact smoke contract | med | Extended smoke (Q5) keeps the 10 core checks and adds MCP-specific ones; core surface must work without the server |
| Scope creep (13 ideas balloon per plugin) | med | Each plugin bundles a fixed 2–3 sub-ideas; no plugin exceeds its theme; OQ cap respected |
| A plugin partially duplicates niche prior art (esp. observability vs disler's reference impl) | low-med | Differentiate on packaging/UX and the trace+replay+token-lens bundle; cite prior art in the plugin ADR |
| Stock `promote-to-loop.sh` path mismatch blocks handoff | med | Q4 decision: symlink `.claude/skills/` → plugin skill dirs at promote time |

**Rollback story**: Each plugin is an isolated directory plus one `marketplace.json` entry and one README row. Reverting a phase = delete the directory, remove the entry/row, re-validate JSON. No cross-plugin coupling means any phase can be backed out independently.

---

## Consequences

### Positive

- Six genuinely under-served plugins, each grounded in verified research rather than guesswork.
- Establishes the marketplace's identity around agentic-workflow tooling (observability, guardrails, orchestration) rather than another commodity code-review collection.
- Validates the repo contract on low-risk plugins first; proves the MCP-extended smoke shape for future plugins.

### Negative

- Six new maintenance surfaces (manifests, READMEs, smoke tests, ADRs) to keep in sync.
- Two plugins introduce optional MCP runtime, a new dependency class for this repo.

### Neutral / Worth noting

- "Novelty" was inferred from surveyed marketplaces, not an exhaustive search; partial prior art may exist for some ideas (observability most likely) — each plugin ADR should cite known prior art.
- The arXiv pain figures are SO-answer-behavior signals, not market sizing; treat as directional.

---

## Methodology

- **Sub-agents invoked**: deep-research workflow (109 agents) — fan-out web search across 6 angles, source fetch + claim extraction, 3-vote adversarial verification, synthesis. Results drive Sections "Why this matters" and the plugin breakdown.
- **Sources consulted**: arXiv 2510.25423 (AI-agent dev pain); Anthropic features-overview/hooks/sub-agents docs; wshobson/agents; anthropics/claude-plugins-official marketplace.json; VoltAgent/awesome-claude-code-subagents; disler/claude-code-hooks-multi-agent-observability.
- **Comparable platforms surveyed**: official Anthropic marketplace, wshobson, VoltAgent, jeremylongshore aggregator, claudemarketplaces.com.
- **Counter-evidence considered**: 3 research claims were refuted and excluded (a 425-plugin aggregate count; a "skills cannot create external capability" claim — refuted 1-2, leaving the MCP-vs-pure question genuinely open, which is why R4/Q1 exist; a primitive-taxonomy claim).

---

## Approval

When this ADR's status flips to **Accepted**:

1. The companion plan is the source of truth for execution.
2. `promote-to-loop.sh novel-plugins-suite` initializes apex-execute state (after the Q4 symlink fix).
3. `/loop iterate the next phase of .claude/plans/novel-plugins-suite-plan.md` starts execution.

---

## Changelog

- 2026-05-29 — Drafted by skobyn@gmail.com via `apex-plan` skill, seeded from the deep-research suite findings.
- 2026-05-29 — Accepted; promoted to apex-execute; all 6 plugins built (single coder agent each), smoke-green, registered in marketplace.json + root README; consistency verified. Status → Implemented.
