# ADR-0001: apex-console contract

- **Status:** Accepted
- **Date:** 2026-10-12
- **Plugin:** apex-console v0.2.0 (tier simulator in v0.2.0)

## Context

apex-scope-loop, apex-dispatch and apex-decision-layer each write their own records: checkpoints, a hash-chained ledger, a decision log, review records. Each also reads its own settings: env vars, a policy overlay, a config file. The operator had no single place to:

- put API keys;
- see what is running and how far each plan has got;
- tell whether the factory is getting better or worse;
- change how strict it is.

The tier definitions and the review-strictness settings could not be changed without editing scripts.

## Decision

apex-console is an **admin layer, not an orchestration layer**. It is a local web page served by `bin/apex-console serve` (Python 3 stdlib) on `127.0.0.1`. It:

1. reads what the three plugins write, and never writes their run state;
2. writes only settings the plugins honour, only after the owning plugin's own validator accepts them;
3. writes API keys to a file the user's shell sources;
4. computes metrics from the plugins' own records, using the plugins' own pricing and chain verification;
5. never starts, routes, reviews or completes work. The one exception is the kill switch: it writes or removes `<state-base>/HALT`, the file apex-scope-loop already obeys.

### Surface

- `bin/apex-console`: `serve [--port N] [--repo PATH]... [--open]`, `repos [add PATH | remove ID]`, `metrics [--repo ID] [--days N]`, `progress`.
- `/apex-console:console`: starts the server for the current repository and prints its address.
- `ui/`: the page (`index.html`, `app.js`, `app.css`), plus `demo.json` for `?demo=1`.
- The HTTP API is specified in `docs/api.md`. It is the contract between `scripts/lib/` and `ui/`.

### Files

| File | Owner | The console |
|---|---|---|
| `<config-dir>/console.json` (registered repos, metric targets) | apex-console | reads, writes |
| `<config-dir>/console-audit.jsonl` | apex-console | appends only |
| `<config-dir>/keys.env` (mode 0600) | apex-console | writes; never returns a value |
| `<state-base>/<plan>/checkpoint.json`, `findings/`, `gate/` | apex-scope-loop | reads |
| `<state-base>/ACTIVE/owner.json`, `HALT` | apex-scope-loop | reads; writes and removes `HALT` only |
| `<state-base>/knobs/scope-loop.json` | apex-scope-loop (ADR-0003, v0.5.0) | writes after `knobslib.py validate` |
| `<state>/dispatch*/ledger.jsonl`, `doctor.json` | apex-dispatch | reads; verifies with `ledger.verify` |
| `<repo>/.claude/apex-dispatch/policy.json` | apex-dispatch | writes after `compile.py --print-merged --overlay` |
| `<state-base>/decisions/decisions.jsonl` | apex-decision-layer | reads |
| `<repo>/.claude/apex-decision-layer/config.json` | apex-decision-layer | writes `egress`, `state_fields`, `primary`, `shadow` after `decide.load_config`; never `calibration_lock` |

`<config-dir>` is `APEX_CONFIG_DIR`, default `~/.config/apex`. `<state-base>` comes from apex-scope-loop's own `apex_state_base` (it honours `APEX_STATE_ROOT`).

The plugins are found as siblings by the marketplace rule: a checkout's `plugins/<name>`, or the highest cached `<name>/<version>/`. The env overrides `APEX_SCOPE_LOOP_ROOT`, `APEX_DISPATCH_ROOT` and `APEX_DECISION_LAYER_ROOT` win.

### Settings ("knobs") and why each is safe to edit

- **Review strictness and tier definitions** live in `<state-base>/knobs/scope-loop.json`, apex-scope-loop's file. During a run apex-dispatch's `pre-bash` and `pre-edit` hooks already refuse agent writes to the state base. So an agent cannot loosen them mid-run, and no hook had to change.
  - Env vars still win over the file.
  - An invalid file stops the scripts rather than falling back.
- **Reviewers and providers** go in the apex-dispatch overlay. Its merge rules already bound what an overlay may do:
  - providers may be disabled or narrowed;
  - `min_acceptance` may only be raised;
  - `max_review_rounds` may only be lowered, and is at most 3.
  - The console offers exactly those three fields: `enabled`, the `reviewer` role, and `min_acceptance`.
- **Decision layer:** `egress`, `state_fields`, the primary backend per rubric, and shadow. `calibration_lock` is never edited, because only the measurement job grants calibration.
- **Running tasks:** a change made while a task is running applies from that task's next check. The page says so before it applies.
- **Audit and undo:** every write is recorded in the audit log with the file's previous bytes. Undo restores them, but only if the file is unchanged since the console wrote it. Key changes are logged without values and cannot be undone.

### Metrics

Every metric is computed from records, carries `n` (how many items it rests on), and is `null`, never 0, when it cannot be computed. The window is the last N days; `prev` is the window before it.

**Uber software factory.** Source: Uber Engineering, "Running a Software Factory Efficiently at Uber Scale", 2026. Uber decomposes spend as users × sessions/user × turns/session × requests/turn × tokens/request × price/token. It grows the first two terms (adoption), cuts the next three (agent overhead), and routes work to the cheapest capable model (price). It denominates cost by outcome and pairs each cost with a quality signal. Mapped onto this suite:

| Uber term | Here | Definition |
|---|---|---|
| users | active repos | registered repositories with a `route` row in the window |
| sessions/user | tasks per repo | distinct tasks routed (plan line, or ad-hoc route family) / active repos |
| turns/session | turns per task | `route` rows / tasks routed (a re-route is a new turn) |
| requests/turn | runs per turn | `worker_run` rows / `route` rows |
| tokens/request | tokens per run | input + output + cache_read + cache_write / runs |
| price/token | price per Mtok | apex-dispatch USD (`report.row_usd`) / tokens × 1e6 |

The six terms × their factors multiply to the window's spend by construction. Runs without a priced model add tokens but no USD, and their count is shown.

Outcome cost and its quality pair:
- cost per completed task, paired with **revert rate**: a task counts as reverted when git finds `This reverts commit <sha>` for a commit in its `since..head`;
- cost per review, paired with **findings addressed**: blocking findings closed / raised;
- **time to recover**: median hours from a task's first `escalate` to its completion. This is the MTTR analogue.

Also: cost per 1,000 runs, runs per week, prompt cache hit rate (cache_read / (input + cache_read + cache_write)), and autonomy rate (completed tasks without a G12 approval, waiver or human gate). The last stands in for Uber's share of agent-authored PRs, since every change here is agent-made.

**Factory flow and integrity:**
- first-pass yield (approved in round 1 of attempt 1);
- review rounds per task;
- lead time p50 and p90 (first route to completion);
- throughput per week;
- escalation rate;
- human touches per task;
- unreadable-verdict rate (UNPARSED);
- policy violations;
- ledgers whose chain verifies.

**Targets.** Each metric can carry a target, stored in `console.json`. Status is good, watch (within 15% on the wrong side) or off. Defaults are set only where a sensible neutral value exists. Cost targets are left to the operator.

### Security

- The server binds `127.0.0.1` only.
- Each launch prints a random token. `GET /?t=<token>` sets an `HttpOnly; SameSite=Strict` cookie, and every API call needs it.
- A `Host` header other than `127.0.0.1:<port>` or `localhost:<port>` is refused, which blocks DNS rebinding.
- Every POST needs `X-Apex-Console: 1` and a JSON body under 64 KiB.
- The CSP is `script-src 'self'`. Fonts are the only third-party load.
- Key values are accepted, written at mode 0600, reported only as set or not set and their last four characters, and never logged.

## Consequences

- One place to manage and observe the suite. The plugins remain the source of truth, and the console holds no state they depend on.
- Tier definitions became data (apex-scope-loop v0.5.0). Loosening them is now possible from the page: exemptions need a reason, are logged, and are named in every tier record they affect.
- Metrics depend on the plugins' record formats. When a format changes, the console needs a matching change, and the smoke test catches drift on its fixture.

## Compatibility

- apex-scope-loop ≥ 0.5.0 for the knobs file and ≥ 0.6.0 for the tier simulator (older versions: progress and metrics only; the scope-loop knobs show as unavailable).
- apex-dispatch ≥ 0.6.0, whose `report.row_usd`, `ledger.verify` and `compile.py --print-merged --overlay` the console calls.
- apex-decision-layer ≥ 0.6.0.
- python3 ≥ 3.8 and git. bash only for apex-scope-loop's `apex_state_base`.

## Namespace coordination

apex-console claims `<config-dir>/console.json`, `console-audit.jsonl`, `keys.env` and `keys.meta.json`. It writes no memory or AgentDB keys. It writes inside other plugins' namespaces only through the files in the table above, each validated by its owner.

## Smoke contract

`scripts/smoke.sh` checks the manifest and README sections. It then builds a fixture repository whose dispatch ledger is written by apex-dispatch's own `ledger.append` and asserts:
- the six equation terms multiply to the spend;
- the scorecard values on the fixture;
- the server's token, Host and header checks;
- that no route returns a key value;
- refusals by each plugin's validator;
- the audit and undo round trip, and the kill switch.

## Status log

- 2026-10-12 (v0.1.0): first release.
- 2026-10-12 (v0.2.0) — **Tier simulator.** `POST /api/tiers/simulate` replays up to 60 completed tasks of a repository under a proposed tiers object. The proposal is the knobs file in force merged with the patch, validated by `knobslib.py`. Each task's committed diff (its tier record's `since` to its `completes` head) is classified twice by apex-scope-loop's own `risk-tier.sh --no-record --since --head` (0.6.0), once under the knobs in force and once with `--knobs <proposal>`. The result lists per task the recorded, current and proposed tiers, the move, and the reasons added and removed. It is read-only: it holds no write lock and writes nothing. Only the heuristic is replayed, never reviewer raises or the decision layer, and the page says so. Smoke check 11.
