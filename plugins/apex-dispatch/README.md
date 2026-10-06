# apex-dispatch

**Route and govern every delegation.** A compiled routing policy picks the tier, provider, fan-out and review shape for each task or ad-hoc ask; PreToolUse/SubagentStop hooks enforce it; provider shims run external workers; every route, spawn, worker run and verdict lands in a hash-chained ledger. Drives apex-scope-loop as its execution engine.

> **Status: 0.1.0, under construction.** This release is the skeleton (manifest, contract, smoke). Routing, the compiled policy, hooks, provider workers and the ledger land in later phases of the apex-dispatch plan; see [ADR-0001](docs/adrs/0001-apex-dispatch-contract.md).

## What it is

Three layers, each enforced by something a smoke test can assert:

- **Execution:** [apex-scope-loop](../apex-scope-loop) 0.3.0 is the only loop (init → iterate → green gate → risk tier → review → checkpoint → land). apex-dispatch ships no second loop and no second state directory.
- **Routing and governance (this plugin):** `policy.json` compiles to hooks, generated agents and a settings snippet; `route.sh` chooses tier, provider, fan-out and review shape; hooks enforce what was routed; provider shims run external workers; a hash-chained ledger records it all.
- **Decision (optional):** a typed decision layer consumed only through `${APEX_DECIDE_CMD}`; absent, routing is table-only.

Hard rules outrank verdicts. No new model-judged gates.

## Compatibility

- **Claude Code:** 2.1.251+ (hook fields this plugin relies on are verified by `doctor.sh` when it ships)
- **apex-scope-loop:** 0.3.0+ as a sibling plugin (`APEX_SCOPE_LOOP_ROOT` overrides the lookup); without it apex-dispatch degrades to route + govern + ledger
- **git** 2.40+, **bash** 4+, **python3** 3.8+ (stdlib only)
- **ruflo:** not used

## Namespace coordination

This plugin claims the memory/state namespace **`apex-dispatch`**, following the kebab-case `<plugin-stem>-<intent>` convention:

| Key prefix | Holds |
|---|---|
| `apex-dispatch:routes/<plan-hash>/<line>` | Route decisions per plan task |
| `apex-dispatch:ledger/<plan-hash>` | Ledger head and export pointers |
| `apex-dispatch:providers` | Provider availability and rolling acceptance |

On disk it writes only under `<state>/dispatch/` and `<state>/adhoc/`, inside the `.dev-plan-state/` layout that apex-scope-loop's [ADR-0003](../apex-scope-loop/docs/adrs/0003-portability-and-dispatch-consumer.md) owns (including the `ACTIVE` lock).

## Verification

```bash
bash plugins/apex-dispatch/scripts/smoke.sh
```

The smoke script checks the plugin contract (manifest keys, no enumerated surfaces, marketplace registration, README sections, ADR status, script executability) and grows with each phase (compile `--check`, route dry-runs, hook contracts, ledger verify).

## Architecture Decisions

- [ADR-0001 — apex-dispatch plugin contract](docs/adrs/0001-apex-dispatch-contract.md) — Status: **Proposed**. Surface, namespace, dependency on apex-scope-loop, the governance layers and the smoke contract.

## License

MIT
