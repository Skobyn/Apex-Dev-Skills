---
name: console
description: Start the apex-console admin page for this repository (keys, progress, software-factory metrics, review and tier knobs, kill switch, audit log) on 127.0.0.1 and print its address. Pass extra repository paths as $ARGUMENTS to register them too.
argument-hint: "[<repo-path> ...]"
---

You are starting the apex-console admin page. It is an admin layer: it reads what apex-scope-loop, apex-dispatch and apex-decision-layer write, and edits only the settings they honour. It never starts or drives work, and neither do you here.

1. Build the repo list: this repository (`git rev-parse --show-toplevel`), plus each word of `$ARGUMENTS` that is an existing directory. Ignore any other words.
2. Start the server in the background (it runs until stopped): `"${CLAUDE_PLUGIN_ROOT}/bin/apex-console" serve --repo "<repo>" [--repo "<repo>" ...]`. If port 4747 is taken, add `--port 0`.
3. Wait for its `CONSOLE_URL:` line and print that address. It carries a one-time token; the page needs it once.
4. Tell the user, briefly:
   - API keys are entered on the page's Keys tab, never in this chat. The console writes them to `~/.config/apex/keys.env` (mode 600) and never shows them again. Claude Code reads keys from its environment, so the shell profile must source that file; the Keys tab shows the line to add and whether it is there.
   - Knob changes are validated by each plugin's own validator, apply from the next check of a running task, and are logged on the Audit tab with Undo.
   - Stop the server with Ctrl-C in its terminal, or stop the background task.

Never print, echo or ask for a key value.
