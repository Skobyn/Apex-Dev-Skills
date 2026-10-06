# apex-dispatch

**Route and govern every delegation.** A compiled routing policy picks the tier, provider, fan-out and review shape for each task or ad-hoc ask; PreToolUse/SubagentStop hooks enforce it; provider shims run external workers; every route, spawn, worker run and verdict lands in a hash-chained ledger. Drives apex-scope-loop as its execution engine.

> **Status: 0.1.0, under construction.** Shipped so far: the manifest, the contract, the routing policy with its overlay and schema, `compile.sh`, the generated agents and the settings snippet. Routing (`route.sh`), the hook scripts, provider workers and the ledger land in later phases of the apex-dispatch plan; see [ADR-0001](docs/adrs/0001-apex-dispatch-contract.md).

## What it is

Three layers, each enforced by something a smoke test can assert:

- **Execution:** [apex-scope-loop](../apex-scope-loop) 0.3.0 is the only loop (init → iterate → green gate → risk tier → review → checkpoint → land). apex-dispatch ships no second loop and no second state directory.
- **Routing and governance (this plugin):** `policy.json` compiles to hooks, generated agents and a settings snippet; `route.sh` chooses tier, provider, fan-out and review shape; hooks enforce what was routed; provider shims run external workers; a hash-chained ledger records it all.
- **Decision (optional):** a typed decision layer consumed only through `${APEX_DECIDE_CMD}`; absent, routing is table-only.

Hard rules outrank verdicts. No new model-judged gates.

## Policy and compile

| File | Role |
|---|---|
| `resources/dispatch.default.json` | The canonical policy: `tiers`, `providers`, `roles`, `classes`, `tag_classes`, `hard_rules`, `escalation`, `semantic`, `pruning`, `mcp`, `disabled`. Every list entry has a stable `id`. |
| `resources/sections.json` | The section registry: each section's kind (`map` or `list`) and merge rule, registered once. |
| `resources/schema.json` | Hand-written schema checked by `scripts/lib/compile.py` (python3 stdlib): required keys, types, enums (model alias `sonnet\|opus\|haiku\|fable`, effort `low\|medium\|high\|xhigh`) and references (rosters name roles, `providers_allowed` names providers, `tag_classes` name classes). |
| `.claude/apex-dispatch/policy.json` | Optional per-repo overlay, found under `git rev-parse --show-toplevel` (or at `$APEX_DISPATCH_POLICY`). |

**Overlay rules.** A section the overlay omits is inherited. `[]` clears a list section. A non-empty list merges by `id`: a known id is merged field by field with the project winning, a new id is appended. Map sections deep-merge. `"disabled": [{"id": "...", "reason": "...", "section": "..."}]` removes entries after the merge and drops list references to them; a reason is required, and `section` is needed only when the id is ambiguous. `hard_rules` is add-only: an overlay may add rules but never clear, replace or disable one. An invalid overlay is a non-zero exit with every problem named.

**Overlay bounds.** An overlay configures policy within the hard rules and can never weaken confinement or change what a hard rule refers to. What it may change is an allowlist; anything else is refused with a named error:

- **providers:** only on providers the default defines (an overlay cannot add a provider): `enabled`; `allowed_classes` and `roles_allowed` narrowed to a subset of the default; `max_tier` lowered; `min_acceptance` raised; `forbidden_flags` added to (unioned onto the default's). Every other provider field (`forced_flags`, `binary`, `kind`, `family`, `sandbox_mode`, `hosts`, `key_env`, `reports_usage`, ...) is fixed.
- **tiers:** nothing. An overlay cannot change, add, clear or disable a tier.
- **roles:** a default role may lose tools but not gain them, may not stop being read-only and may not drop a disallowed tool; `reviewer` and `adversarial-reviewer` cannot be disabled because hard rules' review shapes need them.
- **hard_rules:** append only. Matching hard rules combine by max (strictest wins); an added `route_floor` rule may not be weaker than a default rule it overlaps and may not set `tier_ceiling`.
- **escalation:** `max_review_rounds` and the halt rung may be lowered, never raised above 3.
- **classes, tag_classes, semantic, pruning, mcp:** configurable, subject to the schema and the checks above.

**`scripts/compile.sh`** validates the default policy and writes the committed artifacts: `resources/compiled/policy.json` (the default policy, validated, sorted keys), `resources/compiled/VERSION` (plugin version and the sha256 of the inputs), `agents/<role>.md` for each enabled role plus `builder-high` and `builder-xhigh` for the escalation ladder, `resources/settings-snippet.json` (layer A deny rules and layer I sandbox settings, no `ask` rules) and `hooks/hooks.json`. Artifacts come from the default policy only; readers apply the overlay at runtime, so the hooks and `route.sh` must read the overlay-merged policy (`--print-merged`), not only `resources/compiled/policy.json`.

- `compile.sh --check` regenerates in memory and exits 1 naming every stale, missing or orphaned artifact, without writing.
- `compile.sh --print-merged [--overlay PATH]` prints this repo's merged policy.
- `--overlay PATH` on a plain or `--check` run validates that overlay as well.
- `hooks/hooks.json` registers only hook scripts that exist under `hooks/`, through a fixed event and matcher table; policy never changes registration. With no hook scripts yet it is `{"hooks": {}}`.
- `agents/` is fully generated and never edited by hand: `--check` flags any `agents/*.md` that is not an expected artifact, and compares bytes exactly. Edit the policy and recompile. Generated agents deliberately carry no `model:` line (it would be a default, not a pin; the model is enforced at spawn time). `reviewer-exec` is opt-in, so it is not generated while it is disabled in the default policy.

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

The smoke script checks the plugin contract (manifest keys, no enumerated surfaces, marketplace registration, README sections, ADR status, script executability) and the compiled policy: `compile.sh --check` passes, a stale artifact is caught, the overlay rules hold, invalid overlays are rejected, generated reviewers have no Bash and builders no `Agent`, `hooks.json` wraps `hooks`, and the settings snippet carries the deny rules. Route dry-runs, hook contracts and ledger verify come in later phases.

## Architecture Decisions

- [ADR-0001 — apex-dispatch plugin contract](docs/adrs/0001-apex-dispatch-contract.md) — Status: **Proposed**. Surface, namespace, dependency on apex-scope-loop, the governance layers and the smoke contract.

## License

MIT
