# Apex-Dev-Skills

A Claude Code plugin marketplace for Get Apex Insights development skills and plugins.

## Install the marketplace

```
/plugin marketplace add Skobyn/Apex-Dev-Skills
```

Then install a plugin:

```
/plugin install <plugin-name>@apex-dev-skills
```

Run `/reload-plugins` (or restart Claude Code) to activate.

## Plugins

| Name | Description |
|---|---|
| [apex-scope-loop](plugins/apex-scope-loop) | **Price it once, route it forever.** The **SCOPE** workflow — Scope → Compose → Optimize → Plan → Execute — turns a fuzzy idea into a co-authored ADR + phased plan, then drives it to done with autonomous `/loop` + `/schedule` swarms. Every phase carries a compute tier routed to a named `phase-worker` subagent, so cost is decided at planning time, not improvised mid-loop. Requires the [ruflo](https://github.com/ruvnet/ruflo) plugin suite (for memory + swarm MCP tools). |
| [apex-guardrails](plugins/apex-guardrails) | **Rules the model can't ignore.** Deterministic `PreToolUse` hooks that hard-block edits to sensitive paths, deny destructive bash, and scan tool inputs for secrets — plus a declarative YAML policy compiled straight into enforced matcher config. Enforcement, not after-the-fact scanning. |
| [apex-agent-team](plugins/apex-agent-team) | **Lint your swarm before you run it.** TeamLint statically audits subagent/agent-team config for dead agents, overlapping roles, missing tool grants, and unbounded fan-out; ContextBudget hooks warn before compaction silently drops critical state. |
| [apex-legacy-comprehension](plugins/apex-legacy-comprehension) | **Make unfamiliar code safe to change.** Pin current behavior with characterization tests *before* refactoring (built for vibe-coded "new legacy"), and map an unknown codebase in an isolated subagent context that never pollutes your main thread. |
| [apex-contracts-reliability](plugins/apex-contracts-reliability) | **Catch drift and flakiness at runtime.** A `PostToolUse` ledger infers per-tool schemas and flags contract drift, while FlakeGuard surfaces non-deterministic agent failures — retries, partial failures, flaky tools — the marketplace barely covers. |
| [apex-agent-observability](plugins/apex-agent-observability) | **See where a multi-agent run went wrong.** Hook-driven JSONL AgentTrace, deterministic OrchestrationReplay, and per-subagent TokenLens cost attribution — pure artifacts, with an optional read-only MCP dashboard server. |
| [apex-rag-memory](plugins/apex-rag-memory) | **Diagnose retrieval quality, not just connect to it.** Audit chunking, detect embedding-model drift, find stale vectors, and regression-test recall with a golden Q/A harness. Not a vendor connector — a lifecycle doctor for RAG/memory. |

## Layout

```
.
├── .claude-plugin/
│   └── marketplace.json     # marketplace manifest
├── plugins/
│   └── <plugin-name>/
│       ├── .claude-plugin/plugin.json
│       ├── agents/ commands/ skills/ scripts/
│       └── README.md
└── README.md
```

## Adding a plugin

1. Drop the plugin directory under `plugins/<name>/` with a valid `.claude-plugin/plugin.json`.
2. Add an entry to `.claude-plugin/marketplace.json` with `"source": "./plugins/<name>"`.
3. Commit and push. Users run `/plugin marketplace update apex-dev-skills` to pick up the new entry.

## License

MIT.
