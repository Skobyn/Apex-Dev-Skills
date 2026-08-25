# ADR-0001: apex-rag-memory plugin contract

- **Status:** Proposed
- **Date:** 2026-05-29
- **Author:** solutions@getapexinsights.com
- **Plugin:** apex-rag-memory v0.1.0

## Context

RAG/embedding/memory is a confirmed high-pain, low-supply gap: a large majority of practitioner RAG questions go unanswered, and the tooling that *does* exist clusters at one end — vendor vector-DB **connectors** (pinecone, qdrant, zilliz) that give you an access pipe to a store. Those are saturated. What is missing is anything that diagnoses whether retrieval is *healthy*.

The deeper problem is framing. Teams treat a vector store as a database you load once. It is actually a **lifecycle-managed subsystem** (index build → query → reindex → eviction), and the failures live at the seams: an embedder swapped under the query path (drift), chunking that fragments or dilutes context, vectors that outlived their source, and recall that nobody measures. The memory-as-lifecycle framing (arXiv:2510.25423) is the design lens.

This plugin therefore **diagnoses retrieval quality and lifecycle health** — it is explicitly NOT a vendor vector-DB connector. The single point where it can touch a live store is an *optional* MCP server; all core value is delivered from the repo alone.

## Decision

Ship one plugin, `apex-rag-memory`, bundling two complementary sub-features behind this contract.

### Layout

```
plugins/apex-rag-memory/
├── .claude-plugin/plugin.json          # name, version, description, author, license, keywords
├── .mcp.json                           # OPTIONAL python3 stdlib MCP server (one server)
├── mcp/server.py                       # stdlib-only JSON-RPC server (rag_stats, rag_search)
├── skills/
│   ├── memory-doctor/SKILL.md          # C1 — lifecycle audit + findings report
│   │   ├── scripts/audit.sh
│   │   └── resources/templates/findings-report.md
│   └── eval-harness/SKILL.md           # C2 — golden-set retrieval eval
│       └── resources/examples/{sample-golden,sample-results}.jsonl
├── commands/memory-audit.md            # /apex-rag-memory:memory-audit [root]
├── scripts/
│   ├── build-golden.sh                 # seed a committed golden Q/A set
│   ├── measure-recall.sh               # recall@k / precision@k / MRR
│   └── smoke.sh                         # extended 12-check structural contract
├── docs/adrs/0001-apex-rag-memory-contract.md
└── README.md
```

### Surface

- **2 skills** — `memory-doctor`, `eval-harness` — auto-discovered from `skills/`, NOT enumerated in plugin.json.
- **1 slash command** — `/apex-rag-memory:memory-audit`.
- **1 optional MCP server** — declared in `.mcp.json`, `command: python3`, args → `mcp/server.py`. Stdlib only.

### The optional-MCP boundary (load-bearing)

The MCP server is the ONLY component that reaches a live vector store. The skills MUST degrade gracefully without it:

- MemoryDoctor detects drift, chunking smells, source-side staleness, and missing controls from config/code/on-disk artifacts alone. Live-only findings (real index dimension, vector counts, sampled neighbors) are marked "needs live store to confirm" — never block.
- EvalHarness builds/commits golden sets and computes recall/precision/MRR with pure stdlib against any supplied results JSONL. The MCP server's `rag_search` is merely a convenient source of those results.
- `allowed-tools` in SKILL.md files therefore list NO `mcp__*` tools — MCP availability is environmental. The smoke test asserts this (check 12).

### Embedding-model / version drift is the headline diagnosis

Drift (vectors built with model/dimension A, queried with B) produces plausible-looking cosine scores while retrieval is meaningless. It is invisible in normal monitoring. MemoryDoctor treats it as the top severity class and confirms build-time vs query-time embedder before anything else.

### Compatibility

- Claude Code 2.0+ (skills, commands, `.mcp.json` discovery).
- python3 3.8+ (MCP server + JSON math), stdlib only, no third-party deps.
- bash 3.2+ with portable `stat`/`find` fallbacks (macOS/BSD + Linux).
- Store-agnostic; a live store is reached only via the optional MCP `RAG_STORE_CMD` shim.

### Namespace coordination

The plugin reserves the AgentDB / memory namespace **`rag-memory`** (kebab-case `<plugin-stem>-<intent>`). Sub-keys:

- `rag-memory:audits/<project>` — MemoryDoctor findings + severity rollup
- `rag-memory:golden/<project>` — golden-set metadata
- `rag-memory:eval/<project>/<date>` — per-run recall@k / precision@k / MRR for trend diffs

Registered against the suite-level registry at `.claude/tasks/novel-plugins-suite-adr.md`. Any future plugin reading/writing these keys must claim a non-overlapping prefix and reference this ADR.

### Smoke contract (extended — 12 checks)

`scripts/smoke.sh` (set -euo pipefail) verifies:

1. `plugin.json` exists with `name`, `version`, `description`, `author`, `license`, `keywords`.
2. `plugin.json` does NOT enumerate `skills`/`commands`/`agents` arrays.
3. Each `skills/<skill>/SKILL.md` has unquoted kebab-case `name:` matching its directory.
4. No SKILL.md `allowed-tools` uses a wildcard (`*` or `mcp__*`).
5. Each `commands/<cmd>.md` has `name:` + `description:` frontmatter.
6. `README.md` has `## Compatibility`, `## Namespace coordination`, `## Verification`, `## Architecture Decisions`, AND `## MCP (optional)`.
7. ADR-0001 exists with `- **Status:** Proposed`.
8. All `*.sh` under the plugin are executable.
9. If (and only if) a `hooks/` dir exists, its `hooks.json` is valid JSON.
10. The eval/audit scripts (`build-golden.sh`, `measure-recall.sh`, `audit.sh`) exist.
11. `.mcp.json` is valid JSON and its referenced server script exists on disk.
12. No SKILL.md `allowed-tools` lists any `mcp__*` tool (MCP is environmental/optional).

Exits non-zero on the first failure with a named reason; prints `smoke passed: 12/12 checks` on success.

## Consequences

### Positive

- Fills a confirmed gap: a *quality/lifecycle diagnostic*, not yet another access connector.
- Core value works offline from the repo — no store, no network, no API keys.
- The golden set is a committed fixture, so RAG changes become a measurable regression diff.
- Drift detection catches the #1 silent RAG killer that cosine scores hide.

### Negative

- Source-side staleness detection compares corpus mtime vs index mtime; it can't see orphaned vectors whose source row was deleted inside an opaque store without the optional MCP `rag_stats`. Documented; live confirmation is opt-in.
- The MCP `RAG_STORE_CMD` shim requires the user to provide a small adapter for their specific store. Kept thin on purpose; the alternative (bundling vendor SDKs) would make it the connector this plugin refuses to be.

### Neutral

- `build-golden.sh` emits DRAFT questions seeded from source files; a human/agent must sharpen them. This is intentional — auto-generated questions without review measure nothing real.

## Status changes

- 2026-05-29 — Proposed (initial scaffold).
