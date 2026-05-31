# Quality gates & CI/CD

Generate these when the corresponding governance toggles are on. All are stack-aware — adapt the commands to the chosen stack.

---

## Git hooks — Lefthook (default)

Single Go binary, one YAML, parallel by default, language-agnostic. (Alternatives: Husky+lint-staged for JS-native teams; `pre-commit` for Python-native teams.)

`lefthook.yml` (TypeScript example — swap commands per stack):
```yaml
pre-commit:
  parallel: true
  commands:
    lint:
      glob: "*.{ts,tsx,js,jsx,json}"
      run: pnpm biome check --staged --no-errors-on-unmatched {staged_files}
    typecheck:
      run: pnpm typecheck
commit-msg:
  commands:
    commitlint:
      run: pnpm commitlint --edit {1}
```
Per stack, the `pre-commit` runner becomes: Python → `uv run ruff check {staged_files}`; Go → `golangci-lint run`; Rust → `cargo fmt --check && cargo clippy`.

Install note (next-steps): `lefthook install`.

---

## Commit convention — Conventional Commits + commitlint

Enforces machine-parsable history (`<type>(scope): desc`), which drives automated versioning + changelogs.

`commitlint.config.js`:
```js
export default { extends: ["@commitlint/config-conventional"] };
```
Add `@commitlint/cli` + `@commitlint/config-conventional` to dev deps (JS). For non-JS repos, run commitlint via the lefthook `commit-msg` hook using `npx`, or document the convention in CONTRIBUTING and enforce in CI with a commit-lint action.

---

## Release & changelog

- **Changesets** (default for JS, esp. monorepos): `.changeset/config.json`, intentional release notes, best changelogs.
  ```json
  { "$schema": "https://unpkg.com/@changesets/config/schema.json",
    "changelog": "@changesets/cli/changelog", "commit": false,
    "access": "restricted", "baseBranch": "main" }
  ```
- **semantic-release** if you want fully-automated, commit-driven releases with no human step.
- Non-JS: generate `CHANGELOG.md` in [Keep a Changelog](https://keepachangelog.com/) format and update via `git-cliff` or release-please.

`CHANGELOG.md` seed:
```markdown
# Changelog
All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]
### Added
- Initial project scaffold.
```

---

## CI — GitHub Actions

`.github/workflows/ci.yml` — jobs: lint → typecheck → test → build, matrix across supported runtime versions, on push + PR, with dependency caching.

TypeScript example:
```yaml
name: CI
on:
  push: { branches: [main] }
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        node: [20, 22]
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with: { node-version: "${{ matrix.node }}", cache: "pnpm" }
      - run: pnpm install --frozen-lockfile
      - run: pnpm lint
      - run: pnpm typecheck
      - run: pnpm test
      - run: pnpm build
```
Per-stack equivalents:
- **Python:** `astral-sh/setup-uv@v4`, `uv sync --frozen`, `uv run ruff check .`, `uv run pyright`, `uv run pytest`. Matrix on `python-version`.
- **Go:** `actions/setup-go@v5` (cache on), `go test -race -cover ./...`, `golangci/golangci-lint-action@v6`.
- **Rust:** `dtolnay/rust-toolchain@stable`, `Swatinem/rust-cache@v2`, `cargo test`, `cargo clippy -- -D warnings`, `cargo fmt --check`.

---

## Dependency updates — Dependabot (default)

`.github/dependabot.yml` (zero-setup, GitHub-native). Use **Renovate** instead when you need 90+ package managers, monorepo grouping, or built-in automerge.
```yaml
version: 2
updates:
  - package-ecosystem: "<npm|pip|gomod|cargo>"
    directory: "/"
    schedule: { interval: "weekly" }
    open-pull-requests-limit: 5
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule: { interval: "weekly" }
```
Security note: auto-merge **patch-level only**, gated on clean CI + unchanged maintainer identity. Never auto-merge minor/major without review (bot-PR malware is a real 2025–2026 vector).

---

## Static analysis — CodeQL

`.github/workflows/codeql.yml` — catches vulnerable *usage* (injection, logic flaws); complements Dependabot's vulnerable-*dependency* scanning. Run both.
```yaml
name: CodeQL
on:
  push: { branches: [main] }
  pull_request:
  schedule: [{ cron: "0 6 * * 1" }]
jobs:
  analyze:
    runs-on: ubuntu-latest
    permissions: { security-events: write }
    steps:
      - uses: actions/checkout@v4
      - uses: github/codeql-action/init@v3
        with: { languages: "<javascript-typescript|python|go>" }
      - uses: github/codeql-action/autobuild@v3
      - uses: github/codeql-action/analyze@v3
```
Note: CodeQL has no Rust support yet — for Rust use `cargo audit` + `cargo deny` in CI instead.

---

## Secret scanning

Enable GitHub secret scanning + **push protection** in repo settings (next-steps note — not a file). Belt-and-suspenders: add a **gitleaks** step to CI and/or a lefthook `pre-commit` hook:
```yaml
# in CI
- uses: gitleaks/gitleaks-action@v2
```

---

## Containerization & dev env (services / on request)

- `mise.toml` — pin all tool versions (already emitted by stack refs). Do not also run direnv.
- `.env.example` — documented placeholder keys; real `.env` gitignored.
- `.devcontainer/devcontainer.json` with `postCreateCommand` running the stack install (e.g. `mise install && <stack install>`).
- `Dockerfile` — multi-stage, non-root user, digest-pinned base for prod; `.dockerignore` mirroring `.gitignore`.
