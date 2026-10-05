# ADR: apex-dispatch, apex-scope-loop 0.3.0, sibling hygiene

**Status**: Accepted
**Date**: 2026-10-05
**Spec**: [`docs/superpowers/specs/2026-10-05-apex-dispatch-design.md`](../../docs/superpowers/specs/2026-10-05-apex-dispatch-design.md) (the spec is the source of truth; this ADR records only the execution decisions)

## Context

The spec designs three things: apex-scope-loop 0.3.0 (portable, fixes the verified defects), a new `apex-dispatch` plugin (route + govern + ledger + provider shims), and hygiene fixes in sibling plugins. The user asked for the whole document to be executed through the apex-scope-loop as far as this environment allows.

## Decision

Execute spec §12 Phases 0–4 in this plan, plus the parts of Phase 5 that are code (`compile --target codex`). Phase 5's multi-week routed-vs-baseline measurement and Phase 6's optional mod adapter are out of scope for this run and are recorded as such in the final report.

Execution decisions:

**Q1. Where does the loop run?**
**Decision**: In an apex-scope-loop worktree forked from `claude/wonderful-einstein-jp4sof`, landed back into that branch, using the 0.2.0 scripts from the base checkout (the scripts being upgraded are not used to run their own upgrade).

---

**Q2. Gate commands?**
**Decision**: `APEX_GATE_TEST` runs every plugin's `scripts/smoke.sh`; `APEX_GATE_LINT` runs `bash -n` and `shellcheck -S error` (when installed) over changed shell files. No `.agents/gate.json` is committed.

---

**Q3. Review shape?**
**Decision**: Tier A: one independent reviewer. Tier B: one six-lens reviewer. Tier C: one six-lens reviewer plus one adversarial reviewer (a deliberate reduction from six per-lens reviewers, recorded here), then G12 from the user, bound to the head SHA.

---

**Q4. Review-shape corrections from the spec review (PR 13)?**
**Decision**: Applied during build: the REVIEW stage is written by `subagent-start.sh` (not by `pre-agent.sh`); `post-bash-prune.sh` stores full logs and adds a summary via `additionalContext` instead of rewriting output (command hooks cannot rewrite Bash output); the ledger is described as tamper-evident, not tamper-proof.

## Consequences

- External providers other than `claude -p` cannot be exercised live here (`codex`, `grok`, `opencode`, `aider` are not installed); their shims are tested against fake binaries in smoke and stay feature-flagged as the spec requires.
- ADR-0001 of apex-dispatch stays **Proposed** until Phase 0 spikes pass, as the spec requires.
