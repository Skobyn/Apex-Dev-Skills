# apex-legacy-comprehension

> Understand and safely change legacy or AI-generated code: pin current behavior with characterization tests before refactoring, and build a living system map of an unfamiliar codebase in an isolated subagent context.

> **Understand it before you touch it. Pin it before you change it.**
> Tools for working safely in code you didn't write — legacy systems and AI-generated
> "new legacy" alike.

The hardest code to change isn't old code — it's *unfamiliar, untested* code. A
twenty-year-old service with no tests and an LLM-emitted module from last Tuesday share
the same problem: **nobody holds the mental model, and there's no safety net.** Michael
Feathers' definition still holds — *legacy code is simply code without tests* — and the
rise of vibe-coding has made that category grow faster than ever.

**apex-legacy-comprehension** gives you two complementary moves for that situation:

## What it does

- **Pin current behavior before refactoring** — the `characterization-test` skill
  generates *characterization (pinning) tests* that capture what an untested module
  does **today** (even where it looks wrong), so a refactor is provably
  behavior-preserving. This is explicitly **not** greenfield TDD and **not** a
  code-quality pass: you assert reality, not intent, and the suite turns red the instant
  observable behavior changes.

- **Map an unfamiliar codebase without polluting your context** — the `system-map`
  subagent explores the repo in **its own isolated context** and returns a concise
  architecture summary: entry points, module boundaries, data flows, external
  dependencies, and concrete "how X talks to Y" call chains. It reads widely and reports
  tersely, so the main thread never has to load hundreds of files.

Use them together: `system-map` tells you *what* the code is and how it connects;
`characterization-test` lets you *change* it safely.

## Why you'll want it

- **Refactor without fear.** A green pinning suite is permission to rename, extract, and
  simplify — the net catches any behavior drift immediately.
- **Tame AI-generated code.** Vibe-coded modules ship without tests; this is the fastest
  honest way to get a net under them before you build on top.
- **Onboard in minutes, not days.** The system-map agent distills a strange codebase
  into a scannable map of entry points, boundaries, and data flows.
- **Keep your context clean.** Exploration cost is paid in the subagent's context, not
  yours — you get the map, not the file dump.

## Install

```bash
# From the Apex marketplace
/plugin marketplace add Skobyn/Apex-Dev-Skills
/plugin install apex-legacy-comprehension@apex-dev-skills

# …or test locally against this repo
claude --plugin-dir ./plugins/apex-legacy-comprehension
```

Then `/reload-plugins` (or restart Claude Code) to activate.

## Quick start

```bash
# Map an unfamiliar codebase (whole-repo onboarding) in an isolated subagent context
/apex-legacy-comprehension:system-map

# …or ask a scoped interaction question
/apex-legacy-comprehension:system-map how does the auth module reach the user store?

# Pin the current behavior of an untested module before refactoring it
# (the characterization-test skill auto-triggers on phrasing like:)
#   "I need to refactor this but there are no tests"
#   "pin the current behavior of this function"
#   "this AI-generated code has no coverage and I'm scared to change it"
```

## What you get

| Surface | Name | Trigger |
|---|---|---|
| Skill | `characterization-test` | Auto-triggered on "no tests but need to refactor", "pin current behavior", "characterization/pinning tests", untested AI-generated code |
| Agent | `system-map` | Delegate when onboarding to / orienting in an unfamiliar codebase, or answering "how X talks to Y" |
| Command | `/apex-legacy-comprehension:system-map [scope]` | Dispatch the system-map agent in its own context |

## Compatibility

- **Claude Code:** 2.0+ (the `system-map` command uses the `Agent` tool to run the
  subagent in an isolated context; the skill uses Read/Write/Edit/Bash/Glob/Grep).
- **Test frameworks:** language-agnostic. The `characterization-test` skill detects and
  reuses whatever framework the target repo already uses (pytest, Jest/Vitest, JUnit, Go
  `testing`, RSpec, …) and never introduces a new one.
- **No MCP server required.** The plugin ships no MCP server; `allowed-tools` are
  conservative built-ins (no `*` / `mcp__*` wildcards). Any MCP tools are environmental.
- **Python / Node / etc.:** not required by the plugin itself (its scripts are bash);
  the target codebase's own toolchain runs the generated tests.

## Namespace coordination

This plugin claims the AgentDB / memory namespace **`legacy-comprehension`**, following
the kebab-case `<plugin-stem>-<intent>` convention from ruflo-agentdb ADR-0001
§"Namespace convention" and registered in the suite-level ADR at
`.claude/tasks/novel-plugins-suite-adr.md`. Sub-keys:

| Key prefix | Holds |
|---|---|
| `legacy-comprehension:characterizations/<module>` | Pinned-behavior notes + surprising-output findings for a module |
| `legacy-comprehension:maps/<repo-or-scope>` | Cached system-map summaries (entry points, boundaries, flows) |

Any future plugin that wants to read/write these keys must claim a non-overlapping
prefix and reference this plugin's ADR-0001 (and the suite ADR).

## Verification

```bash
bash plugins/apex-legacy-comprehension/scripts/smoke.sh
```

The smoke script runs 10 structural checks (plugin.json keys, no enumerated surface
arrays, kebab-case skill names, no wildcard `allowed-tools`, agent `model: sonnet`,
command frontmatter, README sections, ADR status, script executability). It exits
non-zero on the first failing check and names what's wrong.

## Architecture Decisions

- [ADR-0001 — apex-legacy-comprehension plugin contract](docs/adrs/0001-apex-legacy-comprehension-contract.md) — Status: **Proposed**. Defines surface, namespace, compatibility, and smoke contract.

## License

MIT — see the repo-level LICENSE.
