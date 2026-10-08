# apex-decision-layer — Phase 0 spike results

**Date:** 2026-10-08 · **Environment:** Claude Code cloud container (Linux), Python 3.13.16, outbound HTTPS through the session's agent proxy · **Spec:** [§14 Phase 0](../superpowers/specs/2026-10-08-apex-decision-layer-design.md#14-rollout)

Method: `curl` probes from the container, 6 requests per host, recording connect, TLS handshake and total time; and a Python harness that runs the CLI's start-up path 30 times and reports p50/p95. No API key was available, so every hosted request was sent with an invalid credential: it measures reachability and round-trip time, not a real answer. Spend: $0.

## Results

| # | Spike | Result | Consequence for the design |
|---|---|---|---|
| 1 | CLI start-up: bash entry → `python3` with the CLI's stdlib imports (`json, ssl, urllib.request, hashlib, fcntl, math, os`) → envelope on stdout | **p50 53 ms, p95 59 ms, max 69 ms** (n=30). A bare `python3 -c pass` is p50 13 ms; `urllib.request` + `ssl` account for most of the rest (`-X importtime`: ~36 ms cumulative) | The spec's 400 ms margin for start-up and rubric load (§4.1, `--deadline-ms` default `timeout_ms − 400`) is about 6× what is needed. Keep it for slower laptops; an unconfigured install (`backend_none`) costs ~55 ms per routed task |
| 2 | `api.typesafe.ai` reachable through the proxy | **Blocked.** `CONNECT tunnel failed, response 403` on all 6 attempts: this environment's network policy does not allow the host | No live Jev measurement possible here until the host is allowed. Matches the survey's note that vendor pages were egress-blocked during research |
| 3 | `openrouter.ai` (`/api/v1/systemone`) reachable through the proxy | **Blocked.** Same 403 on all 6 attempts | The OpenRouter transport cannot be the workaround in this environment either |
| 4 | `api.anthropic.com` reachable | **Reachable, direct** (listed in the proxy's `noProxy`). Invalid key → `401 authentication_error` in **total 52–61 ms**, TLS handshake ~20 ms | The frontier backend has a fast path to the API from this environment; its latency will be dominated by model time, which needs a key to measure |
| 5 | Jev accepts the pinned id `jev-1.13.0`; what `response.model` reports | **Not run** (spikes 2–3) | `model_pin: record` stays the default; the question is open |
| 6 | Jev p50/p95 for one choice question with ~8 labels | **Not run** (spikes 2–3) | The go/no-go for Jev fitting the ~1.6 s routing budget (decision Q4) is still open |
| 7 | Frontier structured-output call: current request parameter, a real choice answer, p50/p95 | **Not run.** `ANTHROPIC_API_KEY` is not set | The exact structured-output parameter stays to be checked against current API docs in Phase 2, as the spec says |
| 8 | All-zero or tied probability maps from a real frontier model (system-one-adapter bug #45) | **Not run** (spike 7) | The validator rejects them regardless; this spike would only measure how often |

## What Phase 0 needs to finish

1. **Network:** allow `api.typesafe.ai` and `openrouter.ai` in this environment's network access settings (or use a broader access level).
2. **Keys**, stored as environment secrets, never in the repo: `TYPESAFE_API_KEY` (or `JEV_API_KEY`) for TypeSafe, `OPENROUTER_API_KEY` for OpenRouter (one of the two is enough), and `ANTHROPIC_API_KEY` for the frontier backend.
3. Then re-run spikes 2–8 in a new session. Budget: Jev at $0.042 per million input tokens is negligible for ~50 calls; frontier spikes on a small model, ~50 calls, are cents.

## Exit criterion status

The spec's Phase 0 exit is "the numbers in ADR-0001; a go/no-go on `jev` fitting the 1.6 s routing budget". **Not met:** spike 1 is done; the go/no-go depends on spikes 2, 3 and 6. Nothing in Phase 1 depends on them (`none` and `fake` backends, the CLI, the validator, rubrics, the consumer fixes), so Phase 1 can start in parallel.
