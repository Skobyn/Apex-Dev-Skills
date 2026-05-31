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

Ruflo installs in **two independent layers** — provision and verify **both**:

- **Layer 1 — plugins (global, once per machine):** the `ruflo-*` plugins from the `ruvnet/ruflo` marketplace, installed into `~/.claude/plugins/`. These install reliably.
- **Layer 2 — project scaffold (per project):** `.claude/` agents/commands/skills + `CLAUDE.md` + config + the MCP server, written by `init` into the project (gitignored). **This is the layer that silently comes up short** — so verify it every time.

> Package-name note: the CLI is published as **`@claude-flow/cli`**; some versions also respond to **`ruflo`**. Commands below use `@claude-flow/cli`; if a command isn't found, retry with `npx ruflo@latest …` and the same flags. The marketplace is always `ruvnet/ruflo`.

### Layer 1 — plugins (skip if already present on this machine)

1. `claude plugin marketplace add ruvnet/ruflo`, then `claude plugin marketplace update ruflo`. Skip the add if already listed (`claude plugin marketplace list`).
2. Install the core plugins (you don't need all 33): **`ruflo-core`, `ruflo-swarm`, `ruflo-testgen`, `ruflo-intelligence`, `ruflo-rag-memory`** cover most workflows — `claude plugin install <name>@ruflo`. Add domain plugins (`ruflo-neural-trader`, `ruflo-iot-cognitum`, …) only if the project uses them.

### Layer 2 — project scaffold + MCP (per project, from the project root)

1. **Scaffold with the full preset** (non-interactive): `npx @claude-flow/cli@latest init --preset full`. **Use `full`, not `standard`/`minimal`** — a partial preset is the documented incomplete-scaffold bug: it lays down only **one** core agent instead of five and a fraction of the agents/commands/skills. This creates `.claude/`, `.claude-flow/`, and **appends** a hooks/routing block to `CLAUDE.md` (expected — it doesn't clobber the `@AGENTS.md` bridge).
   - Already initialized here? Run `npx @claude-flow/cli@latest upgrade` (preserves memory/data) + `init --add-missing` instead of a fresh init.
2. **Start the coordination daemon:** `npx @claude-flow/cli@latest daemon start`.
3. **Register AND start the MCP server — provisioning is not done until ruflo's MCP is live.** If `init` didn't register it, add it: `claude mcp add claude-flow -- npx -y @claude-flow/cli@latest`. Then confirm with `claude mcp list` (look for `claude-flow`/`ruflo`); the server starts when Claude Code connects to it. Skip the add if already registered. Report the MCP server as running, or surface the failure — do not report success while the MCP is absent.
4. **Verify the scaffold actually completed** (highest-value step — never skip). `doctor` only checks versions/daemon/DB/keys, **NOT agent completeness** — that's why b–d exist. Report each result:
   1. **Doctor:** `npx @claude-flow/cli@latest doctor --fix`.
   2. **Core agents MUST be five** (the common failure): `ls .claude/agents/core/` → expect `coder.md planner.md researcher.md reviewer.md tester.md`. One file (or a missing dir) = broken scaffold → repair (step 5) before continuing.
   3. **Sanity counts** (rough floors: agents 100+, commands 160+, skills 40+):
      ```bash
      for d in agents commands helpers skills; do
        printf "%-9s %s\n" "$d" "$(find .claude/$d -type f 2>/dev/null | wc -l | tr -d ' ')"
      done
      ```
   4. **Rigorous parity diff** (optional, when counts look short) vs a pinned clone of the installed version — compare **only `agents/ commands/ skills/`** (NEVER `helpers/`, `settings.json`, `mcp.json`, or `config/` — the repo's dev tree uses a different layout and produces false "missing" results). Exact diff in [references/provisioning-commands.md](references/provisioning-commands.md).
5. **Repair gaps if verification fails.** Fill missing files from a pinned clone with `rsync -a --ignore-existing` over `agents/ commands/ skills/` only — it adds missing files, never overwrites customizations, and since `.claude/` is gitignored it needs no commit. Re-run doctor + the core-agent check. If core/ still isn't five, **surface it loudly** in the final report rather than claiming success. Exact commands in the reference.
6. **Credentials note (don't block):** ruflo agents need `ANTHROPIC_API_KEY` at runtime. Add it to the project `.env` (already gitignored) via `.env.example` — do NOT prompt for or write a real key.
7. **gitignore:** ensure ruflo's local runtime/memory artifacts are ignored (e.g. `.claude-flow/` memory store, caches). Commit shareable config; ignore machine-local state.

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
- **Verify, don't assume.** ruflo Layer 2 can report "done" while incomplete — the `ls .claude/agents/core/` → 5-files check is mandatory, and the MCP server must be confirmed running.
- **No secrets.** Never write a real API key; route credentials through `.env` / `.env.example`.
- **Respect the toggle.** Only run this if dev-environment provisioning was enabled in the plan. Let the user pick "ruflo only", "Apex skills only", or "both" if they asked.
- **Report outcomes faithfully.** If a step fails (Node version, network, short scaffold, MCP not running), say so with the actual error — don't claim success on a failed or partial install.

After running, report exactly what was installed/updated/skipped/repaired, the **core-agent count (must be 5)** and whether the **MCP server is live**, plus any follow-ups (e.g. "add ANTHROPIC_API_KEY to .env", "restart Claude Code to load plugins").
