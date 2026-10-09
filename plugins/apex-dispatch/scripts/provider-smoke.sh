#!/usr/bin/env bash
# apex-dispatch provider-smoke.sh — the per-version smoke of one provider, and its attestation.
#
# Usage:
#   provider-smoke.sh PROVIDER [--record [--enable]] [--timeout-sec N] [--attempts N] [--keep]
#
# PROVIDER is a subprocess provider id: grok, opencode-ollama, aider-ollama, openai-sdk (and
# claude-p, codex). It runs the REAL provider CLI once (twice if the first try fails on content)
# with exactly the command, run-only files, scrubbed environment and parser bin/worker-<id>.sh
# would use, in a throwaway fixture repository, and checks: the version reads, the forced flags
# are accepted, the run finishes non-interactively inside the timeout, the output parses, usage
# is reported when the policy says so, and either the asked-for edit to an owned file is the
# whole patch (write roles; planted project configs and .env untouched) or the snapshot is left
# byte-identical with a parseable APPROVE (read-only roles). It spends real tokens (a few cents)
# or local-model time.
#
# On PASS, --record adds the installed version to providers[PROVIDER].verified_versions in this
# repository's overlay (.claude/apex-dispatch/policy.json, or APEX_DISPATCH_POLICY), validated
# through the same merge as compile.sh, and writes the evidence under .claude/apex-dispatch/smoke/;
# --enable also sets enabled: true. Commit both. Refused while a run holds the ACTIVE lock.
# Exit: 0 pass, 1 fail, 2 usage, 3 refused, 4 the provider or a tool is unavailable.
set -euo pipefail
case "${1:-}" in ""|-h|--help) sed -n '4,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;; esac
for t in python3 git timeout; do
  command -v "$t" >/dev/null 2>&1 || { echo "provider-smoke: $t is required" >&2; exit 4; }
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROVIDER="$1"; shift
REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
# The run-state base, resolved as apex-scope-loop does (only to refuse under an ACTIVE lock).
BASE=""
# shellcheck source=lib/sibling.bash
source "$ROOT/scripts/lib/sibling.bash"
EX="$(apex_scope_loop_scripts "$ROOT")"
if [[ -n "$EX" ]]; then
  # shellcheck source=/dev/null
  BASE="$(REPO_ROOT="$PWD"; source "$EX/_lib.sh" && apex_state_base "$PWD" 2>/dev/null)" || BASE=""
fi
exec python3 -B "$ROOT/scripts/lib/worker.py" smoke "$PROVIDER" "$ROOT" "$BASE" "$REPO" -- "$@"
