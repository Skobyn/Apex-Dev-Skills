# Apex Project Start

**Interview-first greenfield project initializer for Claude Code.** Apex Project Start takes an empty directory from nothing to a fully-governed, verified, first-commit-ready repository — without dumping generic boilerplate.

It combines the two things the research says actually work:

- **The "golden path" / paved-road model** from mature engineering orgs (Spotify, Netflix, Google) — a new repo is born *governed*: README/LICENSE/CI/linting/tests/security/ADRs from day zero, because the secure and correct path should be the default, not a later audit.
- **The interview → plan → generate → verify loop** from modern agentic tooling (Claude's own gated `/init`, Kiro, Spec-Kit, Devin) — elicit the hard parts, present a plan, get approval, scaffold, then check the result with a fresh-context reviewer. Thin durable artifacts, not a markdown flood.

## What it does

`/apex-project-start:new [target-directory]` runs gated phases:

0. **Discovery** — opens with "what are you trying to build / what problem are you solving?", then *researches that context* (web + Context7) and asks 2–3 clarifying questions before any checklist. Comes back informed instead of interrogating you about things it could look up.
1. **Interview** — stack, project type, audience, governance level, license, dev-environment provisioning. Informed by discovery; proposes defaults rather than asking open questions.
2. **Plan & gate** — shows the exact file list and provisioning steps it will run; waits for your approval.
3. **Scaffold + steering** — generates the governed file set (stack-aware) + AGENTS.md (cross-tool source of truth) + CLAUDE.md bridge + bootstrap ADR.
4. **Dev environment** — installs/configures the standard must-haves: **ruflo** (orchestration/MCP/memory) and the **Apex-Dev-Skills** plugin suite. Idempotent.
5. **Verify & finalize** — a fresh-context auditor checks for secret leaks, broken tests, un-passable CI, and dangling placeholders; then `git init`, install, test, lint, and a first Conventional Commit.

## Supported stacks

| Stack | Defaults |
|---|---|
| TypeScript / JavaScript | pnpm · strict tsconfig · Biome · Vitest |
| Python | uv · Ruff · pyright · pytest · src layout |
| Go | modules · golangci-lint · gofumpt |
| Rust | cargo · clippy · rustfmt · pinned toolchain |

Governance is **full paved-road by default and toggleable down**: community-health files, Lefthook hooks (pre-commit + pre-push, mirrored by CI as the real gate), Conventional Commits, CI (lint/typecheck/test/build matrix + Dependabot + CodeQL + secret scanning), **GitHub hardening** (rulesets, OIDC, merge queue, SHA-pinned least-privilege actions, environments, GitHub Apps), warnings-as-errors, ADRs, Keep-a-Changelog, AGENTS.md/CLAUDE.md, and a periodic **maintenance** layer. Optional **sin-bin** quarantine dir and **SonarQube Cloud** quality gate (Clean-as-You-Code).

## Periodic maintenance (dead-code sweep)

Dead-code tools are heuristic, so they're set up as a **periodic, human-triaged sweep — not a per-PR gate**. Each new project gets:

- a tracked `.apex/maintenance.json` (last-run dates per task),
- a non-destructive `scripts/dead-code-sweep.sh` (Python: `vulture src/ --min-confidence 80 --sort-by-size`; TS: `knip`; Go: `deadcode`; Rust: compiler `-D warnings` + `cargo udeps`), and
- a **Maintenance** section in `AGENTS.md` that tells future agents to check the last-run on session start and, if the dead-code sweep is **>3 days** stale, remind you and offer to run it (triage → propose deletions for approval → whitelist false positives → stamp the run).

So the sweep stays reliable without depending on a cron that may never fire.

## Dev-environment provisioning

After scaffolding, Apex Project Start (optionally) installs and configures the standard must-haves — idempotently, updating if already present:

- **[ruflo](https://github.com/ruvnet/ruflo)** — multi-agent orchestration layer: `npx ruflo@latest init --yes`, registers the MCP server, runs `ruflo doctor`. Needs Node 20+; routes `ANTHROPIC_API_KEY` through `.env` (never a committed key).
- **[Apex-Dev-Skills](https://github.com/Skobyn/Apex-Dev-Skills)** (marketplace `apex-dev-skills`) — installs/updates its 7 Claude Code plugins (`apex-scope-loop`, `apex-guardrails`, `apex-agent-team`, `apex-legacy-comprehension`, `apex-contracts-reliability`, `apex-agent-observability`, `apex-rag-memory`). ruflo installs first, since `apex-scope-loop` depends on it.

Choose **both / ruflo only / Apex skills only / skip** during the interview.

## Components

```
apex-project-start/
├── .claude-plugin/
│   └── plugin.json            # manifest
├── commands/
│   └── new.md                 # /apex-project-start:new — the interview-first orchestrator
├── skills/
│   ├── repo-scaffold/         # directory skeletons + governed file set + per-stack refs
│   ├── steering-docs/         # AGENTS.md / CLAUDE.md / ADR authoring
│   └── dev-environment/       # ruflo + Apex-Dev-Skills provisioning (idempotent)
├── agents/
│   └── apex-project-auditor.md     # fresh-context pre-commit verifier
└── README.md
```

## Install

Ships in the **Apex-Dev-Skills** marketplace (`apex-dev-skills`):
```bash
/plugin marketplace add Skobyn/Apex-Dev-Skills    # or: marketplace update apex-dev-skills
/plugin install apex-project-start@apex-dev-skills
```
Then: `/apex-project-start:new ./my-new-project`

Test locally from a clone without the marketplace:
```bash
claude --plugin-dir ./plugins/apex-project-start
claude plugin validate ./plugins/apex-project-start --strict
```

## Feature development after init

The steering files this plugin writes into every new project (`AGENTS.md` / `CLAUDE.md`) instruct future agents to build features *within* the scaffolded frameworks using the Apex workflow:

- **apex-plan** — `/apex-scope-loop:start <feature-slug>` to co-author an ADR + phased, gated build plan before coding non-trivial work.
- **apex-loop** — `/apex-scope-loop:iterate <plan-path>` to execute the plan phase-by-phase (swarm dispatch, acceptance gates, checkbox tracking).

This closes the loop: Apex Project Start lays the governed foundation; apex-plan/apex-loop drive every subsequent feature through it.

## Design notes

- **AGENTS.md is canonical; CLAUDE.md bridges to it** via `@AGENTS.md` — one source of truth, no duplicated rules across files.
- **Progressive disclosure:** each skill's `SKILL.md` is short; stack-specific templates live in `references/` and load only when the matching stack is chosen.
- **The auditor never trusts the scaffolder** — it runs in its own context and actually executes the test/lint commands, so "tests pass" means tests were run.

## License

MIT — see [LICENSE](LICENSE).
