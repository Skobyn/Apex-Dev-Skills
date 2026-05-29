# ADR-0001: apex-guardrails plugin contract

- **Status:** Proposed
- **Date:** 2026-05-29
- **Author:** solutions@getapexinsights.com
- **Plugin:** apex-guardrails v0.1.0

## Context

Agentic coding tools can write any file and run any shell command the host
permits. Most "security" tooling for this is *after-the-fact*: a scanner reads
the repo or the transcript and reports problems that already happened — the `.env`
was already overwritten, the `rm -rf /` already ran, the AWS key was already
committed. That is detection, not prevention.

Claude Code exposes a **PreToolUse hook** protocol: before a tool call executes, a
hook receives the event JSON on stdin and may return a `permissionDecision` of
`deny` or `allow`. A `deny` stops the tool call from ever running. This is the
right primitive for *deterministic enforcement* — the guardrail is a gate, not a
review.

This plugin packages three guardrails that share that enforcement model, plus a
Policy-as-Code layer so the rules are declared once and compiled into the matcher
config rather than hand-maintained.

See the suite-level planning note at `.claude/tasks/novel-plugins-suite-adr.md` for
where apex-guardrails sits among the broader plugin set.

## Decision

Ship a single plugin `apex-guardrails` with this contract.

### Layout

```
plugins/apex-guardrails/
├── .claude-plugin/plugin.json          # name, version, description, author, license, keywords
├── skills/
│   └── guardrail/SKILL.md              # overview + how to configure the guardrails
├── commands/
│   └── guardrails-policy.md            # /apex-guardrails:guardrails-policy view|validate|compile
├── hooks/
│   ├── hooks.json                      # PreToolUse matchers → hook commands (compile target)
│   ├── block-sensitive-paths.sh        # B1 — deny edits to sensitive paths
│   ├── block-destructive-bash.sh       # B1 — deny destructive shell commands
│   └── secret-scan.sh                  # B3 — deny tool input containing secrets
├── resources/
│   └── policy.example.yaml             # B2 — declarative allow/deny ruleset (source of truth)
├── scripts/
│   ├── compile-policy.sh               # B2 — compile policy YAML → hooks.json
│   └── smoke.sh                        # structural contract checks
├── docs/adrs/0001-apex-guardrails-contract.md
└── README.md
```

### Sub-features

- **B1 GuardRail** — two PreToolUse hooks. `block-sensitive-paths.sh` hard-blocks
  `Write`/`Edit`/`MultiEdit`/`NotebookEdit` to `.env`, `**/secrets/**`,
  `**/*credential*`, private keys/keystores, and `infra/prod` config.
  `block-destructive-bash.sh` denies `rm -rf /`, `rm -rf ~`/`$HOME`, force-push to
  `main`/`master`, `git reset --hard` onto a protected branch, and curl/wget piped
  into a shell.
- **B2 PolicyAsCode** — `resources/policy.example.yaml` is the declarative ruleset.
  `scripts/compile-policy.sh` validates it and compiles it into `hooks/hooks.json`,
  so the matcher config is derived from policy, not hand-edited. The
  `/apex-guardrails:guardrails-policy` command exposes view/validate/compile.
- **B3 SecretGuard** — `secret-scan.sh` scans `Write`/`Edit` content and `Bash`
  commands for AWS keys, PEM private keys, GitHub/Slack tokens, and inline
  `password=`/`secret=`/`api_key=` values, denying before the bytes are written or
  transmitted. `allow.placeholders` in the policy prevents obvious template
  placeholders from tripping it.

### Hook protocol

Every hook reads the PreToolUse event JSON on stdin and emits exactly one decision
object on stdout:

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"apex-guardrails: …"}}
```

or the `allow` variant. Hooks fail closed on a matched rule and allow otherwise.
`hooks.json` references hook scripts via `${CLAUDE_PLUGIN_ROOT}` so paths resolve
regardless of install location.

### Surface

- **1 skill** — `guardrail` (auto-discovered, not enumerated in plugin.json)
- **1 slash command** — `/apex-guardrails:guardrails-policy`
- **3 hooks** + **1 hooks.json** under `hooks/`
- **1 policy resource** + **1 compiler script** under `resources/` and `scripts/`
- No agents.

### Compatibility

- Claude Code: 2.0+ (requires the PreToolUse hook protocol with
  `hookSpecificOutput.permissionDecision` and `${CLAUDE_PLUGIN_ROOT}` expansion).
- Bash 3.2+ (the hooks and compiler are pure bash; no jq required — JSON fields are
  extracted with grep/sed). `python3` is used opportunistically by
  `compile-policy.sh` to re-validate the emitted JSON if present, but is optional.
- The plugin ships no MCP server. `allowed-tools` in the skill is an explicit list
  (`Bash, Read, Write, Edit, Glob, Grep`) — no `*` or `mcp__*` wildcards.

### Namespace coordination

This plugin claims the configuration namespace **`guardrails-policy`** (the policy
ruleset and its compiled matcher config). It does not write to any AgentDB / memory
namespace at runtime — its state is the on-disk policy YAML and `hooks.json`. Any
future plugin that reads or rewrites the guardrails policy/matcher config must claim
a non-overlapping prefix and reference this ADR. Suite coordination is tracked in
`.claude/tasks/novel-plugins-suite-adr.md`.

### Smoke contract

`scripts/smoke.sh` verifies at minimum these structural checks and exits non-zero
on the first failure with a named reason:

1. `plugin.json` exists with `name`, `version`, `description`, `author`, `license`, `keywords`
2. `plugin.json` does **not** enumerate `skills`/`commands`/`agents` arrays
3. `skills/guardrail/SKILL.md` has valid frontmatter with kebab-case `name:`
4. No SKILL.md uses wildcard tools (`*`, `mcp__*`)
5. `commands/guardrails-policy.md` exists with valid `name:` + `description:` frontmatter
6. `hooks/hooks.json` exists and is valid JSON
7. All three hook scripts exist
8. `README.md` exists with "Compatibility", "Namespace coordination", "Verification", "Architecture Decisions" sections
9. This ADR-0001 exists with `Status: Proposed`
10. All `*.sh` scripts (hooks/, scripts/) are executable

## Consequences

### Positive

- Guardrails are enforced at the gate: a denied action never runs, so there is no
  cleanup or "it already leaked" scenario to recover from.
- Policy-as-Code keeps the ruleset declarative and reviewable; the live matcher
  config is a compile artifact, reducing drift between intent and enforcement.
- No external dependencies: pure-bash hooks run anywhere Claude Code does.

### Negative

- Pattern-based detection has false positives (a legitimate `password=` template)
  and false negatives (a novel token format). Mitigations: `allow.placeholders`
  carve-outs, and the policy is editable + recompilable. It is a guardrail, not a
  proof.
- Hooks load at startup; recompiling the policy requires a `/reload-plugins` or
  restart to take effect. Documented in the README.
- Grep/sed JSON extraction is intentionally simple; deeply nested or unusually
  escaped tool inputs may not be parsed perfectly. The hooks fail *open* (allow)
  when they cannot extract a field, so they never block a legitimate call they
  cannot understand — at the cost of not catching a secret hidden in an unparseable
  field.

### Neutral

- The plugin is opinionated about which paths/commands are "sensitive" out of the
  box. Orgs are expected to tune `resources/policy.example.yaml` and recompile.

## Status changes

- 2026-05-29 — Proposed (initial scaffold)
