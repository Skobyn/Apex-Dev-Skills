# Universal & community-health files

Stack-agnostic files. The **universal** set is generated for every project. The **community-health** set is generated only for team/public projects (gate on audience).

---

## Universal (always)

### `.gitignore`
Start from the canonical [github/gitignore](https://github.com/github/gitignore) template for the chosen stack and merge if polyglot. Always include OS/editor cruft and secrets:

```gitignore
# Secrets & local env
.env
.env.local
.env.*.local
*.pem
*.key

# OS / editor
.DS_Store
Thumbs.db
.idea/
.vscode/*
!.vscode/extensions.json
!.vscode/settings.json

# Logs / coverage / build (extend per stack)
*.log
coverage/
dist/
build/
```

Rationale: hand-rolled ignores miss ecosystem cruft; never let `.env` reach history.

### `.gitattributes`
```gitattributes
* text=auto eol=lf
*.sh text eol=lf
*.{cmd,bat} text eol=crlf
*.png binary
*.jpg binary
*.gif binary
*.ico binary
*.pdf binary
```
After creating, the project owner should run `git add --renormalize .`. Rationale: LF-in-repo is the cross-platform-safe default; stops CRLF churn between Windows/macOS/Linux.

### `.editorconfig`
```editorconfig
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true
indent_style = space
indent_size = 2

[*.py]
indent_size = 4

[*.go]
indent_style = tab

[*.md]
trim_trailing_whitespace = false
```
Rationale: enforces style at the editor layer before any linter runs; natively supported by VS Code, JetBrains, Vim, the GitHub web editor.

### `README.md`
README is **for humans** (push agent detail to AGENTS.md). Structure:
```markdown
# <project-name>

<one-line description>

## Quickstart

```bash
<install in 1 command>
<run in 1 command>
```

## Usage

<minimal example>

## Development

```bash
<install dev deps>
<run tests>
<run linter>
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).   <!-- omit if solo -->

## License

<SPDX id> — see [LICENSE](LICENSE).
```
Keep the quickstart to ≤3 commands. Add badges (CI, version, license) only if the corresponding tooling exists.

### `LICENSE`
Fetch the full canonical text for the chosen SPDX license and fill in year (current year) and author. Selection guidance:

| Want | Choose |
|---|---|
| Maximum adoption, simple | **MIT** |
| Adoption + patent grant (SDK/library/platform) | **Apache-2.0** |
| Force derivatives open (app / library) | **GPL-3.0 / LGPL-3.0** |
| Close the SaaS loophole | **AGPL-3.0** |
| Commercial, protect from cloud competitors (time-bombs to open) | **BSL-1.1** (not OSI-approved) |
| Private / closed | proprietary header or no LICENSE (state "All rights reserved" in README) |

LICENSE must be at the repo **root** (it ships with clones/tarballs; a `.github` org default won't travel).

---

## Community-health (team / public only)

GitHub resolves these from `.github/` → repo root → `docs/`. Prefer `.github/` to keep the root clean (LICENSE excepted — must be root).

### `CONTRIBUTING.md`
Dev-env setup, how to run tests/lint, branch & PR naming, commit convention pointer (→ Conventional Commits), review expectations. Surfaces a "Contributing" link in GitHub's PR UI.

### `CODE_OF_CONDUCT.md`
Use [Contributor Covenant 2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/) verbatim; fill in the contact method for enforcement.

### `SECURITY.md`
Supported-versions table + a **private** reporting channel. Prefer GitHub Private Vulnerability Reporting over a public issue or bare email.
```markdown
# Security Policy
## Supported Versions
| Version | Supported |
|---------|-----------|
| latest  | ✅        |
## Reporting a Vulnerability
Please report privately via GitHub's "Report a vulnerability" (Security tab),
or email <contact>. We aim to acknowledge within 48 hours.
```

### `.github/CODEOWNERS`
Map paths → reviewers; pairs with branch protection to require expert review.
```
# Default owners for everything
*       @<owner>
# Example path-scoped ownership
# /src/api/   @<api-team>
```

### `.github/ISSUE_TEMPLATE/` + `PULL_REQUEST_TEMPLATE.md`
- `bug_report.yml` and `feature_request.yml` (GitHub form schema) for structured triage.
- `PULL_REQUEST_TEMPLATE.md`: summary, linked issue, type of change, checklist (tests added, docs updated, changeset added).

### Optional (larger/funded OSS)
`SUPPORT.md`, `GOVERNANCE.md`, `.github/FUNDING.yml` — add only on request.

---

## Branch-protection guidance (team — output as guidance, not a file)
Apex Project Start can't set GitHub branch protection via files, so include this as a "next steps" note for `main`: require PR reviews (≥1) + CODEOWNERS review, require status checks (CI) to pass, dismiss stale approvals on new commits, require conversation resolution, require signed commits, enforce linear history, restrict direct pushes. Optionally provide a `gh` command snippet or a ruleset JSON.
