#!/usr/bin/env bash
# apex-dispatch worker-claude-p.sh — run one routed worker on a separate `claude -p` session (family of record: anthropic-separate-session): `--agent apex-dispatch:<role>`, the apex-dispatch (and apex-guardrails) plugin dirs so the same hooks govern it, `--max-budget-usd`, `--permission-mode dontAsk --permission-prompts none`; the policy's forbidden_flags never appear (worker.py check_flags).
#
# Usage (from the orchestrator or the provider-runner role only; pre-bash.sh refuses others):
#   worker-claude-p.sh --route ROUTE_ID --role builder|tester|docs|reviewer|adversarial-reviewer|diagnoser \
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
apex_worker_main claude-p "$@"
