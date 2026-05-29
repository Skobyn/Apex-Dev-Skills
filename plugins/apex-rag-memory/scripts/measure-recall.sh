#!/usr/bin/env bash
# EvalHarness: measure recall@k / precision@k / MRR of retrieval results against a golden set.
# Pure stdlib (python3). Store-agnostic: you supply the retrieval results JSONL.
#
# golden.jsonl  line: {"id":"q001","question":"...","relevant_doc_ids":["a","b"]}
# results.jsonl line: {"id":"q001","retrieved":["a","x","y"]}
#
# Usage: measure-recall.sh <golden.jsonl> <results.jsonl> [k]
set -euo pipefail

GOLDEN="${1:-}"
RESULTS="${2:-}"
K="${3:-5}"

[ -n "$GOLDEN" ] && [ -f "$GOLDEN" ] || { echo "measure-recall FAIL: golden jsonl required (arg 1)" >&2; exit 2; }
[ -n "$RESULTS" ] && [ -f "$RESULTS" ] || { echo "measure-recall FAIL: results jsonl required (arg 2)" >&2; exit 2; }
case "$K" in (*[!0-9]*|'') echo "measure-recall FAIL: k must be a positive integer" >&2; exit 2;; esac

python3 - "$GOLDEN" "$RESULTS" "$K" <<'PY'
import json, sys

golden_path, results_path, k = sys.argv[1], sys.argv[2], int(sys.argv[3])

def load(path):
    out = {}
    with open(path, encoding="utf-8") as fh:
        for ln, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError as e:
                sys.stderr.write(f"measure-recall FAIL: {path}:{ln} invalid JSON: {e}\n")
                sys.exit(3)
            out[rec["id"]] = rec
    return out

golden = load(golden_path)
results = load(results_path)

per = []
sum_recall = sum_prec = sum_rr = 0.0
misses = []
evaluated = 0

for qid, grec in golden.items():
    relevant = set(grec.get("relevant_doc_ids", []))
    if not relevant:
        continue
    evaluated += 1
    retrieved = results.get(qid, {}).get("retrieved", [])[:k]
    rset = set(retrieved)
    hit = relevant & rset
    recall = len(hit) / len(relevant)
    prec = (len(hit) / len(retrieved)) if retrieved else 0.0
    rr = 0.0
    for rank, doc in enumerate(retrieved, 1):
        if doc in relevant:
            rr = 1.0 / rank
            break
    sum_recall += recall
    sum_prec += prec
    sum_rr += rr
    if not hit:
        misses.append(qid)
    per.append((qid, round(recall, 3), round(prec, 3), round(rr, 3)))

if evaluated == 0:
    sys.stderr.write("measure-recall FAIL: no golden records with relevant_doc_ids\n")
    sys.exit(4)

agg = {
    "k": k,
    "questions_evaluated": evaluated,
    f"recall@{k}": round(sum_recall / evaluated, 4),
    f"precision@{k}": round(sum_prec / evaluated, 4),
    "mrr": round(sum_rr / evaluated, 4),
    "miss_count": len(misses),
    "misses": misses,
}

print(f"=== Retrieval eval @k={k} ({evaluated} questions) ===")
print(f"{'id':<10}{'recall':>8}{'prec':>8}{'rr':>8}")
for qid, r, p, rr in per:
    print(f"{qid:<10}{r:>8}{p:>8}{rr:>8}")
print("-" * 34)
print(f"recall@{k}    = {agg[f'recall@{k}']}")
print(f"precision@{k} = {agg[f'precision@{k}']}")
print(f"mrr          = {agg['mrr']}")
print(f"misses       = {agg['miss_count']}  {misses}")
print()
print("=== SUMMARY_JSON ===")
print(json.dumps(agg, ensure_ascii=False))
PY
