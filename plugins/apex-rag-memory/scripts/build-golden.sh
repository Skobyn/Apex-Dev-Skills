#!/usr/bin/env bash
# EvalHarness: seed a golden Q/A set from a corpus. Pure bash + stdlib (python3 for JSON).
# Emits DRAFT records; a human/agent must sharpen the questions before committing.
#
# Usage: build-golden.sh <corpus-dir> <out.jsonl> [max-questions]
set -euo pipefail

CORPUS="${1:-}"
OUT="${2:-}"
MAX="${3:-30}"

[ -n "$CORPUS" ] && [ -d "$CORPUS" ] || { echo "build-golden FAIL: corpus dir required (arg 1)" >&2; exit 2; }
[ -n "$OUT" ] || { echo "build-golden FAIL: output path required (arg 2)" >&2; exit 2; }

mkdir -p "$(dirname "$OUT")"
: > "$OUT"

# Pick representative text/code/doc files, capped at MAX.
FILES="$(find "$CORPUS" -type f \( \
  -name '*.md' -o -name '*.txt' -o -name '*.rst' -o -name '*.py' -o \
  -name '*.ts' -o -name '*.js' -o -name '*.go' -o -name '*.java' \) \
  2>/dev/null | grep -vE '/(node_modules|\.git|dist|build|vendor)/' | head -"$MAX" || true)"

[ -n "$FILES" ] || { echo "build-golden FAIL: no candidate source files under $CORPUS" >&2; exit 3; }

n=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  n=$((n+1))
  qid="$(printf 'q%03d' "$n")"
  # Derive a seed question from the first heading / def / meaningful line.
  hint="$(grep -mE -h '^#{1,3} |^(def|class|func|function|public|export) ' "$f" 2>/dev/null | head -1 | tr -s ' ' | cut -c1-100 || true)"
  [ -n "$hint" ] || hint="$(basename "$f")"
  # Emit a valid JSONL record via python3 (stdlib only) for correct escaping.
  python3 - "$qid" "$f" "$hint" >> "$OUT" <<'PY'
import json, sys
qid, path, hint = sys.argv[1], sys.argv[2], sys.argv[3]
hint = hint.strip().lstrip('#').strip()
rec = {
    "id": qid,
    "question": f"DRAFT: What does '{hint}' cover / how does it work?",
    "relevant_doc_ids": [path],
    "notes": f"seeded from {path} — SHARPEN this question before committing",
}
print(json.dumps(rec, ensure_ascii=False))
PY
done <<< "$FILES"

echo "build-golden: wrote $n DRAFT golden records to $OUT"
echo "NEXT: sharpen each 'DRAFT:' question into a real user query and add any missing relevant_doc_ids, then commit."
