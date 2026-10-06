# ruflo provisioning (optional)

> **Legacy:** describes the optional ruflo/claude-flow layer. Nothing in Apex-Dev-Skills requires it; apex-scope-loop 0.3.0 runs on plain Claude Code subagents and seeds memory only when `APEX_MEMORY_CMD` is set. The commands below are still current for anyone who opts in.

Use this only when the user chose "both" or "ruflo only" during provisioning.

### Procedure

Ruflo installs in **two independent layers** — provision and verify **both**:

- **Layer 1 — plugins (global, once per machine):** the `ruflo-*` plugins from the `ruvnet/ruflo` marketplace, installed into `~/.claude/plugins/`. These install reliably.
- **Layer 2 — project scaffold (per project):** `.claude/` agents/commands/skills + `CLAUDE.md` + config + the MCP server, written by `init` into the project (gitignored). **This is the layer that silently comes up short** — so verify it every time.

> Package-name note: the CLI is published as **`@claude-flow/cli`**; some versions also respond to **`ruflo`**. Commands below use `@claude-flow/cli`; if a command isn't found, retry with `npx ruflo@latest …` and the same flags. The marketplace is always `ruvnet/ruflo`.

#### Layer 1 — plugins (skip if already present on this machine)

1. `claude plugin marketplace add ruvnet/ruflo`, then `claude plugin marketplace update ruflo`. Skip the add if already listed (`claude plugin marketplace list`).
2. Install the core plugins (you don't need all 33): **`ruflo-core`, `ruflo-swarm`, `ruflo-testgen`, `ruflo-intelligence`, `ruflo-rag-memory`** cover most workflows — `claude plugin install <name>@ruflo`. Add domain plugins (`ruflo-neural-trader`, `ruflo-iot-cognitum`, …) only if the project uses them.

#### Layer 2 — project scaffold + MCP (per project, from the project root)

1. **Scaffold with the full preset** (non-interactive): `npx @claude-flow/cli@latest init --preset full`. **Use `full`, not `standard`/`minimal`** — a partial preset is the documented incomplete-scaffold bug: it lays down only **one** core agent instead of five and a fraction of the agents/commands/skills. This creates `.claude/`, `.claude-flow/`, and **appends** a hooks/routing block to `CLAUDE.md` (expected — it doesn't clobber the `@AGENTS.md` bridge).
   - Already initialized here? Run `npx @claude-flow/cli@latest upgrade` (preserves memory/data) + `init --add-missing` instead of a fresh init.
2. **Start the coordination daemon:** `npx @claude-flow/cli@latest daemon start`.
3. **Register, APPROVE, and start the MCP server — provisioning is not done until ruflo's MCP is live *and approved*.**
   1. **Register:** if `init` didn't, `claude mcp add claude-flow -- npx -y @claude-flow/cli@latest`. Skip if already registered (`claude mcp list`).
   2. **Approve (the step `init` forgets — this is the common "⏸ Pending approval" cause):** ruflo's settings template declares `enabledMcpjsonServers: ["claude-flow"]`, but `init` does not write it into the project, so the server stays pending. Add `claude-flow` to **`enabledMcpjsonServers`** in the project **`.claude/settings.json`** (merge into the existing array, don't clobber; back up first). That's the documented project-scope approval Claude Code reads at startup. Belt-and-suspenders: the same array lives under this project's entry in **`~/.claude.json`** (where the interactive trust prompt records approval) — set it there too. Exact merge snippet in [the command reference below](#command-reference-verified-2026-05-31). Do **not** use `enableAllProjectMcpServers: true` (approves everything — too broad).
   3. **Confirm:** `claude mcp list` shows `claude-flow`; it starts when Claude Code (re)connects (a restart/`/reload` may be needed for the approval to take effect). Report it as approved + running, or surface the failure — never report success while the MCP is pending or absent.
4. **Verify the scaffold actually completed** (highest-value step — never skip). `doctor` only checks versions/daemon/DB/keys, **NOT agent completeness** — that's why b–d exist. Report each result:
   1. **Doctor:** `npx @claude-flow/cli@latest doctor --fix`.
   2. **Core agents MUST be five** (the common failure): `ls .claude/agents/core/` → expect `coder.md planner.md researcher.md reviewer.md tester.md`. One file (or a missing dir) = broken scaffold → repair (step 5) before continuing.
   3. **Sanity counts** (rough floors: agents 100+, commands 160+, skills 40+):
      ```bash
      for d in agents commands helpers skills; do
        printf "%-9s %s\n" "$d" "$(find .claude/$d -type f 2>/dev/null | wc -l | tr -d ' ')"
      done
      ```
   4. **Rigorous parity diff** (optional, when counts look short) vs a pinned clone of the installed version — compare **only `agents/ commands/ skills/`** (NEVER `helpers/`, `settings.json`, `mcp.json`, or `config/` — the repo's dev tree uses a different layout and produces false "missing" results). Exact diff in [the command reference below](#command-reference-verified-2026-05-31).
5. **Repair gaps if verification fails.** Fill missing files from a pinned clone with `rsync -a --ignore-existing` over `agents/ commands/ skills/` only — it adds missing files, never overwrites customizations, and since `.claude/` is gitignored it needs no commit. Re-run doctor + the core-agent check. If core/ still isn't five, **surface it loudly** in the final report rather than claiming success. Exact commands in the reference.
6. **Credentials note (don't block):** ruflo agents need `ANTHROPIC_API_KEY` at runtime. Add it to the project `.env` (already gitignored) via `.env.example` — do NOT prompt for or write a real key.
7. **gitignore:** ensure ruflo's local runtime/memory artifacts are ignored (e.g. `.claude-flow/` memory store, caches). Commit shareable config; ignore machine-local state.

### Command reference (verified 2026-05-31)

**What it is:** multi-agent orchestration layer for Claude Code. Ships an MCP server (~300 tools), hooks/routing, vector+RAG memory, and many agents/skills/commands.

**Two install layers** (provision + verify both):

| Layer | What | Source | Lives | Reliability |
|---|---|---|---|---|
| 1. Plugins | the `ruflo-*` plugins | `ruvnet/ruflo` marketplace | `~/.claude/plugins/` (global) | installs reliably |
| 2. Project scaffold | `.claude/` agents/commands/skills + `CLAUDE.md` + config + MCP | `@claude-flow/cli init` | `<project>/.claude/` (gitignored) | **can silently come up short — verify every time** |

**Package names:** CLI = **`@claude-flow/cli`** (some versions also respond to `ruflo`); marketplace = **`ruvnet/ruflo`**; MCP server name = **`claude-flow`**.

**Prereqs:** Node **>=20** (avoid 22/25, install issue #1825 — prefer Node 20 LTS). `claude` CLI present.

#### Layer 1 — plugins (once per machine)
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

#### Layer 2 — scaffold + daemon + MCP (per project)
```bash
node --version                                              # confirm >= 20
npx @claude-flow/cli@latest init --preset full             # FULL preset — not standard/minimal
npx @claude-flow/cli@latest daemon start                   # coordination daemon
# register the MCP server if init didn't:
claude mcp add claude-flow -- npx -y @claude-flow/cli@latest
claude mcp list                                            # confirm claude-flow/ruflo is registered + starts
```
`init` scaffolds `.claude/` + `.claude-flow/` and **appends** a hooks/routing block to `CLAUDE.md` (expected; doesn't clobber the `@AGENTS.md` bridge). **Provisioning isn't done until the MCP server is live.**

#### Approve the MCP server (the step `init` forgets)

After registering, the server is **⏸ Pending approval** until `claude-flow` is in `enabledMcpjsonServers`. ruflo's settings template declares this key, but `init` doesn't write it into the project — so approve it explicitly. **Don't** use `enableAllProjectMcpServers: true` (approves every project MCP — too broad).

Project scope — `.claude/settings.json` (the file the running session reads; primary fix), merge-preserving + backup:
```bash
[ -f .claude/settings.json ] && cp .claude/settings.json .claude/settings.json.bak
node -e '
const fs=require("fs"), p=".claude/settings.json";
const s=fs.existsSync(p)?JSON.parse(fs.readFileSync(p,"utf8")):{};
const set=new Set(s.enabledMcpjsonServers||[]); set.add("claude-flow");
s.enabledMcpjsonServers=[...set];
fs.writeFileSync(p, JSON.stringify(s,null,2)+"\n");
console.log("enabledMcpjsonServers:", s.enabledMcpjsonServers);
'
```
User scope (belt-and-suspenders) — this project's entry in `~/.claude.json` (where the interactive trust prompt records approval), merge-preserving + backup:
```bash
cp ~/.claude.json ~/.claude.json.bak-preapprove
node -e '
const fs=require("fs"), os=require("os"), p=os.homedir()+"/.claude.json";
const j=JSON.parse(fs.readFileSync(p,"utf8"));
const key=process.cwd();
j.projects=j.projects||{}; j.projects[key]=j.projects[key]||{};
const set=new Set(j.projects[key].enabledMcpjsonServers||[]); set.add("claude-flow");
j.projects[key].enabledMcpjsonServers=[...set];
fs.writeFileSync(p, JSON.stringify(j,null,2)+"\n");
console.log("approved for", key, "->", j.projects[key].enabledMcpjsonServers);
'
```
Then `claude mcp list` (or restart / `/reload`) — `claude-flow` should be approved, not pending. `claude mcp get claude-flow` is an interactive-trust reader and may still show "pending"; the settings-based approval is applied by the app at startup, so trust the settings files + a reconnect.

#### Already initialized (idempotent update)
```bash
npx @claude-flow/cli@latest upgrade            # update helpers, preserve memory/data
npx @claude-flow/cli@latest init --add-missing # add newly-introduced agents/skills
```
Check MCP first with `claude mcp list`; if present, skip `claude mcp add`.

#### Verify the scaffold (the step that catches the bug)
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

#### Repair gaps (if core/ is short or parity shows missing)
```bash
git clone --depth 1 https://github.com/ruvnet/ruflo.git /tmp/ruflo-ref
for sub in agents commands skills; do
  rsync -a --ignore-existing /tmp/ruflo-ref/.claude/$sub/ .claude/$sub/
done
rm -rf /tmp/ruflo-ref
```
`--ignore-existing` only **adds** missing files, never overwrites customizations. `.claude/` is gitignored, so this is safe and needs no commit. Re-run `doctor --fix` and `ls .claude/agents/core/` afterward. If core/ still isn't five, surface it loudly — don't claim success.

#### One-page checklist
```
[ ] claude plugin marketplace add ruvnet/ruflo
[ ] claude plugin marketplace update ruflo
[ ] install plugins via /plugin (or claude plugin install <name>@ruflo)
[ ] cd project && npx @claude-flow/cli@latest init --preset full
[ ] npx @claude-flow/cli@latest daemon start
[ ] claude mcp add claude-flow -- npx -y @claude-flow/cli@latest ; claude mcp list
[ ] approve MCP: add "claude-flow" to enabledMcpjsonServers in .claude/settings.json (+ ~/.claude.json)
[ ] npx @claude-flow/cli@latest doctor --fix
[ ] ls .claude/agents/core/   -> MUST show 5 files
[ ] parity diff agents/commands/skills vs pinned clone
[ ] rsync --ignore-existing to fill any gaps
```

#### Credentials (runtime only — never write real keys)
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

#### .gitignore additions
```gitignore
# ruflo local runtime / memory
.claude-flow/
*.ruflo.local
```
(Commit shareable config; ignore machine-local memory/cache. Whether to commit `.claude/` is a team choice.)
