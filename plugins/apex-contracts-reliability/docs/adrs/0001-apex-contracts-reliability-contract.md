# ADR-0001: apex-contracts-reliability plugin contract

- **Status:** Proposed
- **Date:** 2026-05-29
- **Author:** solutions@getapexinsights.com
- **Plugin:** apex-contracts-reliability v0.1.0

## Context

The Apex marketplace has plugins for planning, guardrails, and agent teams, but
two empirically common failure families have no coverage: (1) **tool-contract
drift** — a tool or MCP server's call shape silently changes (field added or
removed, type flips), so an agent that worked yesterday quietly misbehaves
today; and (2) **non-deterministic agent failures** — a tool that fails then
succeeds on retry, partial tool failures, the same call passing once and failing
the next time. Both are runtime phenomena invisible to ordinary test/lint
tooling, which inspects *source code*, not the live *tool-call traffic* an agent
produces. They are exactly the kind of problem that compounds across an
autonomous `/loop` into wasted iterations and untrustworthy results.

This is theme **F** of the novel-plugins suite (see
`.claude/tasks/novel-plugins-suite-adr.md`). The aim is a single, dependency-free
plugin that observes real tool calls and surfaces both classes of problem.

## Decision

Ship one plugin, `apex-contracts-reliability`, that captures tool-call I/O via
hooks into a local JSONL ledger and analyzes it two ways. Contract:

### Layout

```
plugins/apex-contracts-reliability/
├── .claude-plugin/plugin.json              # name, version, description, author, license, keywords
├── skills/
│   ├── tool-contract-check/SKILL.md        # F1 — reviewing the drift report
│   └── flake-guard/SKILL.md                # F2 — reviewing the reliability report
├── commands/
│   └── reliability-report.md               # /apex-contracts-reliability:reliability-report [drift|all]
├── hooks/
│   ├── hooks.json                          # PreToolUse + PostToolUse, matcher "*"
│   └── capture-tool-io.sh                  # appends a shape record per call to the ledger
├── scripts/
│   ├── analyze-ledger.sh                   # drift | reliability report engine (python3 stdlib)
│   └── smoke.sh                            # structural contract checks
├── docs/adrs/0001-apex-contracts-reliability-contract.md
└── README.md
```

### Surface

- **2 skills** — `tool-contract-check`, `flake-guard` — auto-discovered from the
  `skills/` subtree, **not** enumerated in `plugin.json`.
- **1 slash command** — `/apex-contracts-reliability:reliability-report`.
- **2 hooks** — one `capture-tool-io.sh` script bound to both `PreToolUse` and
  `PostToolUse` for every tool (`"*"`).
- **0 agents** — none are needed; the work is observational + analytical.

### F1 — ToolContractCheck

`capture-tool-io.sh` records each call's input shape (and output shape on
PostToolUse) as a field → JSON-type map, one level deep. `analyze-ledger.sh
drift` treats the first observed input shape per tool as the established schema
and flags later calls that add a field, drop a field, or change a field's type.
Shapes (not raw values) are stored, so the ledger never hoards secrets or large
payloads.

### F2 — FlakeGuard

`analyze-ledger.sh reliability` computes per tool: failure rate (PostToolUse
`ok:false` ÷ total), retry runs (≥2 consecutive identical-shape PreToolUse
calls), and flip-flops (one input shape observed both succeeding and failing). A
tool is FLAKY when `0 < rate < 1`, or it has retry runs, or it has flip-flops. A
100%-failing tool is reported as `stable` (broken, not flaky).

### Reliability of the hook itself

The capture hook is **observational only**: it never blocks a tool call. On any
error it emits an allow/continue verdict and exits 0, so a malformed event or a
missing `python3` can never wedge the agent. Without `python3` it degrades to a
raw-line append; the analyzer tolerates and skips unparseable lines.

### Compatibility

- Claude Code: 2.0+ (requires the hooks system with `PreToolUse` / `PostToolUse`
  events and `${CLAUDE_PLUGIN_ROOT}` / `${CLAUDE_PROJECT_DIR}` substitution).
- python3 3.8+ (stdlib only) for shape inference and report generation; the hook
  degrades gracefully if it is absent. No third-party packages, no MCP server.

### MCP tool surface

The plugin ships **no** MCP server. `allowed-tools` in the skills and command are
a conservative explicit list — `Bash`, `Read`, `Grep`, `Glob` — with **no**
wildcards and **no** `mcp__*` entries. The capture hook matches all tools (`"*"`)
at the *hook* layer, which is the hook matcher syntax and is distinct from a
skill's `allowed-tools`.

### Namespace coordination

The plugin claims the namespace **`contracts-reliability`**, following the
kebab-case `<plugin-stem>-<intent>` convention and registered against
`.claude/tasks/novel-plugins-suite-adr.md`. Concrete artifacts under it:

- on-disk ledger path: `.claude/contracts-reliability/ledger.jsonl`
- any AgentDB / memory keys: prefix `contracts-reliability:` (e.g.
  `contracts-reliability:schema/<tool>`, `contracts-reliability:flaky/<tool>`)

Any future plugin that reads or writes these keys (or this ledger) must claim a
non-overlapping prefix and reference this ADR.

### Smoke contract

`scripts/smoke.sh` verifies at minimum these structural checks, exiting non-zero
on the first failure with a named reason and printing `smoke passed: N/N checks`
on success:

1. `plugin.json` exists with `name`, `version`, `description`, `author`,
   `license`, `keywords`.
2. `plugin.json` does **not** enumerate `skills`/`commands`/`agents` arrays.
3. Each `SKILL.md` has unquoted kebab-case `name:` matching its directory.
4. No `SKILL.md` uses wildcard tools (`*`, `mcp__*`).
5. The `reliability-report` command has valid `name:` + `description:`
   frontmatter.
6. `hooks/hooks.json` is valid JSON and references `capture-tool-io.sh`.
7. `README.md` has the required sections (Compatibility, Namespace coordination,
   Verification, Architecture Decisions).
8. This ADR exists with `Status: Proposed`.
9. All `*.sh` files are executable.

## Consequences

### Positive

- Two high-value, low-coverage failure families become observable from real
  traffic with zero configuration and no source-code instrumentation.
- Dependency-free (bash + python3 stdlib) and non-blocking, so it is safe to
  leave installed in any project.
- The analyzer's exit code (`3` on drift/flakiness) lets a `/loop` or CI step
  gate on tool reliability.

### Negative

- The "first call defines the schema" heuristic means an unusual first call can
  set a misleading baseline; mitigated by documenting how to reset the ledger.
- Shape inference is one level deep, so deeply nested contract changes collapse
  to `object` and may be missed. Acceptable for v0.1.0; a later ADR can deepen it.

### Neutral

- The ledger lives under the project's `.claude/` directory and is per-developer;
  teams should `.gitignore` it. A future ADR can add an opt-in shared store under
  the `contracts-reliability:` memory namespace.

## Status changes

- 2026-05-29 — Proposed (initial scaffold).
