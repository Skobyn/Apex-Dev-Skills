#!/usr/bin/env bash
# apex-dispatch subagent-stop — SubagentStop, matcher `^(apex-dispatch|apex-scope-loop):` (spec §5.1, §5.3 F/G).
# Records the stop; for reviewer roles writes <D>/reviews-raw/<agent_id>.json from the final VERDICT: line (bound to HEAD at stop) and a verdict row; audits read-only transcripts and, on a write or git mutation, refuses the record, writes policy_violation and exits 2 once (stop_hook_active is never blocked).
# No-op ({}) unless the run's ACTIVE lock exists; prints exactly one JSON
# object; fails open on unparseable stdin. Registered by scripts/compile.sh in
# hooks/hooks.json with timeout 10.
set -euo pipefail
# shellcheck source=../scripts/lib/hook-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/hook-common.bash"
apex_hook_run subagent-stop
