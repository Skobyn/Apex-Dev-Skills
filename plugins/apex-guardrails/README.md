# apex-guardrails

> Deterministic runtime guardrails via PreToolUse hooks: hard-block edits to sensitive paths, deny destructive bash, scan tool inputs for secrets, and compile a declarative YAML policy into enforced matcher config.

> **Block the bad action before it happens — don't scan for it afterward.**
> Deterministic PreToolUse hooks that hard-deny edits to secrets, destructive shell
> commands, and credential leaks, driven by a declarative Policy-as-Code ruleset.

Most "security" tooling for AI coding agents is *after-the-fact*: it reads the repo
or the transcript and tells you about the `.env` that already got overwritten, the
`rm -rf /` that already ran, the API key that already landed in a commit. That is
detection. **apex-guardrails is enforcement.** It plugs into Claude Code's
PreToolUse hook protocol so a dangerous tool call is denied *before it executes* —
the edit isn't written, the command isn't run, the secret isn't sent.

## What it does

apex-guardrails bundles three guardrails that share one enforcement model — a hook
returns `permissionDecision: deny` and the tool call never happens:

| Sub-feature | Hook | Enforces |
|---|---|---|
| **B1 GuardRail (paths)** | `hooks/block-sensitive-paths.sh` | Hard-blocks `Write`/`Edit`/`MultiEdit`/`NotebookEdit` to `.env`, `**/secrets/**`, `**/*credential*`, private keys/keystores, and `infra/prod` config. |
| **B1 GuardRail (bash)** | `hooks/block-destructive-bash.sh` | Denies `rm -rf /`, `rm -rf ~`/`$HOME`, force-push to `main`/`master`, `git reset --hard` onto a protected branch, and `curl`/`wget` piped into a shell. |
| **B3 SecretGuard** | `hooks/secret-scan.sh` | Scans `Write`/`Edit` content and `Bash` commands for AWS keys, PEM private keys, GitHub/Slack tokens, and inline `password=`/`secret=`/`api_key=` values — denying before the bytes hit disk or the wire. |

…plus **B2 PolicyAsCode**: a declarative `resources/policy.example.yaml` ruleset and
`scripts/compile-policy.sh` that compiles it into the hooks matcher config, so org
rules are *enforced*, not just written down. The `/apex-guardrails:guardrails-policy`
command exposes `view` / `validate` / `compile`.

## Install

```bash
# From the Apex marketplace
/plugin marketplace add Skobyn/Apex-Dev-Skills
/plugin install apex-guardrails@apex-dev-skills

# …or test locally against this repo
claude --plugin-dir ./plugins/apex-guardrails
```

Then `/reload-plugins` (or restart Claude Code) to load the hooks.

## Quick start

```bash
# See what the policy enforces and which hooks are wired
/apex-guardrails:guardrails-policy view

# Edit resources/policy.example.yaml, then recompile into enforced config
/apex-guardrails:guardrails-policy compile

# Confirm a block fires (by hand)
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' \
  | bash hooks/block-destructive-bash.sh
# → {"hookSpecificOutput":{...,"permissionDecision":"deny",...}}
```

## How it works

Each hook reads the PreToolUse event JSON on stdin and emits one decision object:

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"apex-guardrails: …"}}
```

`hooks/hooks.json` maps tool matchers (`Write|Edit|MultiEdit|NotebookEdit`, `Bash`)
to these scripts via `${CLAUDE_PLUGIN_ROOT}`. The policy YAML is the source of truth;
`hooks.json` is a compile artifact. Edit the policy, recompile, reload.

## Compatibility

- **Claude Code:** 2.0+ — requires the PreToolUse hook protocol with
  `hookSpecificOutput.permissionDecision` and `${CLAUDE_PLUGIN_ROOT}` expansion in
  hook command paths.
- **Bash:** 3.2+ — hooks and the compiler are pure bash; no `jq` required (JSON
  fields are extracted with grep/sed). `python3` is used opportunistically by
  `compile-policy.sh` to re-validate emitted JSON when present, but is optional.
- **No MCP server** — the plugin ships none. The skill's `allowed-tools` is an
  explicit list (`Bash, Read, Write, Edit, Glob, Grep`) with no `*`/`mcp__*`
  wildcards.

## Namespace coordination

This plugin claims the configuration namespace **`guardrails-policy`** — the policy
ruleset (`resources/policy.example.yaml`) and its compiled matcher config
(`hooks/hooks.json`). It does not read or write any AgentDB / memory namespace at
runtime; its only persistent state is on-disk policy + hooks. Any future plugin that
reads or rewrites the guardrails policy/matcher config must claim a non-overlapping
prefix and reference this plugin's ADR-0001. Suite-level coordination is tracked in
`.claude/tasks/novel-plugins-suite-adr.md`.

## Verification

```bash
bash plugins/apex-guardrails/scripts/smoke.sh
```

The smoke script runs 10 structural checks (plugin.json keys, no enumerated surface
arrays, kebab-case skill name, no wildcard tools, command frontmatter, valid
`hooks/hooks.json`, presence of all hook scripts, README sections, ADR status,
script executability). It exits non-zero on the first failing check and names what's
wrong.

## Architecture Decisions

- [ADR-0001 — apex-guardrails plugin contract](docs/adrs/0001-apex-guardrails-contract.md) — Status: **Proposed**. Defines the surface, the three sub-features, the hook protocol, the `guardrails-policy` namespace, compatibility, and the smoke contract.

## Caveats

Pattern-based detection has false positives and false negatives. The hooks fail
*open* (allow) when they cannot parse a tool-input field, so they never block a
legitimate call they can't understand — at the cost of missing a secret hidden in an
unparseable field. Tune `resources/policy.example.yaml` (including `allow.placeholders`)
and recompile rather than disabling a hook outright. This is a guardrail, not a proof.

## License

MIT — see the repo-level LICENSE.
