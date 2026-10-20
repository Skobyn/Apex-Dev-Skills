# shellcheck shell=bash
# hook-common.bash — the shared bash prelude of apex-dispatch's hooks
# (hooks/pre-{agent,bash,edit,mcp}.sh, post-agent.sh, post-bash-prune.sh,
# subagent-start.sh, subagent-stop.sh, stop-gate.sh). Sourced, never executed.
#
# Contract (ADR-0001 "Hook contract", spec §5.3 E):
#   - prints exactly one JSON object on stdout, always (an EXIT trap prints {}
#     if nothing else was printed) and exits 0 — except subagent-stop (the
#     transcript-audit refusal) and stop (the Stop gate), which exit 2 with the
#     reason on stderr when hooks.py exits 2 (Phase 0 spike 10);
#   - no-op ({}) unless the run's ACTIVE lock exists — except pre-bash's operate
#     deploy deny (apex_hook_operate_gate), which holds at every stage. The state root is resolved
#     by apex-scope-loop's own _lib.sh (apex_state_base: `git rev-parse
#     --path-format=absolute --git-common-dir`, APEX_STATE_ROOT first), so the
#     base checkout, the plan worktree and shim worktrees see one lock;
#   - the no-op path is bash only (one git call); python3 (scripts/lib/hooks.py)
#     starts only while a lock exists, to parse the JSON payload and decide;
#   - fails open ({} plus a stderr advisory) when python3, the sibling
#     apex-scope-loop or the payload is unusable; hooks.py also writes a
#     hook_error ledger row when the run's ledger is writable.

apex_hook_out() {
  [[ "${APEX_HOOK_PRINTED:-0}" == 1 ]] && return 0
  APEX_HOOK_PRINTED=1
  printf '%s\n' "$1"
}

apex_hook_scope_loop_scripts() {
  # The highest installed version wins (scripts/lib/sibling.bash), never the first glob match.
  # shellcheck source=/dev/null
  source "$1/scripts/lib/sibling.bash"
  apex_scope_loop_scripts "$1"
}

# apex_hook_operate_gate ROOT INPUT — the deploy control (aidlc-borrowings Phase 3.3).
# Bash only, no state needed: a command whose text (shell quotes and backslashes
# removed) never names operate.sh, and does not pair the word deploy with an
# expansion or glob ($ ` * ? [), returns 1 at once, so ordinary calls with no lock
# stay bash-only. A command that names it is judged by hooks.py operate-gate (the
# allow-list: operate.sh … status, plain mentions); a deny is printed and 0
# returned. This rule fails closed: without python3, or when the engine fails, a
# command naming operate.sh with the word deploy is denied.
apex_hook_operate_gate() {
  local root="$1" input="$2" flat out rc=0 reason expand='*[$`*?[]*'
  flat="${input//[\"\'\\]/}"
  # Not named: still judged when deploy appears beside an expansion or glob that could hide the name.
  if [[ "$flat" != *operate.sh* ]]; then
    [[ "$flat" == *deploy* && "$input" == $expand ]] || return 1
  fi
  reason="apex-dispatch: operate.sh deploy must be run by a human in their own terminal; pre-bash could not judge this command"
  if command -v python3 >/dev/null 2>&1; then
    out="$(printf '%s' "$input" | python3 -B "$root/scripts/lib/hooks.py" operate-gate 2>/dev/null)" || rc=$?
    out="$(printf '%s' "$out" | tail -n 1)"
    [[ "$rc" -eq 0 && "$out" == \{*\} ]] || out=""
  else
    out=""; reason="$reason (python3 not found)"
  fi
  if [[ -z "$out" ]]; then
    [[ "$flat" == *deploy* ]] || return 1
    out="{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"$reason\"}}"
  fi
  [[ "$out" == "{}" ]] && return 1
  apex_hook_out "$out"
  return 0
}

# apex_hook_run KIND — KIND is agent | bash | edit | mcp | post-agent | post-bash |
# subagent-start | subagent-stop | stop.
apex_hook_run() {
  local kind="$1" root input scripts dir out rc=0 name
  case "$kind" in agent|bash|edit|mcp) name="pre-$kind" ;; post-bash) name="post-bash-prune" ;; stop) name="stop-gate" ;; *) name="$kind" ;; esac
  APEX_HOOK_PRINTED=0; APEX_HOOK_RC=0
  trap 'apex_hook_out "{}"; exit "${APEX_HOOK_RC:-0}"' EXIT
  input="$(cat 2>/dev/null || true)"
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  # The one rule that is not lock-scoped (ADR-0001, Amendments 2026-10-20): before
  # APEX_DISPATCH_MODE and before the ACTIVE lock test, pre-bash denies any command
  # that starts apex-scope-loop's operate.sh deploy.
  [[ "$kind" == bash ]] && apex_hook_operate_gate "$root" "$input" && return 0
  [[ "${APEX_DISPATCH_MODE:-}" == off ]] && { apex_hook_out "{}"; return 0; }
  scripts="$(apex_hook_scope_loop_scripts "$root")"
  [[ -n "$scripts" ]] || { apex_hook_out "{}"; return 0; }   # no apex-scope-loop: no ACTIVE lock exists
  # The session's directory (the payload's cwd), else the hook's own.
  dir="$PWD"
  if [[ "$input" =~ \"cwd\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" && -d "${BASH_REMATCH[1]}" ]]; then
    dir="${BASH_REMATCH[1]}"
  fi
  # shellcheck source=/dev/null
  source "$scripts/_lib.sh" || { apex_hook_out "{}"; return 0; }
  REPO_ROOT="$dir"                                   # apex_state_base's fallback outside git
  STATE_BASE="$(apex_state_base "$dir" 2>/dev/null)" || { apex_hook_out "{}"; return 0; }
  [[ -n "$STATE_BASE" && -d "$STATE_BASE/ACTIVE" ]] || { apex_hook_out "{}"; return 0; }
  REPO_ROOT="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || (cd "$dir" && pwd -P))"
  if ! command -v python3 >/dev/null 2>&1; then
    echo "apex-dispatch $name: python3 not found; failing open" >&2
    apex_hook_out "{}"; return 0
  fi
  out="$(cd "$dir" && printf '%s' "$input" | python3 -B "$root/scripts/lib/hooks.py" "$kind" "$root" "$STATE_BASE" "$scripts" "$REPO_ROOT")" || rc=$?
  out="$(printf '%s' "$out" | tail -n 1)"
  if [[ "$rc" -eq 2 && ( "$kind" == subagent-stop || "$kind" == stop ) && "$out" == \{*\} ]]; then
    APEX_HOOK_RC=2                                   # a documented block: the reason is already on stderr
  elif [[ "$rc" -ne 0 || "$out" != \{*\} ]]; then
    echo "apex-dispatch $name: hook engine failed (exit $rc); failing open" >&2
    out="{}"
  fi
  apex_hook_out "$out"
}
