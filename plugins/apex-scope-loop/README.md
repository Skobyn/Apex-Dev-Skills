# apex-scope-loop

> **Plan it once. Ship it for days.**
> A co-authored decision record and a phased plan that an autonomous swarm actually executes — across `/loop` iterations and `/schedule`d sessions, with gates that stop runaway work before it starts.

Most "AI planning" ends the moment the plan is written. The doc rots, the agent drifts, and by the next session nobody remembers why a choice was made. **apex-scope-loop** closes that gap: it walks you through a structured decision, captures the *why* in an ADR, compiles it into a runnable plan, and then keeps the work moving — phase by phase, gate by gate — without you re-explaining the project every morning.

It does that through five phases that spell **SCOPE**:

| Phase | What happens | You stay in control by… |
|---|---|---|
| **S**cope | 4–6 sharp `AskUserQuestion` rounds pin down scope, constraints, success criteria, ownership | answering, not prompt-wrangling |
| **C**ompose | A SPARC-shaped ADR + plan stub are scaffolded from your answers | seeing your words on the page immediately |
| **O**ptimize | You and the agent refine the ADR section-by-section until every Open Question is a Decision | signing off on each section |
| **P**lan | The resolved ADR compiles into a phased checklist with per-phase swarm directives + gates | reviewing runnable acceptance criteria |
| **E**xecute | The plan is promoted into an autonomous `/loop` that dispatches swarms inside an isolated worktree and advances on green | choosing auto / human / partner gates |

The result is a system that **thinks alongside you**: it watches reality, persists knowledge, and adjusts strategy across days and weeks — not just a single chat.

## Why you'll want it

- **No more abandoned plans.** The plan *is* the execution engine — checked off as work lands, not a stale to-do list.
- **Decisions survive the session.** Every choice is captured as an ADR with rationale, so future-you (and your teammates) inherit the *why*, not just the *what*.
- **Guardrails by default.** Phases close behind runnable checks or explicit human/partner approval. Bad work can't quietly cascade into the next phase.
- **Autonomy you can trust.** `/loop` drives active sessions; `/schedule` runs nightly audits and weekly architecture reviews so progress continues while you sleep.
- **Right-sized compute.** Each phase declares its own swarm — a single agent for trivial work, a full hierarchical-mesh for the heavy lifting.
- **A harness with teeth.** Execution runs under disciplines adapted from [The Gibson](https://github.com/The-AIE/the-gibson). Each task must pass a green gate measured against the fork-point baseline, then get an independent review of its exact commit from an agent that didn't write it. Anything touching money, auth, PII, security, schema, or prod data stops for your approval. Repeated failures become permanent lessons. See [The Gibson harness](#the-gibson-harness).
- **Isolated by default.** The whole plan runs in a dedicated git worktree on its own branch. `main` stays clean until the final gate passes and the branch is landed — a half-finished or abandoned plan never leaks partial code into your base branch.

## Prerequisites

| Requirement | Why |
|---|---|
| **Claude Code 2.0+** *(required)* | Needs `/loop`, `/schedule`, `AskUserQuestion`, `ScheduleWakeup`, and `Agent`. |
| Python 3.11+ *(optional)* | Matches the surrounding apex toolchain; plugin scripts themselves are bash. |
| A memory store *(optional, via `APEX_MEMORY_CMD`)* | Seeds a plan record into the `apex-scope-loop` namespace. Unset means the seed is skipped quietly. |

The loop runs on plain Claude Code subagents. Nothing else needs installing.

Memory seeding is optional and happens only when `APEX_MEMORY_CMD` is set. `init.sh` runs it with `APEX_MEMORY_NAMESPACE`, `APEX_MEMORY_KEY` and `APEX_MEMORY_VALUE` in its environment. With the optional [ruflo](https://github.com/ruvnet/ruflo) CLI, for example (APEX_MEMORY_CMD):

```bash
export APEX_MEMORY_CMD='npx -y @claude-flow/cli@latest memory store --namespace "$APEX_MEMORY_NAMESPACE" --key "$APEX_MEMORY_KEY" --value "$APEX_MEMORY_VALUE"'
```

`Swarm:` directives in a plan are advisory (optional ruflo/claude-flow swarms, or apex-dispatch `fanout` once available). Without them, each task runs as a single subagent.

## Install

```bash
# From the Apex marketplace
/plugin marketplace add Skobyn/Apex-Dev-Skills
/plugin install apex-scope-loop@apex-dev-skills

# …or test locally against this repo
claude --plugin-dir ./plugins/apex-scope-loop
```

Then `/reload-plugins` (or restart Claude Code) to activate.

## Quick start

```bash
# 1. Author the ADR + plan with the user (the S-C-O-P phases)
/apex-scope-loop:start my-feature

# Walks you through: scope → constraints → success criteria → ownership → swarm pref → gate pref
# Produces: .claude/tasks/my-feature-adr.md + .claude/plans/my-feature-plan.md
# Promotes to apex-execute state if validation passes

# 2. Execute the plan one phase at a time (all work happens in an isolated worktree)
/apex-scope-loop:iterate .claude/plans/my-feature-plan.md

# …or hand it to /loop for self-paced, autonomous execution:
/loop /apex-scope-loop:iterate .claude/plans/my-feature-plan.md

# 3. When the final gate passes, land the worktree branch onto main:
.claude/skills/apex-execute/scripts/land.sh .claude/plans/my-feature-plan.md
```

## What you get

| Surface | Name | Trigger |
|---|---|---|
| Skill | `apex-plan` | Auto-triggered on "decide and plan", "design this with me", "let's plan together" |
| Skill | `apex-execute` | Auto-triggered on "iterate plan", "autonomous loop", `/loop` invocations referencing a plan |
| Command | `/apex-scope-loop:start <slug>` | Begin a new SCOPE authoring session |
| Command | `/apex-scope-loop:iterate <plan>` | Run one phase of a promoted plan |
| Command | `/apex-scope-loop:operate` | Watch landed plans: `status`, `monitor`, `ingest`; `deploy` is run by you in a terminal (see [Scope, intent and operate](#scope-intent-and-operate-v070)) |
| Agent | `gibson-reviewer` | Independent, read-only six-lens reviewer of one task's exact head SHA (Opus). Dispatched by the iterate loop; never reviews its own work |
| Agent | `plan-author` | Delegate the SCOPE/COMPOSE/OPTIMIZE rounds to a Sonnet subagent (saves main-thread context) |

## How the two skills compose

```
apex-plan  (authoring — the five phases spell SCOPE)

   SCOPE → COMPOSE → OPTIMIZE → PLAN → EXECUTE
                                          │
                                          │  init.sh + checkpoint.json
                                          ▼
apex-execute  (execution — the loop, inside an isolated worktree)

   init.sh ──► git worktree add apex-scope-loop/<slug>  (forked from main)

   /loop next task → swarm dispatch (in worktree) → acceptance check → advance / halt
        ▲                                                                │
        └── /schedule audit.sh, architecture-review.sh                   ▼
                                              final gate passed → land.sh
                                              (merge branch → main, remove worktree)
```

## The Gibson harness

apex-execute adopts the portable core of [The Gibson](https://github.com/The-AIE/the-gibson), an open source SDLC harness for agent fleets (Apache-2.0, Mark Hinkle). It's **on by default**. Set `APEX_GIBSON=0` to opt out.

Per task, inside the worktree:

```
build swarm → commit → green-gate.sh check → risk-tier.sh → gibson-reviewer (exact head SHA)
           → [Tier C: 6-lens fan-out + adversarial pass + your G12 approval] → acceptance → checkpoint complete
```

| Gibson law | What you get |
|---|---|
| Green gate vs. baseline (Law 4) | `init.sh` snapshots generate/typecheck/lint/test/build at the fork. A task fails only on *new* red. Commands come from `.agents/gate.json` (Gibson format), `APEX_GATE_*`, or `package.json` |
| Never grade your own homework (Law 5) | The `gibson-reviewer` agent reviews in a fresh context and fails closed. Check-off is refused without an `APPROVE` on the current head |
| Tier C is sacred (Law 7) | `risk-tier.sh` flags money/auth/PII/security/schema/prod-data diffs. They halt for your approval, asked in plain language (the Ask Contract) |
| The ratchet (Law 9) | A failure seen twice must be filed in `.claude/apex-scope-loop/LESSONS.md`, and lessons are recalled by tag before each task |
| Kill switch + error budget | `touch .dev-plan-state/HALT` (or `gibson/HALT`, or `APEX_HALT=1`) stops the loop. Two failures in a row buy a second opinion. Three stalled failures halt the plan, and so do six in a row of any kind (a failure that closed findings and moved the head is not a stall) |

### Review-loop calibration (v0.4.0, ADR-0004)

- **Threat model first.** A plan's `## Threat model` section (or a task's `- Threat:` line, else a stated default: trusted agents, accidents and realistic misuse in scope, deliberate tampering and obfuscated inputs out) is printed in the brief and handed to every reviewer verbatim.
- **A fixed bar.** `[blocking]` means a realistic actor under that model can cause it in an ordinary flow, or Acceptance is unmet, or tests were weakened. At most `APEX_ADVERSARY_BUDGET` (3) blocking findings per pass. Everything else goes to the hardening backlog (`backlog.sh`, `.claude/apex-scope-loop/BACKLOG.md`), which a later docs task consumes.
- **Verify-only re-reviews.** Round 1 is the full review (and the attempt's one full adversarial pass); later rounds check the prior findings and the fixes since `LAST_REVIEWED`.
- **Ask the human sooner.** After REQUEST_CHANGES in 2 rounds, `checkpoint.sh review` prints `ASK_HUMAN:`. The human can accept the residual risk at that exact head with `checkpoint.sh waive`; the gate, the tier, G12 and Acceptance still apply, and the completion is recorded as waived, not approved.
- **Carried findings, frozen heads, shared snapshots.** `findings.sh` keeps each task's findings (a defect counted once; non-blocking ones go to the backlog), `checkpoint.sh freeze` holds the head for a review round, `snapshot.sh` gives reviewers one read-only checkout per commit, and `status.sh --review-metrics` measures rounds and minutes. The review cap counts only rounds that requested changes; a task's `Review:` directive can set it.
- **Calibrated tiers.** Content signals in tests, fixtures, smoke files, examples and docs no longer raise Tier C (their paths still do), and an explicit `[tier:a reason="…"]`/`[tier:b reason="…"]` override decides over size and content signals (the reason is recorded), never over Tier C paths or `[security]`/`[tier:c]`.

### Knobs file (v0.5.0)

The review-loop strictness and the risk-tier definitions can be set per repository in a **knobs file**, `<state-base>/knobs/scope-loop.json`. `<state-base>` is the `.dev-plan-state` directory beside the main checkout (or under `APEX_STATE_ROOT/.dev-plan-state/<repo-id>/` when that is set). The admin console (`apex-console`) edits this file; you can also write it by hand. It sits in the state directory on purpose: during a run, apex-dispatch's hooks refuse agent writes to `.dev-plan-state`, so an agent cannot loosen it mid-run. Never commit it.

```json
{"schema": 1,
 "review": {"cap": 3, "ask_human_after": 2, "adversary_budget": 3, "escalate_after": 2, "error_budget": 3, "attempt_cap": 6},
 "tiers": {"c_paths_extra": ["regex"], "c_terms_extra": ["regex"],
           "exempt": [{"glob": "plugins/*/agents/*.md", "reason": "agent prompts name auth terms as prose"}],
           "b_max_lines": 150, "b_max_files": 6, "b_shared_dirs": ["api", "route", "routes", "shared", "common", "core", "lib"]}}
```

- **All keys are optional.** The values above are the built-in defaults, so a missing file changes nothing. Limits: `review.cap` 1–10, `ask_human_after` 1–10, `adversary_budget` 0–20, `escalate_after` 1–10, `error_budget` 1–20, `attempt_cap` 1–50, `b_max_lines` 10–5000, `b_max_files` 1–500. `c_paths_extra` and `c_terms_extra` each take up to 50 Python regexes (200 characters at most, matched case-insensitively, none may match the empty string). They are added to the built-in Tier C path and content patterns with OR. `b_shared_dirs` takes up to 30 directory names. `exempt` takes up to 50 `{glob, reason}` entries. Unknown keys are errors, and `schema` must be 1.
- **Exempt globs** are fnmatch patterns on the repo-relative path, where `*` also matches `/`. A matching path is not treated as a Tier C path, and its added lines are not scanned for Tier C terms. `risk-tier.sh` prints `REASON: exempted by knobs: <path> (<glob>: <reason>)` for each one. A catch-all glob is refused, and so is a reason shorter than 8 characters. Tags (`[security]`, `[tier:c]`), `--raise` and the decision layer still raise the tier.
- **Precedence:** an environment variable that is set to a whole number wins (`APEX_REVIEW_CAP`, `APEX_ASK_HUMAN_AFTER`, `APEX_ADVERSARY_BUDGET`, `APEX_ESCALATE_AFTER`, `APEX_ERROR_BUDGET`, `APEX_ATTEMPT_CAP`). Otherwise the file wins over the default.
- **Fail closed:** if the file is invalid, `risk-tier.sh`, `iterate.sh` and `checkpoint.sh review`/`fail` stop with an error that names the file and each problem. They never fall back to the defaults.
- **Traceability:** `risk-tier.sh` and the brief print `KNOBS: <sha12>|default`, and the tier record stores it as `tiers[line].knobs`.
- **Tooling:** `skills/apex-execute/scripts/knobslib.py validate FILE` checks a file. `knobslib.py get --state-base DIR KEY` prints one effective value. `knobslib.py effective --state-base DIR` prints the merged values, their sources, the built-in regexes, the limits and the env names as JSON. The console uses the same validator.

Full mapping, and what was deliberately left out (cross-vendor routing, GitHub claims, CI templates): [skills/apex-execute/docs/GIBSON_HARNESS.md](skills/apex-execute/docs/GIBSON_HARNESS.md). For repo-level setup (CI gates, branch protection, labels), run The Gibson's own `gibson-setup` skill against the target repo.


### Replaying a past task (v0.6.0)

`risk-tier.sh PLAN LINE --no-record --since <base> --head <sha> [--knobs <file>]` classifies a completed task's committed diff, `<base>..<sha>`, without touching the current head or anything uncommitted. With `--knobs`, it classifies the diff under a proposed knobs file instead of the one in force. That file is validated the same way, and an invalid one exits 3. Both flags need `--no-record` and refuse `--raise` and `--classify`, so a replay never changes a recorded tier. apex-console's tier simulator uses them to show what a tier-definition change would have done to your past tasks before you apply it.
## Scope, intent and operate (v0.7.0)

**Scope sizing.** `start.sh` takes `--scope bugfix|poc|feature` and picks a template to match. `bugfix` and `poc` get lean templates with fewer required sections; `feature` gets the full SPARC-shaped set. The scope is written into the plan header, and `status.sh` and apex-console show it. A plan without one reads `feature`.

**Intent round.** Before the ADR is composed, the start flow asks a short intent round (problem, who it is for, why now, non-goals) and writes it to `.claude/tasks/<slug>-intent.md`. `status.sh` prints the Scope and Intent lines for the plan. It is a summary for the reader and does not change the gates.

**Operate.** Once a plan has landed, `operate.sh` watches what it shipped:

```bash
operate.sh PLAN deploy                  # human only, see below
operate.sh PLAN status | monitor | ingest
operate.sh --all status | monitor [--ingest]   # every landed plan
```

Or run `/apex-scope-loop:operate`. Operate only runs on landed plans.

- **`## Monitor` section.** A plan can declare `window_days` and a list of checks. Each check uses an `http`, `cmd` or `runner` probe with a threshold and a severity. `monitorlib` validates the section. Without a `## Monitor` section, a landed plan has no checks to measure.
- **Repo-level checks.** `.claude/apex-scope-loop/monitor.json` holds checks that belong to the whole repository, not to one plan. `operate.sh --all monitor` runs them with the plans.
- **Watch windows.** A successful deploy opens a window of `window_days`. A deploy that exits non-zero opens none. A later successful deploy closes the window still open (`redeploy`) and opens a new one. A window closes as `operated-clean` or `closed-with-breaches`. Checks still in breach, or never measured, at close are flagged **open-at-close**. An unmeasured probe is recorded as unmeasured, never as a zero.
- **Breaches are filed once.** `ingest` files each breach as a lesson or a backlog item, tagged `operate:<slug>`. Repeat runs do not file it again.
- **Deploy is human-only.** `operate.sh PLAN deploy` asks you to type `<slug>@<landed sha>` at your terminal. apex-dispatch's pre-bash hook denies any agent command that names both `operate.sh` and `deploy`, so an agent cannot run it. An agent can run `status`, `monitor` and `ingest`.

Each deploy, check breach and closed window is written to the ledger as an `operate_*` event (see apex-dispatch). Apex-console shows the operate state read-only and never runs these commands.

## Compatibility

- **Claude Code:** 2.0+ (requires `/loop`, `/schedule`, AskUserQuestion, ScheduleWakeup, Agent)
- **git:** 2.40+ (the clean-worktree check builds its comparison checkout with `--attr-source=HEAD`; older git makes the gate fail closed on files git converts on checkout)
- **bash** 3.2+ (the macOS default `/bin/bash` included) and **python3** 3.8+ (stdlib only)
- **apex-dispatch:** optional; 0.7.0+ supplies the operate deploy deny and the `operate_*` ledger events. Without it the terminal ack still stands, but no agent-side deny applies
- **ruflo / `@claude-flow/cli`:** optional — used only when `APEX_MEMORY_CMD` seeds memory or a plan's advisory `Swarm:` directive is run through it

## Namespace coordination

This plugin claims the AgentDB / memory namespace **`apex-scope-loop`**, following the kebab-case `<plugin-stem>-<intent>` convention (borrowed from the optional ruflo-agentdb ADR-0001 §"Namespace convention"). Sub-keys:

| Key prefix | Holds |
|---|---|
| `apex-scope-loop:adrs/<slug>` | ADR metadata + status |
| `apex-scope-loop:plans/<slug>` | Plan checkpoint + completion % |
| `apex-scope-loop:outcomes/<slug>/<phase>` | Per-phase verdict + trajectory pattern |
| `apex-scope-loop:lessons/<tag>` | Ratchet lessons (mirror of the tracked `.claude/apex-scope-loop/LESSONS.md`, per ADR-0002) |
| `apex-scope-loop:operate/<slug>` | Operate state for a landed plan (deploys, watch window, check readings), per ADR-0001 (v0.7.0) |

The hardening backlog (ADR-0004) is a tracked file beside the ledger, `.claude/apex-scope-loop/BACKLOG.md`, not a memory key.

Any future plugin that wants to read/write these keys must claim a non-overlapping prefix and reference this plugin's ADR-0001.

## Verification

```bash
bash plugins/apex-scope-loop/scripts/smoke.sh
```

The smoke script runs 73 checks: the structural contract (frontmatter, namespace declaration, ADR status, script executability, README sections) plus behavioural fixtures for the harness (plan dialect, checkpoint provenance, risk tiers, the chain, land, the clean-worktree inventory, the review-loop calibration of ADR-0004, and the knobs file). It exits non-zero on the first failing check and names what's wrong.

## Architecture Decisions

- [ADR-0001 — apex-scope-loop plugin contract](docs/adrs/0001-apex-scope-loop-contract.md) — Status: **Proposed**. Defines surface, namespace, compatibility, and smoke contract.
- [ADR-0002 — Adopt The Gibson's harness disciplines](docs/adrs/0002-gibson-harness.md) — Status: **Proposed**. Green gate, independent review, Tier C / G12, ratchet, kill switch.
- [ADR-0003 — Portability, the per-run guarantee, and apex-dispatch as a consumer](docs/adrs/0003-portability-and-dispatch-consumer.md) — Status: **Proposed**. ruflo optional, template profiles, the chain and epochs, landing without merge machinery, the clean-worktree contract and what lies outside it.
- [ADR-0004 — Review-loop calibration](docs/adrs/0004-review-loop-calibration.md) — Status: **Accepted**. Threat model before review, severity bar, verify-only re-reviews, adversary budget, human waiver, progress-aware halts, hardening backlog, classifier calibration; what it loosens and why that is safe.

## Migration from `.claude/skills/`

This plugin was extracted from `.claude/skills/apex-plan/` and `.claude/skills/apex-execute/`. Both source skills are still present in the apex repo for backwards compatibility, but the plugin is the canonical version.

To remove the duplicate skill copies once you've verified the plugin works:

```bash
rm -rf .claude/skills/apex-plan .claude/skills/apex-execute
```

After that, the only source of truth lives under `plugins/apex-scope-loop/skills/`.

## Anti-patterns

The skills' own SKILL.md files document anti-patterns at length. The most important ones, in plugin terms:

1. **Composing before scoping.** Stage 1 (SCOPE) of apex-plan is non-negotiable.
2. **Vague acceptance criteria.** "Improve UX" is not a runnable check. Either it's `pytest`/`curl`/`grep` or it's an explicit `[gate:human]` with a literal approval phrase.
3. **Skipping surface parity.** When the work is user-facing, enumerate every surface in the ADR — don't let it default to "obvious."
4. **One mega-phase.** > 6 tasks or > 1 day of work in one phase → split it. Gates between small phases are cheaper than rollbacks of giant ones.
5. **Promoting with `Default:` lines.** Every Open Question must resolve to a `Decision:` before the plan can be promoted.

## License

MIT — see the repo-level LICENSE. The execution harness adapts concepts from The Gibson (Apache-2.0); see [NOTICE](NOTICE).
