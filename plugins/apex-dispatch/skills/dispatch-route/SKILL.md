---
name: dispatch-route
description: Read an apex-dispatch ROUTE block (from route.sh, or between TAGS and STATUS in an apex-scope-loop iterate brief) and dispatch exactly what it says — only roster roles, as the generated apex-dispatch agents, at the routed model and effort, within the routed fan-out, lanes and budgets, with the review shape the risk tier sets. Use whenever a brief carries ROUTE_STATUS, before spawning any builder or reviewer for a routed task, when a route says NEEDS_SPEC / HUMAN_GATE / HALTED / BUSY, and when checkpoint.sh fail prints ESCALATE_ROUTE.
allowed-tools: Bash Read Grep Glob Agent
---

# dispatch-route — dispatch exactly the route

`route.sh` is a pure function of trusted features and the merged policy. It chooses the class, tier, model, effort, provider, roster, fan-out, review shape and budgets. **You do not.** Your job is to read the block, act on it literally, and say so when you cannot. A model that ignores the ROUTE block is blocked once by the Stop hook (`stop-gate.sh`) and is visible in the ledger regardless.

Script paths below: `$D` = `${CLAUDE_PLUGIN_ROOT}/scripts` (this plugin); `$S` = the sibling apex-scope-loop's `skills/apex-execute/scripts` (the `/apex-dispatch:run` command shows how to resolve it).

## Where the block comes from

- **Plan task:** `$S/iterate.sh PLAN` calls `$D/route.sh plan PLAN --line N --base TASK_BASE [--lanes …]` and prints the block between the task fields and `STATUS:`. Without apex-dispatch installed it prints `ROUTE: none` and you route by the `Swarm:` directive as in apex-scope-loop 0.2.0.
- **Ad-hoc ask:** `$D/route.sh adhoc --tags CSV [--paths GLOBS] [--acceptance CMD]` (`/apex-dispatch:route`). Tags are caller-supplied tokens, never free text.
- `--dry-run` computes the same block and writes nothing (no lock, no ledger row, no `active-route.json`).

## Every field

| Field | What you do with it |
|---|---|
| `ROUTE_STATUS` | `READY` → dispatch. Anything else → see "Non-READY statuses"; nothing is spawned. |
| `ROUTE_ID` | `r-<plan-hash>-L<line>-<n>` or `a-<adhoc-id>-<n>`. Put it in every brief, every `checkpoint.sh review --route`, and every non-provenance row you append with `ledger.sh append --route-id` (`escalate`, `hook_advisory`, `human_gate`, …). Provenance rows (`route`, `spawn_request`, `spawn`, `worker_run`, `verdict`) are never yours to write; the hooks and shims stamp the route id on them. `none` on a non-READY status. |
| `ROUTE_MODE` | `table` / `decision` (normal), `escalated` (a rung after a failure), `baseline` / `shadow` (the route below is the 0.2.0 choice; the table's own choice is on `ROUTE_TABLE_CHOICE` and is **not** what you dispatch). `ROUTE: none` (`APEX_DISPATCH_MODE=off` or no apex-dispatch) → route by `Swarm:` as in 0.2.0. |
| `ROUTE_CLASS` | docs, tests, mechanical, feature, bugfix, migration, security, gate. Shapes the brief: `bugfix` is diagnosis-first with a fresh context; `security`/`migration` never use external builders. |
| `ROUTE_TIER` | cheap / standard / strong / max. Informational; `ROUTE_MODEL` + `ROUTE_EFFORT` are what you pass. |
| `ROUTE_RISK_TIER` | A / B / C used for this route (persisted tier, else the tag floor). Re-derived after build by `risk-tier.sh`; the review shape follows the **real** tier, not this one. |
| `ROUTE_MODEL` | `haiku`, `sonnet` or `opus` — the model of the routed tier in the merged policy (`compile.sh --print-merged`, `tiers[].model`). Pass it as the Agent call's `model` parameter for every builder-side spawn. Never substitute a different model "because it is better". |
| `ROUTE_EFFORT` | low / medium / high / xhigh. Effort is fixed per agent definition, so it is carried by the roster name (`builder` medium, `builder-high`, `builder-xhigh`); do not try to set it any other way. |
| `ROUTE_PROVIDER` | `claude-session` → in-session `Agent` spawns. Anything else (`claude-p`, `codex`, …) → the `dispatch-worker` skill (`${CLAUDE_PLUGIN_ROOT}/bin/worker-codex.sh`, `${CLAUDE_PLUGIN_ROOT}/bin/worker-claude-p.sh`, then `${CLAUDE_PLUGIN_ROOT}/scripts/apply.sh` for a build); when the shim refuses with exit 4 (provider unavailable), run the role as `claude-session` and note the deviation. |
| `ROUTE_ROSTER` | The **only** roles you may spawn for this route, comma-separated. Spawn each as `subagent_type: "apex-dispatch:<role>"` (e.g. `apex-dispatch:builder-high`). A role not on the roster is not spawned, ever. `orchestrator` (baseline mode with no `Swarm:`) means you do the work inline. |
| `ROUTE_FANOUT` / `ROUTE_LANES` | `single` → one builder. `lanes:<k>` with `ROUTE_LANES: L1,L2,…` → one builder per listed plan line, all in **one message**, each confined to its own task's `Paths:` and given its own Acceptance; commit serially; gate and review each lane as its own task. Never invent lanes. |
| `ROUTE_REVIEW_SHAPE` | Provisional; finalised after the gate by `route.sh review-shape` (see Review). |
| `ROUTE_DIVERSITY` | `off`, `warn` (try a different family; record if you could not), `block` (a different family is required for Tier C; see Review). |
| `ROUTE_HUMAN_GATE` | `G12` → after review, halt for the human via `checkpoint.sh approve` (never an `ask` prompt). |
| `ROUTE_BUDGET_USD` / `_SPAWNS` / `_MINUTES` | Hard ceilings for this route. Count your spawns; stop before the next one would exceed `_SPAWNS`; stop when wall-clock passes `_MINUTES`. Exhaustion is a halt, not a reason to continue inline. |
| `ROUTE_MISSING` | On `NEEDS_SPEC`: what is missing (`acceptance`, `acceptance-command`, …). |
| `ROUTE_FLOORS` | Hard rules that tightened the route (e.g. `tier-c-floor`). Not negotiable. |
| `SEMANTIC_SOURCE` | `table` (no decision layer or it failed), `decision`, `none`. Informational. |
| `ROUTE_RUNG` / `ROUTE_PRIOR` / `ROUTE_DIAGNOSER_PROVIDER` | Present on an escalated route: the rung, the failed route it follows, and where the read-only diagnoser runs. |
| `ROUTE_FILE` / `ROUTE_ENFORCED` | Where `active-route.json` was written, and whether this is the enforcing `<state>/dispatch/` (`yes`, the default) or `<state>/dispatch-shadow/` (`no`: the human opted out with `APEX_DISPATCH_ENFORCE=0`). |
| `ROUTE_NOTE` | Zero or more explanations (why fan-out stayed single, why a provider was skipped). Read them. |
| `ROUTE_REASON` | Why a route is HALTED / BUSY / `none`. |

## Non-READY statuses — nothing is dispatched

- **`NEEDS_SPEC`** — the input gate failed closed. Do not spawn, do not "fill in" an Acceptance yourself. Report `ROUTE_MISSING` and ask the plan owner for a runnable `Acceptance:` (or the missing directive). No model tokens are spent on a task that cannot be checked.
- **`HUMAN_GATE`** — a `[gate:…]` task. Follow apex-scope-loop's gate path: Ask Contract (what / what it does / why / risks), wait for the literal approval phrase, `checkpoint.sh approve`. Never auto-approve.
- **`HALTED`** — a kill switch (`APEX_HALT=1`, a HALT file, a halted checkpoint, the HALT rung, budget exhausted). Report `ROUTE_REASON` verbatim and stop. Never work around it.
- **`BUSY`** — another plan or ad-hoc ask holds the `ACTIVE` lock. Report the owner in `ROUTE_REASON` and stop. Do not force-unlock (`APEX_FORCE_UNLOCK=1` is manual human recovery only).

## Dispatching a READY route

1. **Brief.** Each builder prompt carries: `ROUTE_ID`, the plan `WORKTREE:` (all edits there, never the base checkout), the task title, its `Acceptance:` line, its owned `Paths:` globs, the budgets, the recalled lessons (`lessons.sh recall`), and the return contract from the agent definition. For `bugfix`, lead with diagnosis. For an escalated route, include the prior failure masked to a ≤400-token summary and, on the model-up rung, the diagnoser's note.
2. **Spawn.** One `Agent` call per roster builder-side role you need, `subagent_type: "apex-dispatch:<role>"`, `model: <ROUTE_MODEL>`, `run_in_background: true`, all in one message. Do not spawn reviewers yet. Builders cannot spawn agents (depth 1). Wait for completion notices; do not poll.
3. **Spawn records are not yours to write.** `spawn_request`, `spawn`, `worker_run`, `verdict` and `route` rows are provenance: they are written only in-process by `route.py`, the hooks and the shims, and `ledger.sh append` refuses them from anyone else. Do not try to record spawns by hand. While the run holds the `ACTIVE` lock, `pre-agent.sh` (Phase 3.1) denies a spawn off the roster, at a model other than `ROUTE_MODEL` (an omitted `model` is filled in), over `ROUTE_BUDGET_SPAWNS`/`_MINUTES`, under HALT, from inside a subagent, a builder during REVIEW, and a reviewer before the gate passed at HEAD; it records each allowed spawn as a `spawn_request` row. It also denies builder-side spawns once the route's estimated USD (real usage from `post-agent.sh` × the policy's prices) reaches `ROUTE_BUDGET_USD`, and a reviewer while a builder is still running. A denial is final: do not retry with another type or model, and never do the work inline instead. The Phase 3.2 hooks record the rest: `subagent-start.sh` registers each agent (a `spawn` row), `post-agent.sh` its resolved model and usage (a `worker_run` row; a `model_mismatch` row if it ran on another family), and `subagent-stop.sh` each reviewer's final `VERDICT:` line as a raw review record.
   - **`ROUTE_ENFORCED: yes`** (`<state>/dispatch/`, the default since Phase 3.2): `checkpoint.sh review` takes only the hook-written review records (`--agent-id`) or shim results (`--worker`), and `complete` needs `ledger.sh evidence`, which the hook-written spawn rows satisfy.
   - **`ROUTE_ENFORCED: no`** (`dispatch-shadow/`): the human opted out with `APEX_DISPATCH_ENFORCE=0` before the run. The hooks still enforce the route and record everything in `dispatch-shadow/`, but `checkpoint.sh` stays in its classic mode (typed verdicts accepted). Say so in your report; never set or unset the variable yourself (`pre-bash.sh` refuses it).
4. **Commit** the builders' work on the worktree branch (lanes: one commit per lane, serially).

## Gate, tier, review shape

1. Run the task's Acceptance command in the worktree, then `$S/green-gate.sh PLAN check`. On FAIL go to Escalation. A PASS (or SKIPPED) at HEAD moves the `ACTIVE` lock to stage **GATE**: from then on commits and writes in the checkout are refused, and the next step is the review. To change code again you re-route (`$D/route.sh plan PLAN --line LINE`, which returns the lock to BUILD under a new route id).
2. `$S/risk-tier.sh PLAN LINE --since TASK_BASE` (re-run after every fix commit).
3. `$D/route.sh review-shape <ROUTE_ID> --tier <A|B|C>` with the tier just recorded. Dispatch what it prints:
   - **A — `solo`:** one `apex-dispatch:reviewer`.
   - **B — `six-lens`:** one `apex-dispatch:reviewer` that covers all six lenses (correctness, security, consent/PII, money, performance, maintainability). `REVIEW_DIVERSITY: warn`: prefer a different family; if you cannot, note it.
   - **C — `fanout6+adversarial`:** six `apex-dispatch:reviewer` (one `LENS:` each: correctness, security, consent-pii, money, performance, maintainability; each ends its return with `LENS: <lens>` above the verdict) plus one `apex-dispatch:adversarial-reviewer`, all in one message, then `G12`. `checkpoint.sh complete` counts six distinct lens approvals and one adversarial approval at HEAD. `REVIEW_DIVERSITY: block`: at least one verdict must come from a different family: `${CLAUDE_PLUGIN_ROOT}/bin/worker-codex.sh --route <ROUTE_ID> --role reviewer --brief <file>` when `doctor.json`'s `second_families` lists `codex`, else `${CLAUDE_PLUGIN_ROOT}/bin/worker-claude-p.sh` (the `dispatch-worker` skill; record it with `checkpoint.sh review … --worker <WORKER_OUT>`). A second family counts only when its shim ships and `doctor.json` shows its CLI available with auth and accepted forced flags; when none does, `complete` degrades diversity to a warning and a ledger row — report that explicitly; never stall and never pretend it was met.
   - **`none`:** dispatch no reviewer. Only the `gate` class has it (a `[gate:…]` task whose route is `HUMAN_GATE`): the human approval through the Ask Contract and `checkpoint.sh approve` is the review. Never choose `none` yourself, and never read it as "review optional" for any other class; if `review-shape` prints `none` for a task that is not a human gate, stop and report it.
   - External builders are forbidden for a Tier C task even if the build route allowed them.
4. Reviewers get WORKTREE, the head SHA, SINCE, the task, Acceptance, the tier, their lens, and the gate and Acceptance output (reviewers have no Bash), plus the review-loop inputs from the apex-scope-loop brief (its ADR-0004): `THREAT_MODEL` verbatim, `TIER_REASONS` verbatim (an overridden Tier C signal included; a reviewer who finds it real asks for the tier to be raised, which the orchestrator records with `risk-tier.sh --raise C --reason …`), `BUDGET` (= `ADVERSARY_BUDGET`), and `MODE`. Round 1 (`REVIEW_ROUND: 1`) is `MODE: full` with SINCE=TASK_BASE and carries the attempt's one full adversarial pass; later rounds are `MODE: verify` with SINCE=`REVIEW_SINCE` (=`LAST_REVIEWED`), unless the brief says `REVIEW_MODE: full` (tier rose, or no adversarial review yet in a Tier C attempt), and `PRIOR_FINDINGS` (the previous round's findings, verbatim). Non-blocking findings go to `backlog.sh`; an `ASK_HUMAN:` line from `checkpoint.sh review` means ask the human (accept the residual risk with `checkpoint.sh waive`, which this plugin's ledger records as a `human_gate` row, or keep fixing). Each must end with `VERDICT: APPROVE` or `VERDICT: REQUEST_CHANGES`. Wait until every builder has finished: `pre-agent.sh` refuses the move to REVIEW while one of this route's builders is still registered as running (a registration whose stop was lost clears after `ROUTE_BUDGET_MINUTES`, or re-route). A review that did not approve at a head (including a record the transcript audit refused) blocks `complete` at that head; only a new commit supersedes it, never another reviewer at the same SHA.
5. Record each verdict from its record: `$S/checkpoint.sh PLAN review LINE <sha> <VERDICT> apex-dispatch:reviewer --agent-id <agent_id>`, where `<agent_id>` is the reviewer's agent id from its Agent result (the record is `<state>/dispatch/reviews-raw/<agent_id>.json`, written by `subagent-stop.sh` from the reviewer's last `VERDICT:` line and bound to HEAD when it stopped). The role (`reviewer`, `lens:<name>`, `adversarial`) comes from the record; omit `--role`. A record is used once; a reviewer whose transcript shows a write or a git mutation gets a refused record (and a `policy_violation` row) instead — re-review with a fresh reviewer. External reviewers use `--worker DIR`. Under `ROUTE_ENFORCED: no` the classic typed form (`--role …`) still works. Three review rounds max, in code.
6. `G12`: `$S/checkpoint.sh PLAN halt "awaiting human gate G12 line <LINE>"`, Ask Contract, then `checkpoint.sh approve` with the human's literal reply.

## Escalation

On a gate failure or `REQUEST_CHANGES` past the fix you can make: `$S/checkpoint.sh PLAN fail LINE "<reason>"`. It prints `ESCALATE_ROUTE:` lines from `route.sh escalate`:

- `RUNG: effort-up` → next iteration routes `NEXT_BUILDER` (`builder-high`), same model, prior failure masked to `PRIOR_FAILURE_SUMMARY_TOKENS`.
- `RUNG: model-up` → `NEXT_MODEL` one tier up plus a read-only `DIAGNOSER` on a different family; inject its note into the builder brief.
- `RUNG: halt` → do what `ACTION:` says: halt with the Ask Contract.

Then re-run iterate (or `route.sh`): the next route already carries the rung (`ROUTE_MODE: escalated`). Never pick the rung yourself.

## Honesty rules

- Report the route you were given and what you dispatched; if they differ (a shim missing, diversity degraded, budget hit), say which field and why.
- `ROUTE_ENFORCED: no` means the human opted out (`APEX_DISPATCH_ENFORCE=0`): the hooks enforce and record the route in `dispatch-shadow/`, but `checkpoint.sh` does not require hook-written review records or spawn evidence. Do not describe the run as fully governed.
- The `stop-gate.sh` hook may refuse to end your turn once per route (uncommitted work in the worktree while no builder is running, or HEAD moved with nothing spawned). Ending the turn while background builders run is fine. Do what it says; to stop deliberately, close the task (`checkpoint.sh complete` or `fail`) or ask the human to set HALT.
- Never mark a task done that a sensor did not verify. `checkpoint.sh complete` (via `/apex-dispatch:done`) is the only way to close it.
