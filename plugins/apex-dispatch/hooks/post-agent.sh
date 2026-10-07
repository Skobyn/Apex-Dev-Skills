#!/usr/bin/env bash
# apex-dispatch post-agent — PostToolUse + PostToolUseFailure, matcher `Agent|Task` (spec §5.1, §5.3 H; ADR-0001 "Hook contract").
# A worker_run row per tool use (resolvedModel, usage, duration, tool count); a model_mismatch row when the resolved family is not ROUTE_MODEL; the route's USD estimate (pre-agent enforces ROUTE_BUDGET_USD). Exit 0.
# No-op ({}) unless the run's ACTIVE lock exists; prints exactly one JSON
# object; fails open on unparseable stdin. Registered by scripts/compile.sh in
# hooks/hooks.json with timeout 10.
set -euo pipefail
# shellcheck source=../scripts/lib/hook-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/hook-common.bash"
apex_hook_run post-agent
