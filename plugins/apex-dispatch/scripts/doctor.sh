#!/usr/bin/env bash
# apex-dispatch doctor.sh — preflight; writes doctor.json for route.sh and the hooks.
#
# Usage:
#   doctor.sh [--state DIR | --plan PLAN] [--repo DIR]
#
# Writes <D>/doctor.json where <D> is <state>/dispatch/ when enforcing, else
# <state>/dispatch-shadow/ (see ledger.py enforcing()). Without --state/--plan a
# temporary state dir is used and its path printed (DOCTOR_FILE:). --repo is the
# repository whose .claude/settings.json is checked (default: git toplevel or cwd).
# Each check is ok | warn | fail | unverified | skipped; checks that need a live
# Claude Code session are recorded as unverified with the reason.
# Exit codes: 0 ok (or warn), 1 fail (the JSON is still written), 2 usage.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "doctor: python3 is required" >&2; exit 1; }
usage() { sed -n '4,5p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

STATE=""; PLAN=""; REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --state) STATE="${2:?--state needs a value}"; shift 2 ;;
    --plan) PLAN="${2:?--plan needs a value}"; shift 2 ;;
    --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "doctor: unknown argument $1" >&2; usage ;;
  esac
done
[[ -z "$STATE" || -z "$PLAN" ]] || { echo "doctor: --state and --plan are exclusive" >&2; exit 2; }
[[ -n "$REPO" ]] || REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"

TEMP=()
if [[ -n "$PLAN" ]]; then
  [[ -f "$PLAN" ]] || { echo "doctor: plan not found: $PLAN" >&2; exit 1; }
  EX=""
  for c in "${APEX_SCOPE_LOOP_ROOT:-}" "$PLUGIN_ROOT/../apex-scope-loop"; do
    [[ -n "$c" && -f "$c/skills/apex-execute/scripts/_lib.sh" ]] && { EX="$c/skills/apex-execute/scripts"; break; }
  done
  [[ -n "$EX" ]] || { echo "doctor: --plan needs apex-scope-loop beside apex-dispatch (or pass --state)" >&2; exit 1; }
  # shellcheck source=/dev/null
  source "$EX/_lib.sh"
  APEX_RESOLVE_MODE=read
  apex_resolve "$PLAN"
  STATE="$STATE_DIR"
elif [[ -z "$STATE" ]]; then
  STATE="$(mktemp -d "${TMPDIR:-/tmp}/apex-dispatch-doctor.XXXXXX")"
  TEMP=(--temp)
fi
mkdir -p "$STATE"
exec python3 -B "$PLUGIN_ROOT/scripts/lib/doctor.py" "$PLUGIN_ROOT" --state "$STATE" --repo "$REPO" ${TEMP[@]+"${TEMP[@]}"}
