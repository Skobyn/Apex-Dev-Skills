# Directory skeletons (brief §5.1 / §5.2)

The canonical layouts the scaffolder emits. Create the skeleton **first** (before writing stack/config files into it), then populate. **Generate only what the project needs** — don't emit `infra/` for a library or `migrations/` for a project with no database. Empty directories that must exist get a `.gitkeep`.

## Principles
- **Root holds meta + manifests only** (README, LICENSE, CHANGELOG, dotfiles, build manifest). Code lives under `src/` / `cmd/` / `crates/` / `apps/`.
- **Organize by feature/domain, not technical layer**, past trivial size. A `controllers/ models/ services/` split stops scaling; `feature-x/ feature-y/` keeps related code together.
- **Secrets never enter VCS.** `.env.example` is committed; real `.env` is gitignored.
- **`.github/` holds contributor governance**; root holds machine-relevant meta. Health-file resolution order is `.github/` → root → `docs/`.

---

## Single-service skeleton (default)

```
my-project/
├── README.md  LICENSE  CHANGELOG.md
├── .gitignore  .gitattributes  .editorconfig  .env.example
├── .github/
│   ├── workflows/ci.yml            # + codeql.yml, sonar.yml, dependabot.yml as enabled
│   ├── ISSUE_TEMPLATE/             # bug_report.yml, feature_request.yml
│   ├── PULL_REQUEST_TEMPLATE.md
│   ├── CONTRIBUTING.md  CODE_OF_CONDUCT.md  SECURITY.md  CODEOWNERS
├── src/                            # ← stack-specific (see below)
├── tests/
├── docs/
│   ├── adr/                        # 0001-record-architecture-decisions.md ...
│   ├── architecture/               # overview, diagrams (optional)
│   └── runbooks/                   # ops runbooks (services only)
├── scripts/                        # dead-code-sweep.sh, maintenance-check.sh, dev helpers
├── config/                         # app config (optional)
├── migrations/                     # DB migrations (only if there's a database)
├── infra/                          # services only
│   ├── terraform/
│   └── k8s/
└── .apex/maintenance.json          # if maintenance toggle on
```

**Gating:** `docs/architecture` + `docs/runbooks` and `infra/` are for **services**; omit for libraries/CLIs. `migrations/` only with a DB. `config/` optional. Community-health files only for team/public (audience gate). `tests/` always.

---

## Per-stack `src/` layout

### Python — src layout
```
src/<package_name>/__init__.py
tests/
pyproject.toml          # root
```
src-layout forces an editable install so tests import the *installed* package (kills import-shadowing). Flat layout only for throwaway scripts.

### Go — cmd + internal
```
cmd/<app>/main.go       # tiny main; wiring only
internal/               # most logic; compiler-enforced privacy
<pkg>.go                # or library code at module root
```
Skip `pkg/` unless the code is genuinely public API. (`golang-standards/project-layout` is *not* an official standard — don't cargo-cult `/pkg`+`/cmd` into a small project.)

### Rust — single crate vs workspace
Single crate (default):
```
src/lib.rs              # library
src/main.rs             # binary (lib + thin main is more testable)
```
Workspace (2+ crates):
```
Cargo.toml              # [workspace] members + [workspace.dependencies]
Cargo.lock              # shared, committed
crates/
├── core/Cargo.toml     # dependency = { workspace = true } to centralize versions
└── cli/Cargo.toml
```

### TypeScript — library vs app (FSD)
Library:
```
src/index.ts            # public entry
tests/
```
App — **Feature-Sliced Design** for non-trivial apps (layers, top→bottom; lower layers can't import upper):
```
src/
├── app/                # init, providers, routing, global styles
├── pages/  (or views/) # route compositions
├── widgets/            # standalone UI blocks
├── features/           # user-facing actions
├── entities/           # business entities
└── shared/             # ui kit, libs, config (no business logic)
```
Next.js App Router keeps `app/` at the repo/`src` root for routing; put the FSD layers under `src/` alongside it.

---

## Monorepo skeleton (when mono is chosen)

Default to **poly** (one repo per package); choose **mono** only for tightly-coupled multi-package work or when the user asks. Polyglot projects usually warrant a monorepo.

```
my-monorepo/
├── apps/               # deployables (web, api, worker)
│   ├── web/
│   └── api/
├── packages/           # shared libs (ui, config, types, utils)
│   ├── ui/
│   └── config/
├── tooling/            # shared eslint/biome/tsconfig presets (optional)
├── docs/  scripts/
├── package.json        # workspace root (private: true)
├── pnpm-workspace.yaml # JS workspaces
└── turbo.json          # or nx.json
```
- **Each package has its own manifest + tests**, and a **nested `AGENTS.md`** with only its deltas (agents read the nearest file).
- **JS tooling:** **Turborepo** (minimal, fast remote cache — default) or **Nx** (full platform: generators, graph, plugins — for larger orgs). Workspaces via `pnpm-workspace.yaml`.
- **Rust monorepo** = a Cargo **workspace** (`crates/` as above), not apps/packages.
- **Polyglot mono:** group by language at the top (`js/`, `py/`, `rs/`) or by app, each with its own toolchain; pin everything with one root `mise.toml`.

---

## Template reuse across repos — Copier

For an org that spins up many similar repos, drive scaffolding from a **Copier** template (not Cookiecutter): Copier records an **answers file** and supports `copier update` to merge template improvements **into existing projects** — Cookiecutter is one-shot. Mention this as a next-step for teams; Apex Project Start itself plays the interactive-scaffolder role for a single repo.

---

## Generation rules
- Create dirs that must exist but start empty with a `.gitkeep`.
- Don't emit a directory the project won't use (no `infra/k8s` for a library, no `migrations/` without a DB) — surface it as "add later if you need it" instead.
- The skeleton is **step 1**; stack/config/CI files from the other references populate it.
