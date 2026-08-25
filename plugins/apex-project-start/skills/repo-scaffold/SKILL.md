---
name: repo-scaffold
description: Generate the governed file set for a new repository — universal hygiene files, community-health files, stack-specific scaffolding (TypeScript/Python/Go/Rust), quality gates, and CI/CD. Invoked by /apex-project-start:new after the plan is approved; can also be used directly to add a missing governance layer to a fresh repo. Loads only the stack reference that matches the project.
---

# repo-scaffold

Generates a fully-governed greenfield repository. You receive resolved choices from the orchestrator: **project name, purpose, stack, project type, audience, license, governance toggles**. If any are missing, ask before writing.

## How to use the references (progressive disclosure)

Load only what the project needs:

- **Always (first):** [references/directory-skeletons.md](references/directory-skeletons.md) — the canonical directory tree: single-service skeleton, per-stack `src/` layout (Python src / Go cmd+internal / Rust crate-or-workspace / TS library-or-FSD), monorepo layout (apps+packages, Turborepo/Nx, Cargo workspace), and Copier for cross-repo template reuse. Build the tree before populating it.
- **Always:** [references/universal-and-community.md](references/universal-and-community.md) — `.gitignore`, `.gitattributes`, `.editorconfig`, README structure, LICENSE selection, and (if team/public) CONTRIBUTING / CODE_OF_CONDUCT / SECURITY / CODEOWNERS / issue & PR templates.
- **One stack file**, by chosen stack:
  - [references/stack-typescript.md](references/stack-typescript.md) — pnpm + strict tsconfig + Biome + Vitest
  - [references/stack-python.md](references/stack-python.md) — uv + Ruff + pyright + pytest + src layout
  - [references/stack-go.md](references/stack-go.md) — modules + golangci-lint + gofumpt
  - [references/stack-rust.md](references/stack-rust.md) — cargo + clippy + rustfmt
- **If quality gates / CI enabled:** [references/quality-and-ci.md](references/quality-and-ci.md) — Lefthook (with `pre-push` tests + the local-hooks-aren't-a-gate framing), Conventional Commits/commitlint, Changesets, GitHub Actions, Dependabot, CodeQL, secret scanning, mise tool-pinning, **GitHub hardening** (rulesets/OIDC/merge queue/SHA-pinned actions/environments/GitHub Apps), and the **optional SonarQube Cloud** quality gate.
- **If maintenance toggle on (default):** [references/maintenance-and-hygiene.md](references/maintenance-and-hygiene.md) — periodic dead-code sweep (vulture/knip/deadcode/udeps) with last-run tracking + >3-day reminder, dependency hygiene, the optional sin-bin quarantine, and consistent warnings-as-errors.

## Ordering

1. Directory skeleton (always — per directory-skeletons.md; single-service or monorepo; `.gitkeep` empty dirs; emit only what the project needs).
2. Universal hygiene files (always).
3. Community-health files (team/public only — gate on audience).
4. Stack scaffolding (manifest, config, `src/` + `tests/` in the skeleton layout, one passing example test).
5. Quality gates (hooks incl. pre-push, commit convention, release tooling) — if enabled.
6. CI/CD workflows + GitHub hardening + optional SonarQube — if enabled.
7. `CHANGELOG.md` (Keep a Changelog) and `docs/` — if enabled.
8. Maintenance & hygiene (if enabled): `.apex/maintenance.json`, `scripts/dead-code-sweep.sh`, whitelist/config, warnings-as-errors wiring, and the optional `sandbox/` sin-bin. The AGENTS.md **Maintenance** section itself is authored by `steering-docs`.

Steering docs (AGENTS.md / CLAUDE.md / ADRs) are handled by the separate `apex-project-start:steering-docs` skill — don't author them here.

## Hard rules

- **Never write a real secret.** Generate `.env.example` with documented placeholder keys; ensure `.env` and `.env.local` are gitignored.
- **Everything must run.** The example test must pass; configs must be valid; CI must be able to go green. No placeholder code that breaks the build.
- **Substitute, don't templatize-and-leave.** Replace project name, purpose, author (`skobyn <skobyn@gmail.com>` unless told otherwise), and current year everywhere. Leave no `{{placeholder}}` behind.
- **Respect the toggles.** If the user dropped a governance layer in the plan, skip it — don't silently re-add it.
- **Pin tool versions.** Use a `mise.toml` (or `.nvmrc`/`rust-toolchain.toml`/`go.mod` go directive) so the runtime is reproducible.
- **Warnings are errors.** Configure linters/type-checkers/compilers/tests to fail, not warn (see maintenance-and-hygiene §5). Don't swallow non-zero exits in CI.
- **Default branch is `main`.** Conventional Commits throughout.

When done, report the exact file list created so the orchestrator can pass it to the auditor.
