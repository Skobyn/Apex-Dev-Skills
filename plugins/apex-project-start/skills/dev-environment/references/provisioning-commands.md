# Provisioning commands (verified 2026-05-31)

Exact commands for the two dev-environment must-haves. Run from the project root. Sources: [ruvnet/ruflo](https://github.com/ruvnet/ruflo) (README, USERGUIDE, install.sh), the maintainer's full-installation guide (audit-derived), and [Skobyn/Apex-Dev-Skills](https://github.com/Skobyn/Apex-Dev-Skills) (`.claude-plugin/marketplace.json`).

---

## ruflo (ruvnet/ruflo)

**What it is:** multi-agent orchestration layer for Claude Code. Ships an MCP server (~300 tools), hooks/routing, vector+RAG memory, and many agents/skills/commands.

**Two install layers** (provision + verify both):

| Layer | What | Source | Lives | Reliability |
|---|---|---|---|---|
| 1. Plugins | the `ruflo-*` plugins | `ruvnet/ruflo` marketplace | `~/.claude/plugins/` (global) | installs reliably |
| 2. Project scaffold | `.claude/` agents/commands/skills + `CLAUDE.md` + config + MCP | `@claude-flow/cli init` | `<project>/.claude/` (gitignored) | **can silently come up short — verify every time** |

**Package names:** CLI = **`@claude-flow/cli`** (some versions also respond to `ruflo`); marketplace = **`ruvnet/ruflo`**; MCP server name = **`claude-flow`**.

**Prereqs:** Node **>=20** (avoid 22/25, install issue #1825 — prefer Node 20 LTS). `claude` CLI present.

### Layer 1 — plugins (once per machine)
```bash
claude plugin marketplace add ruvnet/ruflo
claude plugin marketplace update ruflo
# install core set (not all 33 needed):
claude plugin install ruflo-core@ruflo
claude plugin install ruflo-swarm@ruflo
claude plugin install ruflo-testgen@ruflo
claude plugin install ruflo-intelligence@ruflo
claude plugin install ruflo-rag-memory@ruflo
# or browse/install interactively with:  /plugin
```

### Layer 2 — scaffold + daemon + MCP (per project)
```bash
node --version                                              # confirm >= 20
npx @claude-flow/cli@latest init --preset full             # FULL preset — not standard/minimal
npx @claude-flow/cli@latest daemon start                   # coordination daemon
# register the MCP server if init didn't:
claude mcp add claude-flow -- npx -y @claude-flow/cli@latest
claude mcp list                                            # confirm claude-flow/ruflo is registered + starts
```
`init` scaffolds `.claude/` + `.claude-flow/` and **appends** a hooks/routing block to `CLAUDE.md` (expected; doesn't clobber the `@AGENTS.md` bridge). **Provisioning isn't done until the MCP server is live.**

### Already initialized (idempotent update)
```bash
npx @claude-flow/cli@latest upgrade            # update helpers, preserve memory/data
npx @claude-flow/cli@latest init --add-missing # add newly-introduced agents/skills
```
Check MCP first with `claude mcp list`; if present, skip `claude mcp add`.

### Verify the scaffold (the step that catches the bug)
`doctor` checks versions/daemon/DB/keys — **not** agent/skill completeness. Run all of these after every `init`:
```bash
# 1. health check
npx @claude-flow/cli@latest doctor --fix

# 2. core agents MUST be FIVE, not one (this was the bug)
ls .claude/agents/core/
#    expect: coder.md  planner.md  researcher.md  reviewer.md  tester.md

# 3. sanity counts (rough floors: agents 100+, commands 160+, skills 40+)
for d in agents commands helpers skills; do
  printf "%-9s %s\n" "$d" "$(find .claude/$d -type f 2>/dev/null | wc -l | tr -d ' ')"
done
```
Rigorous parity check vs a pinned clone (compare **agents/ commands/ skills/ only**):
```bash
V=$(npx @claude-flow/cli@latest --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
git clone --depth 1 --branch "v$V" https://github.com/ruvnet/ruflo.git /tmp/ruflo-ref 2>/dev/null \
  || git clone --depth 1 https://github.com/ruvnet/ruflo.git /tmp/ruflo-ref
for sub in agents commands skills; do
  echo "### missing in project ($sub):"
  comm -23 <(cd /tmp/ruflo-ref/.claude/$sub && find . -type f|sort) \
           <(cd .claude/$sub && find . -type f|sort)
done
rm -rf /tmp/ruflo-ref
```
> **Don't diff `helpers/`, `settings.json`, `mcp.json`, or `config/`** against the repo — its `.claude/` is the maintainers' dev tree with a different layout for those, producing false "missing" results. Only `agents/`, `commands/`, `skills/` are meaningful.

### Repair gaps (if core/ is short or parity shows missing)
```bash
git clone --depth 1 https://github.com/ruvnet/ruflo.git /tmp/ruflo-ref
for sub in agents commands skills; do
  rsync -a --ignore-existing /tmp/ruflo-ref/.claude/$sub/ .claude/$sub/
done
rm -rf /tmp/ruflo-ref
```
`--ignore-existing` only **adds** missing files, never overwrites customizations. `.claude/` is gitignored, so this is safe and needs no commit. Re-run `doctor --fix` and `ls .claude/agents/core/` afterward. If core/ still isn't five, surface it loudly — don't claim success.

### One-page checklist
```
[ ] claude plugin marketplace add ruvnet/ruflo
[ ] claude plugin marketplace update ruflo
[ ] install plugins via /plugin (or claude plugin install <name>@ruflo)
[ ] cd project && npx @claude-flow/cli@latest init --preset full
[ ] npx @claude-flow/cli@latest daemon start
[ ] claude mcp add claude-flow -- npx -y @claude-flow/cli@latest ; claude mcp list
[ ] npx @claude-flow/cli@latest doctor --fix
[ ] ls .claude/agents/core/   -> MUST show 5 files
[ ] parity diff agents/commands/skills vs pinned clone
[ ] rsync --ignore-existing to fill any gaps
```

### Credentials (runtime only — never write real keys)
Agents need provider keys at run time, via env (put in gitignored `.env`):
- `ANTHROPIC_API_KEY` (required for Claude models)
- `OPENAI_API_KEY`, `GOOGLE_API_KEY` (optional)

`.env.example`:
```dotenv
# ruflo agent runtime (do not commit real values)
ANTHROPIC_API_KEY=
# OPENAI_API_KEY=
# GOOGLE_API_KEY=
```

### .gitignore additions
```gitignore
# ruflo local runtime / memory
.claude-flow/
*.ruflo.local
```
(Commit shareable config; ignore machine-local memory/cache. Whether to commit `.claude/` is a team choice.)

---

## Apex-Dev-Skills (Skobyn/Apex-Dev-Skills)

**What it is:** a Claude Code plugin **marketplace** (marketplace name **`apex-dev-skills`**) shipping 7 plugins from `plugins/`. Note: the marketplace name differs from the repo slug — always use `apex-dev-skills` in commands.

**The 7 plugins:**
`apex-scope-loop`, `apex-guardrails`, `apex-agent-team`, `apex-legacy-comprehension`, `apex-contracts-reliability`, `apex-agent-observability`, `apex-rag-memory`.
(`apex-scope-loop` depends on the ruflo suite for memory/swarm MCP tools → install ruflo first.)

### Add (first time)
```bash
claude plugin marketplace list                       # check if already added
claude plugin marketplace add Skobyn/Apex-Dev-Skills # owner/repo shorthand (or full .git URL)
```

### Update to latest (if marketplace already present)
```bash
claude plugin marketplace update apex-dev-skills
```

### Install / refresh all 7
```bash
claude plugin install apex-scope-loop@apex-dev-skills
claude plugin install apex-guardrails@apex-dev-skills
claude plugin install apex-agent-team@apex-dev-skills
claude plugin install apex-legacy-comprehension@apex-dev-skills
claude plugin install apex-contracts-reliability@apex-dev-skills
claude plugin install apex-agent-observability@apex-dev-skills
claude plugin install apex-rag-memory@apex-dev-skills
```
Then `/reload-plugins` in the session (or restart Claude Code) to activate.

### Other non-interactive forms
```bash
claude plugin list                                   # what's installed
claude plugin uninstall <name>@apex-dev-skills
claude plugin marketplace remove apex-dev-skills
claude --plugin apex-scope-loop@apex-dev-skills      # enable at launch
```

Note: `apex-agent-observability` and `apex-rag-memory` ship their own MCP servers (`.mcp.json`); they start automatically when enabled.
