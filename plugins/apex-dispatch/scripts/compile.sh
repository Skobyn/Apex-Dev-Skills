#!/usr/bin/env bash
# apex-dispatch policy compiler.
#
# Usage:
#   compile.sh                          regenerate the committed artifacts
#   compile.sh --check                  regenerate in memory; exit 1 naming every
#                                       stale, missing or orphaned artifact
#   compile.sh --print-merged           print the default policy merged with this
#                                       repo's overlay (.claude/apex-dispatch/policy.json
#                                       under `git rev-parse --show-toplevel`, or
#                                       $APEX_DISPATCH_POLICY)
#   compile.sh --write                  same as no flag (explicit)
#   ... [--overlay PATH]                use PATH as the overlay; it is validated
#                                       only. `--overlay PATH` alone runs as
#                                       --check (no rewrite); add --write to
#                                       also regenerate the artifacts
#
# Artifacts are always generated from resources/dispatch.default.json alone;
# overlays are applied at runtime by the readers.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "compile: python3 is required" >&2; exit 1; }
exec python3 -B "$PLUGIN_ROOT/scripts/lib/compile.py" "$PLUGIN_ROOT" "$@"
