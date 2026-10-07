---
name: compile
description: Compile apex-dispatch's routing policy (compile.sh) into its committed artifacts — compiled policy, generated agents, settings snippet, hooks.json — or check them for staleness (--check), print this repo's overlay-merged policy (--print-merged), or validate an overlay (--overlay PATH). Pass the mode as $ARGUMENTS; empty means --check.
argument-hint: "[--check | --print-merged] [--overlay <path>]"
---

You are running the apex-dispatch policy compiler with `$ARGUMENTS`.

1. If `$ARGUMENTS` is empty, run `${CLAUDE_PLUGIN_ROOT}/scripts/compile.sh --check` (read-only). Otherwise run `${CLAUDE_PLUGIN_ROOT}/scripts/compile.sh $ARGUMENTS`.
   - `--check` regenerates in memory and exits 1 naming every `stale:`, `missing:` or `not generated:` artifact. It writes nothing.
   - `--print-merged [--overlay PATH]` prints the policy this repo actually routes with: the plugin default plus `.claude/apex-dispatch/policy.json` (or `$APEX_DISPATCH_POLICY`). Use it to answer "what will route.sh do here?".
   - `--overlay PATH` on a plain or `--check` run also validates that overlay; an invalid overlay exits 1 with every problem named (an overlay can configure within the hard rules but never weaken confinement: no new providers, no tier changes, roles may only lose tools, hard rules are append-only).
   - A plain run (no `--check`) **rewrites files inside the plugin** (`resources/compiled/`, `agents/`, `resources/settings-snippet.json`, `hooks/hooks.json`). Only do that when the user is developing the plugin and asked for it; artifacts come from the default policy, and a per-repo overlay never needs a recompile because readers merge it at runtime.
2. Report the result plainly: clean, or the list of stale/invalid items verbatim. Never hand-edit `agents/*.md` to make `--check` pass; edit `resources/dispatch.default.json` and recompile.
3. To make settings effective for cloud sessions, the user commits the overlay and the settings snippet's `permissions` under the repo's `.claude/`. Point at `${CLAUDE_PLUGIN_ROOT}/resources/settings-snippet.json`; do not write `.claude/settings.json` yourself.

Exit codes: 0 ok, 1 invalid policy/overlay or stale artifacts, 2 usage.
