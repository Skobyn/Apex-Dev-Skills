# apex-decision-layer

**Typed answers for the questions routing leaves to judgment.** Typed, probability-carrying answers for the questions apex-dispatch and apex-scope-loop leave to judgment (task class, risk tier): one CLI, rubric files, a fail-closed validator for every backend, tri-state uncertainty, and calibration that only a measurement job can grant. Off until a repo opts in; absent, slow or unconfigured, routing stays table-only.

> **Status: 0.2.0, Phase 2.** Shipped:
> - the `apex-decide` CLI, the validator, the two v1 rubrics and their linter, calibration lookup, the decision log and detached shadow calls (Phase 1);
> - the hosted backends: `jev` over TypeSafe or OpenRouter, and `frontier` on the Anthropic Messages API;
> - one transport policy for both (deadline, retries, circuit breaker, host pin, TLS);
> - `doctor --probe`.
>
> Not yet: the labelling and measurement job that can mark a rubric calibrated (Phase 3). Every answer is uncalibrated until then. Spec: [`2026-10-08-apex-decision-layer-design.md`](../../docs/superpowers/specs/2026-10-08-apex-decision-layer-design.md).

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
- `jev.transport` is `typesafe` (`TYPESAFE_API_KEY`, else `JEV_API_KEY`) or `openrouter` (`OPENROUTER_API_KEY`, the default). The two accept different model ids, so each rubric pins one per transport in `backend_models.jev`. `api_key_env` names a different variable.
- A missing key, an unreachable host or a refusal is `provider_error`. The consumer then takes its deterministic path.
- In a cloud session whose network proxy injects the provider key, the variable is absent in the container. Set it to any placeholder (a distinctive one, for example `OPENROUTER_API_KEY=proxy-injected-key`), and the proxy replaces it on the wire. The placeholder is scrubbed like a real key.

## Hosted backends

| Backend | Endpoint | Key | Model (v1 rubrics) |
|---|---|---|---|
| `jev`, transport `typesafe` | `POST https://api.typesafe.ai/v1/systemone` | `TYPESAFE_API_KEY` or `JEV_API_KEY` | `jev-1.13.0` |
| `jev`, transport `openrouter` | `POST https://openrouter.ai/api/v1/systemone` | `OPENROUTER_API_KEY` | `typesafe/jev-1.13-20260917` |
| `frontier` | `POST https://api.anthropic.com/v1/messages`, `output_config.format` json_schema | `ANTHROPIC_API_KEY` | `claude-haiku-5-5` |

Every envelope records `model_requested` and `model_resolved`, the provider's `response.model`. `usage.cost` is the provider's figure when it reports one (OpenRouter). Otherwise it is estimated from the price and marked `cost_estimated`.

Transport policy (spec §6.4), the same for both backends:
- **Deadline:** one wall-clock deadline (`--deadline-ms`) covers every attempt.
- **Retries:** only 408, 429 and 5xx are retried, at most three attempts. `Retry-After` is honoured only when it fits the deadline. No retry is made when less than twice the observed p50 latency remains.
- **Circuit breaker:** 3 failed calls in 30 s open it for 30 s. The state, with the latency samples, is kept in `transport.json` beside the decision log, so consecutive CLI processes share it.
- **Responses:** a body over 4 MiB, or a 2xx that is not JSON, is an error.
- **Host:** pinned. `APEX_DECIDE_JEV_BASE` and `APEX_DECIDE_FRONTIER_BASE` are accepted only for a loopback host, for tests. Redirects are refused.
- **TLS:** always verified. `SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE` are added to the trust store, which is how a proxy CA is trusted.
- **Keys:** never in an envelope, an error, the decision log or `transport.json`. Errors redact the key, and every printed or logged line is scrubbed.

frontier sends the three-part system prompt and the state inside `<document>…</document>` with `&`, `<` and `>` escaped. It converts the JSON answer to the System One shape without rescaling it. A map that sums to 1.2, an all-zero map and a tie are rejected by the validator. A refusal or a truncated answer (`max_tokens`) is `provider_error`.

## CLI

```bash
bin/apex-decide --rubric risk-tier@1 --state - --json < state.json   # ask (exit 0 scored, 3 unscored)
bin/apex-decide lint [rubric.json ...]                                # authoring rules + question_hash
bin/apex-decide doctor [--json] [--probe]                             # config, egress, keys present, reachability, rubrics
```

Slash commands: `/apex-decision-layer:decide <rubric> <state-json>`, `/apex-decision-layer:lint` and `/apex-decision-layer:doctor [--probe]`. Skill: `decision-rubric` (how to write and version a rubric).

## Compatibility

- **Claude Code:** any version that loads plugins. The plugin has no hooks, agents or MCP servers.
- **python3** 3.8+ (stdlib only), **bash** 4+, **git** (to find the repository and its run state).
- **Consumers:** apex-dispatch ≥ 0.5.0 (≥ 0.5.1 also tamper-protects `APEX_DECIDE_FRONTIER_BASE`) and apex-scope-loop ≥ 0.4.2 find this plugin as a sibling (`APEX_DECISION_LAYER_ROOT` overrides the lookup, `APEX_DECIDE_CMD` replaces the CLI). Older consumers call it only when `APEX_DECIDE_CMD` points at `bin/apex-decide`.
- **Network:** OpenRouter (`openrouter.ai`) or TypeSafe (`api.typesafe.ai`) for `jev`; `api.anthropic.com` for `frontier`. Only with `egress: hosted`. Proxies are taken from `HTTPS_PROXY` / `NO_PROXY`.

## Namespace coordination

This plugin claims the memory/state namespace **`apex-decision-layer`**, following the kebab-case `<plugin-stem>-<intent>` convention:

| Key prefix | Holds |
|---|---|
| `apex-decision-layer:rubrics/<rubric_id>@<v>` | Rubric metadata and `question_hash` |
| `apex-decision-layer:calibration/<rubric_id>@<v>/<backend>` | Calibration record summary |
| `apex-decision-layer:decisions/<decision_id>` | Pointer into the decision log |

On disk it writes `<state-base>/decisions/decisions.jsonl` and `<state-base>/decisions/transport.json` (the hosted backends' circuit breaker and latency samples), beside apex-scope-loop's run state; apex-scope-loop ADR-0003 names the subdirectory). It reads, and never writes, `.claude/apex-decision-layer/` in the consumer repository (config, `calibration/`, later `labels/`). apex-dispatch's hooks protect that directory and this plugin during a run.

## Verification

```bash
bash plugins/apex-decision-layer/scripts/smoke.sh
```

The smoke test runs the repository's ten structural checks (manifest, registration, README sections, ADR status, executability, frontmatter). It then runs behaviour checks against the scripted `fake` backend and, for `jev` and `frontier`, against loopback stub servers (`scripts/test/stub_http.py`). It never touches the network, and it unsets any real API key first:
- lint and `question_hash`;
- every validator rejection;
- tri-state thresholds;
- calibration lookup;
- the deadline;
- egress and untrusted-field handling;
- hard rules;
- detached shadow calls and the decision log;
- jev over both transports and frontier: the request shape, the per-transport model id, `response.model` and cost, and every failure mode (sums of 1.2, all-zero maps, ties, invalid JSON, refusals, truncation);
- the transport policy: retries only on 408, 429 and 5xx, `Retry-After`, the 2× p50 rule, the deadline, the 4 MiB cap, non-JSON 2xx, redirects, and the circuit breaker opening, persisting and closing;
- the host pin, egress and TLS (a self-signed certificate is rejected, and `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE` are honoured);
- no key leakage, and `doctor` key presence and `--probe`;
- both consumers end to end, including a ROUTE block that is identical with the plugin installed but unconfigured.

## Architecture Decisions

- [ADR-0001 — apex-decision-layer plugin contract](docs/adrs/0001-apex-decision-layer-contract.md) — Status: **Proposed**. CLI and envelope, pinned rubric ids, the validator, calibration records, egress, the hosted backends and their transport policy (0.2.0), the decision log, the namespace, the Phase 0 numbers and the smoke contract.

## License

MIT
