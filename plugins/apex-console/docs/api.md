# apex-console HTTP API (v1)

The console is a local server (`bin/apex-console serve`) bound to `127.0.0.1`. The UI in `ui/` is
its only client. Every route below is JSON. This file is the contract between `scripts/lib/` (the
server) and `ui/` (the page); `ui/demo.json` holds one example of every GET response so the page
can run with `?demo=1` and no server.

## Transport and safety

- The server prints `http://127.0.0.1:<port>/?t=<token>` once. `GET /?t=<token>` sets an
  `HttpOnly; SameSite=Strict` cookie `apex_console=<token>` and redirects to `/`. Every other
  request needs that cookie. A request whose `Host` is not `127.0.0.1:<port>` or `localhost:<port>`
  is refused (DNS rebinding).
- Every `POST` also needs the header `X-Apex-Console: 1` (a cross-site form cannot set it) and a
  JSON body. Responses carry `Cache-Control: no-store`.
- Errors: HTTP 4xx/5xx with `{"ok": false, "error": "<one sentence>", "errors": ["..."]}`.
- Key values are accepted by `POST /api/keys` and never returned by any route.
- Static files: `GET /`, `/app.js`, `/app.css`, `/demo.json` from `ui/`.

## Identifiers

- `repo`: a short id for a registered repository (`r1`, `r2`, ... stable per registration), or `all`.
- Times are ISO-8601 UTC strings (`2026-10-12T14:03:00Z`). Money is USD as a float. A value that
  cannot be computed is `null`, never `0`. Each metric says how many items it rests on in `n`.

## GET /api/state

```json
{"version": "0.1.0", "generated_at": "...", "config_dir": "~/.config/apex",
 "repos": [{"id": "r1", "name": "my-app", "path": "/Users/x/src/my-app", "ok": true, "error": null,
            "state_base": "/Users/x/src/my-app/.dev-plan-state", "plugins": {"apex-scope-loop": "0.5.0",
            "apex-dispatch": "0.6.1", "apex-decision-layer": "0.6.0"}, "active": true, "halted": false}],
 "targets": {"first_pass_yield": 0.7},
 "keys": {"set": 2, "missing_needed": ["OPENAI_API_KEY"]}}
```

## GET /api/metrics?repo=all&days=28

`days` in 7..365. The window is the last `days` days; `prev` values are the window before it.

```json
{"repo": "all", "days": 28, "window": {"from": "...", "to": "..."},
 "equation": {
   "terms": [
     {"id": "operators", "label": "Active repos", "value": 2, "prev": 1, "unit": "repos",
      "formula": "repositories with at least one route in the window", "group": "adoption"},
     {"id": "sessions", "label": "Tasks per repo", "value": 11.5, "prev": 9, "unit": "tasks/repo", "formula": "...", "group": "adoption"},
     {"id": "turns", "label": "Turns per task", "value": 1.4, "prev": 1.6, "unit": "routes/task", "formula": "...", "group": "overhead"},
     {"id": "requests", "label": "Requests per turn", "value": 3.2, "prev": 3.0, "unit": "agent runs/route", "formula": "...", "group": "overhead"},
     {"id": "tokens", "label": "Tokens per request", "value": 182000, "prev": 201000, "unit": "tokens/run", "formula": "...", "group": "overhead"},
     {"id": "price", "label": "Price per million tokens", "value": 1.9, "prev": 2.4, "unit": "USD/Mtok", "formula": "...", "group": "price", "factor": 1e-6}],
   "total_usd": 47.1,  // every term also has "factor": 1, except price (1e-6, since it is per million tokens) "prev_total_usd": 52.3, "unpriced_runs": 3,
   "note": "value x factor of the six terms multiply to total_usd."},
 "scorecard": [
   {"id": "first_pass_yield", "label": "First-pass yield", "group": "quality", "value": 0.64, "prev": 0.58,
    "unit": "ratio", "direction": "up", "target": 0.7, "status": "watch", "n": 25,
    "formula": "completed tasks approved in review round 1 of attempt 1 / completed tasks",
    "source": "uber|factory"}],
 "series": {"weeks": ["2026-09-14", "2026-09-21"], "requests": [40, 51], "spend": [10.2, 12.9],
            "cost_per_1k_requests": [255.0, 252.9], "cost_per_task": [2.1, 1.9],
            "tasks_completed": [5, 7], "active_repos": [1, 2], "cache_hit_rate": [0.61, 0.66]},
 "tier_mix": {"A": 10, "B": 9, "C": 4},
 "events": [{"at": "2026-09-30T10:12:00Z", "kind": "knobs", "repo": "r1", "id": "a-20260930-0003",
             "summary": "scope-loop: review.cap 3 -> 2"}],
 "notes": ["3 agent runs carried no usage; they are in requests but not in spend."]}
```

`events` are the knob changes and stops/resumes from the audit log inside the charted weeks: draw each as a
thin vertical marker on the weekly charts (hover shows the summary), so the operator sees whether a change moved a metric.

`status` is `good`, `watch` (within 15% of the target on the wrong side) or `off`, and `none`
when there is no target or no value. `direction` is `up` (higher is better) or `down`.

Scorecard ids (the server must emit all of these; `value` may be null):

| id | group | source | direction |
|---|---|---|---|
| `cost_per_task` | cost | uber | down |
| `cost_per_1k_requests` | cost | uber | down |
| `cost_per_review` | cost | uber | down |
| `weekly_requests` | adoption | uber | up |
| `revert_rate` | quality | uber | down |
| `finding_addressed_rate` | quality | uber | up |
| `mttr_hours` | quality | uber | down |
| `autonomy_rate` | adoption | uber | up |
| `cache_hit_rate` | cost | uber | up |
| `first_pass_yield` | quality | factory | up |
| `review_rounds` | quality | factory | down |
| `lead_time_p50_hours` | flow | factory | down |
| `lead_time_p90_hours` | flow | factory | down |
| `throughput_per_week` | flow | factory | up |
| `escalation_rate` | flow | factory | down |
| `human_touch_per_task` | flow | factory | down |
| `unparsed_rate` | integrity | factory | down |
| `policy_violations` | integrity | factory | down |
| `chain_ok_rate` | integrity | factory | up |

## GET /api/progress

```json
{"repos": [{"id": "r1", "name": "my-app", "halted": false, "halt_reason": null,
  "lock": {"kind": "plan", "id": "a1b2c3d4e5f6", "line": 14, "stage": "REVIEW", "since": "..."},
  "plans": [{"hash": "a1b2c3d4e5f6", "slug": "billing", "path": ".claude/plans/billing-plan.md", "name": "billing-plan",
    "scope": "feature",
    "intent": {"file": ".claude/tasks/billing-intent.md", "problem": "...", "who": "...", "why_now": "...", "non_goals": "..."},
    "total": 12, "done": 7, "phase": "Phase 2", "halted": false, "halt_reason": null,
    "landed": false, "last_activity": "...", "usd": 18.4, "open_findings": 2, "enforced": true,
    "operate": null,
    "cost": {"status": "measured", "delegated_usd": 17.9, "delegated_unknown_tasks": 1, "orchestrator_usd": 6.2,
             "orchestrator_unattributed_usd": 0.4, "orchestrator_unattributed_tokens": 120000, "usd_unrouted": 0.0},
    "tasks": [{"line": 12, "title": "Add invoice model", "status": "done", "tier": "C",
               "rounds": 2, "attempts": 1, "completed_at": "...", "usd": 3.1, "tokens": 91000,
               "orchestrator_usd": 0.9, "orchestrator_tokens": 410000, "orchestrator_na": null}]}],
  "watched": [{"hash": "c0ffee123456", "slug": "ship", "path": ".claude/plans/ship-plan.md", "day": 3, "days": 14, "end": "..."}],
  "repo_checks": {"configured": true, "state": "ok", "file": ".../.claude/apex-scope-loop/monitor.json", "problems": [],
                  "checks": [{"id": "site", "metric": "latency.p95", "op": "<", "threshold": 500, "severity": "high",
                              "declared": true, "measured": true, "last_value": 120, "last_status": "ok", "last_ts": "...",
                              "last_reason": null, "breaches": 0, "unmeasured_runs": 0, "filed": null, "unmeasured": false,
                              "last_measured_value": null, "last_measured_status": null, "last_measured_ts": null}],
                  "ingested": {"backlog": [{"id": "B-005", "title": "latency.p95 600 breached the expected ... (check site)", "done": false}],
                               "counts": {"backlog": 1, "backlog_open": 1}}},
  "adhoc": [{"id": "x9", "routes": 2, "usd": 0.8, "last_activity": "..."}]}]}
```

Task `status`: `done`, `active`, `failed` (has failures and is not done), `todo`.

Everything in this payload is read from files the plugins wrote. The console never runs `operate.sh deploy`,
`monitor` or `ingest`, and never writes state. A value that cannot be computed is `null` (never `0`); a
state file that does not exist or cannot be read is reported as such (`"missing"`, `"unreadable"`), not as zeros.

**Scope and intent.** `scope` is the plan header's `> **Scope**: bugfix|poc|feature` (a plan without the header is
`feature`). `intent` is `null` unless `.claude/tasks/<slug>-intent.md` exists; its four sections are each at most
400 characters, `null` when empty. `slug` is the plan file name without `.md` and a trailing `-plan`.

**Operate (`plans[].operate`).** `null` until the plan has landed. For a landed plan, from checkpoint.json's
`operate` block (apex-scope-loop's `operate.sh` schema) and the plan's `## Monitor` section (read with
apex-scope-loop's `monitorlib`):

```json
{"slug": "ship", "tag": "operate:ship", "state": "ok", "scope": "poc", "monitor": "ok", "window_days": 14, "problems": [],
 "deploys": [{"ts": "...", "sha": "bbbb...", "exit": 0}], "last_deploy": {"ts": "...", "sha": "bbbb...", "exit": 0},
 "window": {"state": "open", "day": 3, "days": 14, "start": "...", "end": "...", "outcome": null, "closed_by": null,
            "open_at_close": null, "unmeasured_at_close": null, "measured_runs": 2, "breaches": 2, "last_run": "...",
            "never_measured": false},
 "windows_closed": 1,
 "last_closed_window": {"outcome": "closed-with-breaches", "closed_by": "monitor", "closed_at": "...", "start": "...",
                        "end": "...", "days": 14, "open_at_close": ["p95"], "unmeasured_at_close": ["never"],
                        "measured_runs": 3, "breaches": 4, "never_measured": false},
 "ingested": {"lessons": [{"id": "L-002", "title": "operate-ship-p95-breach"}],
              "backlog": [{"id": "B-001", "title": "errors 9 breached the expected errors < 5 (...)", "done": false}],
              "counts": {"lessons": 1, "backlog": 1, "backlog_open": 1}},
 "checks": [{"id": "p95", "metric": "latency.p95", "op": "<", "threshold": 800, "severity": "high", "declared": true,
             "measured": true, "last_value": 950, "last_status": "breach", "last_ts": "...", "last_reason": null,
             "breaches": 2, "unmeasured_runs": 0, "filed": "lessons", "unmeasured": false,
             "last_measured_value": null, "last_measured_status": null, "last_measured_ts": null, "open_at_close": false}]}
```

- `state`: `ok`, or `missing` when the landed plan's checkpoint has no `operate` block (no deploys, `window.state`
  `not-opened`, nothing measured). `monitor`: `ok`, `empty` (checks: []), `none` (no section; `warning` says so),
  `invalid` (`problems` lists why), `unknown`.
- `window.state`: `not-opened`, `open` (`day` N of `days`), `closed` (`outcome` `operated-clean` or
  `closed-with-breaches`, with `open_at_close`, `unmeasured_at_close`, `measured_runs`; `outcome` is null when
  the window ended but no monitor run has closed it yet) or `unreadable`.
- Each check merges the declared check with its recorded state. A check never measured has `measured: false`,
  `last_value: null`, `breaches: null`, `unmeasured: true`. `last_value` is `null` when the last probe failed
  (`last_status: "unmeasured"`; `last_measured_*` hold the last good reading). Breach counts are the plan-lifetime
  counts operate.sh keeps; `filed` says where the first breach went (lessons or backlog, tag `operate:<slug>`).
  `breaches` and `unmeasured_runs` are `null` (never `0`) when the check was never measured or the recorded count
  is missing or not an integer (a boolean is not one).
- `windows_closed` is how many windows have closed; `last_closed_window` is the last entry of operate's
  `windows_closed` (what `operate.sh status` prints as "last closed window"): `outcome`, `closed_by`, `closed_at`,
  `start`, `end`, `days`, `open_at_close`, `unmeasured_at_close`, `measured_runs`, `breaches` (counts `null` when
  not integers) and `never_measured` (true for 0 measured runs). `null` when no window has closed.
- `ingested` is what `operate.sh ingest` filed for this plan, read from the MAIN checkout's
  `.claude/apex-scope-loop/LESSONS.md` (blocks tagged `#operate:<slug>`) and `BACKLOG.md` (items under a
  `## Plan:` section whose text starts `[operate:<slug>]`), the files `lessons.sh` and `backlog.sh` use
  (`APEX_LESSONS_FILE` / `APEX_BACKLOG_FILE` override them). Ids and short titles only (a title is at most 100
  characters; `done` is the backlog item's `[x]`), at most 50 of each; `counts` are the totals (`backlog_open`
  excludes done items). The files are only read, never written.

**`watched`** lists every plan whose window is open. **`repo_checks`** are the repo-level checks from
`.claude/apex-scope-loop/monitor.json` with their state from `<state base>/operate-repo/state.json`; `state` is
`ok`, `missing` (declared, state file absent), `invalid`, `unreadable` or `none` (no monitor.json, `configured: false`).
`repo_checks.ingested` lists the repo-level backlog items (`[operate:repo]` under `## Repo: ...` in BACKLOG.md; the
repo level never files a lesson, so there is no `lessons` key): `{"backlog": [{id, title, done}], "counts":
{"backlog", "backlog_open"}}`, present whether or not monitor.json exists.

**Cost.** Per task and per plan these are the numbers of `report.sh --per-task --json` (apex-dispatch's
`report.per_task`, called read-only; transcripts are auto-located under `$CLAUDE_CONFIG_DIR` or `~/.claude`).
Per task: `usd` / `tokens` are delegated only and `null` when n/a (an agent with no recorded usage, for example a
background agent, makes both null; there is no partial figure); `orchestrator_usd` / `orchestrator_tokens` are the
main session's, `null` when n/a, with the reason in `orchestrator_na` (`null` when measured; `orchestrator_usd`
alone null with `orchestrator_na` null means tokens measured, price unknown). For a task with no routed row in the
ledger, `orchestrator_na` is the string `"no routed task"` (or the plan's `n/a (...)` status when the whole report is
unavailable), never `null`. The plan's `usd` above is the older
row-priced sum and may differ from `cost.delegated_usd`. `plans[].cost`: `status` is `measured` or the
`n/a (...)` reason every orchestrator figure is null (no ledger, no transcript, report unavailable);
`delegated_usd` is the sum over tasks with a known figure and `delegated_unknown_tasks` counts the n/a ones;
`orchestrator_unattributed_usd` / `_tokens` are main-session turns inside no single task's window (null = n/a).
A task not in the ledger has all the figures null and `orchestrator_na` set as above.
The cost result is cached once per state dir and refreshed when the ledger, a located transcript's (mtime, size) or
the 30-second time bucket changes (the bucket is in the stamp, never in the cache key, so a console left open does
not accumulate entries).

## GET /api/knobs?repo=r1

```json
{"repo": "r1", "active_lock": null,
 "scope_loop": {"available": true, "file": "<state-base>/knobs/scope-loop.json", "sha": "default",
   "effective": {"review": {"cap": 3, "ask_human_after": 2, "adversary_budget": 3, "escalate_after": 2,
                            "error_budget": 3, "attempt_cap": 6},
                 "tiers": {"c_paths_extra": [], "c_terms_extra": [], "exempt": [], "b_max_lines": 150,
                           "b_max_files": 6, "b_shared_dirs": ["api", "routes", "shared", "common", "core", "lib"]}},
   "sources": {"review.cap": "default"},
   "builtins": {"c_paths": "<regex>", "c_terms": "<regex>"},
   "limits": {"review.cap": [1, 10]}},
 "dispatch": {"available": true, "overlay_path": ".claude/apex-dispatch/policy.json",
   "providers": [{"id": "codex", "enabled": true, "family": "openai", "roles_allowed": ["builder", "reviewer"],
                  "roles_default": ["builder", "reviewer"], "min_acceptance": 0.7, "status": "verified",
                  "available": true, "second_family": true, "key_env": "OPENAI_API_KEY"}],
   "escalation": {"max_review_rounds": 3}, "second_families": ["codex"]},
 "decision": {"available": true, "path": ".claude/apex-decision-layer/config.json",
   "config": {"egress": "none", "state_fields": "structured", "primary": {"default": "none"},
              "shadow": {"backend": null, "sample": 0}},
   "rubrics": ["dispatch/task-class@1", "scope-loop/risk-tier@1"], "backends": ["none", "jev", "frontier"]}}
```

## POST /api/knobs/preview and POST /api/knobs

Body: `{"repo": "r1", "plugin": "scope-loop" | "dispatch" | "decision", "patch": {...}}`.
`patch` is a partial object in the shape of that plugin's `effective` / `config` (dispatch:
`{"providers": {"codex": {"enabled": false, "reviewer": true, "min_acceptance": 0.8}},
"escalation": {"max_review_rounds": 2}}`). `preview` validates and returns the change; the plain
route also writes it and records an audit entry.

```json
{"ok": true, "changes": [{"key": "review.cap", "from": 3, "to": 2}], "warnings": ["A task is running ..."],
 "audit_id": "a-20261012-0001"}
```

## POST /api/tiers/simulate (tier simulator)

Body `{"repo": "r1", "patch": {<the proposed tiers object, same shape as knobs.scope_loop.effective.tiers;
partial is fine>}, "limit": 30}` (limit 1-60). Read-only: nothing is written. The proposal is validated by
apex-scope-loop's knobslib (the same refusals as `POST /api/knobs`, HTTP 422). Each of the last `limit`
completed tasks is replayed twice by apex-scope-loop's own `risk-tier.sh --no-record --since <base> --head
<completed head>`, under the knobs in force and under the proposal. Takes seconds (about 1 s per task, 4 at
a time): show progress.

```json
{"ok": true, "repo": "r1",
 "changes": [{"key": "tiers.exempt", "from": [], "to": [{"glob": "plugins/*/agents/*.md", "reason": "..."}]}],
 "summary": {"replayed": 23, "errors": 1, "changed": 6, "looser": 5, "stricter": 1, "moves": {"C→A": 4, "C→B": 1, "A→B": 1},
             "mix_current": {"A": 9, "B": 6, "C": 8}, "mix_proposed": {"A": 13, "B": 6, "C": 4},
             "note": "Replays risk-tier.sh's heuristic only: reviewer raises and the decision layer are not replayed, ..."},
 "tasks": [{"plan": "a1b2c3d4e5f6", "plan_path": ".claude/plans/billing-plan.md", "line": 34, "title": "...",
            "completed_at": "...", "recorded": "C", "current": "C", "proposed": "A", "move": "C→A", "error": null,
            "added": ["exempted by knobs: plugins/x/agents/a.md (plugins/*/agents/*.md: ...)"],
            "removed": ["tier-c path: plugins/x/agents/a.md"],
            "reasons_current": ["..."], "reasons_proposed": ["..."]}]}
```

`recorded` is the tier in the checkpoint (it can include reviewer raises and the decision layer, which a
replay does not); `current` is the replay under the knobs in force; `proposed` under the proposal; `move` is
`"<current>→<proposed>"` or null. A task whose diff cannot be replayed (no recorded base, commits gone) has
`error` and null tiers.

## GET /api/keys

```json
{"path": "~/.config/apex/keys.env", "exists": true, "mode_ok": true,
 "profile": {"sourced_in": ["~/.zshrc"], "snippet": "[ -f ~/.config/apex/keys.env ] && . ~/.config/apex/keys.env"},
 "keys": [{"name": "ANTHROPIC_API_KEY", "set": true, "last4": "x7Qa", "updated_at": "...",
           "in_console_env": true, "used_by": ["apex-dispatch: claude-p worker", "apex-decision-layer: frontier backend"],
           "needed": true}]}
```

`POST /api/keys` body `{"name": "OPENAI_API_KEY", "value": "sk-..."}` or `{"name": "...", "remove": true}`
→ `{"ok": true, "audit_id": "..."}`. Names must match `^[A-Z][A-Z0-9_]{2,63}$`.
`POST /api/keys/check` body `{"probe": false}` → `{"ok": true, "checks": [{"name": "...", "status": "ok|warn|fail|skipped", "detail": "..."}]}`.

## POST /api/halt

Body `{"repo": "r1", "on": true, "reason": "pausing for review"}` → `{"ok": true, "audit_id": "..."}`.
Writes or removes `<state-base>/HALT` (the scope-loop kill switch).

## GET /api/audit?limit=100 and POST /api/audit/undo

```json
{"entries": [{"id": "a-20261012-0001", "at": "...", "repo": "r1", "kind": "knobs|keys|halt|repos|targets",
              "summary": "review.cap 3 -> 2", "changes": [{"key": "review.cap", "from": 3, "to": 2}],
              "undoable": true, "undone_by": null}]}
```

Undo body `{"id": "a-..."}` → the same shape as `POST /api/knobs`. Key changes are not undoable (the
old value is never kept).

## POST /api/repos and POST /api/targets

`{"add": "/abs/path"}` or `{"remove": "r2"}` → `/api/state`. `{"id": "first_pass_yield", "target": 0.75}`
(or `"target": null` to clear) → `{"ok": true}`.
