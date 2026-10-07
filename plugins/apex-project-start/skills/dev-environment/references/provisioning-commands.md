# Provisioning commands (verified 2026-05-31)

Exact commands for the dev-environment must-haves. Run from the project root. Source: [Skobyn/Apex-Dev-Skills](https://github.com/Skobyn/Apex-Dev-Skills) (`.claude-plugin/marketplace.json`).

The optional ruflo layer (two install layers, MCP approval, scaffold verification, repair, `.env` and `.gitignore` additions) lives in [../docs/legacy/ruflo-provisioning.md](../docs/legacy/ruflo-provisioning.md) (optional).

---

## Apex-Dev-Skills (Skobyn/Apex-Dev-Skills)

**What it is:** a Claude Code plugin **marketplace** (marketplace name **`apex-dev-skills`**) shipping its plugins from `plugins/`; the project set below is 8. Note: the marketplace name differs from the repo slug — always use `apex-dev-skills` in commands.

**The 8 plugins:**
`apex-scope-loop`, `apex-dispatch`, `apex-guardrails`, `apex-agent-team`, `apex-legacy-comprehension`, `apex-contracts-reliability`, `apex-agent-observability`, `apex-rag-memory`.
(None of them need ruflo. ruflo is optional; apex-scope-loop seeds memory through it only when `APEX_MEMORY_CMD` is set.)

### Add (first time)
```bash
claude plugin marketplace list                       # check if already added
claude plugin marketplace add Skobyn/Apex-Dev-Skills # owner/repo shorthand (or full .git URL)
```

### Update to latest (if marketplace already present)
```bash
claude plugin marketplace update apex-dev-skills
```

### Install / refresh all 8
```bash
claude plugin install apex-scope-loop@apex-dev-skills
claude plugin install apex-dispatch@apex-dev-skills
claude plugin install apex-guardrails@apex-dev-skills
claude plugin install apex-agent-team@apex-dev-skills
claude plugin install apex-legacy-comprehension@apex-dev-skills
claude plugin install apex-contracts-reliability@apex-dev-skills
claude plugin install apex-agent-observability@apex-dev-skills
claude plugin install apex-rag-memory@apex-dev-skills
```
Then `/reload-plugins` in the session (or restart Claude Code) to activate.

### apex-dispatch settings snippet and memory seeding
After install, apply apex-dispatch's settings snippet: merge the `permissions.deny` rules (and, if the user wants OS sandboxing, the `sandbox` block) from apex-dispatch's `resources/settings-snippet.json` into the project's `.claude/settings.json` — merge, never clobber; back up first — and commit it so cloud sessions get it too. `/apex-dispatch:doctor` reports whether it is applied and prints the snippet's path. Memory seeding is optional: apex-scope-loop seeds a plan record only when `APEX_MEMORY_CMD` is set (e.g. to a ruflo `memory store` command); unset, it skips quietly.

### Other non-interactive forms
```bash
claude plugin list                                   # what's installed
claude plugin uninstall <name>@apex-dev-skills
claude plugin marketplace remove apex-dev-skills
claude --plugin apex-scope-loop@apex-dev-skills      # enable at launch
```

Note: `apex-agent-observability` and `apex-rag-memory` ship their own MCP servers (`.mcp.json`); they start automatically when enabled.
