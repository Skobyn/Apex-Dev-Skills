#!/usr/bin/env bash
# apex-dispatch stop-gate — Stop (spec §5.1, §5.3 J; Phase 0 spike 10).
# Blocks ending the turn (exit 2, reason on stderr) at most once per route while an enforced route is in BUILD and work would be lost or was done inline; never when stop_hook_active, HALT, or the route is closed. Otherwise exit 0.
# No-op ({}) unless the run's ACTIVE lock exists; prints exactly one JSON
# object; fails open on unparseable stdin. Registered by scripts/compile.sh in
# hooks/hooks.json with timeout 10.
set -euo pipefail
# shellcheck source=../scripts/lib/hook-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/hook-common.bash"
apex_hook_run stop
