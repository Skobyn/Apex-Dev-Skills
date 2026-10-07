#!/usr/bin/env bash
# apex-dispatch pre-edit.sh — PreToolUse, matcher `Edit|Write|MultiEdit|NotebookEdit` (spec §5.1, §5.3 E; ADR-0001 "Hook contract").
# Protected paths for every role, the GATE/REVIEW stage lock, read-only roles, plan-worktree and lane Paths confinement.
# No-op ({}) unless the run's ACTIVE lock exists; always prints exactly one JSON
# object and exits 0; fails open on unparseable stdin. Registered by
# scripts/compile.sh in hooks/hooks.json with timeout 10.
set -euo pipefail
# shellcheck source=../scripts/lib/hook-common.bash
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/hook-common.bash"
apex_hook_run edit
