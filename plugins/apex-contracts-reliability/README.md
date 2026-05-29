# apex-contracts-reliability

> Tool-contract validation + runtime reliability: a PostToolUse ledger that infers per-tool schemas and flags contract drift, plus FlakeGuard detection of non-deterministic agent failures (retries, partial failures, flaky tools).

> **Trust your tools, not your luck.**
> Watches every tool and MCP call an agent makes, infers each tool's contract,
> and tells you the moment that contract drifts — or a tool starts failing
> non-deterministically.

Ordinary tests and linters check your *source code*. They say nothing about the
live *tool-call traffic* an agent produces at runtime — which is exactly where
two of the most expensive, hardest-to-reproduce failures hide:

- **Contract drift** — an MCP server adds a field, drops a field, or flips a
  type. Nothing errors; the agent just quietly gets data it wasn't built to
  read. (`tool-contract-check`)
- **Flaky tools** — a call fails, you re-run, it passes, and you call it a fluke.
  It wasn't: the tool is non-deterministic, and across an autonomous loop that
  flakiness compounds into wasted iterations. (`flake-guard`)

**apex-contracts-reliability** captures both from real traffic — zero config, no
source instrumentation, no MCP server of its own.

## What it does

A single `capture-tool-io.sh` hook is bound to **PreToolUse and PostToolUse for
every tool** (`"*"`). On each call it appends one record — the *shape* of the
input (and output), never the raw values — to a local JSONL ledger at
`.claude/contracts-reliability/ledger.jsonl`. Two analyses run over that ledger:

| Feature | Lens | Surfaces |
|---|---|---|
| **F1 ToolContractCheck** (`tool-contract-check` skill) | shape | Per-tool inferred schema (first call = baseline) and any later call that adds a field, drops a field, or changes a type — flagged as **CONTRACT DRIFT**. |
| **F2 FlakeGuard** (`flake-guard` skill) | success/failure | Per-tool failure rate, retry runs (repeated identical calls), and flip-flops (same call succeeds then fails) — flagged as **FLAKY**. |

Render either report with `/apex-contracts-reliability:reliability-report`
(`reliability` by default, `drift`, or `all`), or run the analyzer directly. It
exits `3` when drift or flakiness is found, so it can gate a loop or CI step.

The capture hook is observational only — it **never blocks a tool call** and
exits cleanly on any error, so it is safe to leave installed everywhere.

## Install

```bash
# From the Apex marketplace
/plugin marketplace add Skobyn/Apex-Dev-Skills
/plugin install apex-contracts-reliability@apex-dev-skills

# …or test locally against this repo
claude --plugin-dir ./plugins/apex-contracts-reliability
```

Then `/reload-plugins` (or restart Claude Code) to activate. The hook starts
recording on the next tool call; invoke a few tools, then run the report.

## Quick start

```bash
# Let an agent run normally for a bit (the hook records every tool call), then:

# FlakeGuard reliability report
/apex-contracts-reliability:reliability-report

# Contract-drift report
/apex-contracts-reliability:reliability-report drift

# Or call the engine directly (exits 3 on drift/flakiness, 0 when clean)
bash plugins/apex-contracts-reliability/scripts/analyze-ledger.sh reliability
bash plugins/apex-contracts-reliability/scripts/analyze-ledger.sh drift --json
```

## What you get

| Surface | Name | Trigger |
|---|---|---|
| Skill | `tool-contract-check` | A tool's call shape changed (new/missing field, type flip); reviewing contract drift |
| Skill | `flake-guard` | Intermittent tool failures, retries, or success-then-failure; reviewing reliability |
| Command | `/apex-contracts-reliability:reliability-report [drift\|all]` | Render the report from the captured ledger |
| Hook | `capture-tool-io.sh` (PreToolUse + PostToolUse, `"*"`) | Records every tool call's shape to the JSONL ledger |

## Compatibility

- **Claude Code:** 2.0+ (requires the hooks system with `PreToolUse` /
  `PostToolUse` events and `${CLAUDE_PLUGIN_ROOT}` / `${CLAUDE_PROJECT_DIR}`
  substitution).
- **python3:** 3.8+ (stdlib only) for shape inference and report generation. If
  python3 is absent the hook degrades to a raw-line append and the analyzer
  reports that python3 is required.
- **No third-party packages, no MCP server.** `allowed-tools` in the skills and
  command are an explicit, wildcard-free list (`Bash`, `Read`, `Grep`, `Glob`).
- **Non-blocking:** the capture hook never denies a tool call and exits 0 on any
  error, so it is safe in any project.

## Namespace coordination

This plugin claims the namespace **`contracts-reliability`**, following the
kebab-case `<plugin-stem>-<intent>` convention and registered against
`.claude/tasks/novel-plugins-suite-adr.md`. Concrete artifacts:

| Key / path prefix | Holds |
|---|---|
| `.claude/contracts-reliability/ledger.jsonl` | the append-only tool-call shape ledger |
| `contracts-reliability:schema/<tool>` | reserved for inferred per-tool baseline schemas (memory) |
| `contracts-reliability:flaky/<tool>` | reserved for per-tool flakiness verdicts (memory) |

Any future plugin that reads or writes these keys (or this ledger) must claim a
non-overlapping prefix and reference this plugin's ADR-0001.

## Verification

```bash
bash plugins/apex-contracts-reliability/scripts/smoke.sh
```

The smoke script runs structural checks (plugin.json keys, no enumerated surface
arrays, kebab-case skill names, no wildcard tools, command frontmatter, valid
`hooks/hooks.json`, README sections, ADR status, script executability). It exits
non-zero on the first failing check and names what's wrong.

## Architecture Decisions

- [ADR-0001 — apex-contracts-reliability plugin contract](docs/adrs/0001-apex-contracts-reliability-contract.md) — Status: **Proposed**. Defines surface, the F1/F2 algorithms, namespace, compatibility, and smoke contract.

## License

MIT — see the repo-level LICENSE.
