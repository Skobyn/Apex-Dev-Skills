# ADR-0001: apex-dispatch plugin contract

- **Status:** Proposed
- **Date:** 2026-10-06
- **Author:** solutions@getapexinsights.com
- **Plugin:** apex-dispatch v0.1.0
- **Spec:** `docs/superpowers/specs/2026-10-05-apex-dispatch-design.md` (§3, §5)

## Context

Delegation in this repo is chosen by prose: the orchestrator picks a model, a provider and a review shape by judgement, and nothing records or enforces the choice. apex-scope-loop 0.3.0 made the execution half portable and binds reviews, tiers and the green gate to an exact head, but it does not decide *who* does the work or enforce that the routed choice is what ran.

## Decision

Ship **apex-dispatch** as a separate plugin that routes and governs delegation, with apex-scope-loop as its only execution engine.

- **Surface** (built across the plan's phases; this ADR fixes the contract, not the schedule):
  - `resources/dispatch.default.json` (+ `sections.json`, `schema.json`) and a per-repo overlay `.claude/apex-dispatch/policy.json`;
  - `scripts/compile.sh [--check]` → committed artifacts (`resources/compiled/policy.json`, `hooks/hooks.json`, generated `agents/*.md`, `resources/settings-snippet.json`); a stale artifact fails `--check`;
  - `scripts/route.sh` (plan task or `adhoc --tags`): kill switches, input gate, hard floors, class table, optional decision-layer fill, tiers, fan-out, escalation, review shape; prints a `ROUTE` block and writes `<state>/dispatch/active-route.json`;
  - hooks: `pre-agent`, `pre-bash`, `pre-edit`, `pre-mcp`, `post-agent`, `subagent-start`, `subagent-stop`, `stop-gate`, `post-bash-prune`;
  - provider shims `bin/worker-*.sh` + `scripts/apply.sh`; `scripts/ledger.sh` (hash-chained JSONL, `verify`, `export-trace`), `scripts/report.sh`, `scripts/doctor.sh`;
  - skills `dispatch-route`, `dispatch-worker`; commands `route`, `run`, `done`, `report`, `doctor`, `compile`.
- **Dependency:** apex-scope-loop ≥ 0.3.0 is found as a sibling (`APEX_SCOPE_LOOP_ROOT` overrides). apex-scope-loop finds apex-dispatch by its executable `scripts/route.sh`; until that exists, apex-scope-loop behaves as if apex-dispatch were absent.
- **Namespace:** `apex-dispatch:routes/<plan-hash>/<line>`, `apex-dispatch:ledger/<plan-hash>`, `apex-dispatch:providers`; on disk only `<state>/dispatch/` and `<state>/adhoc/`, by reference to apex-scope-loop ADR-0003, which owns `.dev-plan-state/` and `ACTIVE`.
- **Governance layers, strongest first** (spec §5.3):
  - **A. Permission deny rules** in `resources/settings-snippet.json` (bypass flags, `git push --force`), applied by the user; no `ask` rules anywhere.
  - **B. apex-guardrails always-on floor:** the same bypass-flag and destructive-git denials, independent of any active route.
  - **C. Loader-enforced tool presence** in generated `agents/*.md` (`tools`/`disallowedTools`, `effort`, `maxTurns`): reviewers have no Bash and no edits; builders have no `Agent`; never `Bash(pattern)`, never `isolation: worktree`.
  - **D. Session-scoped stage lock:** an atomic `ACTIVE` lock with stage transitions written by code; GATE/REVIEW deny git mutation and writes.
  - **E. Route-enforcement hooks** (PreToolUse `Agent|Task`, `Bash`, `Edit…`, optional `mcp__`): roster, model deny-on-mismatch, budgets, stage and worktree confinement.
  - **F. Agent identity:** SubagentStart registers `agent_id → role`; per-role enforcement where the payload carries it, else the SubagentStop transcript audit.
  - **G. Provenance and script gates:** `checkpoint.sh` accepts only hook-written or shim-written verdicts at the exact HEAD; `land.sh` verifies the chain.
  - **H. Budgets, layered:** hard `maxTurns`, spawns, lanes, wall-clock and `--max-budget-usd`; advisory estimated USD.
  - **I. OS confinement, proven:** the snippet's sandbox (`failIfUnavailable`, no unsandboxed commands, provider hosts only) plus each shim's in-process probe.
  - **J. Stop hook:** blocks once per route when routed work was done inline; otherwise advisory.

  Hard rules outrank model verdicts; no new model-judged gates.
- **Decision-layer rubric ids, pinned and never renamed:** `dispatch/task-class@1`, `dispatch/size@1`, `dispatch/lens-set@1`, `dispatch/contamination@1`, `risk-tier@1`, `escalation@1` (also asserted as constants by `resources/schema.json`).
- **Overlay bounds:** the per-repo overlay configures policy within the hard rules and never weakens confinement or changes what a hard rule refers to. `compile.py` refuses (exit 1, named error) an overlay that changes a default tier's `model`/`effort`/`rank`, a default provider's `kind`/`family`/`binary`, removes a default `forbidden_flags` entry (add-only, unioned) or default `forced_flags` (append-only), forces a layer-A bypass flag, `danger-full-access` or a forbidden flag, loosens a provider's `sandbox_mode` (read-only|strict < workspace-write < danger-full-access), widens a default role's tools or `read_only`, raises `escalation.max_review_rounds` or the halt rung above 3, or disables a role a hard rule's review shape needs (`reviewer`, `adversarial-reviewer`). New tiers keep rank monotonic with model strength (haiku < sonnet < opus = fable) and effort.
- **Hard-rule combination:** matching hard rules combine by max (strictest wins); `route.sh` applies every matching `route_floor` rule and keeps the strictest value of each field, and an overlay-appended rule may not be weaker than a default rule whose `when` it overlaps.
- **Policy readers:** hot-path hooks (Phase 3) and `route.sh` must read the overlay-merged policy (`compile.sh --print-merged`, or the same merge and checks), not only `resources/compiled/policy.json`, which is the default policy alone.
- **Generated agents omit `model:`** deliberately: frontmatter `model` is a default the per-call parameter overrides, not a pin (spec §5.3 C), so the model is enforced by `pre-agent.sh` deny-on-mismatch; the repo CLAUDE.md `model:` convention applies to hand-written agents. `agents/` is fully generated: `compile.sh --check` flags any `agents/*.md` that is not an expected artifact, and compares bytes exactly (a CRLF copy is stale).
- **Hook registration:** `scripts/compile.sh` registers in `hooks/hooks.json` only the hook scripts that exist under `hooks/`, each through a fixed event/matcher table; per-repo policy never changes registration (disabled features no-op in bash). With no hook scripts present the file is `{"hooks": {}}`.
- **Compatibility:** Claude Code 2.1.251+, git 2.40+, bash 4+, python3 3.8+ stdlib; no ruflo.

## Consequences

- Delegation becomes a recorded, enforced decision rather than prose.
- Two plugins must stay version-compatible; `doctor.sh` checks the sibling's version.
- The smoke contract grows per phase: compile `--check`, route dry-runs, hooks on garbage stdin emit exactly one JSON object and exit 0, ledger verify passes a sample chain and fails a tampered row, no forbidden flags in `bin/`, generated reviewers have no Bash.
