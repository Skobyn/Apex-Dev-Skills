# The Gibson harness in apex-execute

apex-execute runs every plan under a set of harness disciplines adapted from
[The Gibson](https://github.com/The-AIE/the-gibson), Mark Hinkle's open source
SDLC harness for agent fleets (Apache-2.0). The Gibson's operating principle is
*"Agent = Model + Harness"*: you rent the model, but the harness is yours, and
it gets better every time it catches a failure. This document maps each Gibson
law we adopted onto the concrete apex-scope-loop mechanism that enforces it.

The harness is **on by default**. Set `APEX_GIBSON=0` before `init.sh` (and
keep it set for the loop) to run with the pre-0.2 behavior.

## What we adopted

| Gibson law | What it says | How apex-execute enforces it |
|---|---|---|
| **Law 3** — never edit the canonical checkout | All mutation happens in a worktree | Already the apex-execute contract (`init.sh` worktree, `land.sh` merge). Unchanged. |
| **Law 4** — the green gate is absolute | generate → typecheck → lint → test → build with **zero new failures vs. the branch point** | `init.sh` records a baseline (`green-gate.sh baseline`) at the fork. `green-gate.sh check` fails on any step that was green at baseline and is red now. `checkpoint.sh complete` refuses unless the gate passed on the current head SHA, and `land.sh` re-runs the gate on the final head. |
| **Law 5** — never grade your own homework | The reviewer is a different agent, is read-only, reviews the exact head SHA, and fails closed | The `gibson-reviewer` agent (six lenses, `file:line` findings, final `VERDICT:` line). `checkpoint.sh review` records the verdict against a SHA, and `complete` refuses a missing, stale, or non-APPROVE review. |
| **Law 6** — acceptance criteria are the contract | Done means a sensor verified every criterion | Already the apex-plan rule (every task has a runnable `Acceptance:`). The reviewer re-runs it and quotes the result. |
| **Law 7** — Tier C is sacred | Money, auth, consent/PII, security boundaries, schema, alerting, and prod data get adversarial review plus a human merge gate (G12) | `risk-tier.sh` classifies each task's diff as A, B, or C from paths, added-line content, size, and tags, and the tier only ratchets upward. Tier C gets a six-lens fan-out, an adversarial refutation pass, and a G12 halt. `complete` refuses a Tier C task without a recorded human approval for the exact head SHA. |
| **Law 8** — report truthfully | Failures verbatim, skipped steps named | Pre-existing red is reported as `PREEXISTING`, never hidden. A gate with nothing configured reports `SKIPPED`, not `PASS`. `--skip-review` requires a recorded reason. |
| **Law 9** — feed the ratchet | A failure that happens twice is a harness bug | `lessons.sh fail` counts failure signatures and prints `RATCHET: FILE_LESSON` on the second occurrence. Lessons are appended to a tracked ledger (`.claude/apex-scope-loop/LESSONS.md`) and recalled by tag at the start of each task. |
| **Kill switch** | A HALT file stops the loop every iteration | `iterate.sh` and `land.sh` stop if `APEX_HALT=1` or any of `.dev-plan-state/HALT`, `<state-dir>/HALT`, or `gibson/HALT` exists. |
| **Error budget + escalation** | Two failures buy a second opinion; the budget stops runaway lanes | `checkpoint.sh fail` tracks consecutive failures: `ESCALATE:` at `APEX_ESCALATE_AFTER` (2), halt at `APEX_ERROR_BUDGET` (3). |
| **Ask Contract** | Every human ask states what, what it does, why, and the risks | Used for G12 and `[gate:human]` halts in `/apex-scope-loop:iterate`. |

## What we did not adopt (and why)

- **Cross-vendor runner routing** (Grok, Codex, Devin as merge captain) and
  Mission Control dispatch. apex-scope-loop runs inside one Claude Code session
  on ruflo swarms. Law 5 is approximated with a *fresh-context, separate
  agent* reviewer. The Gibson treats a fresh-context adversarial pass as a
  degraded-mode fallback for when no second vendor is available (its docs/11),
  and it specifies a different *session*. A subagent in the same session is
  weaker than that. If you have a second vendor or a separate session
  available, point the reviewer step at it.
- **GitHub issue claims, PR-body claims, and labels** (`claim.sh`,
  `agent-claimed`). A plan runs on one worktree branch owned by one loop, so
  there's nothing to race. Use The Gibson directly for multi-lane fleets.
- **CI workflow templates, DCO, branch protection, delivery control.** These
  are repo-setup concerns. Run The Gibson's `gibson-setup` skill against the
  target repo if you want them. `green-gate.sh` reads the same
  `.agents/gate.json` twin, so a Gibson-wired repo needs no extra config.
- **UX eval against live previews, and the eight-layer security scan.** These
  are out of scope for the loop core. Express them as plan tasks with runnable
  `Acceptance:` lines, or as `[gate:human]` checkpoints.

## Gate command configuration

`green-gate.sh` resolves each step in this order: `APEX_GATE_<STEP>` env var,
then `<worktree>/.agents/gate.json`, then a same-named `package.json` script.

```json
{
  "generate": "",
  "typecheck": "npx tsc --noEmit",
  "lint": "npm run -s lint",
  "test": "npm test --silent",
  "build": "npm run -s build"
}
```

An empty string means the step doesn't apply. If no step resolves at all, the
gate reports `SKIPPED`, and the task's `Acceptance:` check becomes the only
sensor. Configure the gate rather than relying on that.

## Credit

The laws, tier definitions, six review lenses, Ask Contract, kill-switch, and
ratchet concepts come from The Gibson (Copyright 2026 Mark Hinkle, Apache
License 2.0). The apex-scope-loop scripts are independent implementations of
those concepts. See the plugin's `NOTICE` file.
