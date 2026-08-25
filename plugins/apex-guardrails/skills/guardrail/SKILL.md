---
name: guardrail
description: Configure and reason about apex-guardrails — deterministic PreToolUse hook enforcement that hard-blocks edits to sensitive paths (.env, secrets/, credentials, prod infra), denies destructive bash (rm -rf /, force-push to main, curl|sh), and scans tool inputs for leaked secrets (AWS keys, private keys, tokens, inline passwords) before they are written or sent. Also covers the declarative Policy-as-Code ruleset and the compile-policy workflow. Use when the user wants to set up runtime guardrails, harden a repo against accidental secret leaks or destructive commands, edit or compile the guardrails policy, or understand why a tool call was denied by a guardrails hook.
allowed-tools: [Bash, Read, Write, Edit, Glob, Grep]
---

# apex-guardrails

Deterministic, runtime **enforcement** of org guardrails via Claude Code
PreToolUse hooks. The value here is that bad actions are *blocked before they
happen* — not flagged in an after-the-fact scan. A denied tool call never runs:
the edit isn't written, the command isn't executed, the secret isn't sent.

This skill helps you configure the three bundled guardrails and operate the
Policy-as-Code workflow.

## The three guardrails

| Sub-feature | Hook | What it enforces |
|---|---|---|
| **B1 GuardRail (paths)** | `hooks/block-sensitive-paths.sh` | Hard-blocks `Write`/`Edit`/`MultiEdit`/`NotebookEdit` to `.env`, `**/secrets/**`, `**/*credential*`, private keys/keystores, and `infra/prod` config. |
| **B1 GuardRail (bash)** | `hooks/block-destructive-bash.sh` | Denies `rm -rf /`, `rm -rf ~`/`$HOME`, force-push to `main`/`master`, `git reset --hard` onto a protected branch, and `curl`/`wget` piped into a shell. |
| **B3 SecretGuard** | `hooks/secret-scan.sh` | Scans `Write`/`Edit` content and `Bash` commands for AWS keys, PEM private keys, GitHub/Slack tokens, and inline `password=`/`secret=`/`api_key=` values — denying before the bytes hit disk or the wire. |

All three are wired in `hooks/hooks.json` against `PreToolUse` matchers. Each hook
reads the hook event JSON on stdin and emits the Claude Code decision shape:

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"apex-guardrails: …"}}
```

…or `"permissionDecision":"allow"` when nothing matches.

## B2 — Policy as Code

`resources/policy.example.yaml` is the **source of truth** for what gets enforced.
It declares `sensitive_paths`, `destructive_bash`, `secret_patterns`, and `allow`
carve-outs (placeholders that should not trip the secret scanner). The compiler
turns it into the live matcher config:

```bash
# Validate the policy is well-formed
bash scripts/compile-policy.sh validate resources/policy.example.yaml

# Compile it into the enforced hooks matcher config
bash scripts/compile-policy.sh resources/policy.example.yaml hooks/hooks.json
```

The `/apex-guardrails:guardrails-policy` slash command wraps `view`/`validate`/`compile`.

## How to configure

1. **Edit the policy, not the hooks.** Add a glob to `sensitive_paths`, a pattern
   to `destructive_bash`, or a carve-out to `allow.placeholders` in
   `resources/policy.example.yaml`.
2. **Recompile** with `compile-policy.sh` so `hooks/hooks.json` reflects which rule
   families are active. (If a family is removed from the policy, its hook is
   dropped from the matcher config.)
3. **Reload** — run `/reload-plugins` or restart Claude Code so the new hook config
   takes effect. Hooks are loaded at startup.
4. **Verify** with the smoke test:
   ```bash
   bash scripts/smoke.sh
   ```

## Testing a hook by hand

Each hook reads an event on stdin. To confirm a block fires:

```bash
echo '{"tool_name":"Write","tool_input":{"file_path":".env","content":"X"}}' \
  | bash hooks/block-sensitive-paths.sh
# → permissionDecision: deny

echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' \
  | bash hooks/block-destructive-bash.sh
# → permissionDecision: deny

echo '{"tool_name":"Write","tool_input":{"content":"aws_key=AKIAIOSFODNN7EXAMPLE"}}' \
  | bash hooks/secret-scan.sh
# → permissionDecision: deny
```

A passing path or clean content emits `permissionDecision: allow`.

## When a hook denies your action

The `permissionDecisionReason` always starts with `apex-guardrails:` and names the
matched rule. That is intentional friction, not a bug:

- **Editing a real secret?** Use a secret manager / env reference; don't write it
  into a tracked file.
- **Need a genuinely destructive command?** Run it outside the agent, or scope it
  narrowly (e.g. `rm -rf ./build` is allowed; `rm -rf /` is not).
- **False positive on a placeholder?** Add the marker (e.g. `your_`, `example`,
  `${`) to `allow.placeholders` and recompile — don't disable the whole hook.

## Anti-patterns

1. **Editing `hooks/hooks.json` by hand.** It is a compile target. Edit the policy
   YAML and recompile so the policy stays the single source of truth.
2. **Wildcard matchers.** Keep matchers explicit (`Write|Edit|...`, `Bash`). Never
   broaden `allowed-tools` here to `*` or `mcp__*`.
3. **Treating this as a scanner.** It is runtime enforcement. There's no "report"
   to review later — the action is stopped at the gate.
4. **Whitelisting by disabling a hook.** Narrow the rule or add a placeholder
   carve-out instead of dropping a guardrail entirely.
