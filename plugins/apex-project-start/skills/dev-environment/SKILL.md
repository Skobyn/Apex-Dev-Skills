---
name: dev-environment
description: Install and configure the standard dev-environment must-haves after a new project is scaffolded — the ruflo multi-agent orchestration layer (ruvnet/ruflo) and the Apex-Dev-Skills Claude Code plugin suite (Skobyn/Apex-Dev-Skills). Invoked by /apex-project-start:new during provisioning; can also be used directly to (re)provision these tools on an existing project or machine. idempotent — updates if already present.
---

# dev-environment

Provisions the standard dev-environment tooling for a project after scaffolding. Two components: **ruflo** (orchestration/MCP/memory) and the **Apex-Dev-Skills** plugin suite. Run from the project root. Be **idempotent** — detect what's already installed and update rather than re-adding.

See [references/provisioning-commands.md](references/provisioning-commands.md) for the exact, verified commands, flags, and gotchas. Summary of the flow below.

## Preflight (verify, don't assume)

1. **Node 20+** — `node --version`. ruflo requires `>=20.0.0`; Node 22/25 have a known install issue (#1825). If the system Node is <20 or is 22/25, warn the user and prefer Node 20 LTS (`nvm use 20` / `fnm use 20`). Do not silently proceed on an unsupported version.
2. **Claude Code CLI** — `claude --version`. Needed for `claude mcp add` and `claude plugin` commands.
3. Confirm you are in the project root (the scaffolded directory).

## Step 1 — ruflo (ruvnet/ruflo)

1. Initialize in the project (non-interactive): `npx ruflo@latest init --yes`.
   - This creates `.claude/`, `.claude-flow/`, and **augments `CLAUDE.md`** with ruflo's hooks/routing block. That augmentation of the Apex Project Start-written `CLAUDE.md` is **expected and fine** — it appends, it doesn't clobber the `@AGENTS.md` bridge.
   - If ruflo was already initialized here, run `npx ruflo@latest upgrade` (preserves memory/data) and `npx ruflo@latest init --add-missing` instead of a fresh init.
2. Register the MCP server: `claude mcp add ruflo -- npx ruflo@latest mcp start`. Skip with a note if a `ruflo` MCP server is already registered (`claude mcp list`).
3. Health check: `npx ruflo doctor` (or `ruflo doctor`). Report the result.
4. **Credentials note (don't block):** ruflo agents need `ANTHROPIC_API_KEY` at runtime. Add it to the project `.env` (already gitignored) via `.env.example` — do NOT prompt for or write a real key.
5. **gitignore:** ensure ruflo's local runtime/memory artifacts are ignored (e.g. `.claude-flow/` memory store, caches). Commit shareable config; ignore machine-local state.

## Step 2 — Apex-Dev-Skills (Skobyn/Apex-Dev-Skills)

Marketplace name is **`apex-dev-skills`** (not the repo slug). Use non-interactive `claude plugin ...` forms since this runs in a session.

1. Add or update the marketplace:
   - If not present: `claude plugin marketplace add Skobyn/Apex-Dev-Skills`
   - If already present: `claude plugin marketplace update apex-dev-skills`
   - (Check first with `claude plugin marketplace list`.)
2. Install/refresh the 7 plugins (ruflo from Step 1 must come first — `apex-scope-loop` depends on the ruflo suite):
   `apex-scope-loop`, `apex-guardrails`, `apex-agent-team`, `apex-legacy-comprehension`, `apex-contracts-reliability`, `apex-agent-observability`, `apex-rag-memory` — each `@apex-dev-skills`.
3. Activate: `/reload-plugins` (or note that a restart is needed).

## Rules

- **Idempotent always.** Detect-then-act: update/upgrade if present, install if absent. Never double-add a marketplace or MCP server.
- **No secrets.** Never write a real API key; route credentials through `.env` / `.env.example`.
- **Respect the toggle.** Only run this if dev-environment provisioning was enabled in the plan. Let the user pick "ruflo only", "Apex skills only", or "both" if they asked.
- **Report outcomes faithfully.** If a step fails (e.g. Node version, network), say so with the actual error and continue with the rest where safe — don't claim success on a failed install.

After running, report exactly what was installed/updated/skipped and any follow-ups (e.g. "add ANTHROPIC_API_KEY to .env", "restart Claude Code to load plugins").
