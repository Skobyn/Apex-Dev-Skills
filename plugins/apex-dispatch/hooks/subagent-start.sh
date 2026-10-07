#!/usr/bin/env bash
# apex-dispatch subagent-start — SubagentStart, matcher `^(apex-dispatch|apex-scope-loop):` (spec §5.3 F).
# Registers agent_id -> role -> route_id under <D>/agents/ and writes a hook-sourced spawn row. Injects nothing (additionalContext on SubagentStart is unverified in Phase 0). Exit 0.
# No-op ({}) unless the run's ACTIVE lock exists; prints exactly one JSON
# object; fails open on unparseable stdin. Registered by scripts/compile.sh in
# hooks/hooks.json with timeout 10.
set -euo pipefail
# shellcheck source=../scripts/lib/hook-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/hook-common.bash"
apex_hook_run subagent-start
