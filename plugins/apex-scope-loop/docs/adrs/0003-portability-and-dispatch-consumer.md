# ADR-0003: Portability, the per-run guarantee, and apex-dispatch as a consumer

- **Status:** Proposed
- **Date:** 2026-10-06
- **Author:** solutions@getapexinsights.com
- **Plugin:** apex-scope-loop v0.3.0
- **Amends:** [ADR-0001](0001-apex-scope-loop-contract.md), [ADR-0002](0002-gibson-harness.md)

## Context

apex-scope-loop 0.2.0 assumed ruflo (now optional) was installed and the repo looked like an Apex repo. Its harness bound reviews and the green gate to a head SHA, but did not say which diff a review covered, what "the worktree is the head" means, or what `land.sh` may merge. apex-dispatch (a separate plugin) will drive single tasks through these scripts. It needs a stable contract for state, records and refusals.

## Decision

### 1. Portability

- **ruflo is optional.** `init.sh` seeds memory only when `APEX_MEMORY_CMD` is set (empty means skip quietly). The loop uses plain Claude Code subagents. `Swarm:` directives are advisory. ruflo swarm docs live under `skills/apex-execute/docs/legacy/`.
- **Plan templates have profiles.** `skills/apex-plan/resources/templates/profiles/{generic,apex}/`. `start.sh` picks `apex` when `.claude/agent-coord-config.json` exists or `APEX_PLAN_PROFILE=apex`, and `generic` otherwise.
- **Partner gates post through `APEX_PARTNER_NOTIFY_CMD`** (JSON on stdin). Without it, they degrade to `[gate:human]`.
- **The green gate autodetects toolchains** (npm, uv/pytest, cargo, go, make), unless `APEX_GATE_*` or `.agents/gate.json` names the steps.
- **State** lives in `.dev-plan-state/<repo-id>/` beside the main checkout, or under `APEX_STATE_ROOT` when set. This ADR owns `.dev-plan-state/`, the `ACTIVE` lock and the `dispatch/` subdirectory, which apex-dispatch writes.
- **Minimum versions:** git 2.40 (for `--attr-source`), python3 3.8, bash 4.

### 2. The per-run guarantee (user decision)

The guarantee covers **one run, against the base it forked from**:

1. **Classification and review.** A run's own diff since its fork point is classified at `complete` (recorded tier, recomputed at complete; the effective tier is the maximum). It gets the review shape for that tier: Tier C needs a reviewer APPROVE and an adversarial APPROVE in the current attempt and epoch, plus a human G12 approval for that head and epoch. It also needs a green gate at the exact head.
2. **Landing.** `land.sh` merges only what reviewed completions covered. The landed tree is the base tip plus exactly the reviewed fork..head diff.

**The operator owns the base.** Other runs' branches, any spelling of the base, a renamed or rewritten base, and direct commits to it are the operator's responsibility. The cross-run guards (restart guard, refusing another live run's branch as a base, the `run_branch` pin) are defence in depth, not part of the claim.

**The chain.** `init` records `fork_sha`. Each harness-on `complete` appends `{line, id, head}` to `completes[]`. The floor for the next review is the last verified head if that head is an ancestor, and otherwise the fork. `risk-tier --since` may only reach back to the floor or further. `APEX_GIBSON=0` completions do not advance the chain.

**Refork and epochs.** After the run merges its base, `checkpoint.sh refork REASON` does the following:
- moves the fork to the base tip;
- clears `completes[]`;
- bumps `epoch`;
- when no task remains open, reopens the last completed task by id.

Tiers, reviews and G12 approvals count only in the current epoch. Review rounds are not reset by a refork: a refork cannot be used to dodge the round cap.

**Single active task.** The chain assumes one active task at a time. `LANES` is a hint. Parallel lanes would need a floor per lane.

### 3. Landing without merge machinery

`land.sh` refuses to land unless both of these hold:
- `merge-base(run head, base tip) == fork_sha`, which means the run branch never merged its base;
- the paths the run changed and the paths the base changed since the fork are disjoint, as paths and as file/directory prefixes, with submodules included.

It builds the landed tree with plumbing: the run head's tree, overlaid with the base's own changes. The plan file and the lessons ledger always come from the base. It checks again against the exact base tip, then fast-forwards. No merge strategy, driver or attribute takes part. A re-run after a failed teardown finishes the teardown. `--force` keeps the legacy `git merge`.

### 4. "The worktree is its head" (`apex_dirty`, `inventory.py`)

When the gate starts, and again at land, the worktree (submodules included) must match its head. Every entry must be one of:
- a tracked regular file whose bytes are its blob's bytes, or exactly what a checkout of that blob writes under **the head's own attributes**;
- a tracked symlink or type that `git status` vouches for;
- a directory leading to tracked paths;
- a submodule checked the same way (a submodule that is not checked out must be an empty directory);
- something the head's **committed** `.gitignore` rules ignore.

Anything else is reported, and so is any error. That covers untracked files and directories (empty ones included), unlistable directories, any `.git` entry below the top, and files hidden by an untracked `.gitignore`.

The check is a positive inventory. It walks the real tree and byte-compares every tracked file, rather than listing the ways git can hide a file. Names are compared as bytes, and folded only under `core.precomposeUnicode`. `check-ignore` is asked in chunks under a deadline (`APEX_INVENTORY_TIMEOUT`, default 600 s).

**Outside the guarantee (user decisions):**
- **Ignored content.** Content the head's committed rules ignore, files or directories, is the operator's environment: venvs, `node_modules`, `*.pyc`, `.env`, logs. It can influence gate steps. For example, a stray `calc/__init__.pyc` matching `*.py[cod]` can shadow a tracked `calc.py`. It cannot change how a tracked file is judged, because the comparison checkout uses `--attr-source=HEAD`.
- **Local git configuration and repository internals.** This covers `git config` (filter drivers, `core.autocrlf`, `core.attributesFile`, `core.excludesFile`, `core.filemode`, `core.symlinks`, `core.precomposeUnicode`), index flags, `.git/info/*`, merge drivers, hooks and a submodule's own git dir. The scripts pin the cheap overrides (fsmonitor off, trustctime on, checkStat default, ignoreStat off, no replace objects or grafts, no external diff or textconv). Tampering during a run is for the apex-dispatch pre-bash/pre-edit hooks (Phase 3.1).
- **Changes made while gate steps run** (TOCTOU). The check runs before the steps.
- **Runs without a worktree** keep state in the checkout, so they gate cleanly only when `.dev-plan-state/` is committed to `.gitignore`. A hint says so.

False "dirty" reports fail closed and are accepted. Examples: macOS case-insensitive volumes, NFD names committed from Linux on macOS, and git older than 2.40 with converted files.

### 5. Records apex-dispatch relies on

- **Review records.** `checkpoint.sh review LINE SHA VERDICT [--role adversarial] [--agent-id ID]` stores `{attempt, epoch, sha, verdict, reviewer, role, provider, model, agent_id, route, provenance, source}`; a record's id is kept in `source` as `record:<record_id>`. With dispatch state present, a verdict needs provenance: a hook-written `reviews-raw` record with a `record_id` (used once) and `line`. The role comes from the record.
- **Review rounds.** Rounds are distinct SHAs per attempt, capped by `APEX_REVIEW_CAP` (default 3; a refusal starts with `REVIEW_CAP:`).
- **Failed attempts.** `checkpoint.sh fail` counts consecutive failures: two print `ESCALATE` (`APEX_ESCALATE_AFTER`, with an `ESCALATE_ROUTE` seam) and three halt the run (`APEX_ERROR_BUDGET`).
- **Tier records.** `risk-tier.sh LINE` records `{tier, since, head, epoch}`. `--no-record` prints `TIER:`/`HEAD:`. `--classify` takes the maximum of the heuristic and the decision layer, and only raises.
- **Iterate briefs.** `iterate.sh` prints `TASK_BASE` (the floor) and route fields. `BUSY`, `BLOCKED`, `NEEDS_SPEC` and `HUMAN_GATE` are terminal brief states.
- **Operator overrides are not yet recorded by the scripts.** `land.sh --force` and `APEX_GIBSON=0` leave no record; `refork` stores its reason in `reforks[]`. Until a later phase adds an `operator_overrides[]` writer, an orchestrator that waives a review records the operator's literal words in the checkpoint by hand, and never as a review verdict. Consumers must not treat a missing record as "no override happened".

## Consequences

- apex-scope-loop runs in a plain Claude Code install; ruflo is optional.
- Gate and land checks read every tracked file: seconds on large repos (about 3–7 s for 50–60k files in tests).
- The claim is narrower and stated: per run, under the head's own committed rules. Anything outside it is the operator's or Phase 3's.
- Review-loop cost is high for Tier C harness work. Feedback for loosening it is in `.claude/apex-scope-loop/REVIEW-LOOP-FEEDBACK.md` of the development repo.
