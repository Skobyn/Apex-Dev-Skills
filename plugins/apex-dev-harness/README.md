# apex-dev-harness

Makes apex-app's governance mechanical: lanes and the surface ledger become a query, the guardrails run on every platform, and a phase closes on computed obligations instead of prose.

## Install

```bash
npm install -g apex-dev-harness     # the engine
/plugin install apex-dev-harness    # the Claude Code surface
cd /path/to/apex-app && apex init   # the hooks + policy (review the PR it produces)
```

## Commands

| Command | What it does |
|---|---|
| `/apex:route <path>` | Where does this work go? |
| `/apex:gate` | What does this diff owe? |
| `/apex:build <ask>` | Orient, decide, execute, gate, done |
| `/apex:status` | Read-only orientation |

## Relationship to apex-plan-loop

`/apex:build` step 2 hands non-trivial work to `decide-plan-loop`, and step 3 executes it with
`dev-plan-loop` — both from the **apex-plan-loop** plugin. Install it alongside this one. Claude Code
plugins have no dependency mechanism, so this is documentation, not enforcement: without
apex-plan-loop, `/apex:build` still orients and gates, but has no planner to hand off to.
