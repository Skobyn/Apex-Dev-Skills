# ADR-0002: Adopt The Gibson's harness disciplines in apex-execute

- **Status:** Proposed
- **Date:** 2026-09-27
- **Author:** solutions@getapexinsights.com
- **Plugin:** apex-scope-loop v0.2.0
- **Extends:** [ADR-0001](0001-apex-scope-loop-contract.md)

## Context

Before this change, apex-execute advanced a task when its `Acceptance:` check passed. The agents that built the code were the same agents that judged it. Nothing distinguished a regression the plan caused from one it inherited. A task touching auth or billing got the same treatment as a docs edit. And when the same failure recurred, the loop just retried it.

[The Gibson](https://github.com/The-AIE/the-gibson) (Mark Hinkle, Apache-2.0) is a portable SDLC harness for agent fleets. It encodes a tested answer to each of those gaps in its Ten Laws. Its core is agent-agnostic (Markdown, shell, CI), so its disciplines can be ported without adopting its fleet runtime: cross-vendor runners, Mission Control, and Devin as merge captain.

## Decision

Adopt the Gibson disciplines that apply to a single-loop, single-worktree plan executor, and enforce them in scripts rather than prose. The harness is **on by default**, and `APEX_GIBSON=0` restores v0.1 behavior.

| Gibson law | apex-scope-loop mechanism |
|---|---|
| Law 4: green gate vs. branch point | `green-gate.sh baseline` (run by `init.sh`) and `green-gate.sh check`. Resolves generate/typecheck/lint/test/build from `APEX_GATE_*`, `.agents/gate.json` (the Gibson format), or `package.json` |
| Law 5: never grade your own homework | New `gibson-reviewer` agent (read-only, six lenses, exact head SHA, `VERDICT:` line). `checkpoint.sh review` records verdicts, and review fails closed |
| Law 7: Tier C is sacred | `risk-tier.sh` (paths + added-line content + size + tags, ratchets upward only). Tier C gets a lens fan-out, an adversarial pass, and a G12 human approval via `checkpoint.sh approve` |
| Law 8: report truthfully | `PREEXISTING` / `SKIPPED` gate states. `--skip-review` requires a recorded reason |
| Law 9: the ratchet | `lessons.sh` counts failure signatures, prints `RATCHET: FILE_LESSON` on the second occurrence, and keeps a tracked `LESSONS.md` that is recalled by tag |
| Kill switch, error budget | `HALT` files / `APEX_HALT=1` checked by `iterate.sh` and `land.sh`. `ESCALATE` after 2 consecutive failures, halt after 3 |
| Ask Contract | G12 and `[gate:human]` halts ask what / what it does / why / risks |

**Enforcement point:** `checkpoint.sh complete` refuses to check off a non-gate task unless all of the following bind to the worktree's current `HEAD`:

1. a green-gate result of PASS or SKIPPED
2. an `APPROVE` review, unless `--skip-review "<reason>"`
3. for Tier C, a recorded human G12 approval, which `--skip-review` never waives

`land.sh` refuses to auto-commit stray worktree changes and re-runs the gate on the final head.

### Checkpoint schema additions

`harness`, `consecutive_failures`, `tiers{line→{tier,since}}`, `reviews{line→{sha,verdict,reviewer,round}}`, `approvals{line→{gate,sha,phrase}}`, and `skipped_reviews`. Gate results live in `<state-dir>/gate/{baseline,last}.json`, and failure counts in `<state-dir>/failures.json`.

### Namespace

Adds the sub-key `apex-scope-loop:lessons/<tag>` for ratchet lessons mirrored to memory. The canonical ledger is the tracked file `.claude/apex-scope-loop/LESSONS.md` (override: `APEX_LESSONS_FILE`).

### Smoke contract additions

11. `agents/gibson-reviewer.md` exists with `name: gibson-reviewer` and a `model:` line, and requires a final `VERDICT:` line
12. `green-gate.sh`, `risk-tier.sh`, and `lessons.sh` exist, and `NOTICE` credits The Gibson
13. This ADR-0002 exists with `Status: Proposed`

### Not adopted

- Cross-vendor runner routing and Devin merge captain. The reviewer is a fresh-context subagent, which is weaker than The Gibson's different-session fallback, and the docs say so.
- GitHub claims and labels
- CI templates, DCO, and branch protection
- UX eval and the eight-layer security scan. Express these as plan tasks, or run The Gibson's own `gibson-setup` against the target repo.

## Consequences

### Positive

- A plan can no longer check off code that only its own builders have looked at, or that regressed a previously green step.
- Risky surfaces get a human decision, framed in plain language, before they land.
- Repeated failures become durable lessons instead of repeated spend.
- Repos already wired for The Gibson (`.agents/gate.json`, `gibson/HALT`) interoperate with no extra config.

### Negative

- Each task now costs at least one extra agent (the reviewer), and Tier C costs about seven. Opt out per run with `APEX_GIBSON=0`.
- The tier classifier is heuristic and biased toward C, so false positives cost a human click. Tier only ratchets upward, so a reviewer who disagrees must say so in the review, and the human decides.
- A repo with no gate commands gets `GATE: SKIPPED`. That's truthful, but it's weaker than a configured gate.

### Neutral

- License: the Gibson concepts are re-implemented, not copied, and `NOTICE` credits the Apache-2.0 source.

## Status changes

- 2026-09-27 — Proposed (initial Gibson harness integration, plugin v0.2.0)
