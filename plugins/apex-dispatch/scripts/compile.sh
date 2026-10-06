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
#   ... [--overlay PATH]                use PATH as the overlay; with plain or
#                                       --check runs it is validated only
#
# Artifacts are always generated from resources/dispatch.default.json alone;
# overlays are applied at runtime by the readers.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "compile: python3 is required" >&2; exit 1; }
exec python3 -B "$PLUGIN_ROOT/scripts/lib/compile.py" "$PLUGIN_ROOT" "$@"
