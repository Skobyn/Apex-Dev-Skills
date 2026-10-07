#!/usr/bin/env bash
# apex-dispatch worker-grok.sh — run one routed worker on xAI Grok Build in print mode with a prompt file, --sandbox strict, no subagents, stream-json output and --deny rules for git push and curl, plus a run-only .claude/settings.json (dontAsk, a strict sandbox profile) written into the confined directory and restored before the diff. Grok hooks fail open by design: it is confined by its sandbox, the throwaway directory, the environment scrub and apply.sh. doctor.sh rejects the colliding @vibe-kit/grok-cli binary.
#
# Usage (from the orchestrator or the provider-runner role only; pre-bash.sh refuses others):
#   worker-grok.sh --route ROUTE_ID --role ROLE --brief FILE [--mode build|readonly] [--base SHA] [--out DIR] [--timeout-sec N]
#
# FLAGGED OFF: the default policy has this provider enabled: false with status flagged-off.
# It runs only when this repository's overlay (.claude/apex-dispatch/policy.json) sets
# providers[grok].enabled: true AND lists the installed CLI version under
# providers[grok].verified_versions (a human attests the per-version smoke passed), and
# doctor.json shows that version installed with its forced flags accepted. Otherwise: exit 3.
# The command comes only from the merged policy (forced_flags + structured fields); the
# provider's forbidden_flags never appear (worker.py check_flags). The same arguments,
# out dir, result.json, ledger rows and DISPATCH-DONE sentinel as worker-codex.sh.
# Exit: 0 ok, 1 the run failed, 2 usage, 3 refused, 4 provider unavailable, 5 confinement failed.
set -euo pipefail
# shellcheck source=worker-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/worker-common.sh"
apex_worker_main grok "$@"
