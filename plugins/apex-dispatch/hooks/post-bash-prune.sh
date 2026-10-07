#!/usr/bin/env bash
# apex-dispatch post-bash-prune — PostToolUse, matcher `Bash` (spec §5.1; Phase 0 spike 9).
# Record-only: keeps the full output of a long test/lint run at <D>/logs/<tool_use_id>.log and writes a hook_advisory row; never changes the output the model sees (PostToolUse cannot replace Bash output). Exit 0.
# No-op ({}) unless the run's ACTIVE lock exists; prints exactly one JSON
# object; fails open on unparseable stdin. Registered by scripts/compile.sh in
# hooks/hooks.json with timeout 10.
set -euo pipefail
# shellcheck source=../scripts/lib/hook-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/hook-common.bash"
apex_hook_run post-bash
