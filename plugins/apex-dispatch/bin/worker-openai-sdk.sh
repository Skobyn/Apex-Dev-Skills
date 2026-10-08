#!/usr/bin/env bash
# apex-dispatch worker-openai-sdk.sh — run one routed docs/tester/builder worker on the OpenAI Agents SDK
# through harnesses/openai_sdk_runner.py (pip install openai-agents for the python3 on PATH): an SDK agent
# whose only tools are file tools confined to the throwaway worktree and the task's owned Paths (no shell,
# no network tool, no MCP server, no handoff; tracing off), the role's generated contract as its
# instructions and the role's turn limit. Usage comes from the SDK.
#
# Usage (from the orchestrator or the provider-runner role only; pre-bash.sh refuses others):
#   worker-openai-sdk.sh --route ROUTE_ID --role ROLE --brief FILE [--mode build] [--base SHA] [--out DIR] [--timeout-sec N]
#
# FLAGGED OFF: the default policy has this provider enabled: false with status flagged-off.
# It runs only when this repository's overlay (.claude/apex-dispatch/policy.json) sets
# providers[openai-sdk].enabled: true AND lists the installed openai-agents version under
# providers[openai-sdk].verified_versions (scripts/provider-smoke.sh openai-sdk --record --enable
# does both after the per-version smoke passes), and doctor.json shows that version installed
# with OPENAI_API_KEY set. Otherwise: exit 3 (or 4).
# The command comes only from the merged policy (forced_flags + a run config in the out dir).
# The same arguments, out dir, result.json, ledger rows and DISPATCH-DONE sentinel as worker-codex.sh.
# Exit: 0 ok, 1 the run failed, 2 usage, 3 refused, 4 provider unavailable, 5 confinement failed.
set -euo pipefail
# shellcheck source=worker-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/worker-common.sh"
apex_worker_main openai-sdk "$@"
