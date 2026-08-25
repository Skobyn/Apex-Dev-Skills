---
name: apex-orientation
description: Use before building or extending ANY operator-facing surface in apex-app, and before claiming any apex-app change is done. Routes the work to its canonical home via the lanes registry and the surface ledger, names the mandatory skills and parity surfaces, and computes what the diff owes. Triggers - "where does this go", "build a page", "add a feature", "is this done", "extend the UI", any edit under ui/src or backend/app.
---

# Apex orientation

Two questions have mechanical answers in this repo. Never answer them from memory.

## Before you build: where does this go?

```bash
apex route <path-or-route>
```

The verdict composes three sources you must not second-guess:

- **`tools/repo-lanes/lanes.json`** — the module's lane. `legacy` means do not build new features there. `retired` means do not touch it.
- **`.claude/tasks/apex-studio-surface-ledger.md`** — the surface's canonical home today. A `no row` verdict means the ledger has a bug: **add the row, do not guess the status.** Flipping a row is an owner decision, recorded with a date — a Studio build shipping does not auto-flip anything.
- **`.harness/policy.json`** — the MWG browser target, the mandatory skills, and the parity surfaces.

Invoke every skill named before writing code. For UI work that means `awesome-design` **before and after**, plus `modern-web-guidance` for any web-platform primitive.

## Before you claim done: what does this owe?

```bash
apex gate --message "<your completion report>"
```

This computes obligations from the actual diff — manifest regeneration, Studio guard suites, style generators, import guards — runs them, and returns a verdict. `NOT DONE` means the work is not done, regardless of how complete it feels.

A guard failure is a real drift, not a flaky test.

## What this skill will not do

It will not tell you a surface's status when the ledger has no row, and it will not infer one from a neighbouring row. That gap is a finding to report, not a blank to fill.
