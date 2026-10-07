---
name: dev-environment
description: Install and configure the standard dev-environment must-haves after a new project is scaffolded — the Apex-Dev-Skills Claude Code plugin suite and, optionally, the ruflo multi-agent orchestration layer (Skobyn/Apex-Dev-Skills). Invoked by /apex-project-start:new during provisioning; can also be used directly to (re)provision these tools on an existing project or machine. idempotent — updates if already present.
---

# dev-environment

Provisions the standard dev-environment tooling for a project after scaffolding. Two components, in this order: the **Apex-Dev-Skills** plugin suite and, optionally, **ruflo** (orchestration/MCP/memory). Run from the project root. Be **idempotent** — detect what's already installed and update rather than re-adding.

See [references/provisioning-commands.md](references/provisioning-commands.md) for the exact, verified commands, flags, and gotchas. Summary of the flow below.

## Preflight (verify, don't assume)

1. **Node 20+** (only for the optional ruflo layer) — `node --version`. ruflo requires `>=20.0.0`; Node 22/25 have a known install issue (#1825). If the system Node is <20 or is 22/25, warn the user and prefer Node 20 LTS (`nvm use 20` / `fnm use 20`). Do not silently proceed on an unsupported version.
2. **Claude Code CLI** — `claude --version`. Needed for `claude mcp add` and `claude plugin` commands.
3. Confirm you are in the project root (the scaffolded directory).

## Step 1 — Apex-Dev-Skills (Skobyn/Apex-Dev-Skills)

Marketplace name is **`apex-dev-skills`** (not the repo slug). Use non-interactive `claude plugin ...` forms since this runs in a session.

1. Add or update the marketplace:
   - If not present: `claude plugin marketplace add Skobyn/Apex-Dev-Skills`
   - If already present: `claude plugin marketplace update apex-dev-skills`
   - (Check first with `claude plugin marketplace list`.)
2. Install/refresh the 8 plugins (none of them need the optional ruflo layer):
   `apex-scope-loop`, `apex-dispatch`, `apex-guardrails`, `apex-agent-team`, `apex-legacy-comprehension`, `apex-contracts-reliability`, `apex-agent-observability`, `apex-rag-memory` — each `@apex-dev-skills`. `apex-dispatch` (routing + enforcement hooks) and `apex-guardrails` (always-on deny hooks) are part of the default set, not extras.
3. Activate: `/reload-plugins` (or note that a restart is needed).
4. Settings snippet. After install, apply apex-dispatch's settings snippet: merge the `permissions.deny` rules (and, if the user wants OS sandboxing, the `sandbox` block) from apex-dispatch's `resources/settings-snippet.json` into the project's `.claude/settings.json` — merge, never clobber; back up first — and commit it so cloud sessions get it too. `/apex-dispatch:doctor` reports whether it is applied and prints the snippet's path. Memory seeding is optional: apex-scope-loop seeds a plan record only when `APEX_MEMORY_CMD` is set (e.g. to a ruflo `memory store` command); unset, it skips quietly.

## Step 2 — ruflo (optional, only if opted in)

Skip this step unless the user opted in to the optional ruflo layer ("both" or "ruflo only"). Nothing in the Apex suite needs it; apex-scope-loop seeds memory through it only when `APEX_MEMORY_CMD` is set.

If opted in, follow [docs/legacy/ruflo-provisioning.md](docs/legacy/ruflo-provisioning.md) (optional): two install layers, MCP approval, the five-core-agent check, and repair.

## Rules

- **Idempotent always.** Detect-then-act: update/upgrade if present, install if absent. Never double-add a marketplace or MCP server.
- **Verify, don't assume.** If the optional ruflo layer was installed, its Layer 2 can report "done" while incomplete — the `ls .claude/agents/core/` → 5-files check is mandatory, and the MCP server must be confirmed running.
- **No secrets.** Never write a real API key; route credentials through `.env` / `.env.example`.
- **Respect the toggle.** Only run this if dev-environment provisioning was enabled in the plan. Default is "Apex skills only"; let the user pick "both" or "ruflo only" (ruflo is optional) if they asked.
- **Report outcomes faithfully.** If a step fails (Node version, network, short scaffold, MCP not running), say so with the actual error — don't claim success on a failed or partial install.

After running, report exactly what was installed/updated/skipped/repaired, and, if the optional ruflo layer was installed, the **core-agent count (must be 5)** and whether the **MCP server is live**, plus any follow-ups (e.g. "add ANTHROPIC_API_KEY to .env", "restart Claude Code to load plugins").
