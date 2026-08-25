---
name: eval-harness
description: Build a golden Q/A set from a repo or corpus and measure retrieval precision/recall so that an embedding-model, chunking, or index change can be regression-tested instead of eyeballed. Use when the user wants to "test retrieval", "measure RAG recall", "build an eval set", "regression-test embeddings", "compare two embedders/chunkers", or wants a number on whether a RAG change helped or hurt. Stores golden sets as committed repo files (docs/<project>/retrieval-golden.jsonl). Pure stdlib/bash; reaching a live vector store is the optional MCP server's job.
allowed-tools: Bash Read Write Edit Glob Grep AskUserQuestion
---

# EvalHarness — golden-set retrieval evaluation

You cannot improve what you cannot measure, and "the answers feel better now" is not a measurement. EvalHarness gives a RAG pipeline a **regression test**: a committed golden Q/A set plus precision@k / recall@k numbers, so changing the embedding model, the chunk size, or the index becomes a measurable diff instead of a vibe.

This is the quantitative half of the plugin. `memory-doctor` finds *what's wrong*; `eval-harness` proves *whether a fix worked*.

## When to use this skill

- Before/after an embedding-model swap, chunker change, or reindex — to prove it helped (or caught a regression)
- To establish a recall baseline so future RAG changes have a gate
- When MemoryDoctor flags "no recall measurement exists" (finding class 4)
- When the user asks to "measure retrieval", "build a golden set", "compare embedders", "regression-test RAG"

## The golden-set contract

A golden set is a JSONL file at `docs/<project>/retrieval-golden.jsonl`, one record per line:

```json
{"id": "q001", "question": "How does the auth middleware refresh tokens?", "relevant_doc_ids": ["src/auth/middleware.py", "docs/auth.md#refresh"], "notes": "seeded from src/auth/middleware.py"}
```

- `relevant_doc_ids` are the source chunks/docs that *should* appear in top-k. They are stable identifiers (file paths, doc anchors, chunk ids) — **not** vector ids, so the set survives a reindex or an embedder change.
- The set is **committed to the repo**. That's the whole point: it's a fixture, versioned alongside the code it tests.

## Building a golden set

```bash
bash scripts/build-golden.sh <corpus-dir> docs/<project>/retrieval-golden.jsonl [max-questions]
```

`build-golden.sh` walks the corpus, samples representative source files, and emits **seed** golden records — each with a generated candidate question and the originating file pre-filled as the relevant doc id. It is intentionally pure-bash + stdlib: it does not call an LLM or a vector store. The seeds are *drafts* — then:

1. Read the generated JSONL.
2. Use **AskUserQuestion** (or your own judgment of the corpus) to sharpen vague questions into ones a real user would ask, and to add any additional `relevant_doc_ids` a good answer would need.
3. Commit the file. Now it's a fixture.

A 20–50 question golden set is enough to catch most regressions; bigger isn't better if the questions are redundant.

## Measuring recall / precision

```bash
bash scripts/measure-recall.sh docs/<project>/retrieval-golden.jsonl <retrieval-results.jsonl> [k]
```

`measure-recall.sh` compares the golden set against a **retrieval results file** you supply — one line per question id mapping to the ranked doc ids the retriever returned:

```json
{"id": "q001", "retrieved": ["src/auth/middleware.py", "src/auth/store.py", "README.md"]}
```

It computes, per question and aggregate:

- **recall@k** — fraction of `relevant_doc_ids` that appear in the top-k retrieved
- **precision@k** — fraction of top-k retrieved that are relevant
- **MRR** — mean reciprocal rank of the first relevant hit
- **misses** — questions with zero relevant docs in top-k (the actionable list)

Output is a human table plus a machine-readable JSON summary you can diff between runs. Stash each run as `docs/<project>/retrieval-eval-<date>.json` so a before/after comparison is just two files.

## Where retrieval results come from

EvalHarness is store-agnostic by design. The `retrieved` ids can be produced by:

- **The optional MCP server** (`rag_search` tool) when a live vector store is configured — see README "MCP (optional)". This is the only path that touches a real store.
- **The project's own retriever** dumped to JSONL by a one-off script the user already has.
- **A hand-built fixture** for unit-testing the eval math itself.

The skill itself never requires the MCP server: if no live store is reachable, you still build and commit the golden set, and you measure against whatever results file is provided. The harness math is pure stdlib.

## Graceful degradation

- **No MCP / no live store:** build + commit the golden set, and run `measure-recall.sh` against any results JSONL. Full value minus the convenience of auto-generating results from a live index.
- **No results file yet:** the golden set alone is a deliverable — it's the fixture every future run measures against.

## Regression-testing a RAG change (the payoff loop)

```
1. build-golden.sh  → commit docs/<project>/retrieval-golden.jsonl   (once)
2. produce results with the OLD embedder/chunker → measure-recall.sh → save baseline.json
3. make the change (new embedder / chunk size / index)
4. produce results with the NEW setup → measure-recall.sh → save candidate.json
5. diff recall@k / precision@k: ship only if it went up (or held with a reason)
```

## Anti-patterns

1. **Golden ids that are vector ids.** Use stable source identifiers so the set survives a reindex.
2. **Treating seed questions as final.** `build-golden.sh` emits drafts; a human/agent must sharpen them or the eval measures nothing real.
3. **One-shot eval.** The value is the *regression* gate — save runs and diff them.
4. **Requiring the MCP server.** The harness math is stdlib; the server is just a convenient results source.
