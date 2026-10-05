# Jev-ecosystem repo survey — what to adopt, copy, reference, or ignore

**Date:** 2026-10-05 · **Method:** one reader per repo, a source-level deep read for every repo scoring ≥ 6/10, a clustering pass, then three-lens adversarial refutation (license and maintenance; works without Jev access; enforceable in Claude Code hooks or Codex) of every adopt or copy recommendation. 71 agents. Backing research for [`docs/superpowers/specs/2026-10-05-apex-dispatch-design.md`](../superpowers/specs/2026-10-05-apex-dispatch-design.md).

## Headline

- **Adopt nothing as a dependency.** Every repo except `system-one-connector` and Vercel's `json-render` is one to three weeks old with a single author and a single-day or single-week commit burst. Two are archived or withdrawn by their own authors.
- **Copy from about fifteen.** The Jev wire contract and validator (eleven independent implementations agree), rubric schemas and authoring rules, threshold ladders, the done-claim and commit-hygiene rubrics, the relevance-filter shape, the measurement harnesses, and the observability record.
- **Three negative results become laws** (see below). They are the most valuable thing in the set.
- **Two optional shadow-mode trials**, uncoupled from our code and pinned: `winnow` (relevance filter) and `jev-belay` (done-claim Stop nudge).

## Per-repo verdicts

| Repo | What it is | Verdict | Keep from it |
|---|---|---|---|
| `GhalebDweikat/winnow` (MIT, 101★, v0.5.1 2026-09-30) | Tool-result relevance filter: function hook → sidecar → one noul per 25-line block → hard gates → stub with recall key | **copy-pattern + optional 1-week shadow trial** from its own marketplace (`WINNOW_MODE=shadow`). Needs `tool_use_id` in our contracts ledger first | `policy.decide()` gates (error_present → hide nothing; hidden < 20% → no rewrite; keep ≥ 0.5, 0.1–0.5 kept-and-logged, < 0.1 hidden), three question sets, judge factory with keyless fakes, replay/labels/review calibration loop, "report AUC beside ECE" |
| `valentynkit/jev-belay` (MIT, 21★, tag v0.2.0) | Stop-hook done-claim gate; the only repo with a measured gate (AUROC 0.976 shipped vs 0.777 wording-only, n=100/12 positives, Sonnet-proxy labels) | **copy-pattern**; optional install pinned to v0.2.0 in `JEV_BELAY_SHADOW=1` as a one-shot nudge, never as a completion gate (blocks once per prompt, yields on `stop_hook_active`, blind to Bash-driven edits) | Four-question rubric (`claims_done`, `claims_verified`, `verification_applies` noul + `outcome` choice), `measure.mjs` (AUROC + Hanley-McNeil CI, ablation arms, threshold sweep with wrong-block budget, kill criterion), 14 redaction regexes, loop safety (1 block per prompt_id, 60 s cooldown, 3 per session) |
| `WXK-AI/jev-opus` (MIT, 8★) | Per-step effort routing for Opus via a Jev "reflex"; gateway rewrites transcript | **copy-pattern** (client, policy skeleton, reducer); ignore the gateway | Strict answer validation + circuit breaker (2.5 s deadline, 3 failures / 30 s), task/step triage rubric seeds, effort asymmetry (raise immediately, hold one step, de-escalate only with zero open issues), query gate, issue-fingerprint reducer. Its Jev-vs-heuristic comparison is circular (state = heuristic labels) |
| `valentynkit/jev-commit` (MIT, 13★) | commit-msg hook with five commit-hygiene nouls | **copy-pattern**, narrowed: belt.py 13 block patterns + entropy rule, git child-env lockdown, chunk budgets, five rubrics. Not its thresholds (calibration never ran; `thresholds.json` absent) | gate / dead-band (0.30–0.70) / combine semantics, authoring lint "no counting words, criteria as situations not degrees" |
| `luantak/is-malicious` (MIT, 33★) | Two-pass triage-then-locate supply-chain classifier | **copy-pattern** (rubric schema with closed reason codes and `kind: hostile\|advisory`; escalate-to-narrower-question ladder; `JevAsker` seam; exit 0/1/2 with "skipped is distinct from verdict"). No hook integration exists to copy | Optional Tier B/C pre-install gate, advisory + human |
| `can1357/jegrep` (MIT, 108★) | Semantic grep over a code tree with batched judgments | **copy-pattern** for contract/secrets/bench; reference-only as a tool (ships source to a hosted API) | serde-typed wire contract (cleanest spec), two-tier thresholds (0.45 route on sketches, 0.2 verify on evidence = advisory until verified), failover policy, `secrets.rs` withholding, bench manifest. Reports the hosted service rejected pinned `jev-1.13.0` |
| `kierandotai/jev-scout` (**no license**, 1★) | Governed MCP search/fetch wrapper with relevance/credibility scoring | **reference-only, clean-room**: ideas only, written in our words | `RUBRIC_VERSION` keying cache and drift, annotate/gate switch, drift harness (±0.25 vs pinned baseline), budget manager, SSRF resolve-twice |
| `allebee/pytest-jev` (MIT, 4★) | pytest assertions over typed verdicts | **copy-pattern** | Verdict laws: holds p ≥ t, lacks p ≤ 1−t, the band fails both ways ("a test should not pass on a coin flip"); score comparisons as cumulative mass P(level ≥ L); sha256 cache on the resolved model; claim-writing rules |
| `shimo4228/jev-skill-router` (MIT, 9★, withdrawn 2026-09-28) | UserPromptSubmit hook suggesting skills | **copy-pattern** for `jev_client.py` security posture (host pin, loopback-only override, refuse redirects, no key in logs), `roster.py`, decision-log row; **negative result** for the routing idea | 1,242 decisions, 539 suggestions, 28 followed, 13/20 sampled off-target |
| `suenot/codex-jev-router` (MIT, private, retired) | Pre-delegation model router for Codex | **copy-pattern** narrowed to `evidence.mjs` deterministic filter and the two-question tier/exceptional ladder (0.8 / 0.1 / 0.75 / 0.6 / 0.7); **negative result** for delegation economics | Jev-routed subagents 27.2% cheaper than fixed strong children but **69.7% more expensive than one strong agent with no delegation** |
| `0xNatoshi/jev-codex-router` (MIT, 273★, archived) | Per-call model/effort/lease router proxy for Codex desktop | **copy-pattern** (four-way rubric, bounded dossier, lease cache, validator); ignore the proxy | Backtest: low-confidence fallback to the frontier fired on ~2/3 of turns, −11.9% vs −59.9% with middle-tier fallback |
| `itsmostafa/system-one-connector` (MIT, 339★, 146 commits) | MCP connector for a System One model | **copy-pattern**; at most an allowlisted convenience, never the backend | 17-line rubric-authoring spec, validation limits, client-side abstention (`__uncertain__`), confidence formulas (choice (N·p_top−1)/(N−1), noul \|2p−1\|), ECE/coverage scorer, profiles precedence |
| `jkudish/jev-mcp` (MIT, 496★) | MCP server + example PreToolUse hook gate | **copy-pattern** (`jev_decide`/`jev_review`/`jev_gate` contracts, fail-closed validators, hook-gate idiom: deny only when p(block) ≥ 0.85, never emit allow) | Four 0–2 review rubrics (correctness, spec_match, test_gap, blast_radius), "claims are assertions, not proof" |
| `sharziki/semdecide` (MIT, 76★) | Decision CLI with a guard-question rule table | **copy-pattern** | Six guard questions + 8-row allow/escalate/block table with Jev's own route answer logged but never consulted; tri-state uncertain with exit 3; provider-failure-fails-closed |
| `devagrawal09/jev-review` (MIT, 670★) | Probabilistic PR review funnel | **copy-pattern** | Vocabularies as data, funnel noul → 0.7 → choice with `noMatch` ≥ 0.55 → severity score; request_changes iff severity ≥ 2 |
| `carldaws/hunch` (MIT, Ruby) | Typed decision SDK | **copy-pattern** (named threshold ladder with generated predicates, Rating semantics, duck-typed backend + Stub). No shadow wrapper exists despite claims | |
| `tamaratran/fast-jev-compaction` (MIT, 7.4k★, 38 open issues) | Function-hook compaction | **copy-pattern** for fail-safe defaults; ignore as dependency | Never delete errors / Edit / Write / Agent results; always append a removal marker; missing answer ⇒ keep; reduction < 0.25 ⇒ fall back |
| `browser-use/jev-ultrafast` (MIT, 22k★ brand-driven) | Browser action choice | **reference-only** | `validate_choice()`, conditional-head fan-out (tier + tier-specific gate in one request, act only on the matching head), hard guards as laws |
| `ellipsis-dev/blink` (**no license**) | Probabilistic beam search | **reference-only**, re-implement `splitWalkers` largest-remainder allocation | |
| `vercel-labs/json-render` (Apache-2.0, 18.5k★) | Generative UI framework | **ignore** as dependency; two ideas (`unavailable` as a first-class option; fetch-mocked evaluator test checklist) | |

## Negative results that become laws

1. **Advisory routing hints are ignored.** jev-skill-router's per-prompt suggestion moved Claude's skill choice in 28 of 539 suggestions; the author withdrew it. *Law: binding routing is enforced by allowlists, listing rewrites, or fixed pipeline decision points, never by injected hints.*
2. **Delegation can cost more than one strong agent.** codex-jev-router's own audit: routed subagents 69.7% more expensive than a single strong agent with no delegation; retired in four days. *Law: fan-out is a decision with a logged cost counterfactual and a budget, not a default.*
3. **Uncertain routing must fall back to the middle tier.** jev-codex-router's backtest: frontier fallback fired on two thirds of turns. *Law: uncertain or uncalibrated routing falls back to the pinned middle tier, never the frontier, never the most expensive model.*
4. **State must carry observed facts.** jev-opus sent Jev only its own heuristic's labels, making its comparison circular, and 61 snapshots carried false issues from misclassified successful reads. *Law: the decision state is built from observed records with original field names, never another model's labels.*
5. **Every hosted gate fails open silently** (missing key, timeout, oversize) except semdecide. *Law: advisory surfaces fail open with a logged `scored:false`; completion and commit gates keep a deterministic belt that holds regardless.*

## The Jev `/v1/systemone` contract (eleven implementations agree)

```
POST ${BASE:-https://api.typesafe.ai}/v1/systemone
Authorization: Bearer <TYPESAFE_API_KEY | JEV_API_KEY>
{ model, state, questions: { <id>: { type: noul|choice|score, instructions, criteria } } }
→ { model, answers: { <id>: ... }, usage: { input_tokens, output_tokens } }
noul   answer: { noul: p }                      # key is `noul`, not `p`
choice answer: { choice, probabilities, confidence }
score  answer: { score, probabilities, confidence [, legend] }
noul criteria wire keys: `true` / `false`
```

Limits: choice ≤ 255 options, score 2–10 levels, ~32k request ceiling, $0.042 per 1M input tokens, output free. Alternative transports: OpenRouter `/api/alpha/decisions` (`typesafe/jev-1.13`, provider pinned), Vercel AI Gateway v4 evaluation-model headers. **Pinning is unverified**: jegrep reports the hosted service rejected `jev-1.13.0` and only `jev-latest` worked; three other repos pin `1.13.0` in code without live tests.

**Validator (union of the repos):** every requested id answered and no extras; probabilities keyset == criteria keyset; each value finite in [0,1]; sum within 1 ± 0.02; `choice` equals argmax within 1e-6; score in [0, n−1] with distribution mean within 0.02 of score; booleans rejected; malformed → reject, never clamp; HTTP 200 with zero valid answers == failure; a missing answer keeps the local estimate, never a neutral default; a null confidence never satisfies a threshold.

**Transport policy:** single wall-clock deadline (2.5–8 s) across all attempts; retry only 408/429/5xx/529 honouring `Retry-After` with a cap; circuit breaker 3 failures / 30 s; 4 MiB body cap; non-JSON 2xx is an error; host pinned with loopback-only override and redirects refused; label-only or hashed state by default, raw text only behind an explicit per-repo flag.

## Gaps none of the repos cover (ours to build)

Cross-provider delegation routing; enforced per-agent tool allowlists (only "deny the builtin, register a governed MCP wrapper" and listing rewrites exist); a frontier structured-output fallback backend (only via TypeSafe's own `system-one-adapter`, marked "not calibrated"); local `@ruvector/typesafe` heads; two-backend shadow mode (every "shadow" surveyed is backend-vs-nothing); a `calibrated` flag (no repo reads one; confidence is always distribution peakedness); score calibration and the legend contract (three different probability shapes); rubric files as versioned data with thresholds loaded from a file; fan-out shape as a decision; error-budget integration; completion-gate blind spots (multi-turn false dones, Bash-driven edits); a per-repo data-egress switch; hook equivalents for Codex, Grok and local agents; a bash + jq port (~200 lines) of contract, validator and tri-state policy; Stop-hook interaction with the host's 8-consecutive-block cap.

## Claude Code limits the repos confirm

A per-prompt hook cannot change the skill listing. A hook cannot change the current session's effort (jev-opus spawns a child process). Classic command hooks cannot rewrite tool output; winnow and fast-jev-compaction need function hooks (`tool.call → updatedToolOutput`, `session.compact`, `turn.complete`, `prompt.submit`).

## Follow-up leads

Surveyed separately (see the spec's backend section): `typesafe-ai/system-one-adapter` as the frontier structured-output fallback, `BillionsBobby/JevRouter`, and the Jev score/legend, calibrated-flag and model-pinning semantics from primary sources.
