# ADR-0001: apex-decision-layer plugin contract

- **Status:** Proposed
- **Date:** 2026-10-08
- **Author:** solutions@getapexinsights.com
- **Plugin:** apex-decision-layer v0.2.0 (Phase 1 in v0.1.0: the CLI, the `none` and `fake` backends, the validator, rubrics and lint, calibration lookup, the decision log, shadow calls. Phase 2 in v0.2.0: the `jev` and `frontier` backends, the transport policy, `doctor --probe`)
- **Spec:** `docs/superpowers/specs/2026-10-08-apex-decision-layer-design.md`; Phase 0 results in `docs/research/apex-decision-layer-phase0.md`

## Context

apex-dispatch's routing step and apex-scope-loop's `risk-tier.sh --classify` already call a decision CLI through `APEX_DECIDE_CMD` for two questions code cannot answer: a task's class when its tags do not say, and whether a diff touches something the path heuristics missed. Nothing implemented that CLI, so both fell through to their deterministic path every time. The parent spec (apex-dispatch design §4) fixed the contract and the laws; this plugin implements them.

## Decision

Ship **apex-decision-layer** as its own plugin. It has no hooks. Its consumers call it as a sibling.

- **Surface:** `bin/apex-decide` (`ask` | `lint` | `doctor`; `label`, `corpus`, `measure` and `replay` are reserved for Phase 3 and exit 2), `scripts/lib/decide.py`, `scripts/lib/backends/`, `rubrics/<id>@<v>.json`, commands `decide`, `lint` and `doctor`, skill `decision-rubric`.
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
- **Backends:** `none` and `fake` (0.1.0), and the hosted `jev` and `frontier` (0.2.0, spec §6.4–§6.5). A hosted backend runs only with `egress: hosted` and a key in its environment variable. Without a key it answers `provider_error` and opens no socket.
  - **`jev`.** `jev.transport` selects the endpoint. `typesafe` is `POST https://api.typesafe.ai/v1/systemone` with `TYPESAFE_API_KEY`, else `JEV_API_KEY`. `openrouter` (the default) is `POST https://openrouter.ai/api/v1/systemone` with `OPENROUTER_API_KEY`. `jev.api_key_env` names a different variable. The model id is `backend_models.jev[<transport>]`, because the transports accept disjoint ids (Phase 0). Untrusted fields go on the wire as `untrusted_<field>`, and `data_handling` ends every question's instructions.
  - **`frontier`.** `POST https://api.anthropic.com/v1/messages` with `ANTHROPIC_API_KEY` and `anthropic-version: 2023-06-01`. Structured output uses `output_config.format` (`json_schema`: one required number per label, no additional properties). The request carries the three-part system prompt and the state in `<document>` with `&`, `<` and `>` escaped, and sends no temperature. The answer is converted to the wire shape with confidence `(max − 1/n)/(1 − 1/n)` and is never rescaled. Invalid JSON is `invalid_answer`. `stop_reason` `refusal` or `max_tokens`, or no text block, is `provider_error`.
  - **Recorded per call:** `model_resolved` is the provider's `response.model`. `usage.cost` is the provider's figure (OpenRouter), or an estimate from the price marked `cost_estimated: 1` (TypeSafe at $0.042 per million input tokens; Haiku 5.5 at $0.10/$0.50). The decision-log row keeps the raw response and `transport: {transport, attempts, http_latency_ms}`.
- **Transport policy** (spec §6.4, `scripts/lib/backends/transport.py`, both hosted backends):
  - **Deadline:** one wall-clock deadline for all attempts, `--deadline-ms` less a 30 ms local margin.
  - **Retries:** only 408, 429 and 5xx, at most three attempts. `Retry-After` in seconds is honoured only when it fits; an HTTP-date is not honoured. No retry is made when less than 2× the observed p50 remains. The p50 comes from the last 20 successes, with the Phase 0 p50 as the prior.
  - **Circuit breaker:** 3 failed calls in 30 s (a call counts once, however many attempts it made). It is persisted in `<state-base>/decisions/transport.json` under `flock`.
  - **Responses:** capped at 4 MiB. A non-JSON 2xx is `provider_error`.
  - **Host:** pinned. `APEX_DECIDE_JEV_BASE` and `APEX_DECIDE_FRONTIER_BASE` are accepted only for `127.0.0.1`, `::1` or `localhost`, and loopback bypasses any proxy. Redirects are refused.
  - **TLS:** always verified, with `SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE` added to the default trust store.
  - **Keys:** sent only in the request header. They are redacted from error text, and every envelope and log line is scrubbed of the known key variables' values.
- **`doctor`:** for each hosted backend it reports whether a key is present (the variable's name, never its value) and the pinned endpoint. With `--probe` it sends one empty JSON object through the same transport (free, since the provider rejects it before any model runs) and reports reachable, key rejected or unreachable.
- **Shadow:** a second backend runs in a detached child after the primary envelope is printed. Its answer goes only to the decision log, with `shadow_of`.
- **Decision log:** `<state-base>/decisions/decisions.jsonl`, where `<state-base>` is apex-scope-loop's `apex_state_base`. Rows are appended under `flock`, one row per call or shadow answer. Nothing is created in a repository that has neither run state nor a decision-layer config. A failure to write the log never fails the call.
- **Namespace:** `apex-decision-layer:rubrics/<id>@<v>`, `apex-decision-layer:calibration/<id>@<v>/<backend>`, `apex-decision-layer:decisions/<decision_id>`. On disk the plugin writes `<state-base>/decisions/`, a subdirectory that apex-scope-loop ADR-0003 names, and nothing else outside its own directory.
- **Consumers** (apex-dispatch ≥ 0.5.0, apex-scope-loop ≥ 0.4.2) resolve the CLI as `APEX_DECIDE_CMD` (an override), else `APEX_DECISION_LAYER_ROOT/bin/apex-decide`, else the sibling `../apex-decision-layer/bin/apex-decide`. They call it as an argv list with `--state -` and `--deadline-ms`. During a run, apex-dispatch's hooks deny changes to those variables and writes to `.claude/apex-decision-layer/` and to this plugin's directory.
- **Smoke contract:** `scripts/smoke.sh` covers the repository's ten structural checks, plus behaviour with no network.
  - Against the `fake` backend: lint and the hash, every validator rejection, tri-state, calibration lookup, deadline, egress and untrusted fields, hard rules, shadow, and the decision log.
  - Against loopback stub servers (`scripts/test/stub_http.py`), since 0.2.0: both jev transports and frontier, the transport policy, the host pin, TLS, every failure mode, no key leakage, and `doctor`.
  - The consumers end to end live in their own smoke tests.
  - Smoke unsets any real API key before it starts.

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
- **The frontier model id stays `claude-haiku-5-5`.** Current Claude model ids carry no date suffix, so no dated snapshot exists to pin. `model_pin: record` keeps `response.model` on every call, and calibration keys on it, so a provider-side change of the resolved model leaves the answer uncalibrated.
- **`APEX_DECIDE_FRONTIER_BASE`** (0.2.0) is a loopback-only test override for the frontier backend, beside the spec's `APEX_DECIDE_JEV_BASE`. apex-dispatch 0.5.1 adds it to `TAMPER_ENV`.
- **`doctor --probe` is opt-in.** A plain `doctor` makes no request, so apex-dispatch's `doctor.sh` and hooks can call it offline.
- **Retries are capped at three attempts**, and network errors are not retried. The spec says only "retry only 408/429/5xx".
- **frontier sends `output_config.effort: "low"` and no `thinking` parameter.** That keeps classification latency down on every current model. Haiku 5.5 rejects non-default sampling parameters, so no temperature is sent.

## Status log

- 2026-10-08 — Proposed with v0.1.0 (Phase 1).
- 2026-10-08 — v0.2.0 (Phase 2): the `jev` (TypeSafe and OpenRouter) and `frontier` (Anthropic Messages, `output_config.format`) backends, the §6.4 transport policy with the breaker persisted in `decisions/transport.json`, `APEX_DECIDE_FRONTIER_BASE`, `doctor` key presence and `--probe`, the `doctor` command, and smoke checks 22–27 against loopback stubs. The contract additions are under Decision; the deviations are listed above. Live verification is recorded in `docs/research/apex-decision-layer-phase0.md` § Phase 2. **No native Anthropic Messages call has been made from this environment, because no `ANTHROPIC_API_KEY` is available.** The frontier backend is verified against the loopback stub only (request shape, `output_config.format`, the escaped `<document>`, and every failure mode). The Phase 2 task scope calls for live frontier calls only when the key exists, so this does not block Phase 2; the spec exit criterion's "one live call per backend" then applies to `jev` only.
