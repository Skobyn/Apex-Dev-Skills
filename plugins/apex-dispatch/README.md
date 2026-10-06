# apex-dispatch

**Route and govern every delegation.** A compiled routing policy picks the tier, provider, fan-out and review shape for each task or ad-hoc ask; PreToolUse/SubagentStop hooks enforce it; provider shims run external workers; every route, spawn, worker run and verdict lands in a hash-chained ledger. Drives apex-scope-loop as its execution engine.

> **Status: 0.1.0, under construction.** Shipped so far: the manifest, the contract, the routing policy with its overlay and schema, `compile.sh`, the generated agents, the settings snippet, table-only routing (`route.sh`), the hash-chained ledger (`ledger.sh`), `report.sh` and `doctor.sh`. The hook scripts and provider workers land in later phases of the apex-dispatch plan; see [ADR-0001](docs/adrs/0001-apex-dispatch-contract.md).

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

## Routing (`scripts/route.sh`)

```bash
route.sh plan PLAN --line N [--base SHA] [--lanes L1,L2] [--dry-run]   # one plan task (iterate.sh calls this)
route.sh adhoc --tags CSV [--paths GLOBS] [--acceptance CMD] [--dry-run] # an ad-hoc ask: caller-supplied tags only
route.sh escalate ROUTE_ID [--state DIR]  # next rung; checkpoint.sh fail passes its state dir and prefixes ESCALATE_ROUTE:
route.sh review-shape TIER          # or: review-shape ROUTE_ID --tier TIER
route.sh --version                  # == plugin.json version
```

A pure function of trusted features (tags, Acceptance presence and whether it holds a runnable command, `Route:`/`Paths:`/`Budget:` directives, the persisted risk tier or the tag floor, consecutive failures, toolchain markers on disk) plus the merged policy; no free text enters the state object. In order: kill switches (`APEX_HALT=1`, the HALT files apex-scope-loop honours, a halted checkpoint, the escalation HALT rung) → `HALTED`; another `ACTIVE` owner → `BUSY`; no Acceptance, or no command where the class needs one → `NEEDS_SPEC` with `ROUTE_MISSING`; a `[gate:…]` task → `HUMAN_GATE`; hard floors (`hard_rules`); the class (`Route: class=` unless below a floor, else `tag_classes`, else `auto` → feature); the decision seam for a class still `auto`; tier → model, effort, provider (`claude-session` unless the policy, the class and an installed binary allow another); fan-out (lanes only with `--lanes`, a lanes class, `fanout=lanes` and pairwise-disjoint `Paths`; never Tier C); review shape from the risk tier (A solo, B six-lens, C six lenses + adversarial, diversity block, G12); the escalation rung after a failure.

It prints a `KEY: VALUE` block: `ROUTE_STATUS` (`READY|NEEDS_SPEC|HUMAN_GATE|HALTED|BUSY`), `ROUTE_ID`, `ROUTE_MODE` (`table|decision|escalated|baseline|shadow`), `ROUTE_CLASS`, `ROUTE_TIER`, `ROUTE_RISK_TIER`, `ROUTE_MODEL`, `ROUTE_EFFORT`, `ROUTE_PROVIDER`, `ROUTE_ROSTER`, `ROUTE_FANOUT`, `ROUTE_LANES`, `ROUTE_REVIEW_SHAPE`, `ROUTE_DIVERSITY`, `ROUTE_HUMAN_GATE`, `ROUTE_BUDGET_USD/SPAWNS/MINUTES`, `ROUTE_MISSING`, `ROUTE_FLOORS`, `SEMANTIC_SOURCE`, and `ROUTE_NOTE` lines. Every status exits 0. Without `--dry-run` a READY route is written atomically to `<D>/active-route.json` and appended as a `route` row to the hash-chained `<D>/ledger.jsonl` (`escalate` appends an `escalate` row), where `<D>` is the dispatch directory below (`<state>` is the plan's state dir, or `<state-base>/adhoc/<id>/` for an ad-hoc ask). `--dry-run` writes nothing and ignores the `ACTIVE` lock.

### Enforcement switch (transitional)

`<state>/dispatch/` existing is what puts apex-scope-loop's `checkpoint.sh` into provenance mode (verdicts need hook-written `reviews-raw` records, `complete` needs `ledger.sh evidence`). Until the hooks that write those records ship (Phase 3.2, `hooks/subagent-stop.sh`), creating it would wedge every loop at `checkpoint.sh review`. So `<D>` is:

- `<state>/dispatch/` when `APEX_DISPATCH_ENFORCE=1`, or when `hooks/subagent-stop.sh` exists in this plugin, or when `<state>/dispatch/` already exists (an enforcing run started it; one chain is kept);
- otherwise `<state>/dispatch-shadow/`: the same files (route block, `active-route.json`, ledger, `doctor.json`), which apex-scope-loop does not treat as dispatch state. `checkpoint.sh fail` still relays `route.sh escalate` from it.

The ROUTE block prints `ROUTE_ENFORCED: yes|no` beside `ROUTE_FILE`. The switch removes itself: once `hooks/subagent-stop.sh` ships, enforcement is the default.

- **Decision seam:** with `APEX_DECIDE_CMD` set, a class still `auto` is asked of `$APEX_DECIDE_CMD --rubric dispatch/task-class@1 --state <json> --json` within `semantic.timeout_ms`; an invalid, failed or timed-out answer is `SEMANTIC_SOURCE: table`; an uncalibrated answer may only move the route safer or more expensive (`decision-shadow` otherwise); `uncertain` raises the tier to `semantic.uncertain_tier`. Without it routing is table-only.
- **`APEX_DISPATCH_MODE`:** `baseline` emits the 0.2.0 route (the orchestrator's own choice) and records the table's choice as `ROUTE_TABLE_CHOICE`; `shadow` also runs the decision seam, logs it, and emits the baseline route; `off` prints `ROUTE: none`.
- **Dependencies:** route.sh resolves `.dev-plan-state/`, the kill switches, the `ACTIVE` lock and plan parsing through the sibling apex-scope-loop (`APEX_SCOPE_LOOP_ROOT` overrides the lookup).

## Ledger (`scripts/ledger.sh`)

```bash
ledger.sh append EVENT JSON|- --state DIR --source hook|shim|cli [--route-id R] [--head SHA] [--route-mode M]
ledger.sh verify --state DIR
ledger.sh evidence --state DIR --line N --head SHA
ledger.sh export-trace --state DIR [--out F]
ledger.sh export --state DIR [--plan PLAN] [--out F]
ledger.sh baseline capture --state DIR [--label L]
```

One writer, `scripts/lib/ledger.py` (route.py imports it; hooks and shims call `ledger.sh append`). Events and their required fields are in `resources/ledger-events.json`: `route`, `spawn_request`, `spawn`, `worker_run`, `verdict`, `escalate`, `hook_error`, `hook_advisory`, `human_gate`, `baseline`, `decision_shadow`. An unknown event, a missing or mistyped field, a value outside an enum, an unknown source or a caller-supplied `seq`/`prev_hash`/`hash` is refused (exit 1). Each row is stamped with `seq`, `event`, `ts`, `source`, `route_id`, `head_sha`, `route_mode` (explicit, else the row's own, else `active-route.json`'s; `head_sha` else the worktree's HEAD), `doctor_profile`, `prev_hash` and `hash` = sha256 of the canonical JSON of the row without `hash` (sorted keys, `,`/`:` separators, ASCII). Appends take an exclusive `flock` on `<D>/ledger.lock`, write one line with a single `O_APPEND` write and `fsync`, then replace `<D>/ledger.head` (`{seq, hash}`) atomically; an append onto a torn or rewritten tail is refused.

- **`verify`** walks the chain and exits 1 naming the first bad row: *tampered* (content does not hash, or a rewritten-and-rehashed row breaks the next `prev_hash`), *deleted* (a `seq` gap), *reordered* (a `seq` out of place), *truncated* (`ledger.head` is ahead of the last row; a last row rewritten and rehashed also disagrees with it), or a torn last line. `land.sh` calls it. Limit: whoever can rewrite both the ledger and `ledger.head` can forge a consistent chain; the chain detects edits, it does not authenticate the writer.
- **`evidence`** (`checkpoint.sh complete` calls it) exits 0 only when **all** hold: (1) the chain verifies; (2) a `route` row with status READY names line N (its `line` field, or the `L<N>` of an `r-<plan-hash>-L<N>-<k>` id); (3) that route row's `head_sha` is `--head` or an ancestor of it in the state's worktree (a route from a discarded fork does not count; a row with no `head_sha` passes this step); (4) at least one `spawn_request`, `spawn` or `worker_run` row carries that route's `route_id` (the work was delegated, not done inline). Otherwise it exits 1 with the missing condition; malformed arguments exit 2.
- **`export-trace`** writes one apex-agent-observability AgentTrace line per row, exactly `ts, event, session, subagent_id, parent_id, tool, token_estimate, edge` (`spawn_request` → `PreToolUse`/`Agent`, `spawn` → `SubagentStart` with the `route->agent` edge, `worker_run`/`verdict` → `SubagentStop`, others `Dispatch:<event>`; `token_estimate` = real usage tokens or 0); stdout without `--out`. **`export`** writes a `ledger_head` row plus one `task_summary` row per routed task (default `<D>/export/summary.jsonl`; land.sh calls it). Both refuse a chain that does not verify. **`baseline capture`** appends a `baseline` row (label default `baseline@0.3.0`, plugin versions, policy inputs hash).

## Report and doctor

- **`scripts/report.sh --state DIR | --plan PLAN [--json]`** prints `REPORT_*` lines: chain status, routes by class / tier / provider / mode, spawns, verdicts, escalations, tokens, estimated USD (real `usage` × the policy's tier prices, for rows with a `resolved_model` of a known family, or a row's own `usd`) and the **unverified** bucket (usage without a resolved model), which is listed separately and excluded from USD.
- **`scripts/doctor.sh [--state DIR | --plan PLAN] [--repo DIR]`** writes `<D>/doctor.json` (a temporary state without `--state`/`--plan`), one entry per check with status `ok | warn | fail | unverified | skipped`: `claude` binary ≥ 2.1.251 (absent or older → fail; `APEX_CLAUDE_BIN` overrides the name), apex-scope-loop ≥ 0.3.0, apex-guardrails present, `compile --check`, the merged policy, each enabled provider's binary and version (missing → warn, routes fall back to `claude-session`; `claude -p` auth recorded for the Tier C diversity degrade), `CLAUDE_CODE_SUBAGENT_MODEL*` unset (fail if set), the settings snippet's deny rules in `.claude/settings.json` (warn if not), compiled vs `plugin.json` version, installed vs `plugin.json` version, `claude plugin validate`. Forced-flag and sandbox probes (Phase 4 shims) and the live-session probes (`agent_id` in subagent tool stdin, `updatedInput` on Agent, `${CLAUDE_PLUGIN_ROOT}` in hooks, mods) are recorded as `unverified` with the reason. Exit 0 ok/warn, 1 fail (the JSON is still written), 2 usage.

## Compatibility

- **Claude Code:** 2.1.251+ (hook fields this plugin relies on are verified by `doctor.sh` when it ships)
- **apex-scope-loop:** 0.3.0+ as a sibling plugin (`APEX_SCOPE_LOOP_ROOT` overrides the lookup); `route.sh` uses its state resolution, kill switches, `ACTIVE` lock and plan parser, and exits 1 without it
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

The smoke script checks the plugin contract (manifest keys, no enumerated surfaces, marketplace registration, README sections, ADR status, script executability) and the compiled policy: `compile.sh --check` passes, a stale artifact is caught, the overlay rules hold, invalid overlays are rejected, generated reviewers have no Bash and builders no `Agent`, `hooks.json` wraps `hooks`, and the settings snippet carries the deny rules. It also runs `route.sh` against a fixture repo: `--version` equals `plugin.json`; NEEDS_SPEC without Acceptance or a command; HUMAN_GATE for `[gate:]`; `class=security` floor for `[tier:c]`; lanes only with disjoint Paths; HALTED with `APEX_HALT=1` or a HALT file; BUSY under another plan's or an ad-hoc lock; escalate rungs; review shapes; `adhoc` requires `--tags`; baseline/shadow/off; the decision seam absent, uncalibrated, calibrated and invalid. Ledger: append validates and stamps; `verify` fails tampered, rehashed, deleted, reordered, truncated and torn ledgers; route.sh's rows verify; `evidence` semantics; the enforcement switch; `export-trace` line shape; `report.sh` on a sample; `doctor.sh` writes valid JSON with a status per check. Hook contracts come in later phases.

## Architecture Decisions

- [ADR-0001 — apex-dispatch plugin contract](docs/adrs/0001-apex-dispatch-contract.md) — Status: **Proposed**. Surface, namespace, dependency on apex-scope-loop, the governance layers and the smoke contract.

## License

MIT
