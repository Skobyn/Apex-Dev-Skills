---
description: Start a brand-new software project the right way. Interview-first, gated greenfield initializer — opens with "what are you trying to build?", researches the context, asks a few clarifiers, then a structured interview, then scaffolds a fully-governed repo (README/LICENSE/CI/linting/tests/AGENTS.md/ADRs), provisions dev-environment must-haves (ruflo + Apex-Dev-Skills), and verifies it before the first commit. Use when the user says they want to start/create/bootstrap/scaffold/initialize a NEW project, repo, service, library, or app. Do NOT use to add features to an existing codebase.
argument-hint: [target-directory]
allowed-tools: Read, Write, Edit, Bash, AskUserQuestion, Skill, Task, Glob, WebSearch, WebFetch
---

# Apex Project Start — new project initializer

You are running the Apex Project Start greenfield initializer. Your job is to take an empty (or nearly empty) directory from nothing to a **fully-governed, provisioned, verified, first-commit-ready repository** — without dumping generic boilerplate. Follow the phases **in order**. Do not skip the discovery in Phase 0 or the gate in Phase 3.

Target directory: **$ARGUMENTS** (if empty, use the current working directory; confirm which directory before writing anything).

## Operating principles (read first)

- **Understand before you interview; interview before you scaffold.** Phase 0 builds shared understanding of *what the user is actually trying to build*. Phase 1 only then asks the structured questions. No files are written until the user approves the Phase 3 plan.
- **Paved-road by default, toggleable down.** Full governance is the default; let the user remove layers, don't make them assemble from scratch.
- **Thin durable artifacts, not a markdown flood.** AGENTS.md/CLAUDE.md/ADR-0001 stay concise and project-specific. The documented failure mode of spec-driven tools is 2,500 lines of markdown for 700 lines of code — avoid it.
- **Make the secure/correct path the default.** No secrets in the repo, `.env.example` not `.env`, tests wired and green from commit #1, CI that can actually pass.
- **AGENTS.md is the cross-tool source of truth**; CLAUDE.md bridges to it. Don't duplicate rules across files.

---

## Phase 0 — Discovery (understand the goal first)

First inspect the target directory (`ls -la`; check for existing `.git`, `package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`). If it already looks initialized, STOP and tell the user — Apex Project Start is for greenfield starts (offer to fill only the missing pieces if they insist).

Then **do not jump into a checklist.** Open with the generic question:

1. Ask, with `AskUserQuestion` (free-text welcome): **"What are you trying to build — or what problem are you trying to solve?"** Keep it open. Let them describe it in their own words.

2. **Research and understand that context.** Based on their answer, do a quick, focused investigation (WebSearch / WebFetch, and Context7 for any named library/framework) to understand the domain, the typical architecture for this kind of thing, the common stack choices, and the usual pitfalls. Spend a little effort here — the point is to come back *informed*, not to interrogate the user about things you could have looked up. Keep it brief; you are orienting, not writing a report.

3. **Ask 2–3 clarifying questions** that your research surfaced as genuinely consequential and that you *cannot* infer — the forks that actually change the build (e.g. "real-time or batch?", "who are the users / is this multi-tenant?", "is this a throwaway prototype or something you'll run in production?", "any hard constraint — existing infra, compliance, a language you must use?"). Dig into the hard parts; skip the obvious. Use `AskUserQuestion`.

Briefly reflect back your understanding ("So you're building X, for Y, with Z as the main constraint — right?") and let them correct it before continuing.

## Phase 1 — Structured interview

Now run the concrete setup interview with `AskUserQuestion`, informed by Phase 0. Confirm or propose defaults rather than asking open questions where your research already implies an answer. Cover, in one or two batched rounds:

1. **Project identity** — name, one-line purpose (you likely have these from Phase 0; confirm), public or private.
2. **Stack** — TypeScript/JavaScript, Python, Go, or Rust (one primary; note polyglot if real). Propose the stack your research suggests and let them override. Load only the matching stack reference later.
3. **Project type** — application, library/package, service (long-running, deployed), or CLI. Gates the directory skeleton (services get `docs/runbooks` + `infra/`; libraries don't), observability, and Dockerfile inclusion.
   - **Repo structure** — single-package (default) or **monorepo** (apps/ + packages/, Turborepo/Nx or Cargo workspace). Default monorepo only for tightly-coupled multi-package or polyglot work. Picks the skeleton in directory-skeletons.md.
4. **Audience** — solo/personal vs team/org. Team adds CODEOWNERS, CONTRIBUTING, branch-protection guidance, stricter review gates.
5. **Governance level** — confirm Full paved-road (default) or let them drop layers (community-health files, pre-commit + **pre-push** hooks, CI security scans, ADRs, changelog/release tooling, **periodic maintenance** = dead-code sweep + last-run tracking + >3-day reminder, **GitHub hardening** = rulesets/OIDC/merge-queue/SHA-pinned actions, **sin-bin** quarantine dir, optional **SonarQube Cloud** quality gate). Maintenance + GitHub hardening (team) default on; sin-bin and SonarQube default off (offer SonarQube as the recommended governance gate).
6. **License** — if public: MIT (reach) / Apache-2.0 (patent grant, SDKs) / AGPL-3.0 (copyleft/SaaS) / BSL-1.1 (commercial). If private: proprietary/none.
7. **Dev-environment provisioning** — confirm whether to install the standard must-haves after scaffolding: **ruflo** (orchestration/MCP/memory) and the **Apex-Dev-Skills** plugin suite. Default: both. Options: both / ruflo only / Apex skills only / skip.

Don't ask questions whose answer you can read from the directory or Phase 0, or that have a single sane default — state the default and move on.

## Phase 2 — (reserved) consolidate understanding

Synthesize Phases 0–1 into the resolved choice set (name, purpose, stack, type, audience, license, governance toggles, provisioning choice). No user interaction; this just feeds the plan.

## Phase 3 — Plan and GATE (do not write files yet)

Produce a concise, reviewable plan listing **exactly** what will be created and provisioned, grouped by layer, with the resolved choices. Example shape:

```
Apex Project Start plan for <name> (TypeScript library, team, MIT, full governance)
 Skeleton:         src/ tests/ docs/{adr,architecture} scripts/ .github/  (single-package)
 Universal:        .gitignore .gitattributes .editorconfig README.md LICENSE
 Community health: CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md .github/CODEOWNERS
                   .github/ISSUE_TEMPLATE/* PULL_REQUEST_TEMPLATE.md
 Stack:            package.json tsconfig.json biome.json vitest.config.ts src/ tests/
 Quality gates:    lefthook.yml (pre-commit + pre-push) commitlint.config.js .changeset/
 CI/CD:            .github/workflows/ci.yml dependabot.yml codeql.yml
 GitHub hardening: ruleset.json (or checklist) · least-priv + SHA-pinned actions · OIDC · merge-queue
 SonarQube (opt):  sonar-project.properties .github/workflows/sonar.yml + SONAR_TOKEN next-steps
 Steering:         AGENTS.md CLAUDE.md docs/adr/0001-record-architecture-decisions.md
 Docs:             CHANGELOG.md docs/
 Maintenance:      .apex/maintenance.json scripts/dead-code-sweep.sh vulture_whitelist.py
                   (periodic vulture sweep, last-run tracked, >3-day reminder in AGENTS.md)
 Dev environment:  ruflo (init + MCP) · Apex-Dev-Skills suite (7 plugins)
 Finalize:         git init, install deps, run tests, first commit
```

Then **stop and ask the user to approve, adjust, or cancel.** This gate is mandatory.

## Phase 4 — Scaffold + steering

Once approved:

1. Invoke the **`apex-project-start:repo-scaffold`** skill to generate the governed file set. Pass the resolved choices; it holds the stack-specific templates and loads only the relevant references. Write real, working content — substitute name/purpose/author/year everywhere, generate one passing example test so CI is green from commit #1, never leave a `<placeholder>`.
2. Invoke the **`apex-project-start:steering-docs`** skill to author `AGENTS.md` (canonical), `CLAUDE.md` (a short `@AGENTS.md` bridge), and `docs/adr/0001-record-architecture-decisions.md` (if ADRs enabled; add ADR-0002 for a non-obvious stack choice). When the maintenance toggle is on, AGENTS.md must include the **Maintenance** section that points future agents at `.apex/maintenance.json` and the >3-day dead-code-sweep reminder.

## Phase 5 — Dev environment provisioning

If provisioning was enabled in the plan, invoke the **`apex-project-start:dev-environment`** skill. It installs/configures, idempotently, from the project root:

- **ruflo** (`ruvnet/ruflo`): two layers — (1) global `ruflo-*` plugins (marketplace `ruvnet/ruflo`, once per machine), and (2) per-project scaffold: preflight Node 20+, `npx @claude-flow/cli@latest init --preset full` (full preset, not minimal), `daemon start`, then **register and start the MCP server** (`claude mcp add claude-flow -- npx -y @claude-flow/cli@latest`; confirm via `claude mcp list`). Then **verify the scaffold**: `doctor --fix` + `ls .claude/agents/core/` **must show 5 files** (the common incomplete-scaffold bug) + sanity counts; **repair** with `rsync --ignore-existing` from a pinned clone if short. It augments `CLAUDE.md` (expected); route `ANTHROPIC_API_KEY` through `.env`/`.env.example` (never a real key); ignore ruflo runtime artifacts. Provisioning isn't done until the MCP is live and core/ = 5.
- **Apex-Dev-Skills** (`Skobyn/Apex-Dev-Skills`, marketplace `apex-dev-skills`): `claude plugin marketplace add Skobyn/Apex-Dev-Skills` (or `update apex-dev-skills` if already present), install the 7 plugins, then `/reload-plugins`. Install ruflo first — `apex-scope-loop` depends on it.

Respect the provisioning sub-choice (both / ruflo only / Apex only / skip). Report what was installed, updated, or skipped, with real errors if any step fails.

## Phase 6 — Verify, then finalize

1. **Audit.** Launch the **`apex-project-auditor`** subagent (Task tool) on the scaffolded directory. In a fresh context it checks: no secrets committed, `.env` gitignored with a committed `.env.example`, tests actually wired and passing, CI valid and able to pass, lockfile present, AGENTS.md/CLAUDE.md not duplicating each other, no dangling placeholders. Fix anything it flags.
2. **Initialize & prove it works.** `git init` (default branch `main`), install dependencies, run the test command and the linter, confirm both pass. Fix failures before committing.
3. **First commit.** Stage everything and make an initial Conventional Commit: `chore: initialize project with Apex Project Start`. Do not push or create a remote unless asked.
4. **Report.** Summarize what was created and provisioned, confirm tests/lint pass, and give the 2–3 next steps (e.g. "add ANTHROPIC_API_KEY to .env", "restart Claude Code to load the Apex plugins", "set up branch protection on `main`").

Stay concise in chat; the value is in the files and the working environment, not the narration.
