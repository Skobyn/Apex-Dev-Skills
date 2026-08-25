---
name: memory-doctor
description: Audit a project's RAG / embedding / memory subsystem for lifecycle problems and emit a prioritized findings report. Use when retrieval quality is degrading, when answers cite the wrong chunks, after changing an embedding model or chunker, when a vector store has grown stale or "haunted" by orphaned vectors, or when the user asks to "diagnose RAG", "check memory health", "why is retrieval bad", "audit embeddings", or "find embedding drift". Treats memory as a lifecycle-managed subsystem (index build → query → reindex → eviction), not a one-time load. Diagnoses retrieval QUALITY — it is not a vendor vector-DB access connector.
allowed-tools: Bash Read Write Edit Glob Grep AskUserQuestion
---

# MemoryDoctor — RAG / memory lifecycle diagnosis

Most "my RAG is bad" problems are not model problems — they are **lifecycle** problems. A vector store is a living subsystem with a build phase, a query phase, and a maintenance phase, and the failures cluster at the seams between them (per the memory-as-lifecycle framing in arXiv:2510.25423). MemoryDoctor audits those seams and hands you a prioritized findings report, not a dashboard.

This skill **diagnoses retrieval quality**. It is deliberately *not* a vendor connector (pinecone/qdrant/zilliz access wrappers are saturated and only give you a pipe to the store). MemoryDoctor tells you whether the store is *healthy* and *why retrieval is failing*.

## When to use this skill

Trigger when **any** of these is true:

- Retrieval results are wrong, stale, or irrelevant despite "the data is in there"
- Someone changed the embedding model / dimension / chunker and quality moved
- The vector store keeps growing but recall is dropping
- You inherited a RAG pipeline and need a health baseline before touching it
- The user says "diagnose RAG", "audit my memory", "find embedding drift", "why is retrieval bad"

Do NOT use this skill to *connect* to a vector DB or run production queries — that's the optional MCP server's job (see README "MCP (optional)"). MemoryDoctor reasons about the pipeline's *configuration and artifacts*.

## The five lifecycle failure classes

MemoryDoctor scans for these, highest-impact first:

| # | Failure class | What it looks like | How MemoryDoctor detects it |
|---|---|---|---|
| 1 | **Embedding-model / version DRIFT** | Vectors were built with model A (or dim A), queried with model B (or dim B). Cosine scores look plausible but are meaningless. | Compares the embedder declared at build time vs. query time across config/code/manifests; flags dimension mismatches and unpinned model names. |
| 2 | **Chunking strategy issues** | Chunks too large (recall dilution), too small (context fragmentation), no overlap (boundary loss), or split mid-structure (code/tables broken). | Inspects chunker config + sampled chunk sizes; flags fixed-size-no-overlap, oversized, and structure-blind splitting. |
| 3 | **Stale / orphaned vectors** | Source docs deleted or edited but vectors never re-indexed; vectors with no live source. | Diffs the source corpus (mtime / hash) against the index manifest; flags vectors whose source is gone or newer than the vector. |
| 4 | **Low retrieval recall** | The right chunk exists but never makes the top-k. | Defers to the EvalHarness golden set if present; otherwise flags the *absence* of any recall measurement as the top finding. |
| 5 | **Missing lifecycle controls** | No reindex trigger, no eviction/TTL, no embedder version pinned, no eval gate in CI. | Checks for reindex scripts, version pins, and an eval harness; each missing control is a finding. |

## How to run the audit

1. **Locate the RAG surface.** Use Glob/Grep to find the pieces:
   - Embedder config: search for `text-embedding`, `all-MiniLM`, `bge-`, `model=`, `dimension`, `dim=`, `EMBED_MODEL`.
   - Chunker config: search for `chunk_size`, `chunk_overlap`, `splitter`, `RecursiveCharacter`, `TokenTextSplitter`.
   - Index/store: search for `.faiss`, `.index`, `chroma`, `lancedb`, `pgvector`, `embeddings.json`, `*.jsonl` vector dumps, manifest files.
   - Corpus: the docs/source directory the vectors were built from.

2. **Run the scanner.** It does the mechanical detection and prints a machine-readable findings block:
   ```bash
   bash skills/memory-doctor/scripts/audit.sh <project-root> [corpus-dir] [index-manifest]
   ```
   The script never needs network or a live store — it reads config, code, and on-disk artifacts. If it can't find a piece, it reports that as a finding (an unfindable embedder pin is itself a drift risk).

3. **Interview the gaps.** Where the scanner can't infer intent (e.g. "is this 768-dim index built with the same model the query path uses?"), use **AskUserQuestion** to confirm: build-time model, query-time model, last reindex date, whether deletes propagate.

4. **Write the report.** Synthesize into a prioritized findings report at `docs/<project>/memory-doctor-report.md` using `resources/templates/findings-report.md`. Each finding gets: severity (blocker / high / medium / low), the lifecycle class, evidence (file:line or artifact), and a concrete remediation.

## Severity rubric

- **Blocker** — drift confirmed (build dim ≠ query dim, or model A ≠ model B). Retrieval is *meaningless*, not just degraded. Fix before anything else.
- **High** — orphaned/stale vectors over a threshold, or no recall measurement exists at all.
- **Medium** — chunking smell (no overlap, oversized chunks), no reindex trigger.
- **Low** — missing eviction policy, unpinned-but-matching model, no CI eval gate.

## Graceful degradation (no MCP, no live store)

MemoryDoctor's core value needs **zero external services**. With only the repo it can detect drift, chunking smells, staleness against the source corpus, and missing lifecycle controls — that's findings classes 1, 2, 3 (source-side), and 5. The optional MCP server only adds *live* checks: actual index dimension, vector counts, and sampling real neighbors. When the MCP server is absent, the report says so explicitly and marks those findings as "needs live store to confirm" rather than failing. Never block on the MCP server.

## Hand-off to EvalHarness

Finding class 4 (low recall) can only be *quantified* by the sibling `eval-harness` skill. When MemoryDoctor flags recall risk, recommend building a golden set:

```bash
bash scripts/build-golden.sh <corpus-dir> docs/<project>/retrieval-golden.jsonl
```

Then a before/after `measure-recall.sh` run turns "recall might be low" into a number you can regression-test.

## Anti-patterns

1. **Treating it as a connector.** If the ask is "query my Pinecone index", that's the MCP server, not this skill.
2. **Reporting symptoms without the lifecycle class.** Every finding must name which of the five classes it is — that's what makes it actionable.
3. **Skipping the drift check because "the code looks fine".** Dimension/model drift is the #1 silent killer and is invisible in cosine scores. Always confirm build-time vs query-time embedder.
4. **Blocking on a live store.** The audit must produce value from the repo alone.
