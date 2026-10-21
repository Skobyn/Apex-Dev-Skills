# Borrow from AI-DLC: scope sizing, ideation, operation phase, per-task cost — Development Plan

> **ADR**: [`.claude/tasks/aidlc-borrowings-adr.md`](../tasks/aidlc-borrowings-adr.md)
> **Goal**: Scoped authoring (bugfix/poc/feature), a round-0 intent step, a post-land `operate.sh`, and per-task cost (delegated + orchestrator) in `report.sh`, with execution enforcement unchanged
> **Owner**: skobyn@gmail.com
> **Started**: 2026-10-14
> **Target**: none set

## Design Intent

**Bounded contexts**: `plugins/apex-scope-loop` (apex-plan + apex-execute skills, commands), `plugins/apex-dispatch` (ledger events, report, protected switches), `plugins/apex-console` (collect + UI).

**Architecture** (from the ADR): scope picks the interview rounds, the template and the promote-time limits, and never touches execution. `operate.sh` runs on a landed plan: deploy (human ack, `$APEX_DEPLOY_CMD`) → monitor (`$APEX_MONITOR_CMD` JSON) → ingest (lessons/backlog tagged `operate:{slug}`, ledger `operate_signal`). `report.sh --per-task` lists delegated USD from `tasks_of()` plus orchestrator USD from session-transcript turns attributed by route window.

**Non-negotiable constraints**:

- Plans without a Scope line, including `.claude/plans/apex-dispatch-plan.md` and `novel-plugins-suite-plan.md`, validate, promote, iterate and land exactly as today
- Scope never loosens the green gate, review, risk tier/G12, ratchet, kill switches or ledger evidence
- `operate.sh` never holds deploy credentials. A deploy always needs a human ack that no agent or knob can bypass
- Every touched plugin: smoke green with new checks, `plugin.json` minor bump, ADR-0001 status-log entry; marketplace/plugin/README descriptions consistent
- No new hook. `hooks/hooks.json` only changes through apex-dispatch's `compile.sh`, and `compile.sh --check` stays green
- New memory key `apex-scope-loop:operate/{slug}` is claimed in apex-scope-loop ADR-0001 before use

**Gate commands**: `.agents/gate.json` (committed on the base branch before init) sets `test` to the apex-scope-loop, apex-dispatch and apex-console smoke suites; `generate`/`typecheck`/`lint`/`build` are empty. The loop forks from branch `aidlc-borrowings-base` and lands back onto it; merging that branch to main is a separate PR.

## Threat model

Trusted, non-malicious agents and a single trusted operator (solo). In scope: accidents and realistic misuse by the loop's own agents, such as setting `APEX_OPERATE_ACK` or a deploy env var mid-run, an agent writing lessons/backlog from unvalidated monitor output, a parser that silently skips malformed transcript or monitor lines and reports 0 instead of `n/a`, or an existing plan that stops validating. Out of scope: deliberate tampering with state/config by the trusted agent, a malicious `$APEX_DEPLOY_CMD`/`$APEX_MONITOR_CMD` (the user owns those), obfuscated inputs, and Claude Code transcript forgery. A finding outside this model is non-blocking and goes to the hardening backlog.

---

## Execution Strategy

> **Default per phase**: hierarchical-mesh (chosen in SCOPE round 5). Under apex-dispatch, `Swarm:` is advisory and `route.sh` picks the final roster, tier and fan-out.
> **Gates**: auto-only (round 6). Two built-in exceptions remain: G12 halts any task risk-tier.sh classifies Tier C (tasks tagged `[tier:c]` below), and `operate.sh deploy` always waits for a human ack at run time.

### Swarm directives (per task)

| Directive | Meaning |
|-----------|---------|
| `Swarm: single [{agent-type}]` | One `Agent` tool invocation |
| `Swarm: multi {count} [{t1}, {t2}, ...]` | N parallel `Agent` calls in one message |
| `Swarm: hierarchical {count} [{t1}, {t2}, ...]` | Coordinated group; apex-dispatch fanout or optional ruflo swarm |

### Approval gates (between phases)

| Gate tag | Behavior |
|----------|----------|
| `[gate:auto]` | Orchestrator runs the Acceptance check; advances on pass, halts on fail |

---

## Phases

### Phase 0 — Green baseline on macOS

The three gate suites must exit 0 before any feature work. Two fail on main today for macOS reasons.

- [x] **Phase 0.1** [tests] Make apex-scope-loop's `.GIT` dirty-check fixture work on case-insensitive filesystems (detect case-insensitivity and test the `.GIT` rule on a path that cannot alias `.git`, or skip that one assertion with a printed reason)
  - Acceptance: `L="${TMPDIR:-/tmp}/p01-smoke.log"; { bash plugins/apex-scope-loop/scripts/smoke.sh >"$L" 2>&1 || grep -q 'smoke FAIL: snapshot failed' "$L"; } && ! grep -q 'missed a top-level directory named .GIT' "$L"` (the snapshot failure is Phase 0.3's; the full suite must pass at Gate 0→1)
  - Swarm: single [tester]
  - Paths: plugins/apex-scope-loop/scripts/smoke.sh, plugins/apex-scope-loop/skills/apex-execute/scripts/_lib.sh

- [x] **Phase 0.2** [tests] Fix apex-dispatch smoke's ad-hoc state check under macOS `/var` → `/private/var` (compare resolved paths; fix route.py too if it is the code, not the test, that mis-resolves)
  - Acceptance: `bash plugins/apex-dispatch/scripts/smoke.sh`
  - Swarm: single [tester]
  - Paths: plugins/apex-dispatch/scripts/smoke.sh, plugins/apex-dispatch/scripts/lib/route.py

- [x] **Phase 0.3** [tests] Fix `snapshot.sh` on macOS: move the snapshot tree into place before making it read-only (a read-only directory cannot be renamed across parents on macOS), keeping the snapshot read-only afterwards
  - Acceptance: `bash plugins/apex-scope-loop/scripts/smoke.sh && grep -q 'snapshot-readonly-after-move' plugins/apex-scope-loop/scripts/smoke.sh` (smoke check `snapshot-readonly-after-move`: a snapshot is created on macOS, lands at its sha path, and every file and directory in it is non-writable)
  - Swarm: single [tester]
  - Paths: plugins/apex-scope-loop/skills/apex-execute/scripts/snapshot.sh, plugins/apex-scope-loop/scripts/smoke.sh
  - Blocked-by: phase-0.1

- [x] **Gate 0→1** [gate:auto] All three gate suites green
  - Acceptance: `bash plugins/apex-scope-loop/scripts/smoke.sh && bash plugins/apex-dispatch/scripts/smoke.sh && bash plugins/apex-console/scripts/smoke.sh`
  - Blocked-by: phase-0.1, phase-0.2, phase-0.3

---

### Phase 1 — Scope sizing

- [x] **Phase 1.1** [tests] Add baseline fixtures for the existing plans (validate + promote dry-run output recorded) and a smoke check that they keep validating
  - Acceptance: `bash plugins/apex-scope-loop/scripts/smoke.sh && grep -q 'existing-plans-baseline' plugins/apex-scope-loop/scripts/smoke.sh && python3 plugins/apex-scope-loop/skills/apex-execute/scripts/planlib.py validate .claude/plans/apex-dispatch-plan.md && python3 plugins/apex-scope-loop/skills/apex-execute/scripts/planlib.py validate .claude/plans/novel-plugins-suite-plan.md`
  - Swarm: single [tester]
  - Paths: plugins/apex-scope-loop/scripts/smoke.sh, plugins/apex-scope-loop/scripts/fixtures/**
  - Blocked-by: gate-0-1

- [x] **Phase 1.2** [backend] Add lean ADR/plan templates to both profiles and `start.sh --scope bugfix|poc|feature`
  - Acceptance: `bash plugins/apex-scope-loop/scripts/smoke.sh && grep -q -- '--scope' plugins/apex-scope-loop/skills/apex-plan/scripts/start.sh && ls plugins/apex-scope-loop/skills/apex-plan/resources/templates/profiles/{generic,apex}/{adr,plan}-template-lean.md && grep -q 'scope-start' plugins/apex-scope-loop/scripts/smoke.sh` (smoke check `scope-start` scaffolds each scope in a temp repo, asserts the `**Scope**:` / `> **Scope**:` lines, defaults to feature with no flag, rejects an unknown scope, and diffs generic vs apex lean section headings)
  - Swarm: hierarchical 3 [builder, tester, reviewer]
  - Paths: plugins/apex-scope-loop/skills/apex-plan/scripts/start.sh, plugins/apex-scope-loop/skills/apex-plan/resources/templates/**, plugins/apex-scope-loop/scripts/smoke.sh
  - Blocked-by: phase-1.1

- [x] **Phase 1.3** [backend] Apply per-scope validation in `promote-to-loop.sh`
  - Acceptance: `bash plugins/apex-scope-loop/scripts/smoke.sh && grep -q 'scope-promote' plugins/apex-scope-loop/scripts/smoke.sh` (smoke check `scope-promote`: a 2-phase bugfix fixture promotes (exit 0); a 3-phase bugfix fixture exits 1 naming the phase limit; a 4-phase poc exits 1; a bugfix with `[tier:c]` promotes and prints a warning; a scope-less fixture promotes as before)
  - Swarm: hierarchical 3 [builder, tester, reviewer]
  - Paths: plugins/apex-scope-loop/skills/apex-plan/scripts/promote-to-loop.sh, plugins/apex-scope-loop/scripts/smoke.sh
  - Blocked-by: phase-1.2

- [x] **Phase 1.4** [docs] Document per-scope round sets in SKILL.md, `/apex-scope-loop:start` and both feedback-interview files
  - Acceptance: `bash plugins/apex-scope-loop/scripts/smoke.sh && grep -q 'bugfix' plugins/apex-scope-loop/skills/apex-plan/SKILL.md && grep -q 'bugfix' plugins/apex-scope-loop/commands/start.md && grep -q 'bugfix' plugins/apex-scope-loop/skills/apex-plan/resources/templates/profiles/generic/feedback-interview.md && grep -q 'bugfix' plugins/apex-scope-loop/skills/apex-plan/resources/templates/profiles/apex/feedback-interview.md`
  - Swarm: single [docs]
  - Paths: plugins/apex-scope-loop/skills/apex-plan/SKILL.md, plugins/apex-scope-loop/commands/start.md, plugins/apex-scope-loop/skills/apex-plan/resources/templates/profiles/*/feedback-interview.md
  - Blocked-by: phase-1.3

- [x] **Gate 1→2** [gate:auto] Scope sizing green, existing plans unaffected
  - Acceptance: `bash plugins/apex-scope-loop/scripts/smoke.sh && python3 plugins/apex-scope-loop/skills/apex-execute/scripts/planlib.py validate .claude/plans/apex-dispatch-plan.md && python3 plugins/apex-scope-loop/skills/apex-execute/scripts/planlib.py validate .claude/plans/novel-plugins-suite-plan.md`
  - Blocked-by: phase-1.4

---

### Phase 2 — Ideation (round-0 intent)

- [x] **Phase 2.1** [backend] Add the intent round and `intent-template.md` to both profiles; `start.sh` writes `{slug}-intent.md` and seeds its Problem into the ADR's "Why this matters"
  - Acceptance: `bash plugins/apex-scope-loop/scripts/smoke.sh && grep -q 'intent-seed' plugins/apex-scope-loop/scripts/smoke.sh` (smoke check `intent-seed`: with an intent file present, the scaffolded ADR's "Why this matters" contains its Problem text; with none and `--scope bugfix`, scaffolding succeeds; with none and `--scope feature`, start.sh prints a reminder and still succeeds)
  - Swarm: hierarchical 3 [builder, tester, reviewer]
  - Paths: plugins/apex-scope-loop/skills/apex-plan/scripts/start.sh, plugins/apex-scope-loop/skills/apex-plan/resources/templates/**, plugins/apex-scope-loop/skills/apex-plan/SKILL.md, plugins/apex-scope-loop/commands/start.md, plugins/apex-scope-loop/scripts/smoke.sh
  - Blocked-by: gate-1-2

- [x] **Phase 2.2** [backend] `status.sh` (apex-plan) prints Scope and whether an intent file exists
  - Acceptance: `bash plugins/apex-scope-loop/scripts/smoke.sh && grep -q 'status-scope' plugins/apex-scope-loop/scripts/smoke.sh`
  - Swarm: single [builder]
  - Paths: plugins/apex-scope-loop/skills/apex-plan/scripts/status.sh, plugins/apex-scope-loop/scripts/smoke.sh
  - Blocked-by: phase-2.1

- [x] **Gate 2→3** [gate:auto] Ideation green
  - Acceptance: `bash plugins/apex-scope-loop/scripts/smoke.sh`
  - Blocked-by: phase-2.2

---

### Phase 3 — Operation (post-land, per-plan monitoring)

Per the ADR amendment of 2026-10-18 (R5–R5d): each plan declares its own monitor checks and watch window; one shared runner; signals carry their plan slug; windows close.

- [x] **Phase 3.1** [security][tier:c] Add ledger events `operate_deploy`, `operate_signal` and `operate_window_closed` (non-provenance, CLI-appendable) and protect `APEX_OPERATE_ACK`, `APEX_DEPLOY_CMD` and `APEX_MONITOR_CMD` in `pre-bash.sh`
  - Acceptance: `bash plugins/apex-dispatch/scripts/smoke.sh && bash plugins/apex-dispatch/scripts/compile.sh --check && grep -q 'operate_window_closed' plugins/apex-dispatch/resources/ledger-events.json && grep -q 'APEX_OPERATE_ACK' plugins/apex-dispatch/scripts/lib/hooks.py && grep -q 'operate-ledger-events' plugins/apex-dispatch/scripts/smoke.sh` (smoke check `operate-ledger-events`: each of the three events appends and `verify` passes; an operate event missing a required field, or an `operate_signal` without `slug` or `repo`, is refused; `pre-bash.sh` denies `export APEX_OPERATE_ACK=…` under the ACTIVE lock)
  - Swarm: hierarchical 4 [builder, tester, reviewer, adversarial-reviewer]
  - Paths: plugins/apex-dispatch/resources/ledger-events.json, plugins/apex-dispatch/scripts/lib/ledger.py, plugins/apex-dispatch/scripts/lib/hooks.py, plugins/apex-dispatch/scripts/smoke.sh, plugins/apex-dispatch/docs/adrs/0001-apex-dispatch-contract.md
  - Blocked-by: gate-2-3

- [x] **Phase 3.2** [backend] Define the plan `## Monitor` section: a shared validator (`monitorlib.py validate PLAN` and `validate-file FILE` for the repo-level `monitor.json`), `promote-to-loop.sh` validation when the section is present, a `{"window_days": 14, "checks": []}` stub in every plan template (lean and full, both profiles), and the PLAN-stage instruction in apex-plan SKILL.md to draft checks from the success criteria
  - Acceptance: `bash plugins/apex-scope-loop/scripts/smoke.sh && grep -q 'monitor-section' plugins/apex-scope-loop/scripts/smoke.sh && grep -q '## Monitor' plugins/apex-scope-loop/skills/apex-plan/resources/templates/profiles/generic/plan-template.md && grep -q '## Monitor' plugins/apex-scope-loop/skills/apex-plan/resources/templates/profiles/apex/plan-template.md && grep -q 'Monitor' plugins/apex-scope-loop/skills/apex-plan/SKILL.md` (smoke check `monitor-section`: a valid section passes; each of a missing `id`, an unknown `op`, an unknown `probe.kind`, `window_days` 0 or 91, an `http` probe with headers or a non-GET method, a duplicate check id, and two json blocks is refused with the problem named; a plan without the section and a plan with `checks: []` both promote; every existing plan in `.claude/plans/` still validates and promotes)
  - Threats: 1) an invalid section silently treated as "not watched"; 2) the section's fenced block breaking planlib's task grammar
  - Swarm: hierarchical 3 [builder, tester, reviewer]
  - Paths: plugins/apex-scope-loop/skills/apex-execute/scripts/monitorlib.py, plugins/apex-scope-loop/skills/apex-plan/scripts/promote-to-loop.sh, plugins/apex-scope-loop/skills/apex-plan/resources/templates/**, plugins/apex-scope-loop/skills/apex-plan/SKILL.md, plugins/apex-scope-loop/scripts/smoke.sh
  - Blocked-by: phase-3.1

- [x] **Phase 3.3** [backend][tier:c] Implement `operate.sh PLAN deploy|status` and `operate.sh --all status`: the deploy refused to agents by apex-dispatch's pre-bash at every stage (lock or not, wrappers included) and acked at the controlling terminal, bound to `{slug}@{landed sha}`, deploy history, and the watch window opened on a successful deploy
  - Acceptance: `bash plugins/apex-scope-loop/scripts/smoke.sh && grep -q 'operate-deploy' plugins/apex-scope-loop/scripts/smoke.sh && bash plugins/apex-dispatch/scripts/smoke.sh && bash plugins/apex-dispatch/scripts/compile.sh --check && grep -q 'operate-deploy-deny' plugins/apex-dispatch/scripts/smoke.sh` (smoke check `operate-deploy` in a temp repo: an unlanded plan → exit 3; `APEX_DEPLOY_CMD` unset → exit 2 naming it; HALT → exit 4; landed + stub deploy + correct ack → deploy recorded with ts, sha and exit, window opened for the plan's `window_days`; a wrong-sha or wrong-slug ack → refused; no controlling terminal → refused with a named reason even when `APEX_OPERATE_ACK` holds the correct `{slug}@{sha}`; the ack is read from a pseudo-terminal driven by `script`, with no env var or file test seam; a failing deploy command → recorded, exit 1, no window opened; `status` and `--all status` show the window as day N of M; an `operate_deploy` ledger row is written when the dispatch dir exists; the no-terminal case runs fully detached (setsid) so it cannot read the operator's terminal; the refusal says a human must type `{slug}@{sha}` at their terminal; each `operate_deploy` row records its ack source. Dispatch smoke check `operate-deploy-deny`: pre-bash denies `operate.sh … deploy` with no ACTIVE lock, with a DONE or landed owner and under a live lock, also when wrapped in `script`, `expect`, `unbuffer`, `python -c` pty, `bash -c`, `env` or `sudo`; it allows `operate.sh … status` and plain mentions)
  - Threats: 1) an ack for one landed sha accepted for another; 2) a failed deploy opening a watch window; 3) an agent acking its own deploy after land: a terminal ack alone is agent-satisfiable (a self-made pty), so the control is the pre-bash deny of `operate.sh … deploy` at every stage; the residual (an agent writing a script file that calls it) is deliberate circumvention, out of the threat model, and is stated in the ADRs
  - Swarm: hierarchical 4 [builder, tester, reviewer, adversarial-reviewer]
  - Paths: plugins/apex-scope-loop/skills/apex-execute/scripts/operate.sh, plugins/apex-scope-loop/skills/apex-execute/scripts/_lib.sh, plugins/apex-scope-loop/scripts/smoke.sh, plugins/apex-dispatch/scripts/lib/hook-common.bash, plugins/apex-dispatch/scripts/lib/hooks.py, plugins/apex-dispatch/scripts/smoke.sh, plugins/apex-dispatch/docs/adrs/0001-apex-dispatch-contract.md
  - Blocked-by: phase-3.2

- [x] **Phase 3.4** [backend][tier:c] Implement `operate.sh PLAN monitor|ingest` and `--all monitor [--ingest]`: `http`, `cmd` and `runner` probes; signals carrying their slug or `repo`; first breach filed once (lessons for high, backlog otherwise) and repeats counted; repo-level `monitor.json` filed only under `operate:repo`; window close with `operated-clean` / `closed-with-breaches` and `open-at-close`; `backlog.sh --from operate` with plan-level line 0
  - Acceptance: `bash plugins/apex-scope-loop/scripts/smoke.sh && grep -q 'operate-loop' plugins/apex-scope-loop/scripts/smoke.sh` (smoke check `operate-loop`: a landed fixture plan declares one `http` check against a stub server on 127.0.0.1, one `cmd` check and one `runner` check; `--all monitor --ingest` run twice files the high breach once as a lesson tagged `operate:{slug},{metric}` and only counts the repeat; the low breach goes to the backlog; a probe that times out is `unmeasured`, never a pass; a malformed runner reply fails closed; every signal row carries the plan slug; a repo-level breach lands only in the backlog under `operate:repo`; a second landed plan's breach is credited to that plan; after the window is moved past its end the plan closes as `closed-with-breaches` with `open-at-close` listed, an `operate_window_closed` row is written and the plan is no longer measured; a plan with no Monitor section is skipped and `status` warns for a landed feature plan; `ledger.sh verify` exits 0)
  - Threats: 1) a signal credited to the wrong plan; 2) a failed probe read as healthy or as 0; 3) runner or `note` text written unescaped into LESSONS.md headings; 4) an expired window still measured, or one with a live breach expiring silently
  - Swarm: hierarchical 4 [builder, tester, reviewer, adversarial-reviewer]
  - Paths: plugins/apex-scope-loop/skills/apex-execute/scripts/operate.sh, plugins/apex-scope-loop/skills/apex-execute/scripts/monitorlib.py, plugins/apex-scope-loop/skills/apex-execute/scripts/backlog.sh, plugins/apex-scope-loop/skills/apex-execute/scripts/_lib.sh, plugins/apex-scope-loop/scripts/smoke.sh
  - Blocked-by: phase-3.3

- [x] **Phase 3.5** [docs] Add `/apex-scope-loop:operate`, document operate and the Monitor section (with metric-naming and tagging conventions, and the daily `/schedule` of `--all monitor --ingest`) in apex-execute SKILL.md, and claim `apex-scope-loop:operate/{slug}` in ADR-0001; bring the plan templates' Monitor guidance in line with the Phase 3.4 contract (cmd `value: stdout|exit`, `latency_ms` needs `expect_status`, runner `{value, note}`)
  - Acceptance: `bash plugins/apex-scope-loop/scripts/smoke.sh && grep -q '^name: operate' plugins/apex-scope-loop/commands/operate.md && grep -q '^description:' plugins/apex-scope-loop/commands/operate.md && grep -q 'apex-scope-loop:operate/' plugins/apex-scope-loop/docs/adrs/0001-apex-scope-loop-contract.md && grep -q 'operate.sh' plugins/apex-scope-loop/skills/apex-execute/SKILL.md && grep -q 'window_days' plugins/apex-scope-loop/skills/apex-execute/SKILL.md && grep -q -- '--all monitor' plugins/apex-scope-loop/skills/apex-execute/SKILL.md`
  - Swarm: single [docs]
  - Paths: plugins/apex-scope-loop/commands/operate.md, plugins/apex-scope-loop/skills/apex-execute/SKILL.md, plugins/apex-scope-loop/docs/adrs/0001-apex-scope-loop-contract.md, plugins/apex-scope-loop/skills/apex-plan/resources/templates/profiles/generic/plan-template.md, plugins/apex-scope-loop/skills/apex-plan/resources/templates/profiles/generic/plan-template-lean.md, plugins/apex-scope-loop/skills/apex-plan/resources/templates/profiles/apex/plan-template.md, plugins/apex-scope-loop/skills/apex-plan/resources/templates/profiles/apex/plan-template-lean.md
  - Blocked-by: phase-3.4

- [x] **Gate 3→4** [gate:auto] Operation green in both plugins
  - Acceptance: `bash plugins/apex-scope-loop/scripts/smoke.sh && bash plugins/apex-dispatch/scripts/smoke.sh && bash plugins/apex-dispatch/scripts/compile.sh --check`
  - Blocked-by: phase-3.5

---

### Phase 4 — Per-task cost and console UI

- [x] **Phase 4.1** [backend] Add `report.sh --per-task` (delegated USD, tokens, spawns, review rounds, outcome) from `tasks_of()`
  - Acceptance: `bash plugins/apex-dispatch/scripts/smoke.sh && grep -q 'per-task-listing' plugins/apex-dispatch/scripts/smoke.sh` (smoke check `per-task-listing`: on a fixture ledger, `report.sh --per-task --json` has one `tasks[]` entry per routed task and the per-task USD values sum to `usd_estimated`; text mode prints one `REPORT_TASK` line per task)
  - Swarm: hierarchical 3 [builder, tester, reviewer]
  - Paths: plugins/apex-dispatch/scripts/report.sh, plugins/apex-dispatch/scripts/lib/report.py, plugins/apex-dispatch/scripts/smoke.sh, plugins/apex-dispatch/scripts/fixtures/**
  - Blocked-by: gate-3-4

- [ ] **Phase 4.2** [backend] Attribute orchestrator (main-session) tokens and USD per task from session transcripts (`--transcript PATH`, auto-locate otherwise; `unattributed` bucket; `n/a` without a transcript)
  - Acceptance: `bash plugins/apex-dispatch/scripts/smoke.sh && grep -q 'orchestrator-cost' plugins/apex-dispatch/scripts/smoke.sh` (smoke check `orchestrator-cost`: fixture ledger with two task windows plus fixture transcript with three assistant turns (one in each window, one outside) and one unknown line → per-task orchestrator tokens match, `unattributed` holds the third, the unknown line is counted as skipped; without `--transcript` and no auto-located file, orchestrator is `n/a`, not 0)
  - Threats: 1) a missing transcript reported as $0; 2) a turn counted in two tasks
  - Swarm: hierarchical 3 [builder, tester, reviewer]
  - Paths: plugins/apex-dispatch/scripts/report.sh, plugins/apex-dispatch/scripts/lib/report.py, plugins/apex-dispatch/scripts/smoke.sh, plugins/apex-dispatch/scripts/fixtures/**
  - Blocked-by: phase-4.1

- [ ] **Phase 4.3** [backend] apex-console collects scope, intent, operate state (deploys, watch window, per-check latest value, breach counts, unmeasured, outcome, open-at-close, repo-level checks) and per-task cost (delegated / orchestrator / unattributed via report.py) into the plans API; update `docs/api.md`
  - Acceptance: `bash plugins/apex-console/scripts/smoke.sh && grep -q '"scope"' plugins/apex-console/docs/api.md && grep -q '"operate"' plugins/apex-console/docs/api.md && grep -q 'orchestrator_usd' plugins/apex-console/docs/api.md && grep -q 'console-plans-payload' plugins/apex-console/scripts/smoke.sh` (smoke check `console-plans-payload`: on the per-task fixture, each task's `usd` equals `report.sh --per-task` delegated USD, `orchestrator_usd` matches or is null for `n/a`, a landed fixture plan carries its `operate` block with `window` and `checks`, the payload lists watched plans and repo checks, and a scope-less plan reports scope `feature`)
  - Swarm: hierarchical 3 [builder, tester, reviewer]
  - Paths: plugins/apex-console/scripts/lib/ac_collect.py, plugins/apex-console/scripts/lib/ac_server.py, plugins/apex-console/docs/api.md, plugins/apex-console/scripts/smoke.sh
  - Blocked-by: phase-4.2

- [ ] **Phase 4.4** [frontend] Console UI (read-only): scope badge and scope filter in the plans view, intent summary, an Operate panel per landed plan (deploy history, watch window day N of M or its outcome, each check's latest value / threshold / breach count, `unmeasured` and `open-at-close` flags, ingested lessons/backlog), a Watched plans view (open windows plus repo-level checks), and a per-task cost table with delegated / orchestrator / unattributed columns
  - Acceptance: `bash plugins/apex-console/scripts/smoke.sh && grep -q 'console-ui-borrowings' plugins/apex-console/scripts/smoke.sh && ! grep -qiE "fetch\([^)]*operate[^)]*(deploy|monitor|ingest)" plugins/apex-console/ui/app.js` (smoke check `console-ui-borrowings`: the served page's app.js renders, from `demo.json`, a scope badge for each plan, a scope filter with bugfix/poc/feature, an Operate panel only for landed plans, a Watched plans view listing open windows and repo checks, `unmeasured` rendered as such (never as a value), a cost table whose orchestrator cell shows `n/a` when null, and aria labels on the new badge, filter and table; the UI calls no operate action endpoint)
  - Threats: 1) `n/a` orchestrator cost rendered as $0.00; 2) monitor `note` text rendered as HTML instead of text
  - Swarm: hierarchical 4 [builder, tester, reviewer, docs]
  - Paths: plugins/apex-console/ui/app.js, plugins/apex-console/ui/app.css, plugins/apex-console/ui/index.html, plugins/apex-console/scripts/smoke.sh
  - Blocked-by: phase-4.3

- [ ] **Phase 4.5** [frontend][docs] Update `ui/demo.json` and the demo-mode mock so demo mode shows every new view; document the new panels in the console README
  - Acceptance: `bash plugins/apex-console/scripts/smoke.sh && python3 -c "import json;d=json.load(open('plugins/apex-console/ui/demo.json'));s=json.dumps(d);assert all(k in s for k in ('\"scope\"','\"operate\"','orchestrator_usd'))" && grep -qi 'operate' plugins/apex-console/README.md`
  - Swarm: single [docs]
  - Paths: plugins/apex-console/ui/demo.json, plugins/apex-console/ui/app.js, plugins/apex-console/README.md
  - Blocked-by: phase-4.4

- [ ] **Gate 4→5** [gate:auto] Cost reporting and console UI green
  - Acceptance: `bash plugins/apex-dispatch/scripts/smoke.sh && bash plugins/apex-console/scripts/smoke.sh`
  - Blocked-by: phase-4.5

---

### Phase 5 — Release

- [ ] **Phase 5.1** [docs] Update READMEs, ADR-0001 status logs, and bump versions (apex-scope-loop 0.7.0, apex-dispatch 0.7.0, apex-console 0.3.0) with descriptions consistent across marketplace.json, plugin.json and README
  - Acceptance: `grep -q '"version": "0.7.0"' plugins/apex-scope-loop/.claude-plugin/plugin.json && grep -q '"version": "0.7.0"' plugins/apex-dispatch/.claude-plugin/plugin.json && grep -q '"version": "0.3.0"' plugins/apex-console/.claude-plugin/plugin.json && grep -q 'operate' plugins/apex-scope-loop/README.md && grep -q -- '--per-task' plugins/apex-dispatch/README.md && grep -q '0.7.0' plugins/apex-scope-loop/docs/adrs/0001-apex-scope-loop-contract.md && grep -q '0.7.0' plugins/apex-dispatch/docs/adrs/0001-apex-dispatch-contract.md && grep -q '0.3.0' plugins/apex-console/docs/adrs/0001-apex-console-contract.md && for p in apex-scope-loop apex-dispatch apex-console; do bash plugins/$p/scripts/smoke.sh || exit 1; done`
  - Swarm: single [docs]
  - Paths: plugins/apex-scope-loop/README.md, plugins/apex-dispatch/README.md, plugins/apex-console/README.md, plugins/*/.claude-plugin/plugin.json, plugins/*/docs/adrs/0001-*.md, .claude-plugin/marketplace.json, README.md
  - Blocked-by: gate-4-5

- [ ] **Phase 5.2** [docs] Flip the ADR to `Implemented`
  - Acceptance: `grep -q '^\*\*Status\*\*: Implemented' .claude/tasks/aidlc-borrowings-adr.md`
  - Swarm: single [docs]
  - Paths: .claude/tasks/aidlc-borrowings-adr.md
  - Blocked-by: phase-5.1

- [ ] **Gate 5→done** [gate:auto] The three touched suites green and the existing plans still validate
  - Acceptance: `bash plugins/apex-scope-loop/scripts/smoke.sh && bash plugins/apex-dispatch/scripts/smoke.sh && bash plugins/apex-console/scripts/smoke.sh && python3 plugins/apex-scope-loop/skills/apex-execute/scripts/planlib.py validate .claude/plans/apex-dispatch-plan.md && python3 plugins/apex-scope-loop/skills/apex-execute/scripts/planlib.py validate .claude/plans/novel-plugins-suite-plan.md`
  - Blocked-by: phase-5.2

---

## Out-of-scope

- AI-DLC's nine scopes and silent auto-detection of scope from the request
- Renaming SCOPE or adding a sixth authoring stage
- Any new hook, in any plugin
- Holding, rotating or reading deploy credentials; built-in deploy integrations (users supply `APEX_DEPLOY_CMD`); probes beyond `http` GET, `cmd` and the user's runner; automatic rollback
- Cross-vendor routing changes, codex mirror changes, decision-layer rubric changes
- apex-decision-layer's failing smoke check (commit-hygiene shadow script), and every plugin not listed above
- Console actions for operate: the console stays read-only for deploy, monitor and ingest
- Billing-grade cost: report.sh prices with the policy tier table, as today

## Open questions (escalations)

> If anything during execution requires a human decision, write it here with an `@OWNER` tag so the
> nightly audit (`apex-execute/scripts/audit.sh`) surfaces it.

- (none yet)

---

## Continuity layer suggestions

```bash
# Nightly progress audit
/schedule "0 2 * * *" ${CLAUDE_PLUGIN_ROOT}/skills/apex-execute/scripts/audit.sh .claude/plans/aidlc-borrowings-plan.md

# Weekly architecture drift review
/schedule "0 9 * * 1" ${CLAUDE_PLUGIN_ROOT}/skills/apex-execute/scripts/architecture-review.sh .claude/plans/aidlc-borrowings-plan.md
```

## Status checks

```bash
${CLAUDE_PLUGIN_ROOT}/skills/apex-plan/scripts/status.sh aidlc-borrowings
${CLAUDE_PLUGIN_ROOT}/skills/apex-plan/scripts/gate.sh .claude/plans/aidlc-borrowings-plan.md gate-3-4
```
