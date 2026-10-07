#!/usr/bin/env bash
# apex-dispatch pre-agent.sh — PreToolUse, matcher `Agent|Task` (spec §5.1, §5.3 E; ADR-0001 "Hook contract").
# Roster, model pin (deny-on-mismatch, then updatedInput when absent), spawn and wall-clock budgets, HALT, depth-1 spawns, the GATE/REVIEW stage lock, reviewer spawns only on a gate bound to HEAD (then stage REVIEW); records spawn_request.
# No-op ({}) unless the run's ACTIVE lock exists; always prints exactly one JSON
# object and exits 0; fails open on unparseable stdin. Registered by
# scripts/compile.sh in hooks/hooks.json with timeout 10.
set -euo pipefail
# shellcheck source=../scripts/lib/hook-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/hook-common.bash"
apex_hook_run agent
