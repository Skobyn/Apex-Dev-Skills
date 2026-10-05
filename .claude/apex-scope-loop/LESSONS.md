# apex-scope-loop Lessons (append-only)

Filed by the apex-execute loop when a failure repeats (the ratchet — adapted
from The Gibson, Law 9). Newest last. Never rewrite another entry; supersede it
with a new one.

## L-001 · 2026-10-05 · hand-written-markdown-parser-vs-renderers
**What happened:** Phase 1.2 failed three attempts (9 review rounds): each round an adversarial reviewer found a plan that passes planlib validate while a markdown renderer shows a task differently (fences, HTML blocks, comments, empty list markers, Unicode whitespace, raw HTML in containers)
**Root cause:** planlib emulated CommonMark block state; any construct it did not model let the parsed plan and the rendered plan disagree, and patching one construct per round never converged
**Harness fix:** Define plans as a verified dialect and refuse everything outside it; prove soundness against the renderers with a differential fuzz (commonmark.js, markdown-it, cmark-gfm) before review instead of after; raw HTML must be refused everywhere outside fenced code
**Plan:** apex-dispatch-plan.md
**Tags:** #planlib #parser #markdown #backend

## L-002 · 2026-10-05 · per-task-state-keyed-by-line-leaks
**What happened:** Phase 1.4 failed two attempts (6 review rounds): each fix to the risk-tier diff base and gate exemption (per-line since, per-line base, line-keyed tiers) left a way to classify a task's code from a base chosen after it, or to exempt code under a gate line
**Root cause:** the diff base was caller-chosen and keyed by plan line number, so commits between tasks, retries, rebases and moved lines fell outside every task's diff; gate exemption trusted the line's kind rather than the code
**Harness fix:** Make the task diff a chain: the floor is the head at the last complete (else the fork point), every commit after it belongs to the current task, --since may only widen it, an unreachable floor falls back to merge-base; a gate line is exempt only when no code exists since the floor; classifiers search the original string (no length-changing transforms before indexing)
**Plan:** apex-dispatch-plan.md
**Tags:** ##risk-tier #harness #backend #gate
