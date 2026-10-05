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
