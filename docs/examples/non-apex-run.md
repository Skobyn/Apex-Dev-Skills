# Walkthrough: apex-scope-loop on a plain uv/pytest repo

This walkthrough runs apex-scope-loop 0.3.0 on an ordinary Python repo. The repo has no Apex configuration, no `.claude/skills/` copy and no ruflo. Every command and output below comes from a real run. Paths are shortened to `<state>` (the run's state directory) and `$EX` (the plugin's `skills/apex-execute/scripts`).

In a Claude Code session, the slash commands from a marketplace install wrap these scripts. They are shown directly here so each step is visible.

## Prerequisites

- **Plugin install:** `/plugin marketplace add Skobyn/Apex-Dev-Skills`, then install `apex-scope-loop`.
- **Tools:** git 2.40+, bash 4+, python3. pytest is available (`uv run pytest` or a venv).
- **Optional:** ruflo. It is used only if `APEX_MEMORY_CMD` is set.

## 1. The repo

```text
demo/
├── pyproject.toml        # [tool.pytest.ini_options] pythonpath = ["src"]
├── src/calc/__init__.py  # def add(a, b): return a + b
├── tests/test_add.py
├── .gitignore            # __pycache__/  .pytest_cache/  .dev-plan-state/
└── .claude/plans/calc-plan.md
```

The plan has one task with an Acceptance check. You would normally write it with `/apex-scope-loop:start`, which uses the generic template profile because this repo has no `.claude/agent-coord-config.json`.

```markdown
# Plan: calc — add subtraction

- [ ] **Phase 1.1** [backend] Add sub(a, b) with a test
  - Acceptance: `python -m pytest -q tests`
```

Commit the plan and the `.gitignore`. The run keeps its state, including its worktree, in `.dev-plan-state/` inside your checkout, so that directory must be ignored. This matters most for runs without a worktree (`APEX_NO_WORKTREE=1`): their gate refuses a checkout that isn't exactly its head.

## 2. Initialise the run

```console
$ $EX/init.sh .claude/plans/calc-plan.md
[init]   GATE_STEP: test PASS exit=0
[init]   GATE: BASELINE recorded (1 step(s) ran) -> <state>/gate/baseline.json
[init] harness: gibson (green gate · independent review · Tier-C G12 · kill switch · ratchet). APEX_GIBSON=0 to disable.
[init] ready. next: /loop iterate the next phase of .claude/plans/calc-plan.md
```

`init.sh` creates a worktree on the branch `apex-scope-loop/calc-<id>` and records the fork point. It then runs a baseline green gate. The gate found pytest through `pyproject.toml` (toolchain autodetect), so no gate configuration was needed.

## 3. Get the next task

```console
$ $EX/iterate.sh .claude/plans/calc-plan.md
WORKTREE: <state>/worktree
BRANCH: apex-scope-loop/calc-3671297bcdc6
PHASE: Phase 1.1
TASK: - [ ] **Phase 1.1** [backend] Add sub(a, b) with a test
ACCEPTANCE: python -m pytest -q tests
LINE_NO: 3
TASK_BASE: 205483cf7cb7…
STAGE: BUILD
HARNESS: gibson
ROUTE: none
```

`TASK_BASE` is the diff base for this task's review and risk tier.

## 4. Build in the worktree and commit

The builder (you, or a subagent) works only in `WORKTREE`:

```console
$ cd <state>/worktree
$ # add sub() to src/calc/__init__.py and tests/test_sub.py
$ git add -A && git commit -m "calc: add sub"
```

## 5. Gate, tier, review, complete

```console
$ $EX/green-gate.sh .claude/plans/calc-plan.md check
GATE_STEP: test PASS
GATE: PASS

$ $EX/risk-tier.sh .claude/plans/calc-plan.md 3
TIER: A
DIFF: 2 file(s), 8 line(s) since 205483cf7cb7

$ $EX/checkpoint.sh .claude/plans/calc-plan.md review 3 <head-sha> APPROVE gibson-reviewer
[checkpoint] review @ line 3: APPROVE on 24e9b6eea728 (attempt 1, round 1/3, …)

$ $EX/checkpoint.sh .claude/plans/calc-plan.md complete 3 "sub() added with a test"
[checkpoint] complete @ line 3 (sub() added with a test)
```

- **The gate's clean-tree check:** the gate checks that the worktree is exactly the head commit before it runs any step. A stray file would fail it; see ADR-0003 §4.
- **The review:** the verdict comes from the independent `gibson-reviewer` agent, which grades that exact head SHA. A Tier C task would also need an adversarial approval and a human G12 approval.
- **The complete step:** `complete` refuses unless the gate, the tier and the review all bind to the current head.

Commit the checked-off plan in the main checkout (`git add .claude/plans/calc-plan.md && git commit`).

## 6. Land

```console
$ $EX/land.sh .claude/plans/calc-plan.md
GATE: PASS
[land] landing apex-scope-loop/calc-3671297bcdc6 (24e9b6eea728) onto main as c05c138f11e0 ...
[land] removed worktree <state>/worktree
[land] DONE — apex-scope-loop/calc-3671297bcdc6 merged into main and worktree removed.

$ git log --oneline -3
c05c138 apex-scope-loop: merge apex-scope-loop/calc-3671297bcdc6 into main (final gate passed)
9661a59 plan: Phase 1.1 done
24e9b6e calc: add sub
```

`land.sh` builds the landed tree without merge machinery. It takes the reviewed head, overlays the base's own changes, and fast-forwards `main`. It refuses if the run branch merged its base, or if both sides changed the same path (ADR-0003 §3).

## What was not needed

- **ruflo / claude-flow:** memory seeding is skipped quietly when `APEX_MEMORY_CMD` is unset.
- **Apex configuration:** no `.claude/agent-coord-config.json`, Apex inbox or partner inbox. A partner gate would use `APEX_PARTNER_NOTIFY_CMD`, or fall back to a human approval.
- **A copied `.claude/skills/` directory:** the plugin install is enough.
