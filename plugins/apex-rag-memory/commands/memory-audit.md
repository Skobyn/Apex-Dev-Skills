---
name: memory-audit
description: Run a RAG / embedding / memory lifecycle audit on a project and emit a prioritized findings report. Pass the project root (or leave empty for the cwd) as $ARGUMENTS.
argument-hint: "[project-root]"
---

You are running a RAG / memory lifecycle audit for `$ARGUMENTS` (default: the current working directory).

Invoke the `memory-doctor` skill and follow its flow:

1. **Locate the RAG surface.** Use Glob/Grep to find the embedder config, chunker config, the vector index/store artifacts, and the source corpus the vectors were built from.

2. **Run the scanner:**
   ```bash
   bash skills/memory-doctor/scripts/audit.sh "${ARGUMENTS:-.}"
   ```
   It reads config/code/on-disk artifacts only — no network, no live store required.

3. **Interview the gaps** with AskUserQuestion where intent can't be inferred: build-time embedding model, query-time model, last reindex date, whether deletes propagate to the index.

4. **Write the report** to `docs/<project>/memory-doctor-report.md` from `skills/memory-doctor/resources/templates/findings-report.md`. Each finding: severity, lifecycle class (drift / chunking / staleness / recall / missing-control), evidence (file:line or artifact), remediation.

5. If a **recall** risk is flagged, recommend building a golden set with the `eval-harness` skill:
   ```bash
   bash scripts/build-golden.sh <corpus-dir> docs/<project>/retrieval-golden.jsonl
   ```

Note: the optional MCP server only adds *live-store* checks (real index dimension, vector counts, sampled neighbors). If it is not configured, mark those findings "needs live store to confirm" and proceed — never block on it.
