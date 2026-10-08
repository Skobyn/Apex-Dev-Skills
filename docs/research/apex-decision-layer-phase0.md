# apex-decision-layer — Phase 0 spike results

**Spec:** [§14 Phase 0](../superpowers/specs/2026-10-08-apex-decision-layer-design.md#14-rollout) · **Environment:** Claude Code cloud container (Linux), Python 3.13, outbound HTTPS through the session's agent proxy

Four runs on 2026-10-08. Run 1 had no hosted access: TypeSafe and OpenRouter were blocked by the network policy and no keys were set. Run 2 was in a session whose proxy allows both hosts and attaches an OpenRouter key, so the Jev spikes ran live through OpenRouter. Run 3 re-ran every spike that the session could reach, to check that run 2's numbers repeat (see [Run 3](#run-3-re-run)). Run 4 was the first with a TypeSafe key on the real path, so it measured the TypeSafe direct transport alongside OpenRouter (see [Run 4](#run-4-typesafe-direct)).

## Verdict

**Go on `jev` for routing, on either transport.** 40 live calls answered in p50 274 ms, p95 308 ms, max 628 ms, all well inside the ~1.6 s routing budget (decision Q4). A frontier model on the same question took p50 1.2 s and p95 3.5 s, and 4 of 14 answers missed the budget, which confirms Q4's split (`jev` for routing, `frontier` for `risk-tier@1`, shadow and replay). Run 3 repeated it: p50 266 ms, p95 363 ms, max 627 ms over another 40 calls. Run 4 added the TypeSafe direct transport: p50 232 ms, p95 285 ms, max 460 ms over 40 calls, slightly faster than OpenRouter's p50 256 ms in the same run.

Three findings change the spec before Phase 2:

1. **The two transports accept disjoint model ids.** TypeSafe accepts only `jev-1.13.0` (and `jev-latest`, which resolves to it). OpenRouter rejects `jev-1.13.0` and resolves its aliases to `typesafe/jev-1.13-20260917`. Pin the id per transport (see spike 5 and run 4).
2. **Jev's probabilities are close to one-hot.** In run 2, 7 of 8 tasks came back as `1`/`0` with confidence 1. In run 3 the top label was 0.95–1.0 on every task, so the scores are concentrated rather than strictly one-hot. That is fine for routing, but it will flatten AUROC and ECE in Phase 3 (see spike 6).
3. **The frontier backend can produce invalid JSON and a bad sum** even with a strict schema. Run 2 had 2 invalid responses and 1 bad sum in 16. Run 3 had none in 16. Run 4 had 0 invalid JSON but the same 1.2 sum again, on a `migration` task as in run 2, so the bad sum recurs and the JSON failure is intermittent. The validator's reject-don't-repair rule is needed in practice, not just in theory (see spike 8).

## Results

| # | Spike | Result | Consequence for the design |
|---|---|---|---|
| 1 | CLI start-up: bash entry → `python3` with the CLI's stdlib imports (`json, ssl, urllib.request, hashlib, fcntl, math, os`) → envelope on stdout (run 1, n=30) | **p50 53 ms, p95 59 ms, max 69 ms.** A bare `python3 -c pass` is p50 13 ms. `urllib.request` + `ssl` account for most of the rest (`-X importtime`: ~36 ms cumulative) | The 400 ms start-up margin (§4.1, `--deadline-ms` default `timeout_ms − 400`) is about 6× what is needed. Keep it for slower laptops. An unconfigured install (`backend_none`) costs ~55 ms per routed task |
| 2 | `api.typesafe.ai` through the proxy | Run 1: **blocked** (`CONNECT tunnel failed, response 403`). Run 2: **reachable**, but the request carried no key: `403 {"error_type":"authentication_error","message":"Must supply an API key!…"}` in 563 ms | The network policy is no longer the blocker. The TypeSafe transport is untested until a `TYPESAFE_API_KEY` reaches the request. OpenRouter covers Phase 2 in the meantime |
| 3 | `openrouter.ai/api/v1/systemone` through the proxy | Run 1: **blocked**. Run 2: **works.** `200` with the contract shape `{model, answers, usage}`. Extra fields beyond the contract: `answers.<id>.type`, top-level `id` and `provider: "TypeSafe"`, `usage.cost` | Transport confirmed. The validator should ignore unknown fields rather than reject them. `usage.cost` can feed `report.sh` directly instead of being computed from the price |
| 4 | `api.anthropic.com` reachable (run 1) | **Reachable, direct** (in the proxy's `noProxy`). Invalid key → `401 authentication_error` in 52–61 ms total, TLS handshake ~20 ms | The frontier backend has a fast path. Its latency is model time (spike 7) |
| 5 | Which model ids Jev accepts; what `response.model` reports (OpenRouter) | `typesafe/jev-1.13` → 200, resolved **`typesafe/jev-1.13-20260917`**. `typesafe/jev-1.13-20260917` → 200, same. **`jev-1.13.0` and `typesafe/jev-1.13.0` → `400 Model typesafe/jev-1.13.0 does not exist`.** `jev-latest` → 200, resolved to the same dated id. `typesafe/jev-latest` → 400. Every one of 40 latency calls resolved to the same dated id | The rubric's `backend_models.jev: "jev-1.13.0"` would fail on every OpenRouter call. Make the Jev model id per transport in config, and pin the dated snapshot (`typesafe/jev-1.13-20260917`) for OpenRouter. Pinning it means `model_pin: strict` compares like with like. Pinning the alias `typesafe/jev-1.13` would make every call a `model_mismatch` under `strict`. Calibration records key on the dated id, which is what they should key on |
| 6 | Jev p50/p95 for one 8-label choice question (`dispatch/task-class@1` labels), Python `urllib`, new TLS connection per call as the CLI makes them, n=40 over 8 tasks × 5 | **p50 274 ms, p95 308 ms, min 242, max 628, mean 285.** 0 over 1.6 s, 0 errors. ~575–590 input tokens, `usage.cost` $0.000025 per call (matches $0.042/M), $0.00097 total. Answers: 7 of 8 tasks one-hot (`1`/`0`, confidence 1), all correct by inspection (docs, tests, mechanical, feature, bugfix, migration, security). The vague task ("Update stuff") → `none` 0.93, confidence 0.92. **Stable:** identical answers across the 5 repeats, ±0.01 on the vague task | **Go** for Q4. Real latency is ~2.7× the docs' "about 100 ms" through proxy + OpenRouter, so the transport rule "no retry when less than 2× p50 remains" means ~550 ms. A 1.6 s budget still allows one retry. One-hot output is a Phase 3 risk: AUROC on mostly-tied scores and ECE with every answer in the top bin measure little. Plan the corpus to include ambiguous tasks, and treat the kill criterion's AUROC as possibly degenerate |
| 7 | Frontier structured output: current request parameter, a real choice answer, p50/p95 | **Parameter (from current API docs):** `output_config: {"format": {"type": "json_schema", "schema": {…}}}` on `POST /v1/messages`, GA, no beta header. `output_format` is deprecated. **Direct call not run:** no `ANTHROPIC_API_KEY`. **Stand-in:** Claude Haiku 5.5 through OpenRouter chat completions, `response_format` `json_schema` `strict: true`, the adapter's three-part system prompt and `<document>` wrapper, n=16: **p50 1158 ms, p95 3531 ms, min 929**; 4 of 14 successful answers over 1.6 s. Answers correct on the 7 clear tasks, with soft probabilities (top 0.68–0.90). $0.0019 total | Use `output_config.format`, not `output_format`, in Phase 2. Re-measure on the native Messages API with the pinned dated model once a key exists. The OpenRouter numbers are an upper bound on transport, not a substitute. The latency confirms frontier cannot serve the 1.6 s routing budget |
| 8 | Malformed probability maps (system-one-adapter bug #45 and friends) | Jev, n=40: 0 all-zero, 0 ties, 0 sums outside 1 ± 0.02. Frontier stand-in, n=16: 0 all-zero, 0 ties, but **2 responses were invalid JSON** (both on the vague task, despite `strict`) and **1 map summed to 1.2** (`migration` 0.82 + 0.20 …) | Fail-closed validation is needed. The validator must treat a JSON parse failure as `invalid_answer`/`provider_error` and reject the 1.2 sum, never rescale it (§6.5). Check on the native API whether `output_config.format` closes the JSON-validity gap. The sum check stays either way, because a schema cannot enforce "sums to 1" |

## Run 3 (re-run)

Same day, a new session. The proxy attaches an OpenRouter key on `openrouter.ai` and a TypeSafe key on `*.typesafe.ai`, but only for the path `/api/v1/systemone`. There is still no `ANTHROPIC_API_KEY`. Spike 4 was not repeated.

| # | Run 3 result | Agrees with run 2? |
|---|---|---|
| 1 | Start-up, n=30: **p50 54 ms, p95 60 ms, max 75 ms**. Bare `python3 -I -c pass`: p50 15 ms | Yes |
| 2 | **Still no key on the real path.** `POST https://api.typesafe.ai/v1/systemone` → `403 authentication_error "Must supply an API key!"` (500 ms). The proxy attaches the key only on `/api/v1/systemone`, and `https://api.typesafe.ai/api/v1/systemone` → `404 Not Found`. `typesafe.ai` itself (the apex domain, a Framer marketing site that `www.` redirects to) is not in `*.typesafe.ai` and is refused by the proxy. Other subdomains (`gateway.`, `app.`) → `502` | The blocker has moved from "no key" to "key rule on the wrong path". It needs the injection path changed to `/v1/systemone` on `api.typesafe.ai` |
| 3 | `200`, same shape and the same extra fields: `id`, `provider`, `answers.<id>.type`, `usage.cost`. `usage` reports `input_tokens`/`output_tokens` | Yes |
| 5 | Identical to run 2: `typesafe/jev-1.13`, `typesafe/jev-1.13-20260917` and `jev-latest` → 200, all resolved to `typesafe/jev-1.13-20260917`. `jev-1.13.0`, `typesafe/jev-1.13.0` and `typesafe/jev-latest` → `400 … does not exist` | Yes |
| 6 | Pinned `typesafe/jev-1.13-20260917`, 8 tasks × 5, n=40: **p50 266 ms, p95 363 ms, min 222, max 627, mean 288.** 0 over 1.6 s, 0 errors. 517–542 input tokens, ~$0.000022 per call, $0.00089 total. All 40 answers correct. Top probability 0.95–1.0 on every task (vague task: `none` 0.95–0.97, confidence 0.94–0.97). Same label on all 5 repeats, ±0.02 on the probability | Latency yes. One-hot only roughly: no task was exactly `1`/`0` every time, and the vague task was much surer of `none` than in run 2 (0.93). The synthetic tasks differ from run 2's, so this compares the model's behaviour, not identical inputs |
| 7 | Claude Haiku 5.5 via OpenRouter, same strict-schema setup, n=16: **p50 1110 ms, p95 2044 ms, min 899, max 2951**; 5 of 16 over 1.6 s. All 16 correct, with soft probabilities (top 0.75–0.93 on clear tasks, 0.53–0.60 on `security`, 0.48 on the vague task). $0.0018 total | Yes. Frontier still cannot serve the 1.6 s routing budget |
| 8 | Jev, n=40: 0 all-zero, 0 ties, 0 sums outside 1 ± 0.02. Frontier, n=16: **0 invalid JSON, 0 bad sums**, 0 ties | Not the frontier part. Run 2's 2 invalid JSON and the 1.2 sum did not recur, so they are intermittent. The validator rule stands: a 1-in-8 failure in one run is enough |

Run 3 spend: about $0.003.

## Run 4 (TypeSafe direct)

Same day, a new session. The proxy now attaches `TYPESAFE_API_KEY` on `*.typesafe.ai` for both `/api/v1/systemone` and `/v1/systemone`, and the OpenRouter key as before. There is still no `ANTHROPIC_API_KEY`. The harness is committed beside this doc in [`apex-decision-layer-phase0-harness/`](apex-decision-layer-phase0-harness/).

| # | Run 4 result | Agrees with earlier runs? |
|---|---|---|
| 1 | Start-up, n=30: **p50 59 ms, p95 77 ms, max 81 ms**. Bare `python3 -I -c pass`: p50 14 ms | Yes, within container noise |
| 2 | **TypeSafe direct works.** `POST https://api.typesafe.ai/v1/systemone` → `200`. The response is exactly the contract: top-level `{model, answers, usage}` and nothing else, `usage` is `{input_tokens, output_tokens}` with **no `cost`**, and numbers are floats (`1.0`) where OpenRouter sends ints (`1`). `/api/v1/systemone` is still `404` | Run 3's blocker is cleared. `report.sh` has to compute TypeSafe cost from the token price, since only OpenRouter returns `usage.cost`. The validator must accept int and float probabilities |
| 3 | OpenRouter `200`, same shape and extra fields as runs 2 and 3 (`id`, `provider`, `answers.<id>.type`, `usage.cost`) | Yes |
| 4 | `api.anthropic.com` direct, invalid key → `401` in 59–68 ms, TLS ~25 ms | Yes |
| 5 | **TypeSafe:** `jev-1.13.0` → 200 (resolved `jev-1.13.0`). `jev-latest` → 200, resolved `jev-1.13.0` (one `503 model_unavailable` on the first try, then 5 of 5 OK). Every other id → `400 api_usage_error "Unknown model"`, including `jev-1.13`, `jev-1.13-20260917` and all `typesafe/…` forms. **OpenRouter:** identical to runs 2 and 3, plus the bare `jev-1.13-20260917` → 200. OpenRouter's model list also has a `typesafe/jev-router` (a model router built on Jev, not a System One model) | The spec's `jev-1.13.0` is right for TypeSafe and wrong for OpenRouter, and no id works on both. Per-transport `backend_models.jev` is required, not just tidier. The transient 503 on an alias argues for pinning `jev-1.13.0` rather than `jev-latest` on TypeSafe |
| 6 | Same 8 tasks × 5 on each transport, n=40 each. **TypeSafe (`jev-1.13.0`): p50 232 ms, p95 285 ms, min 197, max 460, mean 243.** **OpenRouter (`typesafe/jev-1.13-20260917`): p50 256 ms, p95 373 ms, min 217, max 575, mean 277.** 0 over 1.6 s, 0 errors on either. 539–564 input tokens. OpenRouter $0.00093 total. All 80 answers correct. 35 of 40 exactly one-hot on each transport (all 7 clear tasks returned `1`/`0`, confidence 1, every time); the vague task returned `none` at 0.93–0.95 (TypeSafe) and 0.95–0.96 (OpenRouter) | Latency yes, and TypeSafe is ~25 ms faster at p50 and ~90 ms at p95. One-hot: closer to run 2 than run 3. The two transports give the same answers to within 0.02, which is consistent with the same model behind both |
| 7 | Claude Haiku 5.5 via OpenRouter, same strict-schema setup, n=16: **p50 1466 ms, p95 1646 ms, min 958, max 1703**; 2 of 16 over 1.6 s. All 16 correct, soft probabilities (top 0.80–0.93 on clear tasks, 0.55–0.63 on `security`, 0.32–0.40 on the vague task). $0.0018 total | Yes. Frontier still cannot serve the 1.6 s routing budget |
| 8 | Jev, n=80: 0 all-zero, 0 ties, 0 sums outside 1 ± 0.02. Frontier, n=16: 0 invalid JSON, 0 ties, **1 map summed to 1.2, on the `migration` task again** | The bad sum is back on the `migration` task, as in run 2 (the synthetic tasks differ between runs), so it is a repeated failure on one kind of input, not noise. The reject-don't-rescale rule is confirmed |

Run 4 spend: about $0.003 (OpenRouter), plus about 55 TypeSafe calls that report no cost.

## Method

- **Run 1:** `curl` probes, 6 per host, recording connect, TLS and total time. A Python harness ran the CLI's start-up path 30 times. Hosted requests used an invalid credential, which measures reachability and round trip only. Spend $0.
- **Run 2:** a Python stdlib harness (`urllib.request`, `SSL_CERT_FILE` set to the proxy CA bundle, `python3 -I`). It sent the same 8-label `class` question used in `dispatch/task-class@1`, with the `data_handling` clause appended. State used the rubric's allowlisted fields (`tags`, `paths`, `risk_tier`, `task_title`, …) over 8 synthetic tasks, one per label plus one vague task. Each call opened a new connection. Latency is wall clock from request to parsed JSON. The frontier stand-in sent the same labels as a strict JSON schema (one required number per label, `additionalProperties: false`), at temperature 0. Spend: ~$0.003 in total.
- **Run 3:** a new stdlib harness of the same shape (the run 2 harness was not committed): the same 8 labels and `data_handling` clause, 8 synthetic tasks (one per label plus "Update stuff") with `task_title`, `tags`, `paths` and `risk_tier`, one new connection per call, the adapter's system prompt and `<document>` wrapper for the frontier stand-in, temperature 0. The TypeSafe probes used `curl` against each candidate path.
- **Run 4:** the run 3 shape, now committed as [`apex-decision-layer-phase0-harness/`](apex-decision-layer-phase0-harness/) (`jev.py` for spikes 5, 6 and 8 on both transports, `frontier.py` for 7 and 8, `entry.sh` for 1). Jev state sends `task_title` as `untrusted_task_title` per §10. Run it with `python3 -I jev.py jev-1.13.0 typesafe/jev-1.13-20260917` and `python3 -I frontier.py`. It sends no key itself: auth came from the session proxy, so elsewhere add a Bearer header in `post()`.

## What is still open

1. ~~**TypeSafe direct transport.**~~ Closed in run 4: it works, accepts `jev-1.13.0`, and is the faster transport.
2. **Native frontier call:** needs `ANTHROPIC_API_KEY`. Repeat spikes 7 and 8 on `POST /v1/messages` with `output_config.format` and the pinned dated model.
3. **Spec edits** to fold in before Phase 2:
   - §5.1: `backend_models.jev` becomes per-transport: `jev-1.13.0` on TypeSafe, `typesafe/jev-1.13-20260917` on OpenRouter.
   - §6.3: tolerate the extra response fields (OpenRouter) and accept int or float numbers.
   - §6.4: record `usage.cost` when present (OpenRouter only) and compute it from tokens otherwise (TypeSafe). The measured p50 is ~230 ms on TypeSafe and ~260 ms on OpenRouter, not ~100 ms.
   - §5.1: correct the note that jegrep saw `jev-1.13.0` rejected by the hosted service. OpenRouter rejects it; TypeSafe accepts it.
   - §6.5: `output_config.format`.
   - §8: plan for near-one-hot Jev scores.

## Exit criterion status

The spec's Phase 0 exit is "the numbers in ADR-0001; a go/no-go on `jev` fitting the 1.6 s routing budget".

- **Go/no-go: met.** It is a go on both transports. TypeSafe direct is slightly faster; OpenRouter needs no early-access key.
- **Numbers: measured.** They go into the plugin's ADR-0001 when Phase 1 creates it, since the plugin does not exist yet.

Item 2 above is a confirmation and does not block Phase 1 or the design of Phase 2.

## Phase 2 (live verification of the shipped backends)

**Spec:** [§14 Phase 2](../superpowers/specs/2026-10-08-apex-decision-layer-design.md#14-rollout), whose exit is "one live call per backend recorded on a fixture plan, with `response.model` asserted". **Plugin:** apex-decision-layer 0.2.0.

**Session 1 (2026-10-08, the session that built 0.2.0):**
- No `TYPESAFE_API_KEY`, `JEV_API_KEY`, `OPENROUTER_API_KEY` or `ANTHROPIC_API_KEY` was set. A reachability probe of the hosted endpoints was refused by the session's permission policy, so no live call was made.
- Every backend path was verified against loopback stub servers instead (smoke checks 22–27): both jev transports, frontier, the transport policy, TLS, every failure mode and key redaction.
- **frontier:** no `ANTHROPIC_API_KEY` is available in this environment, now or later. A native `POST /v1/messages` call with `output_config.format` is **not verified here**. The backend is verified against the loopback stub only, and the Phase 2 task scope calls for live frontier calls only when the key exists, so this does not block Phase 2. Spikes 7 and 8 on the native API (Phase 0 "What is still open", item 2) stay open.

**Session 2 (2026-10-08, a second cloud session, branch head `7f874e1`):**
- Smoke there: 27/27.
- No key was set in the environment. That session's agent proxy injects the TypeSafe key on `*.typesafe.ai` (paths `/v1/systemone` and `/api/v1/systemone`) and the OpenRouter key on `openrouter.ai`. It holds nothing for Anthropic.
- With that session's operator's approval, each call ran with `TYPESAFE_API_KEY` / `OPENROUTER_API_KEY` set to a placeholder, and the proxy swapped in the real key. The placeholder appeared in no envelope, no stderr output and no `.dev-plan-state` file.
- 4 live calls through `bin/apex-decide`, in a throwaway repository with `egress: hosted` and `state_fields: raw`:

| Transport | Rubric (deadline) | Exit | `model_requested` → `model_resolved` | Verdict, confidence | Usage | Latency (whole CLI) |
|---|---|---|---|---|---|---|
| TypeSafe | `risk-tier@1` (10 s), `src/auth/session.py`, 40 lines | 0 | `jev-1.13.0` → `jev-1.13.0` | `C`, 1.0 | 635 in, 45 out, $0.0000267 (estimated) | 910 ms |
| TypeSafe | `dispatch/task-class@1` (1.5 s), "Add CSV export button to the reports page" | 0 | `jev-1.13.0` → `jev-1.13.0` | `feature`, 1.0 | 872 in, 76 out, $0.0000366 (estimated) | 367 ms |
| OpenRouter | `risk-tier@1` (10 s), same state | 0 | `typesafe/jev-1.13-20260917` → same | `C`, 1.0 | 635 in, 45 out, $0.0000267 (reported) | 560 ms |
| OpenRouter | `dispatch/task-class@1` (1.5 s), same state | 0 | `typesafe/jev-1.13-20260917` → same | `feature`, 1.0 | 872 in, 76 out, $0.0000366 (reported) | 335 ms |

What the calls showed:
- **Model ids.** On both transports `response.model` equals the requested id, so the per-transport pin is right and `model_pin: strict` would also pass. The spec's exit criterion ("one live call per backend … with `response.model` asserted") is met for `jev`.
- **The answers.** All four were scored, `uncertain: false`, `calibrated: false` (no record), `add_gate: null`. Both answers are correct by the rubrics (`src/auth/session.py` is a Tier C path under `risk-tier@1`'s criteria).
- **One-hot scores.** Every probability came back exactly 0 or 1, as in Phase 0 (spike 6), which is the near-one-hot risk §8.1 plans for.
- **Cost.** OpenRouter's reported `usage.cost` equals the client-side estimate at $0.042 per million input tokens, so the TypeSafe estimate is calibrated. Both transports now report output tokens (45 and 76) that Phase 0 saw as 0. Output is free, so the estimate is unchanged.
- **Latency.** The task-class calls took 335–367 ms, inside the 1.6 s routing budget. The first TypeSafe call (910 ms) includes a cold TLS connection and the Python start-up.

**Cloud sessions with proxy-injected keys.** When a key exists only as a proxy-injected secret, `apex-decide` sees no key and sends nothing (`provider_error`). Setting the key variable to any placeholder makes it send. The README documents this.

**frontier:** not run. There was no `ANTHROPIC_API_KEY` and no proxy secret for Anthropic (see Session 1).

## Phase 3 (shadow pilot and the first `measure` reports)

**Spec:** [§14 Phase 3](../superpowers/specs/2026-10-08-apex-decision-layer-design.md#14-rollout), whose exit is "a `measure` report per rubric and backend with its n, even if it says `insufficient n`". **Plugin:** apex-decision-layer 0.3.0. **Harness:** [`apex-decision-layer-phase3-pilot/pilot.sh`](apex-decision-layer-phase3-pilot/pilot.sh).

**The pilot.** It sends 8 fixture tasks per rubric through `bin/apex-decide` in a throwaway repository (`egress: hosted`, `state_fields: raw`, `store_state: full`, jev primary, no shadow because there is no Anthropic key). It writes each fixture's intended label as an **outcome-proxy** label, never as a human one, and then runs `measure` for each rubric.

**Run 1 (the building session, 2026-10-08).**
- This session's proxy refuses both jev hosts (`Tunnel connection failed: 403 Forbidden`). All 16 calls were unscored `provider_error`, nothing was sent upstream, and the cost was $0.
- Both reports (`dispatch/task-class@1` and `risk-tier@1` on `jev`) say **`insufficient n`, n = 0**: 0 answers, 0 labels.
- This is the honest first report. It shows the pipeline end to end, with nothing to measure.

**Fixture corpus (the fallback the plan allows).** `scripts/test/make_corpus.py … jev degenerate 160` generates 160 rows per rubric with **exactly one-hot** answers that are right 85% of the time, which is the shape Jev gave in Phase 0 (35 of 40 one-hot in run 4, all 4 in the Phase 2 live calls). There are human labels on 70% of rows and outcome-proxy labels on all of them, with 86% agreement, so the proxy labels count. The reports are committed beside the harness:

| Rubric | Status | AUROC (acted-on), 95% CI | Code-only baseline | Brier | ECE |
|---|---|---|---|---|---|
| `dispatch/task-class@1` | **degenerate** | 0.934 [0.860, 0.997] | 0.790 | 0.1625 | 0.0813 |
| `risk-tier@1` | **degenerate** | 0.940 [0.887, 0.992] | 0.785 | 0.175 | 0.0875 |

**What this means for Phase 4.**
- If Jev keeps answering one-hot, every Jev measurement will be `degenerate`: fewer than 3 distinct scores, so AUROC ranks nothing. The kill criterion then cannot pass, and Jev cannot become calibrated, however accurate it is.
- The AUROC of about 0.94 above comes only from tie-handling. It is not evidence of ranking quality.
- The ways forward are a design decision for the operator, and none is taken here:
  - (a) measure Jev on accuracy against the code-only baseline at a fixed threshold, instead of AUROC;
  - (b) calibrate `frontier`, whose answers are soft, and keep Jev uncalibrated (tighten-only), which the spec already accepts as the likely long-run state;
  - (c) ask TypeSafe whether the probabilities can be made less sharp.
- The live pilot, if run in a session with jev auth, will show whether the real answers are as one-hot as the fixture assumes.

**Run 2 (live, a session with proxy-injected jev keys):** requested; not yet reported.
