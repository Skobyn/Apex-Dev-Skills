#!/usr/bin/env bash
# apex-dispatch worker-aider.sh — run one routed docs/tester worker on aider with a local model (ollama/<model> from the policy): a message file, no auto or dirty commits, no git, no auto lint/test, a generated config and an empty env file (the repository's .aider.conf.yml and .env are never read), the owned Paths' tracked files named after the end of options. Never the always-yes confirmation flag: prompts meet a closed stdin. aider reports no usage; it is costed by wall-clock.
#
# Usage (from the orchestrator or the provider-runner role only; pre-bash.sh refuses others):
#   worker-aider.sh --route ROUTE_ID --role ROLE --brief FILE [--mode build|readonly] [--base SHA] [--out DIR] [--timeout-sec N]
#
# FLAGGED OFF: the default policy has this provider enabled: false with status flagged-off.
# It runs only when this repository's overlay (.claude/apex-dispatch/policy.json) sets
# providers[aider-ollama].enabled: true AND lists the installed CLI version under
# providers[aider-ollama].verified_versions (a human attests the per-version smoke passed), and
# doctor.json shows that version installed with its forced flags accepted. Otherwise: exit 3.
# The command comes only from the merged policy (forced_flags + structured fields); the
# provider's forbidden_flags never appear (worker.py check_flags). The same arguments,
# out dir, result.json, ledger rows and DISPATCH-DONE sentinel as worker-codex.sh.
# Exit: 0 ok, 1 the run failed, 2 usage, 3 refused, 4 provider unavailable, 5 confinement failed.
set -euo pipefail
# shellcheck source=worker-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/worker-common.sh"
apex_worker_main aider-ollama "$@"
