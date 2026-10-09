#!/usr/bin/env bash
# apex-guardrails — B2 PolicyAsCode compiler.
#
# Compiles a declarative policy YAML (resources/policy.example.yaml) into the
# PreToolUse hooks matcher config (hooks/hooks.json), so org rules are ENFORCED
# at runtime rather than merely suggested. Also supports validate-only mode.
#
# Usage:
#   compile-policy.sh validate <policy.yaml>
#   compile-policy.sh <policy.yaml> <hooks.json>      # compile (writes hooks.json)
#
# The matcher config is deterministic: which tools the three hook scripts attach
# to is derived from which rule families the policy declares.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "compile-policy: $1" >&2; exit 1; }

validate_policy() {
  local policy="$1"
  [ -f "$policy" ] || die "policy file not found: $policy"
  grep -qE '^version:' "$policy" || die "policy missing required 'version:' key"
  # At least one rule family must be present, or the policy enforces nothing.
  if ! grep -qE '^(sensitive_paths|destructive_bash|secret_patterns):' "$policy"; then
    die "policy declares no rule families (sensitive_paths / destructive_bash / secret_patterns)"
  fi
  echo "compile-policy: OK — $policy is a valid guardrails policy"
}

emit_hooks_json() {
  local policy="$1"
  local has_paths=false has_bash=false has_secret=false
  grep -qE '^sensitive_paths:'  "$policy" && has_paths=true
  grep -qE '^destructive_bash:' "$policy" && has_bash=true
  grep -qE '^secret_patterns:'  "$policy" && has_secret=true

  # Build PreToolUse hook entries. Write/Edit family gets path + secret hooks;
  # Bash gets destructive + secret hooks — but only for families the policy declares.
  # Exception: block-destructive-bash.sh is ALWAYS wired on Bash, because its
  # permission-bypass-flag denial (--dangerously-*, --yolo, --always-approve,
  # --full-auto) is always on; without a destructive_bash family it runs with
  # --bypass-only.
  local write_hooks=() bash_hooks=()
  $has_paths  && write_hooks+=("block-sensitive-paths.sh")
  $has_secret && write_hooks+=("secret-scan.sh")
  if $has_bash; then bash_hooks+=("block-destructive-bash.sh"); else bash_hooks+=("block-destructive-bash.sh --bypass-only"); fi
  $has_secret && bash_hooks+=("secret-scan.sh")

  hook_array() {
    local first=true
    local s script args
    for s in "$@"; do
      $first || printf ',\n'
      first=false
      script="${s%% *}"; args=""
      [ "$script" = "$s" ] || args=" ${s#* }"
      # ${CLAUDE_PLUGIN_ROOT} is quoted so an install path with spaces still resolves.
      printf '          {\n            "type": "command",\n            "command": "bash \\"${CLAUDE_PLUGIN_ROOT}/hooks/%s\\"%s"\n          }' "$script" "$args"
    done
  }

  printf '{\n  "hooks": {\n    "PreToolUse": [\n'
  local blocks=()
  if [ "${#write_hooks[@]}" -gt 0 ]; then
    blocks+=("$(printf '      {\n        "matcher": "Write|Edit|MultiEdit|NotebookEdit",\n        "hooks": [\n%s\n        ]\n      }' "$(hook_array "${write_hooks[@]}")")")
  fi
  if [ "${#bash_hooks[@]}" -gt 0 ]; then
    blocks+=("$(printf '      {\n        "matcher": "Bash",\n        "hooks": [\n%s\n        ]\n      }' "$(hook_array "${bash_hooks[@]}")")")
  fi
  local i n="${#blocks[@]}"
  # Index loop, not "${!blocks[@]}": bash 3.2 (macOS) with set -u treats an empty array as unbound.
  i=0
  while [ "$i" -lt "$n" ]; do
    printf '%s' "${blocks[$i]}"
    [ "$i" -lt $(( n - 1 )) ] && printf ',\n' || printf '\n'
    i=$((i + 1))
  done
  printf '    ]\n  }\n}\n'
}

main() {
  [ "$#" -ge 1 ] || die "usage: compile-policy.sh validate <policy.yaml> | compile-policy.sh <policy.yaml> <hooks.json>"

  if [ "$1" = "validate" ]; then
    [ "$#" -eq 2 ] || die "usage: compile-policy.sh validate <policy.yaml>"
    validate_policy "$2"
    exit 0
  fi

  local policy="$1"
  local out="${2:-$PLUGIN_ROOT/hooks/hooks.json}"
  validate_policy "$policy"
  emit_hooks_json "$policy" > "$out.tmp"
  # Sanity: the compiled output must itself be valid JSON if a parser is available.
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$out.tmp" \
      || { rm -f "$out.tmp"; die "compiled hooks.json is not valid JSON (internal error)"; }
  fi
  mv "$out.tmp" "$out"
  echo "compile-policy: wrote enforced matcher config → $out"
}

main "$@"
