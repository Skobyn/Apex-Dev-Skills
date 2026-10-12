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
  "plans": [{"hash": "a1b2c3d4e5f6", "path": ".claude/plans/billing-plan.md", "name": "billing-plan",
    "total": 12, "done": 7, "phase": "Phase 2", "halted": false, "halt_reason": null,
    "landed": false, "last_activity": "...", "usd": 18.4, "open_findings": 2, "enforced": true,
    "tasks": [{"line": 12, "title": "Add invoice model", "status": "done", "tier": "C",
               "rounds": 2, "attempts": 1, "completed_at": "...", "usd": 3.1}]}],
  "adhoc": [{"id": "x9", "routes": 2, "usd": 0.8, "last_activity": "..."}]}]}
```

Task `status`: `done`, `active`, `failed` (has failures and is not done), `todo`.

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
