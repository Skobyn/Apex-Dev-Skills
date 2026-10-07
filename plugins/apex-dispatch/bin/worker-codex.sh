#!/usr/bin/env bash
# apex-dispatch worker-codex.sh — run one routed worker on OpenAI `codex exec --json` with `--sandbox workspace-write` (build) or `--sandbox read-only` (review/diagnose), `-c approval_policy=never`, `--ignore-user-config`, `-C <confined dir>`, `-o <out>/result.last.md`; the policy's forbidden_flags never appear (worker.py check_flags). Tool calls inside codex are invisible to Claude Code hooks: it is confined by its own sandbox, the throwaway directory, the environment scrub and apply.sh.
#
# Usage (from the orchestrator or the provider-runner role only; pre-bash.sh refuses others):
#   worker-codex.sh --route ROUTE_ID --role builder|tester|docs|reviewer|adversarial-reviewer|diagnoser \
#     --brief FILE [--mode build|readonly] [--base SHA] [--out DIR] [--timeout-sec N]
#
# --brief (alias --task-file) is the worker's whole context. --mode defaults to build for
# builder-side roles and readonly (the only mode) for reviewers and diagnosers. --base, when
# given, must equal the plan worktree HEAD. --out must be a new directory directly inside
# <state>/dispatch/workers/ (default: one is made). --timeout-sec can only lower the route's
# minutes budget. No other argument is accepted: the provider command comes from the merged
# policy (scripts/compile.sh --print-merged), never from the caller.
# Prints WORKER_* lines and, last, DISPATCH-DONE exit=N (no sentinel = truncated = failure).
# Exit: 0 ok, 1 the run failed, 2 usage, 3 refused, 4 provider unavailable, 5 confinement failed.
set -euo pipefail
# shellcheck source=worker-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/worker-common.sh"
apex_worker_main codex "$@"
