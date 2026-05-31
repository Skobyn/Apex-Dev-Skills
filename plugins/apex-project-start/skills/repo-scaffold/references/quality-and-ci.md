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

Add a `pre-push` stage that runs the (slower) test suite before code leaves the machine:
```yaml
pre-push:
  commands:
    test:
      run: <stack test cmd>   # pnpm test · uv run pytest · go test ./... · cargo test
```

**Local hooks are fast feedback, NOT a security boundary.** They're bypassable (`git commit --no-verify`) and not everyone installs them. So **every check a hook runs MUST also run in CI**, where it's the real, unbypassable gate (enforced via the ruleset's required status checks, below). Mirror, don't duplicate-and-diverge: the hook and the CI job run the same command. Auto-fix + re-stage in the hook rather than only failing.

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

## GitHub hardening (rulesets, OIDC, merge queue, identity)

Generate this when the GitHub-hardening toggle is on (default on for team/org; opt-in for solo). These are mostly **settings + guidance**, not files — emit a "GitHub setup" checklist in the README/next-steps, plus a committed ruleset JSON if the user wants it.

**Rulesets, not legacy branch protection.** Rulesets are layerable, can be org-wide, and have an **"Evaluate" dry-run** mode. On `main` require: PR before merge + **Code Owners** review, **required status checks** (CI jobs + the SonarQube gate below), **linear history**, block force-push, restrict deletions, and **require signed commits**. Can be authored in the UI or committed as JSON and applied via API/`gh`.

**Least-privilege Actions + SHA-pinning.** Set a top-level `permissions: { contents: read }` baseline in every workflow and widen per-job only as needed. **Pin third-party actions to a full commit SHA** (not a moving tag) — Dependabot's `github-actions` ecosystem keeps the SHAs updated. First-party `actions/*` may stay on major tags if you prefer.
```yaml
permissions:
  contents: read          # baseline; widen per-job
# example pinned third-party action:
# - uses: SonarSource/sonarqube-scan-action@<full-sha>  # v4.x
```

**OIDC over stored cloud keys.** For deploys, use short-lived OIDC tokens with a cloud trust policy scoped to `repo` + `environment` instead of long-lived secrets:
```yaml
permissions: { id-token: write, contents: read }
# then aws-actions/configure-aws-credentials (or gcp/azure) with role-to-assume, no stored keys
```

**Merge queue.** Once multiple authors land several PRs/day, enable a merge queue so CI runs against the actual post-merge state. The CI workflow must also trigger on the queue:
```yaml
on:
  pull_request:
  merge_group:            # required for merge-queue checks
```

**Environments** gate production: required reviewers, wait timers, branch restrictions, environment-scoped secrets.

**Identity:** use **GitHub Apps** for automation (short-lived tokens, own identity, fine-grained perms). Fine-grained PATs for personal scripts only. **Never classic PATs.**

---

## Quality gate — SonarQube Cloud (optional)

Sits *above* the linters: bugs, SAST/security hotspots, code smells, duplication, and **coverage tracking**, behind a **Quality Gate** wired as a required PR status check. (It's "SonarQube" — the 2024 rebrand; "SonarCloud" is now **SonarQube Cloud**.) Generate when the SonarQube toggle is on.

- **"Clean as You Code"** — the gate enforces thresholds only on **new/changed** code, which is ideal greenfield (no legacy-debt wall on day one).
- It **ingests** coverage, it does not generate it — run tests with coverage first and point Sonar at the report.
- **Edition:** self-hosted Community Build analyzes only `main` (no PR decoration) — for **PR gating use SonarQube Cloud free tier** (free for public repos; free under 50k LOC private).
- Sonar is **weak on dependency CVEs** — keep Dependabot/CodeQL (and optionally Snyk) for that. Sonar complements, doesn't replace them.

`sonar-project.properties`:
```properties
sonar.organization=<org>
sonar.projectKey=<org>_<repo>
sonar.sources=src
sonar.tests=tests
# coverage report path (per stack — produce it in the test step):
sonar.javascript.lcov.reportPaths=coverage/lcov.info
sonar.python.coverage.reportPaths=coverage.xml
```
`.github/workflows/sonar.yml`:
```yaml
name: SonarQube Cloud
on:
  push: { branches: [main] }
  pull_request:
permissions:
  contents: read
jobs:
  sonar:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }       # full history → accurate new-code detection
      - # run the stack's tests WITH coverage here, producing the report path above
      - uses: SonarSource/sonarqube-scan-action@v4
        env: { SONAR_TOKEN: "${{ secrets.SONAR_TOKEN }}" }
```
Next-steps to surface: create the project in SonarQube Cloud, add `SONAR_TOKEN` as a repo secret, set the org/projectKey, and add the **SonarQube Code Analysis** check to the `main` ruleset's required status checks.

---

## Containerization & dev env (services / on request)

- `mise.toml` — pin all tool versions (already emitted by stack refs). Do not also run direnv.
- `.env.example` — documented placeholder keys; real `.env` gitignored.
- `.devcontainer/devcontainer.json` with `postCreateCommand` running the stack install (e.g. `mise install && <stack install>`).
- `Dockerfile` — multi-stage, non-root user, digest-pinned base for prod; `.dockerignore` mirroring `.gitignore`.
