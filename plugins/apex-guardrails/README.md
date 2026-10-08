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
| **B1 GuardRail (bash)** | `hooks/block-destructive-bash.sh` | Always denies permission-bypass flags (`--dangerously-skip-permissions`, `--dangerously-bypass-approvals-and-sandbox`, any `--dangerously-*`, `--yolo`, `--always-approve`, `--full-auto`) passed to any program, whatever the policy says; then denies `rm -rf /`, `rm -rf ~`/`$HOME`, force-push to `main`/`master`, `git reset --hard` onto a protected branch, and `curl`/`wget` piped into a shell. Reads `tool_input.command` only. |
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
to these scripts via a quoted `"${CLAUDE_PLUGIN_ROOT}"` (install paths with spaces
resolve). The policy YAML is the source of truth; `hooks.json` is a compile artifact.
Edit the policy, recompile, reload. `block-destructive-bash.sh` is wired on `Bash`
even when the policy declares no `destructive_bash` family (then with
`--bypass-only`), because the bypass-flag denial is always on.

**Bypass flags.** `--dangerously-*`, `--yolo`, `--always-approve` and `--full-auto`
switch an agent CLI's own approvals off; any program given one is denied. Text tools
(`echo`, `printf`, `grep`, `rg`, `sed`, `cat`, …) only mention a flag, so
`grep -- --yolo notes.md` passes (git, gh and glab are exec-capable and not text tools; their
prose option values are exempt, so `git commit -m "deny --full-auto"` passes); chained,
`bash -c`, `$(…)` and backtick commands are checked on their own. Quoting follows
bash: single-quoted text and quoted-heredoc bodies (`<<'EOF'`) are literal, so a
flag in backticks there (a commit message, a PR body) is not a command; `$(…)` and
backticks outside quotes, in double quotes and in unquoted heredocs are; `<<` inside
`$(( ))` is a shift. Launchers are covered: for any program that is not a text tool,
an argument with whitespace is checked as a nested command and `<shell> -c ARG`
anywhere in its arguments is too (`tmux new-session '…'`, `ssh host '…'`,
`docker run img sh -c '…'`, `script -qc '…'`, `su -c '…'`), and wrapper option values
are skipped (`sudo -u git …`, `timeout -s KILL 30 …`). The launcher rules apply to every
program that is not a pure text tool — git, gh and glab included — so
`gh codespace ssh '…'`, `gh alias set x '…'`, `git rebase -x '…'` and `git bisect run …`
are checked; for those three only the *values* of prose options are exempt: long ones
everywhere (gh/glab `--title`, `--body`, `--description`, `--notes`, `--message`, `--field`,
…; git `--message`, `--file`, `--author`, `--grep`, `--format`, `--pretty`), short ones only
for the subcommands where they take prose (git `commit`/`tag`/`merge`/`notes add` `-m`/`-F`,
git `log`/`show`/`shortlog` `-S`/`-G`; gh/glab `pr|issue|release|mr` `create|edit|comment|
review|close|note` `-t -b -d -n -f -F`, but `gh pr merge` only `-t -b -F` (its `-d` is the
boolean `--delete-branch`); `gh api -f -F`), in `--opt V`, `--opt=V`, `-oV` and
`-am V` forms, and never a next argument that is option-shaped (`--name[=v]` with no spaces; a bullet value like `'- removes --yolo'` is still a value) (so `git rebase -S --exec='…'` and
`gh codespace ssh -d '…'` are still checked). A heredoc fed to a shell, `ssh` or `su` is a script and
its body is checked as commands whatever its quoting: directly (`bash <<EOF`,
`bash -s <<'EOF'`), via a shell argument of a non-text program (`docker exec -i c sh <<EOF`,
`kubectl exec -i pod -- bash <<EOF`, `ssh -t host bash <<EOF`), or piped into one, also from
a `( )` / `{ }` group (`cat <<'EOF' | bash`, `(cat <<EOF) | bash`). A heredoc to anything
else (`cat > notes.md`, `python3 -`, `gh … --body-file -`, `./run.sh`) stays data. This is the same
approach as apex-dispatch's `pre-bash` hook (step 2 of `bash_rules` in
`plugins/apex-dispatch/scripts/lib/hooks.py`), reimplemented here in
`hooks/bash_scope.py` so the two plugins stay independent.

**Command scoping.** The Bash hook reads `tool_input.command` and nothing else. A
`"command"` key anywhere else in the event (another object, a future field) can
neither hide nor stand in for the real command.

**Composition.** Claude Code runs every plugin's matching hooks in parallel and a
single `deny` wins, so these denials hold whatever other plugins (apex-dispatch,
observability, contracts) return for the same call.

## Compatibility

- **Claude Code:** 2.0+ — requires the PreToolUse hook protocol with
  `hookSpecificOutput.permissionDecision` and `${CLAUDE_PLUGIN_ROOT}` expansion in
  hook command paths.
- **Bash:** 3.2+ — hooks and the compiler are bash; no `jq` required. `python3`
  (stdlib only) is used when present: `block-destructive-bash.sh` reads
  `tool_input.command` and tokenises it with `hooks/bash_scope.py`, and
  `compile-policy.sh` re-validates the emitted JSON. Without `python3` the Bash
  hook falls back to a pure-bash approximation (first `"command"` after
  `"tool_input"`; a bypass flag is denied unless the whole command is a single text
  tool), which the smoke test exercises.
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

The smoke script runs 12 checks: 10 structural ones (plugin.json keys, no enumerated
surface arrays, kebab-case skill name, no wildcard tools, command frontmatter, valid
`hooks/hooks.json` with a quoted `"${CLAUDE_PLUGIN_ROOT}"`, presence of all hook
scripts, README sections, ADR status, script executability), plus `hooks.json` equal
to the compiler's output and the Bash hook's behaviour on fixture events (bypass flags
denied, text tools allowed, `tool_input.command` scoping, the no-`python3` fallback).
It exits non-zero on the first failing check and names what's wrong.

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
