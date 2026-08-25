---
name: guardrails-policy
description: View, validate, or compile the apex-guardrails policy ruleset into enforced PreToolUse hook config. Pass "view", "validate", or "compile" as $ARGUMENTS.
argument-hint: "view | validate | compile"
---

You are operating the **apex-guardrails** Policy-as-Code surface. The declarative
ruleset lives at `resources/policy.example.yaml` and compiles into
`hooks/hooks.json` so org rules are *enforced* (a denied tool call never runs),
not merely documented.

The requested action is: `$ARGUMENTS` (default to `view` if empty).

## view
Read `resources/policy.example.yaml` and summarize for the user:
- the declared `sensitive_paths` (B1 — hard-blocked edit targets)
- the `destructive_bash` patterns (B1 — denied shell commands)
- the `secret_patterns` (B3 — credential families scanned in tool input)
- any `allow.placeholders` carve-outs

Then read `hooks/hooks.json` and report which hook scripts are currently wired to
which tool matchers, so the user can see whether the live config matches the policy.

## validate
Run:
```bash
bash scripts/compile-policy.sh validate resources/policy.example.yaml
```
Report the result. If it exits non-zero, surface the named failure reason verbatim
and stop — do not attempt to compile an invalid policy.

## compile
1. First validate (as above). Abort on failure.
2. Then compile the policy into the enforced matcher config:
   ```bash
   bash scripts/compile-policy.sh resources/policy.example.yaml hooks/hooks.json
   ```
3. Confirm the new `hooks/hooks.json` is valid JSON and report which matchers/hooks
   it now declares. Remind the user to `/reload-plugins` (or restart Claude Code)
   so the recompiled hooks take effect.

Never weaken a rule silently. If the user asks to remove a guardrail, edit
`resources/policy.example.yaml` explicitly, recompile, and note in your summary
exactly which protection was dropped.
