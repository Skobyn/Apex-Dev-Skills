---
name: doctor
description: Run apex-dispatch's preflight (doctor.sh) — claude version, the sibling apex-scope-loop, apex-guardrails, compile --check, the merged policy, provider binaries, CLAUDE_CODE_SUBAGENT_MODEL, the settings snippet, versions — and write doctor.json, which routing reads to choose degrade paths. Pass an optional plan path (or --state DIR / --repo DIR) as $ARGUMENTS.
argument-hint: "[<plan.md> | --state <dir>] [--repo <dir>]"
---

You are running the apex-dispatch preflight for `$ARGUMENTS`.

1. If `$ARGUMENTS` is empty or starts with `--`, run `${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh $ARGUMENTS`. Otherwise treat it as a plan path and run `${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh --plan $ARGUMENTS`. Without a plan or state, doctor.json goes to a temporary state; say so.
2. Print the `DOCTOR_FILE:` line, then read that JSON and list every check that is not `ok`, grouped by status:
   - **fail** (exit 1): blocking. The common ones are `claude-binary` (absent or older than 2.1.251; `APEX_CLAUDE_BIN` overrides the name) and `subagent-model-env` (`CLAUDE_CODE_SUBAGENT_MODEL*` is set and would override every routed model; unset it). Give the fix for each.
   - **warn**: degraded but usable. A missing provider binary means routes fall back to `claude-session`; a missing settings snippet means the deny rules are not applied (copy the `permissions` from `${CLAUDE_PLUGIN_ROOT}/resources/settings-snippet.json` into `.claude/settings.json`, and commit it for cloud sessions); `claude -p` auth unavailable means Tier C diversity degrades to `warn`.
   - **unverified**: probes that need a live session or the Phase 4 shims (agent identity in subagent tool stdin, `updatedInput` on Agent, forced-flag and sandbox probes). State the reason doctor recorded; do not claim them verified.
   - **skipped**: name them.
3. Never edit `.claude/settings.json` or unset environment variables yourself; tell the user what to change.

Exit codes: 0 ok/warn, 1 any fail (doctor.json is still written), 2 usage.
