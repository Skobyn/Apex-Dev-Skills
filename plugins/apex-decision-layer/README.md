# apex-decision-layer

**Typed answers for the questions routing leaves to judgment.** Typed, probability-carrying answers for the questions apex-dispatch and apex-scope-loop leave to judgment (task class, risk tier): one CLI, rubric files, a fail-closed validator for every backend, tri-state uncertainty, and calibration that only a measurement job can grant. Off until a repo opts in; absent, slow or unconfigured, routing stays table-only.

> **Status: 0.1.0, Phase 1.** Shipped: the `apex-decide` CLI, the `none` and `fake` backends, the validator, the two v1 rubrics and their linter, calibration lookup, the decision log and detached shadow calls. Not yet: the `jev` and `frontier` backends (Phase 2), and the labelling and measurement job that can mark a rubric calibrated (Phase 3). Spec: [`2026-10-08-apex-decision-layer-design.md`](../../docs/superpowers/specs/2026-10-08-apex-decision-layer-design.md).

## What it does

Two consumers ask it questions:

| Consumer | Rubric | What the answer can do |
|---|---|---|
| apex-dispatch `route.sh` (a task whose class is still `auto` after tags) | `dispatch/task-class@1` | Uncalibrated: move the task only to a safer or more expensive class. Uncertain: raise the tier to the middle tier. Calibrated with p ≥ 0.8: pick the class. |
| apex-scope-loop `risk-tier.sh --classify` | `risk-tier@1` | Raise the tier, never lower it. An uncalibrated answer raises at most to Tier B; only a calibrated `C` adds Tier C (G12 and the seven-reviewer fan-out). |

Each call prints one JSON envelope: the verdict, the probabilities, whether the answer is `uncertain`, whether it is `calibrated` and why, or, unscored (exit 3), the reason it has no answer. Consumers treat every unscored reason the same way: the deterministic path stands.

## Turning it on

Nothing leaves the machine until a repository opts in with `.claude/apex-decision-layer/config.json`:

```json
{ "egress": "hosted",
  "state_fields": "raw",
  "primary": { "default": "none", "dispatch/task-class@1": "jev", "risk-tier@1": "frontier" },
  "shadow": { "backend": "frontier", "sample": 0.2 },
  "jev": { "transport": "openrouter", "api_key_env": "OPENROUTER_API_KEY" },
  "frontier": { "provider": "anthropic", "api_key_env": "ANTHROPIC_API_KEY" } }
```

- `egress: none` (the default) refuses every hosted backend.
- `state_fields: structured` (the default) keeps task titles and Acceptance text out of every call. `raw` sends them, wrapped as untrusted data.
- Keys come only from the environment variable named for each backend. They are never written to config, rubrics, logs or envelopes.
- In 0.1.0 the hosted backends refuse with `provider_error` (they ship in Phase 2), so a configured repo still routes table-only.

## CLI

```bash
bin/apex-decide --rubric risk-tier@1 --state - --json < state.json   # ask (exit 0 scored, 3 unscored)
bin/apex-decide lint [rubric.json ...]                                # authoring rules + question_hash
bin/apex-decide doctor [--json]                                       # config, egress, keys present, rubrics
```

Slash commands: `/apex-decision-layer:decide <rubric> <state-json>` and `/apex-decision-layer:lint`. Skill: `decision-rubric` (how to write and version a rubric).

## Compatibility

- **Claude Code:** any version that loads plugins. The plugin has no hooks, agents or MCP servers.
- **python3** 3.8+ (stdlib only), **bash** 4+, **git** (to find the repository and its run state).
- **Consumers:** apex-dispatch ≥ 0.5.0 and apex-scope-loop ≥ 0.4.2 find this plugin as a sibling (`APEX_DECISION_LAYER_ROOT` overrides the lookup, `APEX_DECIDE_CMD` replaces the CLI). Older consumers call it only when `APEX_DECIDE_CMD` points at `bin/apex-decide`.
- **Network (Phase 2):** OpenRouter (`openrouter.ai`) or TypeSafe (`api.typesafe.ai`) for `jev`; `api.anthropic.com` for `frontier`.

## Namespace coordination

This plugin claims the memory/state namespace **`apex-decision-layer`**, following the kebab-case `<plugin-stem>-<intent>` convention:

| Key prefix | Holds |
|---|---|
| `apex-decision-layer:rubrics/<rubric_id>@<v>` | Rubric metadata and `question_hash` |
| `apex-decision-layer:calibration/<rubric_id>@<v>/<backend>` | Calibration record summary |
| `apex-decision-layer:decisions/<decision_id>` | Pointer into the decision log |

On disk it writes `<state-base>/decisions/decisions.jsonl` (beside apex-scope-loop's run state; apex-scope-loop ADR-0003 names the subdirectory). It reads, and never writes, `.claude/apex-decision-layer/` in the consumer repository (config, `calibration/`, later `labels/`). apex-dispatch's hooks protect that directory and this plugin during a run.

## Verification

```bash
bash plugins/apex-decision-layer/scripts/smoke.sh
```

The smoke test runs the repository's ten structural checks (manifest, registration, README sections, ADR status, executability, frontmatter). It then runs behaviour checks against the scripted `fake` backend only, with no network:
- lint and `question_hash`;
- every validator rejection;
- tri-state thresholds;
- calibration lookup;
- the deadline;
- egress and untrusted-field handling;
- hard rules;
- detached shadow calls and the decision log;
- both consumers end to end, including a ROUTE block that is identical with the plugin installed but unconfigured.

## Architecture Decisions

- [ADR-0001 — apex-decision-layer plugin contract](docs/adrs/0001-apex-decision-layer-contract.md) — Status: **Proposed**. CLI and envelope, pinned rubric ids, the validator, calibration records, egress, the decision log, the namespace, the Phase 0 numbers and the smoke contract.

## License

MIT
