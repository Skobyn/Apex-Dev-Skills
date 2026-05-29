# ADR-0001: apex-legacy-comprehension plugin contract

- **Status:** Proposed
- **Date:** 2026-05-29
- **Author:** solutions@getapexinsights.com
- **Plugin:** apex-legacy-comprehension v0.1.0

## Context

Engineers increasingly inherit code they did not write and that has no tests — classic
legacy systems and, now at growing volume, AI-generated / "vibe-coded" modules. Michael
Feathers' definition applies to both: *legacy code is code without tests.* Two distinct
needs follow from that situation:

1. **Comprehension** — orienting in an unfamiliar codebase fast, without loading the
   whole repo into the working thread's context.
2. **Safe change** — getting a regression net under an untested module *before*
   refactoring it, so behavior is provably preserved.

These are theme D ("legacy & AI-generated-code comprehension") of the novel-plugins
suite (see `.claude/tasks/novel-plugins-suite-adr.md`). They are complementary — map
then pin — and ship together as one plugin.

## Decision

Bundle two sub-features into a single plugin `apex-legacy-comprehension`:

### Layout

```
plugins/apex-legacy-comprehension/
├── .claude-plugin/plugin.json                 # name, version, description, author, license, keywords
├── skills/
│   └── characterization-test/SKILL.md         # D1: pinning tests for untested legacy/AI code
├── agents/
│   └── system-map.md                          # D2: isolated-context codebase mapper (model: sonnet)
├── commands/
│   └── system-map.md                          # dispatch the system-map agent
├── scripts/smoke.sh                           # structural contract checks
├── docs/adrs/0001-apex-legacy-comprehension-contract.md
└── README.md
```

### Surface

- **1 skill** — `characterization-test`, auto-discovered from `skills/`, not enumerated in plugin.json.
- **1 agent** — `system-map` (Sonnet), runs in its own isolated context to avoid polluting the main thread.
- **1 slash command** — `/apex-legacy-comprehension:system-map [scope]`, dispatches the agent.

### D1 — CharacterizationTest (skill)

The skill pins the **current** observable behavior of an untested module so a refactor
is behavior-preserving. It is explicitly **not** greenfield TDD and **not** a
code-quality pass:

- Assert what the code does **today**, including outputs that look wrong (flag, don't fix).
- Probe-then-pin: assert a placeholder, run, read the real value from the failure, pin it.
- Pin the full observable surface: returns, exceptions, mutations, side effects, collaborator calls.
- All characterization tests must pass against the **unchanged** code before any refactor.
- Pinning, refactoring, and bug-fixing are three separate commits.
- Language-agnostic: detect and reuse the repo's existing test framework; never introduce a new one.

### D2 — SystemMap (agent + command)

The `system-map` subagent explores an unfamiliar codebase in its **own isolated
context** and returns a concise architecture map — entry points, module boundaries,
data flows, external dependencies, and concrete "how X talks to Y" call chains — without
dumping file contents back to the parent thread. It reads source but does not modify it,
and can update an existing `docs/system-map.md` in place to act as a living document.

### Compatibility

- Claude Code: 2.0+ (the command uses the `Agent` tool; the skill uses Read/Write/Edit/Bash/Glob/Grep).
- Language-agnostic for characterization tests; the target repo's own toolchain runs the tests.
- The plugin ships no MCP server. `allowed-tools` lists in the skill are conservative
  built-ins (Read, Write, Edit, Bash, Glob, Grep) — no `*` or `mcp__*` wildcards. MCP
  availability is environmental, not declared.

### Namespace coordination

The plugin reserves a single AgentDB / memory namespace: **`legacy-comprehension`**,
registered against the suite ADR at `.claude/tasks/novel-plugins-suite-adr.md`. Sub-keys:

- `legacy-comprehension:characterizations/<module>` — pinned-behavior notes + surprising-output findings.
- `legacy-comprehension:maps/<repo-or-scope>` — cached system-map summaries.

This follows the namespace convention from ruflo-agentdb ADR-0001 §"Namespace
convention" (kebab-case `<plugin-stem>-<intent>`, colon-scoped sub-keys). Any future
plugin reading/writing these keys must claim a non-overlapping prefix and reference this
ADR.

### Smoke contract

`scripts/smoke.sh` verifies 10 structural checks:

1. `plugin.json` exists with `name`, `version`, `description`, `author`, `license`, `keywords`.
2. `plugin.json` does **not** enumerate `skills`/`commands`/`agents` arrays.
3. `skills/characterization-test/SKILL.md` has valid frontmatter with unquoted kebab-case `name:`.
4. No SKILL.md uses wildcard tools (`*`, `mcp__*`) in `allowed-tools`.
5. `skills/characterization-test/SKILL.md` declares an explicit `allowed-tools:` list.
6. `agents/system-map.md` exists with `name: system-map` and `model: sonnet`.
7. `commands/system-map.md` exists with valid `name:` + `description:` frontmatter.
8. `README.md` exists with "Compatibility", "Namespace coordination", "Verification", "Architecture Decisions" sections.
9. This ADR-0001 exists with `Status: Proposed`.
10. All `*.sh` scripts under `skills/` and `scripts/` are executable.

The smoke script exits non-zero on any failing check and names the first failure, then
prints `smoke passed: N/N checks` on success.

## Consequences

### Positive

- Map-then-pin ships as one cohesive capability; the two moves reinforce each other.
- The system-map agent isolates exploration cost, keeping the parent thread's context clean.
- Characterization-first refactoring gives engineers a provable safety net for both classic legacy and AI-generated code.
- Versioned via `plugin.json` `version:` for coordinated changes.

### Negative

- The skill cannot *guarantee* the pinned behavior is correct — by design it pins reality,
  including bugs. Users must understand the distinction between pinning and fixing.
  **Mitigation:** the skill's "what it is NOT" table and hard rules make this explicit.
- The system-map agent's map is a snapshot; it can drift as the codebase changes.
  **Mitigation:** the agent supports updating an existing `docs/system-map.md` in place.

### Neutral

- The plugin assumes the host provides the `Agent` tool for subagent dispatch and a test
  runner in the target repo. Documented in Compatibility, not enforced at install time.

## Status changes

- 2026-05-29 — Proposed (initial scaffold).
