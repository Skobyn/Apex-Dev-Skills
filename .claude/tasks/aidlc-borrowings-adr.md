# ADR-0002: Borrow from AI-DLC: scope sizing, ideation, operation phase, per-task cost

**Status**: Accepted
**Date**: 2026-10-14
**Slug**: `aidlc-borrowings`
**Author**: skobyn@gmail.com
**Reviewer**: skobyn@gmail.com (solo)
**Implementor**: skobyn@gmail.com, through the apex-scope-loop `/loop` with apex-dispatch routing
**Companion Plan**: [`.claude/plans/aidlc-borrowings-plan.md`](../plans/aidlc-borrowings-plan.md)

> Status transitions: `Proposed` → `Accepted` → `Implemented` → (optional) `Superseded by ADR-MMMM`.
> `promote-to-loop.sh` refuses to run until status is `Accepted`.

---

## TL;DR

- **Scope sizing.** A plan declares `Scope: bugfix | poc | feature`. A smaller scope means fewer authoring rounds, a lean template and fewer phases. `feature` behaves exactly as today. Execution enforcement (green gate, independent review, risk tier, G12, ledger evidence) is the same for every scope.
- **Ideation.** A short intent step ("what are we doing and why") is written to `.claude/tasks/<slug>-intent.md` before the SCOPE interview, and `start.sh` seeds it into the ADR's "Why this matters". The SCOPE name stays.
- **Operation.** A new `operate.sh` (with `/apex-scope-loop:operate`) runs after `land.sh`. Deploy calls a user-configured command and always needs a human ack. Monitor and ingest are automatic: production signals become `LESSONS.md` / `BACKLOG.md` entries.
- **Per-task cost.** apex-console already shows USD per task. `report.sh` gets a `--per-task` listing that reuses the existing `tasks_of()`, so the CLI matches the console.
- Every touched plugin keeps its smoke suite green, gains checks for the new behaviour, bumps its version and logs the change in its ADR-0001.

---

## Context (SPARC: Specification)

### Why this matters

A comparison with AWS AI-DLC v2 (core concepts page, v2.3.0) found four gaps in the apex harness:

1. **Every task pays the full authoring cost.** A one-line bugfix goes through the same six SCOPE rounds, the full SPARC ADR and five SPARC phases as a multi-plugin feature. AI-DLC picks one of nine scopes from the request (bugfix 7 stages … feature 32). The result here is either skipped planning or ceremony people resent.
2. **Nothing after `land.sh`.** AI-DLC has an Operation phase (deploy, monitor, close the loop). Ours ends at the merge to main. Production evidence never reaches `LESSONS.md` (the ratchet) or `BACKLOG.md`, so the loop learns only from its own gate failures.
3. **"Why" and "what" are mixed.** AI-DLC separates Ideation (intent, scope) from Inception (requirements, design). Our Scope round asks scope, constraints and success criteria together, so the motivation behind a plan is never written down separately and gets lost in the ADR.
4. **Cost per task lives only in the console.** `/aidlc-replay` and `session-cost` are read-only cost views. apex-console shows `usd` per plan task, but `report.sh` computes per-task USD only inside `--compare`, so a terminal user can't list cost per task.

### Requirements

| ID | Priority | Requirement |
|----|----------|-------------|
| R1 | MUST | `start.sh <slug> "<Title>" --scope bugfix\|poc\|feature` writes a `**Scope**:` line into the ADR and a `> **Scope**:` plan header, using a template matched to the scope. No `--scope` means `feature`. |
| R2 | MUST | `promote-to-loop.sh` applies per-scope validation: `bugfix` allows ≤ 2 phases and doesn't require the Pseudocode/Architecture/Data Model/API sections; `poc` allows ≤ 3 phases; `feature` keeps today's rules. A plan or ADR with no Scope line validates exactly as today. |
| R3 | MUST | The apex-plan SKILL.md and `/apex-scope-loop:start` say how many interview rounds each scope runs: bugfix 2 (scope+done, gate), poc 4, feature 6. |
| R4 | MUST | An Intent step writes `.claude/tasks/<slug>-intent.md` (problem, who it's for, why now, non-goals), and `start.sh` seeds its "Problem" text into the ADR's "Why this matters". It is optional for `bugfix`. |
| R5 | MUST | `operate.sh PLAN deploy\|monitor\|ingest\|status` runs only on a landed plan. Deploy runs `$APEX_DEPLOY_CMD` after a human ack (Ask Contract) and never stores credentials. Monitor runs `$APEX_MONITOR_CMD`, which prints JSON signals. Ingest writes each signal at or over threshold to `lessons.sh` / `backlog.sh` tagged `operate:<slug>`. Each step is recorded in checkpoint.json. |
| R6 | MUST | `operate.sh` refuses (non-zero exit, named reason) when the plan isn't landed, the relevant command is unset, or a kill switch is set. |
| R7 | MUST | `report.sh --per-task` prints one `REPORT_TASK` line per routed task (task, class, tier, spawns, tokens, USD, review rounds, outcome), or a `tasks` array with `--json`. The totals match the existing aggregate USD. |
| R7b | MUST | `report.sh --per-task` adds orchestrator (main-session) tokens and USD per task from the session transcript, plus an `unattributed` bucket, reading transcripts only (Q5). Without a transcript the column is `n/a`, never 0. |
| R8 | SHOULD | apex-dispatch's ledger gains non-provenance events `operate_deploy` and `operate_signal`, which `operate.sh` appends through `ledger.sh append` when the plan's dispatch dir exists (decided in Q2). |
| R9 | MUST | apex-console UI adapts to every change, **read-only**: (a) a Scope badge on each plan and a scope filter in the plans view; (b) an intent link/summary when `<slug>-intent.md` exists; (c) an Operate panel per landed plan: deploy history (ts, sha, exit), last monitor run, signals with threshold/severity, and the lessons/backlog entries ingested under `operate:<slug>`; (d) a per-task cost table with delegated, orchestrator and unattributed USD and tokens, `n/a` shown as such. The console never runs deploy, monitor or ingest. The plans API, `docs/api.md`, `ui/demo.json` and the demo mock in `app.js` change in step, and the UI meets the console's existing accessibility conventions (aria labels, keyboard focus). |
| R10 | MAY | `status.sh` (apex-plan) prints the Scope and whether an intent file exists. |

### Constraints

- **Plan dialect stays compatible.** `.claude/plans/apex-dispatch-plan.md` and `novel-plugins-suite-plan.md` (and any plan without a Scope line) must still pass `planlib.py validate`, iterate, promote and land unchanged. planlib ignores header lines, and that must stay true.
- **Enforcement is never loosened.** Scope affects authoring only: interview rounds, required ADR sections, phase-count limit. The green gate, independent review, risk tier/G12, the ratchet, kill switches and ledger evidence apply the same way to bugfix, poc and feature.
- **No deploy credentials.** `operate.sh` never holds, reads or logs deploy secrets. It calls a user-configured command whose environment the user owns. A deploy always needs a human ack, and neither an agent nor a knob can turn that off.
- **Smoke + version bump.** Every touched plugin keeps `scripts/smoke.sh` at exit 0, adds checks for the new behaviour, bumps `plugin.json` (minor: new behaviour) and adds an ADR-0001 status-log entry. `marketplace.json`, `plugin.json` and the README descriptions stay consistent.
- **No new hook.** Operation runs as a script plus a slash command. Hooks keep the repo's parallel, deny-first rules, and `hooks/hooks.json` stays untouched except by apex-dispatch's `compile.sh`.
- **Namespaces.** Any new memory key (`apex-scope-loop:operate/<slug>`) is claimed in apex-scope-loop's ADR-0001 namespace table before use.

### Success criteria

- All three smoke suites pass — runnable: `bash plugins/apex-scope-loop/scripts/smoke.sh && bash plugins/apex-dispatch/scripts/smoke.sh && bash plugins/apex-console/scripts/smoke.sh`
- A bugfix plan authors small and promotes, and a scope-less plan promotes as before — runnable: new smoke checks build a fixture `--scope bugfix` plan with ≤ 2 phases in a temp repo, run `promote-to-loop.sh` on it (exit 0), run it on a 3-phase bugfix plan (exit 1, names the phase limit), and promote a scope-less fixture unchanged
- Existing plans still validate — runnable: `python3 plugins/apex-scope-loop/skills/apex-execute/scripts/planlib.py validate .claude/plans/apex-dispatch-plan.md && … novel-plugins-suite-plan.md`
- The operate loop works on stubs — runnable: a smoke fixture lands a plan, runs `operate.sh deploy` with a stub `APEX_DEPLOY_CMD` and a pre-supplied ack, `monitor` with a stub `APEX_MONITOR_CMD` emitting one over-threshold signal, then `ingest`. It asserts a `LESSONS.md` or `BACKLOG.md` entry tagged `operate:<slug>`, an `operate_signal` ledger row, and `ledger.sh verify` exit 0. With `APEX_DEPLOY_CMD` unset it asserts exit ≠ 0 and the reason.
- Orchestrator cost is attributed — runnable: a smoke check runs `report.sh --per-task --json --transcript <fixture.jsonl>` on a fixture ledger with two task windows and three assistant turns (one per window, one outside), and asserts the per-task orchestrator tokens, the `unattributed` bucket, and `n/a` without `--transcript`
- Per-task cost matches — runnable: a smoke check runs `report.sh --per-task --json` on a fixture ledger and asserts the per-task USD values sum to the aggregate `usd_estimated`, and to the console's plan `usd` for the same fixture

---

## Decision

### Pseudocode (SPARC)

```
ALGORITHM author_plan(slug, title, scope=feature):
  PRECONDITIONS: scope ∈ {bugfix, poc, feature}
  STEPS:
    0. IF scope != bugfix OR user asks THEN run Intent round → write <slug>-intent.md
    1. rounds = {bugfix: [scope+done, gate], poc: [scope, constraints, done, gate],
                 feature: [scope, constraints, done, ownership, swarm, gate]}[scope]
       ask each round with AskUserQuestion
    2. start.sh --scope scope → ADR + plan from template(profile, scope), seed intent + answers
    3. OPTIMIZE: resolve every open question to a Decision (bugfix ADR has fewer sections, same rule)
    4. promote-to-loop.sh:
         limits = {bugfix: phases≤2, poc: phases≤3, feature: today's rules}
         required_sections = full set minus scope's exemptions
         fail with the first failing item, else init.sh
  OUTPUT: promoted plan; execution identical for every scope

ALGORITHM operate(plan, step):
  PRECONDITIONS: checkpoint.landed == true; no HALT; step's command env var set
  deploy:  print Ask Contract → require ack (APEX_OPERATE_ACK=<slug>@<landed sha> or interactive)
           run $APEX_DEPLOY_CMD with PLAN_SLUG, LANDED_SHA in env; record exit + ts
  monitor: run $APEX_MONITOR_CMD → JSON [{id, metric, value, threshold, severity, note}]
           validate shape (fail closed on bad JSON); store signals in state
  ingest:  FOR each signal with value ≥ threshold:
             severity=high → lessons.sh PLAN add TITLE WHAT ROOT_CAUSE FIX "operate:<slug>,<metric>"
             else          → backlog.sh PLAN add 0 "[operate:<slug>] <metric> …" --from operate
                             (line 0 = plan-level finding; backlog.sh gains --from operate)
             IF dispatch dir exists THEN ledger.sh append operate_signal
  status:  print last deploy, last monitor, ingested counts
  ERROR PATHS: not landed → exit 3; env unset → exit 2 naming the var;
               HALT → exit 4; deploy cmd non-zero → recorded, exit 1, no ingest
```

### Architecture (SPARC)

```
  intent round ─► <slug>-intent.md ─┐
                                    ▼
  SCOPE rounds (n by scope) ─► start.sh --scope ─► ADR + plan (lean|full template)
                                                       │
                                     promote-to-loop.sh (per-scope limits)
                                                       ▼
                     init → iterate → gate → tier → review → complete → land.sh   (unchanged)
                                                                            │ landed: true
                                                                            ▼
                      operate.sh deploy ─(human ack)─► $APEX_DEPLOY_CMD
                      operate.sh monitor ───────────► $APEX_MONITOR_CMD → signals.json
                      operate.sh ingest ──► lessons.sh / backlog.sh  (+ ledger operate_signal)
                                                                            │
                                     next plan's iterate recalls lessons by tag ◄┘

  session transcript(s) ─► report.py turn usage ─┐ (by route window)
  ledger.jsonl ─► report.py tasks_of() ─────────┴─► report.sh --per-task  (CLI)
                                    └──► ac_metrics / ac_collect    (console, existing)
```

**Modules**:

| Module | Responsibility | Depends on |
|--------|----------------|------------|
| `apex-plan/scripts/start.sh` | `--scope` flag, template pick, intent seeding | templates, intent file |
| `apex-plan/resources/templates/profiles/{generic,apex}/plan-template-lean.md`, `adr-template-lean.md` | Lean bugfix/poc shapes | — |
| `apex-plan/resources/templates/profiles/*/feedback-interview.md` | Intent round + per-scope round sets | — |
| `apex-plan/scripts/promote-to-loop.sh` | Per-scope validation | planlib.py counts |
| `apex-plan/SKILL.md`, `commands/start.md` | Instructions for round count by scope, intent step | — |
| `apex-execute/scripts/operate.sh` (new) | deploy / monitor / ingest / status | _lib.sh, lessons.sh, backlog.sh, ledger.sh (optional) |
| `commands/operate.md` (new) | `/apex-scope-loop:operate <plan> <step>` | operate.sh |
| `apex-dispatch/resources/ledger-events.json` | `operate_deploy`, `operate_signal` events | ledger.py |
| `apex-dispatch/scripts/report.sh`, `lib/report.py` | `--per-task` listing; transcript turn attribution | `tasks_of()`, `row_usd` prices |
| `apex-console/scripts/lib/ac_collect.py` | Collect scope, intent, operate state, per-task cost (calls report.py) | checkpoint.json, intent file, report.py |
| `apex-console/ui/app.js`, `app.css`, `demo.json` | Scope badge/filter, intent summary, Operate panel, per-task cost table; demo mode parity | plans API |

**Bounded contexts touched**: `plugins/apex-scope-loop` (apex-plan and apex-execute skills, commands), `plugins/apex-dispatch` (ledger events, report), `plugins/apex-console` (collect + UI).

### Data Model

```
ADR header:   **Scope**: bugfix|poc|feature            (absent ⇒ feature)
Plan header:  > **Scope**: bugfix|poc|feature          (planlib ignores; promote reads)
.claude/tasks/<slug>-intent.md:  ## Problem / ## Who it's for / ## Why now / ## Non-goals
<state>/checkpoint.json  += "operate": {"deploys":[{ts, sha, exit}], "monitor":{ts, signals_n},
                                        "ingested":{lessons:n, backlog:n}}
<state>/operate/signals-<ts>.json   validated monitor output
ledger events (non-provenance, CLI-appendable):
  operate_deploy {slug, landed_sha, exit_code}
  operate_signal {slug, signal_id, metric, value, threshold, severity, sink: lessons|backlog}
memory namespace: apex-scope-loop:operate/<slug>   (claimed in ADR-0001)
```

### API Surface

| Verb | Path | Purpose | Auth |
|------|------|---------|------|
| CLI | `start.sh <slug> "<T>" [--scope S]` | Scaffold scoped ADR + plan | local user |
| CLI | `operate.sh PLAN deploy\|monitor\|ingest\|status` | Post-land operation | local user; deploy needs ack |
| Slash | `/apex-scope-loop:operate <plan> <step>` | Same, from Claude Code | session |
| CLI | `report.sh --plan P --per-task [--transcript PATH]… [--json]` | Cost per task, delegated + orchestrator | local user |
| Env | `APEX_DEPLOY_CMD`, `APEX_MONITOR_CMD`, `APEX_OPERATE_ACK` | User-owned commands, non-interactive ack | user env; `APEX_OPERATE_ACK` added to pre-bash.sh's protected switches |
| HTTP | apex-console `/api/…` plans payload `scope`, `operate` fields | Display | 127.0.0.1 only (existing) |

---

## What changes / What stays

| Area | Today | After this decision |
|------|-------|---------------------|
| Authoring cost | 6 rounds + full SPARC ADR + 5 phases for everything | 2 / 4 / 6 rounds and lean/full templates by scope |
| Intent | Mixed into round 1 | Own file, seeded into the ADR |
| After land | Nothing | `operate.sh` deploy → monitor → ingest into the ratchet/backlog |
| Cost per task in CLI | Only in `--compare` aggregates; orchestrator tokens nowhere | `report.sh --per-task` with delegated + orchestrator USD |
| Console | Per-task USD | + Scope, + operate status |

**Stays untouched**:

- The execution chain: `init → iterate → green-gate → risk-tier → review → checkpoint → land`, and every knob default
- planlib.py's task grammar, and every existing plan in `.claude/plans/`
- Hook registration in every plugin (no new hook)
- The ledger's provenance events and hash chain

### Surface Matrix

| Surface | Affected? | Notes |
|---------|-----------|-------|
| Slash commands | yes | `/apex-scope-loop:start` text (scope, intent); new `/apex-scope-loop:operate` |
| Skill instructions (SKILL.md) | yes | apex-plan stages; apex-execute mentions operate |
| Skill scripts | yes | start.sh, promote-to-loop.sh, status.sh, new operate.sh; report.sh/report.py |
| Templates (generic **and** apex profiles) | yes | Both profiles get the lean templates and the intent round, in parity |
| apex-console UI + API | yes | Read-only: scope badge + filter, intent summary, Operate panel, per-task cost table (delegated / orchestrator / unattributed). API payload, `docs/api.md`, `ui/demo.json` and demo mock updated together. No action buttons for operate. |
| Plugin READMEs / ADR-0001 / plugin.json / marketplace.json | yes | Description trio kept consistent; required README sections kept |
| Smoke suites | yes | New checks in all three; Phase 0 first fixes the two macOS baseline failures (apex-scope-loop `.GIT` check on case-insensitive APFS; apex-dispatch ad-hoc state path under `/private/var`) |
| Hooks | no | N/A — no new hook by constraint |
| Codex mirror (`compile.sh --target codex`) | no | N/A — no policy/role change; `--check` must stay green |

### Tenant / Environment Impact

N/A — applies to every repo that installs these plugins, with no per-repo divergence. Operate does nothing until a repo sets `APEX_DEPLOY_CMD` / `APEX_MONITOR_CMD`.

---

## Operator workflows

### Workflow A: Fix a bug with a small plan

1. `/apex-scope-loop:start fix-x --scope bugfix`: two rounds (scope+done, gate), lean ADR (Context, Decision, Risks), plan with ≤ 2 phases.
2. OPTIMIZE resolves any open questions, then Accepted, promote, `/loop /apex-scope-loop:iterate …`. Gate, review and tier run exactly as for a feature.

### Workflow B: Operate a landed plan

1. After `land.sh`, run `/apex-scope-loop:operate .claude/plans/x-plan.md deploy`. It prints an Ask Contract, waits for the ack, then runs `$APEX_DEPLOY_CMD`.
2. Later (by hand or from `/schedule`), run `monitor` then `ingest`. Over-threshold signals become tagged lessons/backlog items that the next plan's tasks recall.

---

## Open Questions

**Q1.** Where does Operation live, given that `land.sh` removes the worktree, releases the ACTIVE lock and sets `landed: true`?
- **Decision**: A post-land command (`operate.sh` + `/apex-scope-loop:operate`) on the landed plan's state dir, not a plan phase. Deploy is always human-acked; monitor and ingest are automatic and can be scheduled. No hook. (2026-10-14, skobyn@gmail.com)

**Q2.** Does operate write to the dispatch ledger?
- **Decision**: Yes. Add non-provenance events `operate_deploy` and `operate_signal` to apex-dispatch's `ledger-events.json` (a contract change, minor bump), appended through `ledger.sh append` only when the plan's dispatch dir exists. Always record in checkpoint.json and lessons/backlog. (2026-10-14)

**Q3.** Which scope values ship, and what does each drop?
- **Decision**: `bugfix` (2 rounds, lean ADR, ≤ 2 phases, intent optional), `poc` (4 rounds, lean ADR + Architecture, ≤ 3 phases), `feature` (today). Explicit only: the user passes `--scope`, or the skill suggests one and the user confirms. No silent auto-detection. (2026-10-14)

**Q4.** Is Ideation a new stage that renames SCOPE, or a round-0 intent step?
- **Decision**: Round-0 intent step writing `<slug>-intent.md`. The SCOPE name and its five stages stay. (2026-10-14)

**Q5.** Should cost cover the orchestrator's own main-session tokens (as AI-DLC's session-cost does)?
- **Decision**: Yes, include it. `report.sh --per-task` adds an `orchestrator` column computed from the Claude Code session transcript(s): the real `usage` of each main-session assistant turn, attributed to the task whose route window (its first `route` row's ts to its last ledger row's ts) contains the turn, and priced with the merged policy's tier prices by the turn's model. Turns outside every window go to an `unattributed` bucket. Read-only; transcripts are passed with `--transcript PATH` (repeatable) or found under `~/.claude/projects/<repo-slug>/`. token-lens is not used because it estimates and does not bill. (2026-10-14)

---

## Risks & Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| A bugfix plan ships Tier C work with too little authoring | med | Enforcement is unchanged, so `risk-tier.sh` still raises Tier C and G12 still halts. `promote-to-loop.sh` warns when a bugfix plan has `[tier:c]` tags. |
| Deploy runs without a human | high | Ack required every time. `APEX_OPERATE_ACK` is bound to `<slug>@<landed sha>` and added to apex-dispatch's protected switches so an agent can't set it mid-run. |
| Monitor output injects text into LESSONS.md | med | JSON shape validated fail-closed; `note` fields truncated and stored as data; signal ids sanitised |
| The two template profiles drift | low | A smoke check diffs the section headings of the generic and apex lean templates |
| Transcript format changes between Claude Code versions | med | Parse only `type`, `timestamp`, `message.model`, `message.usage`; unknown lines skipped and counted; a smoke fixture pins the shape; a missing field gives `n/a`, not 0 |
| Per-task USD disagrees with the console | low | Both read `report.row_usd`; a smoke check compares them on one fixture |
| Old plans break | high | No-scope ⇒ feature; both existing plans validated in smoke |

**Debugging guarantees**:

- Before changing promote/planlib behaviour, we run the current scripts on both existing plans and keep their output as a fixture
- We reproduce each failure with a smoke fixture before changing code
- We compare a working (scope-less) case side by side with a broken (scoped) one before code changes

**Rollback story**: Each borrowing is its own phase and its own commits in the plan worktree. Before landing, revert that phase's commits. After landing, revert the merge commit range. Plugin versions roll back via `/plugin marketplace update` to the previous tag. A missing Scope line already means today's behaviour, so removing the feature is safe.

---

## Consequences

### Positive

- Small tasks stop paying feature-sized authoring cost, so the harness is used for them instead of skipped
- Production evidence finally reaches the ratchet
- Intent survives as its own artifact
- Cost per task is visible in the terminal as well as the console

### Negative

- More surface: one new script, one command, two templates per profile, two ledger events. That means more smoke checks to keep green.
- **"Auto-only" gating has two exceptions by design**: an operate deploy always waits for a human ack, and any task in this plan that risk-tier.sh classifies Tier C (`operate.sh` runs prod commands; ledger event and protected-switch changes touch security boundaries) halts for G12.

### Neutral / Worth noting

- Orchestrator attribution by time window is approximate when two plans run at once in one session; such turns are attributed to both windows' overlap as `unattributed`.
- AI-DLC's automatic scope detection and nine scopes are deliberately not copied. Three scopes cover the cases seen so far.
- apex-plan's interview is model-driven, so round counts are an instruction in SKILL.md, not code. Only the template choice and promote-time limits are enforced mechanically.

---

## Methodology

- **Sub-agents invoked**: none. Comparison done in the main thread, with an advisor review of the draft.
- **Sources consulted**: AI-DLC v2 core concepts (builder.aws.com, read 2026-10-13); this repo's apex-scope-loop, apex-dispatch, apex-decision-layer READMEs; `report.py`, `ac_metrics.py`, `docs/api.md`, `planlib.py`, `promote-to-loop.sh`, `land.sh`
- **Comparable platforms surveyed**: AWS AI-DLC v2.3.0
- **Counter-evidence considered**: AI-DLC's every-stage approval leads to approval fatigue, which is why operate keeps a human gate only on deploy. Scope sizing could become a way to skip review, which is why enforcement is held constant.

---

## Industry evidence (optional)

| Platform | What they do | Source (URL + date) |
|----------|--------------|---------------------|
| AWS AI-DLC v2 | Nine intent-detected scopes (bugfix 7 … feature 32 stages); Phase 4 Operation; Ideation before Inception; `/aidlc-replay` session-cost view | https://builder.aws.com/content/3GnQs6zaYp4mAx9FWBulDkhWnBo/ai-dlc-v2-core-concepts (2026-10-13) |

---

## Approval

When this ADR's status flips to **Accepted**:

1. The companion plan is the source of truth for execution
2. `promote-to-loop.sh aidlc-borrowings` initializes apex-execute state
3. `/loop /apex-scope-loop:iterate .claude/plans/aidlc-borrowings-plan.md` starts execution

Solo: approved by skobyn@gmail.com in the authoring session.

---

## Changelog

- 2026-10-14 — Drafted by skobyn@gmail.com via `apex-plan` skill
- 2026-10-14 — Q1–Q5 resolved (Q5: orchestrator cost in scope); status Accepted (solo)
- 2026-10-14 — Amended before promotion: console UI scope made explicit and read-only (R9 → MUST); Phase 0 added for the two pre-existing macOS smoke failures; apex-decision-layer's red smoke (commit-hygiene shadow) is out of scope; the loop forks from branch `aidlc-borrowings-base`, not main
