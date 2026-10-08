#!/usr/bin/env bash
# apex-dispatch apply.sh — apply a write-mode worker's patch to the plan worktree as one commit.
#
# Usage:
#   apply.sh --worker DIR [--route ROUTE_ID]      (or: apply.sh DIR)
#
# DIR is the worker's out directory (<state>/dispatch/workers/<run>, printed as WORKER_OUT by
# bin/worker-<provider>.sh). Refused during stage GATE/REVIEW, for another route, a failed run,
# a patch whose sha256 differs from result.json, a plan worktree that moved since the worker
# forked or has uncommitted changes, any path outside the route's owned Paths (the lanes' union,
# else the task's Paths:) or on the never-touch list (.dev-plan-state, .git, .claude/apex-dispatch, .claude/apex-decision-layer,
# .claude/settings*.json, .claude/hooks, hooks/hooks.json, .mcp.json, .gitmodules, .env*, keys),
# and symlinks/submodules. On success: one commit with Dispatch-Route/-Provider/-Model/-Result
# trailers, a worker_applied ledger row bound to the new HEAD, and the throwaway worktree removed.
# A refused patch is kept under <state>/dispatch/rejected/ for the diagnoser.
# Exit: 0 applied, 1 refused (patch kept), 2 usage, 3 refused before inspection (no run, stage, route).
set -euo pipefail
case "${1:-}" in ""|-h|--help) sed -n '4,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;; esac
# shellcheck source=../bin/worker-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/worker-common.sh"
apex_worker_apply "$@"
