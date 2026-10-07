#!/usr/bin/env bash
# apex-dispatch ledger.sh — the hash-chained ledger at <state>/dispatch/ledger.jsonl.
#
# Usage:
#   ledger.sh append EVENT JSON|- --state DIR --source hook|shim|cli [--route-id R] [--head SHA] [--route-mode M]
#                                                non-provenance events only; route, spawn_request, spawn,
#                                                worker_run and verdict are written in-process (lib/ledger.py)
#   ledger.sh verify --state DIR                 walk the chain; exit 1 naming the first bad row,
#                                                exit 3 "EMPTY" when there are no rows at all
#   ledger.sh evidence --state DIR --line N --head SHA [--plan-hash H]
#                                                exit 0 only when the chain verifies, a READY route row
#                                                r-<H>-L<N>-k (H = this plan) is on HEAD's history, and a
#                                                hook- or shim-written spawn_request/spawn/worker_run row
#                                                carries that route's id
#   ledger.sh export-trace --state DIR [--out F] apex-agent-observability trace lines (stdout without --out)
#   ledger.sh export --state DIR [--plan PLAN] [--out F]
#                                                per-task summary rows (default <state>/dispatch/export/summary.jsonl)
#   ledger.sh baseline capture --state DIR [--label L]
#
# EVENT and its required fields are defined in resources/ledger-events.json.
# Exit codes: 0 ok, 1 failure (invalid row, broken chain, missing evidence), 2 usage,
#             3 verify found no ledger rows (EMPTY: wrong --state, or nothing routed yet).
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "ledger: python3 is required" >&2; exit 1; }
case "${1:-}" in
  ""|-h|--help) sed -n '4,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
exec python3 -B "$PLUGIN_ROOT/scripts/lib/ledger.py" "$PLUGIN_ROOT" "$@"
