# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **Claude Code plugin marketplace**. It is the development workspace for Apex Insights plugins and the source of truth users add via `/plugin marketplace add Skobyn/Apex-Dev-Skills`. There is no application to build or run — the "product" is the set of markdown + shell artifacts under `plugins/` that Claude Code loads at runtime. It is open source (MIT) and public.

## Two-level manifest structure

The repo has two manifest tiers that must stay in sync:

1. **Marketplace manifest** — `.claude-plugin/marketplace.json` lists every plugin with a `source` pointing at `./plugins/<name>`. Adding a plugin directory is not enough; it must also be registered here or users won't see it.
2. **Plugin manifest** — `plugins/<name>/.claude-plugin/plugin.json` declares `name`, `version`, `description`, `author`, `license`, `keywords`. It must **not** enumerate `skills`/`commands`/`agents` arrays — those are auto-discovered from directory layout, and the smoke test fails the build if they are listed.

Each plugin's `name` and `description` are duplicated across `marketplace.json`, `plugin.json`, and the plugin `README.md` — keep all three consistent when editing.

## Plugin anatomy (`plugins/<name>/`)

Surfaces are discovered by directory convention, not declaration:

- `skills/<skill-name>/SKILL.md` — frontmatter `name:` must be **unquoted kebab-case** matching the directory; `allowed-tools:` must be an explicit list (no `*` or `mcp__*` wildcards). Skills carry their own `scripts/`, `resources/templates/`, `resources/examples/`, and `docs/`.
- `commands/<cmd>.md` — slash commands; frontmatter needs `name:` (matching filename) and `description:`. `$ARGUMENTS` is the user-supplied arg. Invoked as `/<plugin-name>:<cmd>`.
- `agents/<agent>.md` — subagent definitions; frontmatter `name:` + `model:` (e.g. `model: sonnet`).
- `scripts/` — bash helpers (`set -euo pipefail`); must be `chmod +x`.
- `docs/adrs/NNNN-*.md` — Architecture Decision Records defining the plugin contract.

## Verification

Each plugin ships a structural smoke test that encodes its contract (see `plugins/apex-scope-loop/scripts/smoke.sh` as the reference pattern). Run it after any change to a plugin:

```bash
bash plugins/apex-scope-loop/scripts/smoke.sh
```

It checks manifest keys, kebab-case skill names, no wildcard tools, command/agent frontmatter, required README sections, ADR status, and script executability — exiting non-zero on the first failure with a named reason. When adding a new plugin, give it its own `scripts/smoke.sh` following the same 10-check shape.

## Adding a plugin

1. Create `plugins/<name>/` with a valid `.claude-plugin/plugin.json` and the surface directories above.
2. Register it in `.claude-plugin/marketplace.json` with `"source": "./plugins/<name>"`.
3. Add a row to the root `README.md` plugins table.
4. Write `plugins/<name>/scripts/smoke.sh` and confirm it passes.
5. Commit and push to GitHub. Users pick it up with `/plugin marketplace update apex-dev-skills`.

## Testing a plugin locally

```bash
claude --plugin-dir ./plugins/<name>
```

Then `/reload-plugins` (or restart Claude Code) to activate changes without reinstalling from the marketplace.

## Conventions

- **Memory/AgentDB namespaces** follow kebab-case `<plugin-stem>-<intent>` and are claimed in the plugin's ADR-0001. A new plugin reading/writing another's keys must claim a non-overlapping prefix and reference the owning ADR (see `plugins/apex-scope-loop/README.md` → "Namespace coordination").
- **ADR-driven contracts**: a plugin's public surface, compatibility matrix, and smoke contract live in `docs/adrs/0001-*.md`. Treat the ADR as the spec the smoke test enforces.
- Plugin `README.md` files must contain `## Compatibility`, `## Namespace coordination`, `## Verification`, and `## Architecture Decisions` sections (the smoke test asserts these).
