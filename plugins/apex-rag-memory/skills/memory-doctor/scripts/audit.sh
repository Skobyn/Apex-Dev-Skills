#!/usr/bin/env bash
# MemoryDoctor scanner — detects RAG/memory lifecycle smells from on-disk artifacts.
# No network, no live vector store required. Prints a findings block (text + JSON).
#
# Usage: audit.sh <project-root> [corpus-dir] [index-manifest]
set -euo pipefail

ROOT="${1:-.}"
CORPUS="${2:-}"
MANIFEST="${3:-}"

[ -d "$ROOT" ] || { echo "audit FAIL: project root not a directory: $ROOT" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd)"

# Findings accumulate as "SEVERITY|CLASS|EVIDENCE|REMEDIATION" lines.
FINDINGS=""
add() { FINDINGS="${FINDINGS}${1}|${2}|${3}|${4}"$'\n'; }

# grep helper that never trips set -e
g() { grep -rInE "$1" "$ROOT" --include='*.py' --include='*.ts' --include='*.js' \
  --include='*.json' --include='*.yaml' --include='*.yml' --include='*.toml' \
  --include='*.env' --include='*.cfg' 2>/dev/null || true; }

echo "MemoryDoctor scanning: $ROOT"

# --- Class 1: embedding-model / version DRIFT ----------------------------------
EMBED_HITS="$(g 'text-embedding|all-MiniLM|bge-[a-z]|e5-[a-z]|gte-[a-z]|EMBED_MODEL|embedding_model|embed_model')"
DIM_HITS="$(g 'dimension|n_dim|embedding_dim|vector_size|\bdim[[:space:]]*[=:]')"

# Collect distinct embedder model tokens
MODELS="$(printf '%s\n' "$EMBED_HITS" | grep -oE '(text-embedding[-a-z0-9]*|all-MiniLM-[A-Za-z0-9-]*|bge-[a-z0-9-]*|e5-[a-z0-9-]*|gte-[a-z0-9-]*)' | sort -u || true)"
NMODELS="$(printf '%s\n' "$MODELS" | grep -c . || true)"

# Collect distinct dimension numbers
DIMS="$(printf '%s\n' "$DIM_HITS" | grep -oE '(384|512|768|1024|1536|3072)' | sort -u || true)"
NDIMS="$(printf '%s\n' "$DIMS" | grep -c . || true)"

if [ "${NMODELS:-0}" -gt 1 ]; then
  ev="$(printf '%s' "$MODELS" | tr '\n' ',' | sed 's/,$//')"
  add "blocker" "drift" "multiple embedder models referenced: ${ev}" \
    "Confirm build-time and query-time embedders are identical; pin ONE model id and dimension."
elif [ "${NMODELS:-0}" -eq 0 ]; then
  add "low" "drift" "no embedding model id found in config/code" \
    "Pin the embedding model id explicitly so build-vs-query drift is detectable."
fi

if [ "${NDIMS:-0}" -gt 1 ]; then
  ev="$(printf '%s' "$DIMS" | tr '\n' ',' | sed 's/,$//')"
  add "blocker" "drift" "multiple embedding dimensions referenced: ${ev}" \
    "Index dimension must equal query embedder dimension. Reconcile to one value or reindex."
fi

# Unpinned model (model name from an env var with no default) is a soft drift risk
if printf '%s\n' "$EMBED_HITS" | grep -qE 'getenv|os\.environ|process\.env' ; then
  add "low" "drift" "embedding model sourced from env var (may differ build vs query)" \
    "Record the resolved model id in the index manifest at build time and assert it at query time."
fi

# --- Class 2: chunking strategy ------------------------------------------------
CHUNK_HITS="$(g 'chunk_size|chunk_overlap|CharacterTextSplitter|RecursiveCharacter|TokenTextSplitter|splitter')"
if [ -n "$CHUNK_HITS" ]; then
  OVERLAP="$(printf '%s\n' "$CHUNK_HITS" | grep -oiE 'chunk_overlap[[:space:]]*[=:][[:space:]]*[0-9]+' | grep -oE '[0-9]+' | sort -un | tail -1 || true)"
  SIZE="$(printf '%s\n' "$CHUNK_HITS" | grep -oiE 'chunk_size[[:space:]]*[=:][[:space:]]*[0-9]+' | grep -oE '[0-9]+' | sort -un | tail -1 || true)"
  if [ -n "$SIZE" ] && [ "${OVERLAP:-0}" = "0" ]; then
    add "medium" "chunking" "chunk_size=${SIZE} with zero overlap" \
      "Add 10-20% overlap so facts spanning a chunk boundary are not lost."
  fi
  if [ -n "$SIZE" ] && [ "$SIZE" -gt 2000 ]; then
    add "medium" "chunking" "chunk_size=${SIZE} is large (recall dilution)" \
      "Large chunks dilute the relevant signal in the embedding. Consider 500-1000 tokens."
  fi
  if [ -n "$SIZE" ] && [ "$SIZE" -lt 100 ]; then
    add "medium" "chunking" "chunk_size=${SIZE} is very small (context fragmentation)" \
      "Tiny chunks lose surrounding context. Consider larger chunks with overlap."
  fi
else
  add "low" "chunking" "no chunker configuration found" \
    "If you embed whole documents, confirm that's intended; otherwise declare a chunking strategy."
fi

# --- Class 3: stale / orphaned vectors (source-side, no live store) ------------
# Find candidate index/manifest artifacts
INDEX_ART="$(find "$ROOT" \( -name '*.faiss' -o -name '*.index' -o -name 'embeddings*.json' -o -name 'embeddings*.jsonl' -o -name '*vectors*.jsonl' \) 2>/dev/null | head -20 || true)"
if [ -z "$MANIFEST" ]; then
  MANIFEST="$(printf '%s\n' "$INDEX_ART" | grep -E 'manifest|embeddings.*\.jsonl|vectors.*\.jsonl' | head -1 || true)"
fi

# Portable mtime: try BSD `stat -f %m`, fall back to GNU `stat -c %Y`.
mtime() { stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null || echo 0; }

if [ -n "$INDEX_ART" ] && [ -n "$CORPUS" ] && [ -d "$CORPUS" ]; then
  # Newest source file vs newest index artifact: if source newer => stale index.
  NEWEST_SRC="$(find "$CORPUS" -type f 2>/dev/null | while read -r f; do [ -n "$f" ] && mtime "$f"; done | sort -n | tail -1 || true)"
  NEWEST_IDX="$(printf '%s\n' "$INDEX_ART" | while read -r f; do [ -n "$f" ] && mtime "$f"; done | sort -n | tail -1 || true)"
  if [ -n "$NEWEST_SRC" ] && [ -n "$NEWEST_IDX" ]; then
    NS="${NEWEST_SRC%.*}"
    if [ "${NS:-0}" -gt "${NEWEST_IDX:-0}" ]; then
      add "high" "staleness" "corpus has files newer than the vector index" \
        "Reindex: source documents changed after the index was built."
    fi
  fi
elif [ -n "$INDEX_ART" ]; then
  add "low" "staleness" "index artifact present but no corpus dir given to compare against" \
    "Re-run with the corpus dir as arg 2 to detect stale/orphaned vectors."
fi

# --- Class 4: low retrieval recall (defer to EvalHarness) ----------------------
GOLDEN="$(find "$ROOT" -name 'retrieval-golden.jsonl' 2>/dev/null | head -1 || true)"
if [ -z "$GOLDEN" ]; then
  add "high" "recall" "no retrieval golden set found (recall is unmeasured)" \
    "Build one: scripts/build-golden.sh <corpus> docs/<project>/retrieval-golden.jsonl, then measure-recall.sh."
fi

# --- Class 5: missing lifecycle controls ---------------------------------------
REINDEX="$(g 'reindex|rebuild_index|refresh_index|upsert')"
[ -z "$REINDEX" ] && add "medium" "missing-control" "no reindex/upsert trigger found" \
  "Add a reindex path so edited/deleted source docs propagate to the store."
EVICT="$(g 'ttl|eviction|expire|prune|delete.*vector')"
[ -z "$EVICT" ] && add "low" "missing-control" "no eviction/TTL/prune policy found" \
  "Define an eviction or TTL policy so the store does not accumulate orphaned vectors."

# --- Live-store note (MCP optional) --------------------------------------------
add "low" "missing-control" "live-store checks (real dim, vector counts, sampled neighbors) not run" \
  "Configure the optional MCP server (.mcp.json -> rag_search/rag_stats) to confirm live findings."

# --- Emit ----------------------------------------------------------------------
echo ""
echo "=== FINDINGS ==="
printf '%s' "$FINDINGS" | while IFS='|' read -r sev cls ev rem; do
  [ -z "$sev" ] && continue
  printf '[%-7s] (%s) %s\n            -> %s\n' "$sev" "$cls" "$ev" "$rem"
done

# Machine-readable JSON (stdlib-free, hand-rolled but valid)
echo ""
echo "=== FINDINGS_JSON ==="
printf '['
first=1
printf '%s' "$FINDINGS" | while IFS='|' read -r sev cls ev rem; do
  [ -z "$sev" ] && continue
  esc_ev="$(printf '%s' "$ev" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  esc_rem="$(printf '%s' "$rem" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  if [ "$first" = "1" ]; then first=0; else printf ','; fi
  printf '{"severity":"%s","class":"%s","evidence":"%s","remediation":"%s"}' \
    "$sev" "$cls" "$esc_ev" "$esc_rem"
done
printf ']\n'

echo ""
echo "audit complete: scanned $ROOT (no live store required)"
