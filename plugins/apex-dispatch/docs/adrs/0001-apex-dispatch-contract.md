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
- **Governance layers, strongest first:** loader-enforced tool presence in generated agents (`tools`/`disallowedTools`; reviewers have no Bash, no edits); PreToolUse denies from the compiled policy; Stop/SubagentStop checks; the ledger. Hard rules outrank model verdicts; no new model-judged gates.
- **Compatibility:** Claude Code 2.1.251+, git 2.40+, bash 4+, python3 3.8+ stdlib; no ruflo.

## Consequences

- Delegation becomes a recorded, enforced decision rather than prose.
- Two plugins must stay version-compatible; `doctor.sh` checks the sibling's version.
- The smoke contract grows per phase: compile `--check`, route dry-runs, hooks on garbage stdin emit exactly one JSON object and exit 0, ledger verify passes a sample chain and fails a tampered row, no forbidden flags in `bin/`, generated reviewers have no Bash.
