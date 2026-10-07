---
name: compile
description: Compile apex-dispatch's routing policy (compile.sh) into its committed artifacts — compiled policy, generated agents, settings snippet, hooks.json — or check them for staleness (--check), print this repo's overlay-merged policy (--print-merged), validate an overlay (--overlay PATH), or render the codex-side mirror (--target codex). Pass the mode as $ARGUMENTS; empty means --check.
argument-hint: "[--check | --print-merged | --write] [--overlay <path>] | --target codex [--out <dir>] [--check]"
---

You are running the apex-dispatch policy compiler with `$ARGUMENTS`.

1. If `$ARGUMENTS` is empty, run `${CLAUDE_PLUGIN_ROOT}/scripts/compile.sh --check` (read-only). Otherwise run `${CLAUDE_PLUGIN_ROOT}/scripts/compile.sh $ARGUMENTS`.
   - `--check` regenerates in memory and exits 1 naming every `stale:`, `missing:` or `not generated:` artifact. It writes nothing.
   - `--print-merged [--overlay PATH]` prints the policy this repo actually routes with: the plugin default plus `.claude/apex-dispatch/policy.json` (or `$APEX_DISPATCH_POLICY`). Use it to answer "what will route.sh do here?".
   - `--overlay PATH` validates that overlay; an invalid overlay exits 1 with every problem named (an overlay can configure within the hard rules but never weaken confinement: no new providers, no tier changes, roles may only lose tools, hard rules are append-only). On its own (or with `--check`) it is read-only: it validates the overlay and checks the artifacts, and never rewrites anything. Only `--overlay PATH --write` also regenerates.
   - `--write` (or `compile.sh` with no flag at all) **rewrites files inside the plugin** (`resources/compiled/`, `agents/`, `resources/settings-snippet.json`, `hooks/hooks.json`). Only do that when the user is developing the plugin and asked for it; artifacts come from the default policy, and a per-repo overlay never needs a recompile because readers merge it at runtime.
   - `--target codex [--out DIR] [--check]` renders the codex-side mirror of the default policy: `AGENTS.md` (roles and rules), `config.toml` (profiles `apex-dispatch-build`/`apex-dispatch-readonly`), `hooks.json` and `apex-dispatch-deny.py` (a PreToolUse deny hook). Without `--out` it targets the plugin's own `resources/compiled/codex/` (rewriting plugin files: only when developing the plugin); with `--check` it only compares. To install for the user's codex, run it with `--out "$CODEX_HOME"` (default `~/.codex`) only when the user asks for that, and say which files it wrote. The default target is unaffected.
2. Report the result plainly: clean, or the list of stale/invalid items verbatim. Never hand-edit `agents/*.md` to make `--check` pass; edit `resources/dispatch.default.json` and recompile.
3. To make settings effective for cloud sessions, the user commits the overlay and the settings snippet's `permissions` under the repo's `.claude/`. Point at `${CLAUDE_PLUGIN_ROOT}/resources/settings-snippet.json`; do not write `.claude/settings.json` yourself.

Exit codes: 0 ok, 1 invalid policy/overlay or stale artifacts, 2 usage.
