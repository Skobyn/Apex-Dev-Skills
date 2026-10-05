# apex-dispatch — Phase 0 spike results

**Date:** 2026-10-05 · **Claude Code:** 2.1.289 (cloud container, Linux) · **Spec:** [§11](../superpowers/specs/2026-10-05-apex-dispatch-design.md#11-verified-refuted-and-what-phase-0-must-settle)

Method: two throwaway plugins (`probe-a`, `probe-b`) whose hooks log every event's stdin and environment to a JSONL file and, when an env flag is set, answer with `updatedInput`, `deny`, `updatedToolOutput` + `additionalContext`, or a Stop `exit 2`. Each spike is one `claude -p --plugin-dir … --output-format json` run in an empty git repo. Total spend about $0.25. `doctor.sh` re-runs the cheap structural subset; the live ones are listed so they can be re-run on each Claude Code minor.

## Results

| # | Spike | Result | Consequence for the design |
|---|---|---|---|
| 1 | PreToolUse `Agent` payload | **Confirmed.** `tool_input` carries `subagent_type`, `model`, `description`, `prompt`, `run_in_background` | `pre-agent.sh` reads these fields as specified |
| 2 | PreToolUse deny on `Agent` under `bypassPermissions` | **Confirmed.** Spawn refused; the model was told a hook denied it | Deny-on-mismatch is a real enforcement layer |
| 3 | `updatedInput` changes the subagent model | **Confirmed.** `model:"opus"` rewritten to `haiku`; `resolvedModel` = `claude-haiku-4-5-20251001` | `updatedInput` is usable as the second layer |
| 4 | Two plugins both writing `updatedInput` | **Last writer wins.** Plugin A wrote `haiku`, plugin B (loaded second) wrote `sonnet`; the subagent ran on `claude-sonnet-5-5` | Deny-on-mismatch first, `updatedInput` second, exactly as §5.3 E says; doctor warns when another plugin registers an `Agent` PreToolUse hook |
| 5 | `agent_id` / `agent_type` in tool-event stdin inside a subagent | **Present.** A `Read` called by subagent `probe-a:ro` arrived with `agent_id` and `agent_type: "probe-a:ro"`; main-thread events carry neither | §5.3 F identity enforcement is available on this version; §13's first risk is retired for 2.1.289 |
| 6 | PostToolUse `Agent` response fields | **`tool_response` keys:** `agentId`, `agentType`, `content`, `prompt`, `resolvedModel`, `status`, `totalDurationMs`, `totalTokens`, `totalToolUseCount`, `usage`. **No `modelsUsed`.** | `post-agent.sh` keys on `resolvedModel`; `modelsUsed` is read only if present |
| 7 | SubagentStart / SubagentStop payloads | **Confirmed.** Start: `agent_id`, `agent_type`. Stop: adds `agent_transcript_path`, `last_assistant_message`, `stop_hook_active` | `subagent-stop.sh` takes the `VERDICT:` line from `last_assistant_message` |
| 8 | Plugin agent frontmatter `tools` / `disallowedTools` | **Honoured.** An agent with `tools: Read, Grep, Glob` and `disallowedTools: Bash, Edit, Write` reported no Bash tool | Loader layer C holds |
| 9 | PostToolUse `updatedToolOutput` on `Bash` from a command hook | **Not applied.** The model saw the real `seq` output; the `additionalContext` from the same reply was delivered | `post-bash-prune.sh` keeps full logs and adds a summary through `additionalContext`; it does not trim output (the review finding on PR 13 is confirmed) |
| 10 | Stop hook `exit 2` | **Confirmed.** Blocked once; the re-fired Stop carried `stop_hook_active: true` and was allowed | `stop-gate.sh` guards on `stop_hook_active` |
| 11 | `${CLAUDE_PLUGIN_ROOT}` inside hooks | **Set** for every hook event | Hooks reference sibling files through it |
| 12 | `CLAUDE_SESSION_ID` in the hook environment | **Not set.** Payload `session_id` is always present | Observability keys traces on payload `session_id` |
| 13 | Deny rule `Bash(* --dangerously-*)` matching mid-string | **Matches.** `echo probe --dangerously-skip-permissions` was denied under `bypassPermissions`; `echo plain-ok` ran | The settings snippet's bypass-flag denials work as written |
| 14 | `claude -p --plugin-dir` fires plugin hooks | **Confirmed** in every run above | `worker-claude-p.sh` loads apex-dispatch + apex-guardrails with `--plugin-dir` |
| 15 | `claude -p --agent <plugin>:<agent>` | **Confirmed.** The plugin agent ran with its own model (`haiku`) and tool set under `--permission-mode dontAsk` | The claude-p worker selects its role with `--agent apex-dispatch:<role>` |
| 16 | `--bare` | **Skips hooks from settings and installed plugins** (`claude --help`) | The claude-p worker never passes `--bare` |
| 17 | `--permission-prompts none` | **Exists**; anything that would prompt is denied automatically | Used by the claude-p worker |
| 18 | `plugin.json` `dependencies` under `claude plugin validate` | **Passes validation** | apex-dispatch may declare a dependency on apex-scope-loop; sibling resolution still has the `APEX_SCOPE_LOOP_ROOT` override |
| 19 | `codex exec` sentinel flow | **Not run.** `codex` is not installed in this container | `worker-codex.sh` is exercised against a fake `codex` in smoke; a live round trip stays open |
| 20 | `Bash(*/apex-execute/scripts/*)` in `--allowedTools`, `experimental.cacheTtl` | **Not run** | Not load-bearing for v0.1; left open |

## What stays open

- Spike 19 (live Codex) and spike 20. ADR-0001 of apex-dispatch therefore stays **Proposed**.
- Results are for 2.1.289 only. `doctor.sh` records the Claude Code version it saw, and the live spikes above should be re-run on each minor.
