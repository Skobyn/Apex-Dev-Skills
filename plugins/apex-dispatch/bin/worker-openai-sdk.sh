#!/usr/bin/env bash
# apex-dispatch worker-openai-sdk.sh — named stub seam for an OpenAI Agents SDK runner (spec §5.4).
# NOT IMPLEMENTED: it refuses every call with exit 6 and runs nothing (no network code, no SDK).
#
# The contract a future runner must keep (identical to bin/worker-codex.sh):
#   worker-openai-sdk.sh --route ROUTE_ID --role builder|tester|docs --brief FILE \
#     [--mode build] [--base SHA] [--out DIR] [--timeout-sec N]
# - refuse before starting (exit 3) when the route, role, class, stage, budget or the
#   policy says no; exit 4 when doctor.json shows the runner or its auth unavailable;
# - fork a throwaway `git worktree` off the plan worktree HEAD under
#   <state>/dispatch/worktrees/, scrub the environment to an allowlist (PATH, HOME,
#   OPENAI_API_KEY, proxy vars), wrap the run in `timeout`;
# - delegate to a runner under harnesses/ (the SDK's needs_approval, tool guardrails and
#   SandboxAgent are the governance), never a gateway pretending to be Claude;
# - write patch.diff and result.json {provider, model, role, exit, usage|null,
#   usage_source, files_changed[], patch_sha256, wall_ms, sentinel_seen, verdict|null},
#   append a worker_run ledger row with source shim, print DISPATCH-DONE exit=N last.
# The policy entry (providers[openai-sdk]: kind stub, status stub, enabled false) cannot be
# turned into a runner by an overlay: worker.py refuses kind stub with exit 6 as well.
# Exit: 6 not implemented (always).
set -euo pipefail
echo "DISPATCH-REFUSED: not-implemented: provider openai-sdk is a stub seam (spec §5.4); no runner exists, nothing ran" >&2
exit 6
