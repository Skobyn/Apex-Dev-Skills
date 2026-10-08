# ADR-0001: apex-decision-layer plugin contract

- **Status:** Proposed
- **Date:** 2026-10-08
- **Author:** solutions@getapexinsights.com
- **Plugin:** apex-decision-layer v0.1.0 (Phase 1: the CLI, the `none` and `fake` backends, the validator, rubrics and lint, calibration lookup, the decision log, shadow calls)
- **Spec:** `docs/superpowers/specs/2026-10-08-apex-decision-layer-design.md`; Phase 0 results in `docs/research/apex-decision-layer-phase0.md`

## Context

apex-dispatch's routing step and apex-scope-loop's `risk-tier.sh --classify` already call a decision CLI through `APEX_DECIDE_CMD` for two questions code cannot answer: a task's class when its tags do not say, and whether a diff touches something the path heuristics missed. Nothing implemented that CLI, so both fell through to their deterministic path every time. The parent spec (apex-dispatch design §4) fixed the contract and the laws; this plugin implements them.

## Decision

Ship **apex-decision-layer** as its own plugin. It has no hooks. Its consumers call it as a sibling.

- **Surface:** `bin/apex-decide` (`ask` | `lint` | `doctor`; `label`, `corpus`, `measure` and `replay` are reserved for Phase 3 and exit 2), `scripts/lib/decide.py`, `scripts/lib/backends/`, `rubrics/<id>@<v>.json`, commands `decide` and `lint`, skill `decision-rubric`.
- **CLI contract** (spec §4): `apex-decide [ask] --rubric <id>@<v> (--state <json> | --state -) --json [--deadline-ms N] [--backend B] [--shadow | --no-shadow] [--repo DIR]`. It prints exactly one JSON envelope (`envelope: "apex-decide/1"`). Exit 0 means scored, `uncertain` included. Exit 3 means unscored, and the envelope names the reason: `backend_none`, `egress_disabled`, `deadline`, `provider_error`, `invalid_answer`, `model_mismatch`, `hard_rule`, `state_rejected`, `rubric_unknown` or `config_invalid`. Exit 2 is a usage error and exit 1 an internal error, both with stdout empty. The default `--deadline-ms` is 1500.
- **Envelope:** the top-level `verdict`, `probabilities`, `uncertain`, `confidence` and `calibrated` describe the rubric's `primary` question, and `answers` carries every question. `probabilities` keys are exactly the primary question's labels, which for `dispatch/task-class@1` are the policy class ids plus `none`. `calibration` says why `calibrated` is what it is. `add_gate` is `null` or a gate id: a field that can add a gate, and no field that can remove one.
- **Pinned rubric ids:** `dispatch/task-class@1` and `risk-tier@1` ship. `dispatch/size@1`, `dispatch/lens-set@1`, `dispatch/contamination@1` and `escalation@1` are reserved and answer `rubric_unknown` until a consumer calls them. Ids are never renamed. Any change to what reaches the wire is a new version, and `question_hash` makes an edit made in place visible.
- **Validator** (spec §6.2), one for every backend, fail-closed:
  - The answered question ids must equal the asked ids.
  - Probability keys must equal the labels exactly.
  - Every probability must be a finite number in [0,1], never a boolean, and the map must sum to 1 ± 0.02.
  - An all-zero map is a missing answer, and so is a tie at the top.
  - `choice` must be the argmax, and a score must be within 0.02 of the distribution mean.
  - Unknown fields in a response are ignored. Phase 0 found `id`, `provider`, `answers.<id>.type` and `usage.cost` on OpenRouter.
  - Answers are never rescaled or clamped. Phase 0 saw a frontier map summing to 1.2 twice.
- **State:** fields on the rubric's allowlist are kept. Unknown fields are dropped and listed in the log, so a consumer can add a feature without breaking the call. A field of the wrong type, or a state over `max_bytes`, is `state_rejected` and is never truncated. `untrusted-text` fields reach a backend only when the repository sets `state_fields: raw`.
- **`calibrated` is never configured.** It is true only when a record at `.claude/apex-decision-layer/calibration/<id>@<v>/<backend>.json` meets all of these:
  - its sha256 is listed in the config's `calibration_lock`;
  - it says `passed: true` and has not been invalidated;
  - its rubric version, `question_hash`, backend and *resolved* model match the call.

  A matching record's thresholds replace the rubric's own thresholds.
- **Egress:** off by default. Without `.claude/apex-decision-layer/config.json`, every call answers `backend_none` in about 55 ms. Hosted backends (`jev`, `frontier`) run only with `egress: hosted`. `fake` is never configurable, except in a config read while `APEX_DECIDE_FAKE` is set for tests.
- **Backends in 0.1.0:** `none` and `fake`. `jev` and `frontier` are named and refuse with `provider_error` until Phase 2.
- **Shadow:** a second backend runs in a detached child after the primary envelope is printed. Its answer goes only to the decision log, with `shadow_of`.
- **Decision log:** `<state-base>/decisions/decisions.jsonl`, where `<state-base>` is apex-scope-loop's `apex_state_base`. Rows are appended under `flock`, one row per call or shadow answer. Nothing is created in a repository that has neither run state nor a decision-layer config. A failure to write the log never fails the call.
- **Namespace:** `apex-decision-layer:rubrics/<id>@<v>`, `apex-decision-layer:calibration/<id>@<v>/<backend>`, `apex-decision-layer:decisions/<decision_id>`. On disk the plugin writes `<state-base>/decisions/`, a subdirectory that apex-scope-loop ADR-0003 names, and nothing else outside its own directory.
- **Consumers** (apex-dispatch ≥ 0.4.0, apex-scope-loop ≥ 0.4.1) resolve the CLI as `APEX_DECIDE_CMD` (an override), else `APEX_DECISION_LAYER_ROOT/bin/apex-decide`, else the sibling `../apex-decision-layer/bin/apex-decide`. They call it as an argv list with `--state -` and `--deadline-ms`. During a run, apex-dispatch's hooks deny changes to those variables and writes to `.claude/apex-decision-layer/` and to this plugin's directory.
- **Smoke contract:** `scripts/smoke.sh` covers the repository's ten structural checks, plus behaviour against the `fake` backend only (no network): lint and the hash, every validator rejection, tri-state, calibration lookup, deadline, egress and untrusted fields, hard rules, shadow, the decision log, and both consumers end to end.

## Phase 0 numbers (spec §14)

| Measure | Result |
|---|---|
| CLI start-up (bash → python3 with stdlib imports → envelope) | p50 53–59 ms, p95 59–60 ms over four runs |
| `jev` via OpenRouter, one 8-label choice question | p50 256–274 ms, p95 308–373 ms, max 628 ms; 0 errors in 120 calls |
| `jev` via TypeSafe direct | p50 232 ms, p95 285 ms, max 460 ms; 0 errors in 40 calls |
| Frontier stand-in (Haiku via OpenRouter, strict JSON schema) | p50 1.1–1.5 s, p95 1.65–3.5 s; 2 to 5 of every 16 calls over the 1.6 s routing budget |
| Model ids | OpenRouter: `typesafe/jev-1.13-20260917` (dated; rejects `jev-1.13.0`). TypeSafe: `jev-1.13.0` (rejects every OpenRouter form) |
| Malformed answers | Jev: none in 160. Frontier: invalid JSON 2 of 16 in one run; a 1.2 sum in two runs |

Go/no-go: **go** on `jev` for routing (decision Q4). Frontier serves `risk-tier@1`, shadow and replay.

## Consequences

- An installed but unconfigured plugin costs each routed task about 55 ms and changes no route. The smoke test asserts that the ROUTE block is identical with and without it.
- Every answer is uncalibrated until Phase 3's measurement job locks a record, so it can only tighten: route.py moves a task only to a class that is safer or more expensive, and risk-tier.sh raises it at most to Tier B (decision Q3).
- `measure`, `label`, `corpus` and `replay` do not exist yet, so a calibration record can only be written by hand, and a hand-written record is exactly what `calibration_lock` makes the operator vouch for.
- Attribution: the validator, rubric schema, authoring rules, tri-state, measurement harness and secure-client posture are copied as patterns from the Jev-ecosystem repos listed in the spec's §16 (jegrep, jev-opus, jev-mcp, system-one-connector, jev-commit, is-malicious, semdecide, pytest-jev, hunch, jev-belay, winnow, jev-skill-router, TypeSafe's system-one-adapter-python, JevRouter). No code or dependency is taken from them.

## Deviations from the spec text

- **Unknown state fields are dropped, not rejected** (spec §4.2 said `state_rejected`). The consumer's routing features change between versions, and rejecting each new field would make every call unscored until the rubric is reissued. Dropped names are logged in `dropped_fields`.
- **`config_invalid`** is added as a reason code, for a repository config that fails validation.
- **No separate schema files.** The checks live in `decide.py`'s `lint` and config validation, the same approach as `apex-dispatch/scripts/lib/compile.py`, rather than in `resources/*.schema.json`.
- **`state_fields` applies to every backend**, `fake` included, so smoke can assert what a hosted backend would receive.
- **`doctor` ships in Phase 1**, with the config, egress, key-presence and rubric checks.
- **The frontier model id is `claude-haiku-5-5`, an alias rather than a dated id.** A dated id is pinned in Phase 2, once a native call measures it.

## Status log

- 2026-10-08 — Proposed with v0.1.0 (Phase 1).
