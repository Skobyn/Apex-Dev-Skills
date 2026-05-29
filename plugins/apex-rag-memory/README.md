# apex-rag-memory

> Diagnose RAG/embedding/memory lifecycle health: audit chunking, detect embedding-model drift, find stale vectors, and regression-test retrieval recall with a golden Q/A harness. Not a vendor connector — it diagnoses retrieval quality.

> **Your vectors aren't a database. They're a living subsystem — and it's probably sick.**
> Diagnose RAG / embedding / memory lifecycle health, then regression-test retrieval with a golden Q/A harness.

Most RAG advice stops at "pick a vector DB and embed your docs." But the failures show up *later*, at the lifecycle seams: an embedder swapped under the query path, chunks that fragment context, vectors that outlived their source, recall quietly drifting with nobody measuring it. The market is saturated with vendor **connectors** (pinecone/qdrant/zilliz) that give you a pipe to the store — and almost nothing that tells you whether retrieval is actually *healthy*. **apex-rag-memory diagnoses retrieval quality.** It is not an access connector.

## What it does

Two complementary sub-features, both pure stdlib/bash:

- **MemoryDoctor** (`memory-doctor` skill + `audit.sh`) — audits a project's RAG/memory setup and emits a *prioritized findings report* across five lifecycle failure classes: embedding-model/version **drift** (vectors built with model A, queried with model B), **chunking** smells (no overlap, oversized/tiny chunks), **stale/orphaned** vectors (source changed, index didn't), **low recall** (the right chunk never makes top-k), and **missing lifecycle controls** (no reindex, no eviction, no eval gate). It treats memory as a lifecycle-managed subsystem (per arXiv:2510.25423), not a one-time load.
- **EvalHarness** (`eval-harness` skill + `build-golden.sh` / `measure-recall.sh`) — builds a golden Q/A set from the repo (committed as `docs/<project>/retrieval-golden.jsonl`) and measures **recall@k / precision@k / MRR**, so an embedding or chunking change can be regression-tested instead of eyeballed.

| Surface | Name | Trigger |
|---|---|---|
| Skill | `memory-doctor` | "diagnose RAG", "audit memory", "find embedding drift", "why is retrieval bad" |
| Skill | `eval-harness` | "measure recall", "build a golden set", "regression-test embeddings", "compare embedders" |
| Command | `/apex-rag-memory:memory-audit [root]` | Run the lifecycle audit + write the findings report |
| Script | `scripts/build-golden.sh` | Seed a committed golden Q/A set from a corpus |
| Script | `scripts/measure-recall.sh` | Score retrieval results against the golden set |

## MCP (optional)

This plugin ships an **optional** MCP server at `mcp/server.py` (declared in `.mcp.json`), launched with `python3` and **no third-party dependencies**. It is the *only* component that reaches a live vector store, exposing two tools:

- `rag_stats` — report the live index's dimension, vector count, and build-time embedder id (confirms drift that MemoryDoctor flagged from config alone).
- `rag_search` — query the live store and return ranked doc ids, shaped for `measure-recall.sh`.

The server binds to a store via the `RAG_STORE_CMD` env var (a thin line-protocol shim you point at your own retriever); with no command set it degrades gracefully, returning an explicit "no live store configured" result instead of crashing.

**The skills do NOT require this server.** MemoryDoctor detects drift, chunking smells, source-side staleness, and missing controls from the repo alone; EvalHarness builds/commits golden sets and scores any results JSONL with pure stdlib. The MCP server only adds *live* confirmation and a convenient results source. When it's absent, reports mark live findings as "needs live store to confirm" — work never blocks on it. Install per-plugin MCP servers are auto-loaded by Claude Code from `.mcp.json`; remove that file if you never want the server offered.

## Install

```bash
/plugin marketplace add Skobyn/Apex-Dev-Skills
/plugin install apex-rag-memory@apex-dev-skills

# …or test locally against this repo
claude --plugin-dir ./plugins/apex-rag-memory
```

Then `/reload-plugins` (or restart Claude Code) to activate.

## Quick start

```bash
# 1. Audit a project's RAG/memory lifecycle
/apex-rag-memory:memory-audit .
#   → docs/<project>/memory-doctor-report.md  (prioritized findings)

# 2. Build + commit a golden retrieval set, then measure recall
bash plugins/apex-rag-memory/scripts/build-golden.sh ./docs docs/myproj/retrieval-golden.jsonl
bash plugins/apex-rag-memory/scripts/measure-recall.sh docs/myproj/retrieval-golden.jsonl results.jsonl 5
```

## Compatibility

- **Claude Code:** 2.0+ (skills, slash commands, optional `.mcp.json` server discovery).
- **python3:** 3.8+ — used by the optional MCP server and by the JSON math in `build-golden.sh` / `measure-recall.sh`. Stdlib only; no third-party packages.
- **bash:** 3.2+ (macOS/BSD and Linux); scripts use portable `stat`/`find` fallbacks.
- **Vector store:** any — the plugin is store-agnostic. A live store is reached only through the optional MCP server's `RAG_STORE_CMD` shim and is never required.

## Namespace coordination

This plugin claims the AgentDB / memory namespace **`rag-memory`**, following the kebab-case `<plugin-stem>-<intent>` convention. Sub-keys:

| Key prefix | Holds |
|---|---|
| `rag-memory:audits/<project>` | MemoryDoctor findings + severity rollup |
| `rag-memory:golden/<project>` | Golden-set metadata (question count, source corpus) |
| `rag-memory:eval/<project>/<date>` | recall@k / precision@k / MRR per run, for trend diffs |

Any future plugin reading/writing these keys must claim a non-overlapping prefix and reference this plugin's ADR-0001. The suite-level namespace registry is `.claude/tasks/novel-plugins-suite-adr.md`.

## Verification

```bash
bash plugins/apex-rag-memory/scripts/smoke.sh
```

The smoke script runs an **extended 12-check** structural contract: the 10 core checks (plugin.json keys; no enumerated surface arrays; each SKILL.md kebab-case name; no wildcard `allowed-tools`; command frontmatter; README sections incl. "MCP (optional)"; ADR `Status: Proposed`; all `.sh` executable; `hooks.json` valid only if a `hooks/` dir exists) plus check 11 (`.mcp.json` is valid JSON and its referenced server script exists) and check 12 (no SKILL.md lists `mcp__*` tools — MCP is environmental/optional). It exits non-zero on the first failing check and names what's wrong.

## Architecture Decisions

- [ADR-0001 — apex-rag-memory plugin contract](docs/adrs/0001-apex-rag-memory-contract.md) — Status: **Proposed**. Defines surface, the optional-MCP boundary, namespace, compatibility, and the extended 12-check smoke contract.

## License

MIT — see the repo-level LICENSE.
