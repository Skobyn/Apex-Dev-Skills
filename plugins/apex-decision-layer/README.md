# apex-decision-layer

**Typed answers for the questions routing leaves to judgment.** Typed, probability-carrying answers for the questions apex-dispatch and apex-scope-loop leave to judgment (task class, risk tier): one CLI, rubric files, a fail-closed validator for every backend, tri-state uncertainty, and calibration that only a measurement job can grant. Off until a repo opts in; absent, slow or unconfigured, routing stays table-only.

> **Status: 0.5.0, Phase 5 seeds.** Shipped:
> - the `apex-decide` CLI, the validator, the two v1 rubrics and their linter, calibration lookup, the decision log and detached shadow calls (Phase 1);
> - the hosted backends: `jev` over TypeSafe or OpenRouter, and `frontier` on the Anthropic Messages API;
> - one transport policy for both (deadline, retries, circuit breaker, host pin, TLS);
> - `doctor --probe`, and (0.2.1) a `calibration <rubric>/<backend>` check per calibration record (locked, passed, not drifted, on the rubric's current hash), which apex-dispatch ≥ 0.5.2 `doctor.sh` summarises.
>
> - (0.3.0) the measurement job: `label`, `corpus`, `measure` (with `--lock`) and `replay`, plus the [shadow-pilot runbook](docs/shadow-pilot.md).
>
> - (0.4.0) the lock flow tested end to end through apex-dispatch (`route.sh` takes a calibrated decision, `report.sh --decision` shows it), `replay --all`, and a weekly drift `/schedule` in the runbook.
>
> - (0.5.0) five seeded rubrics, shadow-only and never calibrated: `commit-hygiene@1`, `done-claim@1`, `code-review@1`, `tool-risk@1` and `relevance@1`, plus `scripts/shadow-commit-hygiene.sh`.
>
> Every answer stays uncalibrated until a human locks a record that passes the kill criterion. That needs weeks of real labels, so Phase 4's exit is **pending on data**, not done. Spec: [`2026-10-08-apex-decision-layer-design.md`](../../docs/superpowers/specs/2026-10-08-apex-decision-layer-design.md).

## What it does

Two consumers ask it questions:

| Consumer | Rubric | What the answer can do |
|---|---|---|
| apex-dispatch `route.sh` (a task whose class is still `auto` after tags) | `dispatch/task-class@1` | Uncalibrated: move the task only to a safer or more expensive class. Uncertain: raise the tier to the middle tier. Calibrated with p ≥ 0.8: pick the class. |
| apex-scope-loop `risk-tier.sh --classify` | `risk-tier@1` | Raise the tier, never lower it. An uncalibrated answer raises at most to Tier B; only a calibrated `C` adds Tier C (G12 and the seven-reviewer fan-out). |

Each call prints one JSON envelope: the verdict, the probabilities, whether the answer is `uncertain`, whether it is `calibrated` and why, or, unscored (exit 3), the reason it has no answer. Consumers treat every unscored reason the same way: the deterministic path stands.

## Seeded rubrics (Phase 5)

These rubrics carry a `seeded` block naming their consumer. Until a consumer exists, a seeded rubric is **shadow only**: its envelope says `seeded: true`, it is never `calibrated` even with a locked record, and `measure --lock` refuses it.

| Rubric | Question | Consumer |
|---|---|---|
| `commit-hygiene@1` | choice: clean / vague / mixed / leak / none | `scripts/shadow-commit-hygiene.sh [REV]` (run by hand or from a git alias; logs only, always exits 0) |
| `done-claim@1` | noul: does a "done" claim cite its passing acceptance check? | none (a Stop-hook nudge would need a hook, not built) |
| `code-review@1` | score 0–4: severity of one review finding | none yet |
| `tool-risk@1` | choice: read_only / local_write / network / destructive / none | none (a PreToolUse consumer would need a hook, not built) |
| `relevance@1` | noul: does a stored memory bear on the task? | none yet |

Each one needs its own Phase 3–4 cycle (labels, `measure`, a consumer) before its answers can do anything.

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
bin/apex-decide doctor [--json] [--probe]                             # config, egress, keys present, reachability, rubrics, calibration records
bin/apex-decide label   --rubric R --decision D --label L [--note T]    # a human label (refused under an ACTIVE run lock)
bin/apex-decide corpus  --rubric R [--outcomes FILE] [--out FILE]       # decision log joined with human and outcome-proxy labels
bin/apex-decide measure --rubric R --backend B [--outcomes F] [--out F] [--lock]   # AUROC/CI, Brier, ECE, ablation, status
bin/apex-decide replay  (--rubric R --backend B | --all) [--dry-run]   # drift check against locked records (exit 4 on drift)
```

Slash commands: `/apex-decision-layer:decide <rubric> <state-json>`, `/apex-decision-layer:lint`, `/apex-decision-layer:doctor [--probe]`, `/apex-decision-layer:label` and `/apex-decision-layer:measure` (which never locks).

## Measurement

The [shadow-pilot runbook](docs/shadow-pilot.md) describes the loop: opt in with shadow on, route as usual, label, measure, lock, replay. Here is what `measure` reports:

- **Rows:** the backend's answers that have a label. A human label always wins. Outcome-proxy labels count only when at least 20 rows carry both kinds of label and they agree at 0.8 or more.
- **AUROC:** one-vs-rest per label, macro-averaged over the rubric's acted-on labels (`measure.acted_on`), with a Hanley-McNeil 95% CI. Brier score and 10-bin ECE are reported beside it.
- **Also reported:** coverage and precision at confidence 0.3, 0.5 and 0.7; a threshold sweep against the rubric's false-tighten and false-loosen budgets (per 100 tasks, using `measure.order` from cheap to expensive); and the ablation arms (code-only baseline, structured fields, with untrusted text).
- **Status:** one of
  - `insufficient n`: under 100 rows, or under 10 positives for an acted-on label;
  - `degenerate`: fewer than 3 distinct scores, the near-one-hot case;
  - `fails kill criterion`;
  - `passes kill criterion`: AUROC ≥ 0.6, at least +0.08 over the baseline, the CI's lower bound above the baseline, and one resolved model.
- **`--lock`:** writes a record only on a pass, and never under an `ACTIVE` lock. It prints the digest that a human adds to `calibration_lock`.
- **Exit codes:** `label`, `measure` and `replay` exit 5 when refused (an `ACTIVE` lock), and `replay` exits 4 on drift. Skill: `decision-rubric` (how to write and version a rubric).

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
- the Phase 4 lock flow end to end with the sibling consumers (an unlocked record only tightens; a locked one lets `route.sh` take the decision; `report.sh --decision` shows the calibrated row; `replay --all` is refused under ACTIVE, then invalidates on drift);
- calibration records in `doctor`; the measurement job against generated corpora (`scripts/test/make_corpus.py`): every status, the proxy rule, `--lock` and its refusals, and `replay` drift;
- both consumers end to end, including a ROUTE block that is identical with the plugin installed but unconfigured.

## Architecture Decisions

- [ADR-0001 — apex-decision-layer plugin contract](docs/adrs/0001-apex-decision-layer-contract.md) — Status: **Proposed**. CLI and envelope, pinned rubric ids, the validator, calibration records, egress, the hosted backends and their transport policy (0.2.0), the decision log, the namespace, the Phase 0 numbers and the smoke contract.

## License

MIT
