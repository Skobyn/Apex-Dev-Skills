# Novel Plugins Suite — Research & Contract Findings

Backing research for [ADR-0001](../../.claude/tasks/novel-plugins-suite-adr.md) and the
companion [plan](../../.claude/plans/novel-plugins-suite-plan.md). Source of the 13
ideas: the `deep-research` workflow pass (109 agents, 26 sources, 22/25 claims
verified) summarized in the ADR's Methodology section.

## Findings

### Ecosystem saturation (what to avoid)

Across the official Anthropic marketplace (~204 plugins), `wshobson/agents`
(191 agents + 155 skills + 102 commands), and `VoltAgent/awesome-claude-code-subagents`
(154+ subagents), the **oversaturated** categories are code review, test
generation, security scanning, scaffolding, and infrastructure setup. A new
plugin whose *core* surface is any of these adds no marketplace value.

### Verified gaps (what to build)

Empirical developer-pain data (arXiv 2510.25423: 82.6% of AI-agent Stack
Overflow questions unanswered; 88.4% for RAG and orchestration) intersects with
under-exploited primitives — chiefly **hooks**, the only primitive with
*guaranteed, deterministic* enforcement. The six themed plugins target:
agent observability (A), deterministic guardrails (B), RAG/memory lifecycle (C),
legacy/AI-code comprehension (D), agent-team coordination (E), and
tool-contract/runtime-reliability (F).

### Repo contract (extracted from `apex-scope-loop`)

Every plugin in this marketplace must satisfy a structural contract, enforced by
a per-plugin `scripts/smoke.sh`:

1. `.claude-plugin/plugin.json` with `name` (== dir), `description`, `version`,
   `author {name,url}`, `license`, `keywords[]` — and **no** enumerated
   `skills`/`commands`/`agents` arrays (auto-discovered from directory layout).
2. Skills at `skills/<name>/SKILL.md`: frontmatter `name:` unquoted kebab-case
   matching the dir; `description:`; `allowed-tools:` an explicit list — never
   `*` or `mcp__*`.
3. Commands at `commands/<cmd>.md`: frontmatter `name:` (== filename) + `description:`.
4. Agents at `agents/<agent>.md`: frontmatter `name:` + `model:`.
5. `README.md` with `## Compatibility`, `## Namespace coordination`,
   `## Verification`, `## Architecture Decisions`.
6. `docs/adrs/0001-<name>-contract.md` with `- **Status:** Proposed`.
7. All `*.sh` executable (755), LF endings, `set -euo pipefail`.
8. Name + description identical across `plugin.json`, `marketplace.json`, and the
   plugin `README.md`.

MCP-bearing plugins (A observability, C rag-memory) extend the smoke to 12
checks: (11) `.mcp.json` valid + referenced server script exists; (12) no
`mcp__*` in any `allowed-tools` (MCP availability is environmental; the server
is optional and the core surface must function without it).

## Recommendations

- Build complexity-ascending (B → E → D → F → A → C) so low-risk hook plugins
  validate the contract before the MCP plugins.
- One coder agent per plugin, writing only inside `plugins/<name>/`; register in
  `marketplace.json` + root README centrally to avoid manifest write races.
- Gate each plugin on its own `smoke.sh` + `marketplace.json` JSON validity.
- Keep plugins pure markdown+shell unless external capability is genuinely
  required; ship MCP servers as optional, dependency-light (`python3` stdlib)
  stubs behind the extended smoke.
