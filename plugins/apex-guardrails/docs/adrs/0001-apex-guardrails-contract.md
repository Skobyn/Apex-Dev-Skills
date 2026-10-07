# ADR-0001: apex-guardrails plugin contract

- **Status:** Proposed
- **Date:** 2026-05-29
- **Author:** solutions@getapexinsights.com
- **Plugin:** apex-guardrails v0.2.0 (contract introduced in v0.1.0)

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
│   ├── block-destructive-bash.sh       # B1 — deny bypass flags (always) + destructive shell commands
│   ├── bash_scope.py                   # B1 — tool_input.command extraction + bypass-flag tokeniser
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
  `block-destructive-bash.sh` reads `tool_input.command` only (never the first
  `"command"` key anywhere in the event, which was a bypass surface) and always
  denies permission-bypass flags — `--dangerously-*` (incl.
  `--dangerously-skip-permissions`, `--dangerously-bypass-approvals-and-sandbox`),
  `--yolo`, `--always-approve`, `--full-auto` — passed to any program, whatever the
  policy declares. Text tools (`echo`, `printf`, `grep`, `rg`, `sed`, `cat`, …)
  only mention such a flag and are not denied; nested `bash -c`, `$(…)` and backtick
  commands are checked in their own right, with bash's quoting (single-quoted text and
  quoted-heredoc bodies are literal; `<<` in `$(( ))` is not a heredoc); for any
  non-text-tool program, arguments containing whitespace and `<shell> -c ARG` anywhere
  in the arguments are checked as nested commands (launchers such as tmux, screen,
  docker, script, su, ssh), depth-capped; wrapper option values (`sudo -u USER`,
  `timeout -s SIG DURATION`, `env -u VAR`, `nice -n N`) are skipped; the launcher rules
  apply to every program that is not a pure text tool (git, gh and glab are not text
  tools), and for git/gh/glab only the values of prose options are exempt — long
  options (titles, bodies, messages, `--grep`, `--format`, …) everywhere, short letters
  only for the subcommands where they take prose (e.g. `-m` for `git commit` but not
  `git rebase`, `-d` for `gh pr create` but not `gh codespace ssh`), and never a next
  argument that starts with `-`; a heredoc is a script — its body checked
  as commands regardless of quoting — when its command is a shell/`ssh`/`su`, when a
  non-text program has a shell/`ssh`/`su` argument (`docker exec -i c sh`,
  `kubectl exec … -- bash`), or when it (or its `( )`/`{ }` group) is piped into such a
  command; other heredocs stay literal data (the approach of apex-dispatch's `pre-bash`
  hook, reimplemented in `hooks/bash_scope.py` so no code is shared across plugins).
  It then denies `rm -rf /`, `rm -rf ~`/`$HOME`, force-push to `main`/`master`,
  `git reset --hard` onto a protected branch, and curl/wget piped into a shell.
- **B2 PolicyAsCode** — `resources/policy.example.yaml` is the declarative ruleset.
  `scripts/compile-policy.sh` validates it and compiles it into `hooks/hooks.json`,
  so the matcher config is derived from policy, not hand-edited.
  `block-destructive-bash.sh` is always compiled onto `Bash` (with `--bypass-only`
  when the policy has no `destructive_bash` family), so the bypass-flag denial
  cannot be compiled away. The
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
`hooks.json` references hook scripts via a quoted `"${CLAUDE_PLUGIN_ROOT}"` so paths
resolve regardless of install location (including paths with spaces).

Hook composition across plugins is parallel and deny-first: Claude Code runs every
matching hook of every enabled plugin and a single `deny` wins. apex-guardrails and
apex-dispatch are the only plugins in this marketplace that emit `allow`/`deny`
decisions; observational hooks elsewhere exit 0 with no JSON (asserted by
apex-contracts-reliability's smoke test).

### Surface

- **1 skill** — `guardrail` (auto-discovered, not enumerated in plugin.json)
- **1 slash command** — `/apex-guardrails:guardrails-policy`
- **3 hooks** + **1 hooks.json** under `hooks/`
- **1 policy resource** + **1 compiler script** under `resources/` and `scripts/`
- No agents.

### Compatibility

- Claude Code: 2.0+ (requires the PreToolUse hook protocol with
  `hookSpecificOutput.permissionDecision` and `${CLAUDE_PLUGIN_ROOT}` expansion).
- Bash 3.2+ (no jq required). `python3` (stdlib) is used when present: the Bash
  hook extracts `tool_input.command` and tokenises it with `hooks/bash_scope.py`, and
  `compile-policy.sh` re-validates the emitted JSON. Without `python3` the Bash hook
  falls back to a pure-bash approximation that keeps the scoping and the bypass-flag
  denial (coarser text-tool exemption: only a single, unchained text-tool command).
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
6. `hooks/hooks.json` exists, is valid JSON, and every command quotes `"${CLAUDE_PLUGIN_ROOT}"`
7. All three hook scripts exist
8. `README.md` exists with "Compatibility", "Namespace coordination", "Verification", "Architecture Decisions" sections
9. This ADR-0001 exists with `Status: Proposed`
10. All `*.sh` scripts (hooks/, scripts/) are executable
11. `hooks/hooks.json` equals `compile-policy.sh` output for the shipped policy, and a
    policy without `destructive_bash` still wires the bypass-flag hook
12. `block-destructive-bash.sh` on fixture events: each bypass-flag form denied (also
    under `--bypass-only`; launchers, wrapper option values, heredoc and arithmetic
    edges included), text tools, single-quoted text and quoted-heredoc bodies that
    mention a flag allowed, a `"command"` key
    outside `tool_input` ignored, and the no-`python3` fallback agreeing on a subset

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
- 2026-10-07 — v0.2.0: always-on bypass-flag denials, `tool_input.command` scoping,
  quoted `"${CLAUDE_PLUGIN_ROOT}"`, smoke checks 11–12 (apex-dispatch spec §7). Still Proposed.
