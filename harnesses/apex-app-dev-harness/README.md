# apex-app-harness

> An agent harness for Claude Code: plan, implement, review, and test code changes.

[![npm](https://img.shields.io/npm/v/apex-app-harness.svg)](https://www.npmjs.com/package/apex-app-harness)

Built on [@metaharness/kernel](https://www.npmjs.com/package/@metaharness/kernel) — a Rust → WASM + NAPI-RS kernel with a pure-JS floor, so it runs on every platform.

## Install

```bash
npx apex-app-harness init     # scaffold .harness/, .claude/ and CLAUDE.md into your project
npx apex-app-harness doctor   # confirm the install
```

`init` never overwrites a file you already have — pass `--force` if you want it to.

Then restart Claude Code. `init` writes a `.claude/settings.json` that registers the MCP server, so the `mcp__apex-app-harness__*` tools appear on the next launch.

## Commands

| Command | What it does |
|---|---|
| `apex-app-harness init` | Scaffold the harness into the current project |
| `apex-app-harness doctor` | Health check — kernel backend, project files, MCP surface, policy |
| `apex-app-harness mcp start` | Run the MCP server on stdio (what Claude Code launches) |
| `apex-app-harness memory search <query>` | Search stored patterns |
| `apex-app-harness memory store <text>` | Append a pattern to the store |
| `apex-app-harness route <task>` | Recommend a routing tier |

## MCP surface

Five tools (`ping`, `route`, `memory-search`, `memory-store`, `agents`), three resources
(`harness://manifest`, `harness://capabilities`, `harness://policy`), and one prompt (`kickoff`).

Every tool call passes one gate: **policy decision → approval check → timeout-bounded run → audit**.
The policy is **default-deny** — a capability it does not grant is refused, not silently allowed —
and every call is appended to `.harness/audit.log`.

The shipped policy denies network, shell, and file-write. That means `memory-store` is **denied out
of the box**; `doctor` tells you so. Grant it deliberately in `.harness/mcp-policy.json`:

```json
{ "allowFileWrite": true }
```

A project's `.harness/mcp-policy.json` always overrides the copy bundled in the package.

## Agents

| Agent | Role |
|---|---|
| `orchestrator` | Routes work and owns the goal state. |
| `architect` | Designs the change before code is written. |
| `implementer` | Writes code that matches the surrounding style. |
| `reviewer` | Hunts correctness bugs in the diff. |
| `test-writer` | Adds the missing tests for the change. |
| `evaluator` | The honest eval gate. |
| `escalator` | Pages humans on severity. |

These are prompt definitions, exported from `apex-app-harness/agents`. Your host decides how to run them.

## Routing

`route` maps a task onto three tiers, configured in `.harness/manifest.json`:

| Tier | Model | For |
|---|---|---|
| `barbarian` | `deepseek/deepseek-v4-pro` | Mechanical, well-specified edits |
| `scholar` | `anthropic/claude-sonnet-4.6` | The default middle |
| `sage` | `anthropic/claude-opus-4.8` | Work where being wrong is expensive |

It is a deterministic keyword + length heuristic, **not a learned router**. Every decision returns
the signals that produced it, so a wrong tier is a one-line fix.

## What is not implemented in 0.1.0

Stated plainly so nothing here is oversold:

- **Memory is lexical, not semantic.** A local append-only JSONL store, ranked by token overlap with
  the kernel's recency decay on top. There are no embeddings and no vector index behind it.
- **Routing is a heuristic**, as above.
- **`witness.json` is an unsigned provenance stub.** No Ed25519 signing yet.
- **The manifest's `darwin` / self-evolution block is configuration data only** — nothing consumes it.

`doctor` reprints this list every run.

## Development

```bash
npm install
npm run build
npm test          # 35 tests: policy, MCP dispatch, routing, memory, and the CLI end-to-end
```

## License

MIT
