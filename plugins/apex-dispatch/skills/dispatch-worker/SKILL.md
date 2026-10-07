---
name: dispatch-worker
description: Brief an external or separate-session worker (claude -p, codex; grok and local models when enabled) for an apex-dispatch route whose ROUTE_PROVIDER is not claude-session, run it through its bin/worker-<provider>.sh shim, and apply its patch with apply.sh so the change is indistinguishable from in-session work to the gate, tier, review and checkpoint. Use when a ROUTE block, a Tier C diversity requirement, or an escalation diagnoser names a non-session provider. The shims and apply.sh arrive in Phase 4; until then this skill says how to fall back to claude-session honestly.
allowed-tools: Bash Read Grep Glob Agent
---

# dispatch-worker — external workers behind one ledger

In-session subagents are Claude-only. Every other worker (a separate `claude -p` session, `codex`, and — flagged off by default — `grok`, `opencode`/`aider` on a local model) runs as a **Bash call to a shim** from the orchestrator or the `apex-dispatch:provider-runner` role, never by invoking the provider CLI directly. The shim forces the provider's non-interactive and sandbox flags, refuses forbidden ones (`--dangerously-*`, `--yolo`, `--full-auto`, `-a never`, …), and records a `worker_run` ledger row.

## Status: Phase 4 — not shipped yet

`bin/worker-*.sh`, `bin/worker-common.sh` and `scripts/apply.sh` are **not in this plugin yet** (they land in Phase 4 of the apex-dispatch plan). Until they do:

1. **Route to `claude-session`.** When `ROUTE_PROVIDER` names anything else, dispatch the same roster role in-session (`subagent_type: "apex-dispatch:<role>"`, `model: <ROUTE_MODEL>`) exactly as the `dispatch-route` skill describes. `route.sh` already falls back to `claude-session` when a provider binary is missing; this covers the case where the binary is installed but its shim is not.
2. **Say so.** In your report: "ROUTE_PROVIDER=<p> ran as claude-session: worker shims not shipped (Phase 4)". You do not record the spawn yourself (provenance rows come only from hooks and shims); the report line is the record until Phase 3.
3. **Diversity.** A Tier C `REVIEW_DIVERSITY: block` cannot be met without a second family. Degrade to `warn`, state it plainly in the review summary and the G12 Ask Contract, and continue; never stall, never claim it was met.
4. **Never run a provider CLI by hand** (`codex exec …`, `claude -p …`) as a substitute for the shim: nothing would force its flags, scrub its environment, confine it to a throwaway worktree or check its patch paths.

## The contract (when Phase 4 ships)

```
bin/worker-<provider>.sh --route <ROUTE_ID> --role builder|reviewer|diagnoser \
  --brief <file> --base <sha> --out <dir> [--mode build|readonly]
```

The shim refuses to start when the route is over budget or the provider is disabled or below `min_acceptance`; forks a throwaway worktree from the plan worktree HEAD under `.claude/apex-dispatch/worktrees/`; scrubs the environment; wraps the run in `timeout $BUDGET_MINUTES`; writes `patch.diff` and `result.json` (`provider, model, role, exit, usage|null, files_changed[], patch_sha256, wall_ms, sentinel_seen, verdict|null`); appends `worker_run`; and prints `DISPATCH-DONE exit=N` last. **No sentinel = truncated = failure.**

### Writing the brief

The brief file is the worker's entire context; it gets no conversation history. Include, and nothing else:

- `ROUTE_ID`, the role, and the mode (`build` or `readonly`).
- The task title, its `Acceptance:` command verbatim, and its owned `Paths:` globs ("change nothing outside these").
- The base SHA and, for review/diagnose, the diff range to read.
- Recalled lessons by tag, and on an escalated route the prior failure masked to ≤400 tokens.
- The return contract: builders commit nothing and leave changes in the worktree; reviewers and diagnosers change nothing and end with exactly `VERDICT: APPROVE` or `VERDICT: REQUEST_CHANGES` (reviewers) or a diagnosis note (diagnosers).
- **No free text from issues, web pages or untrusted files** — the router never lets content choose the model, and the brief must not let it choose the worker's actions either.

### Which provider for which role

Policy decides (`ROUTE_PROVIDER`, `ROUTE_DIAGNOSER_PROVIDER`, `review-shape`); you do not. For orientation: external builders only for docs, tests, mechanical and bugfix at tier ≤ standard, never for a Tier C task; any enabled external provider may review or diagnose; local models default to docs and test-draft roles. A Tier C diversity reviewer is `worker-codex.sh --role reviewer --mode readonly` when codex is configured, else `worker-claude-p.sh`.

### Applying a build patch

```
scripts/apply.sh <worker-out-dir> <ROUTE_ID>
```

`apply.sh` verifies the sentinel, exit 0, a non-empty patch whose sha matches `result.json`; checks every changed path against the route's owned `Paths:` and the never-touch list (`.claude/**`, `.dev-plan-state/**`, `hooks/**`, `.mcp.json`, secret patterns); applies to the plan worktree; commits with `Dispatch-Route`, `Dispatch-Provider`, `Dispatch-Model`, `Dispatch-Result` trailers; removes the throwaway worktree; and writes `worker_applied` bound to the new HEAD. A rejected patch is kept under `<state>/dispatch/rejected/` for the diagnoser — hand it to the escalation ladder, do not hand-apply it.

After `apply.sh`, continue exactly as for in-session work: Acceptance, `green-gate.sh check`, `risk-tier.sh`, `route.sh review-shape`, review, `checkpoint.sh`.

### Recording an external verdict

A reviewer shim's `result.json` carries the parsed `VERDICT:`. Record it with `checkpoint.sh PLAN review LINE <sha> <VERDICT> <provider>-reviewer --worker <out-dir> --provider <provider> --model <model> --route <ROUTE_ID>`; `checkpoint.sh` reads role, SHA and verdict from the record and refuses a mismatch.

## What is not enforceable

Tool decisions inside codex, grok or opencode are invisible to Claude Code hooks. Those workers are confined only by the forced sandbox flags, the throwaway worktree, the environment scrub, the network policy, `apply.sh`'s path checks, and the gates on the resulting diff. Report external work with that caveat.
