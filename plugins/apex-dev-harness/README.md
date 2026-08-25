# apex-dev-harness

Makes apex-app's governance mechanical: lanes and the surface ledger become a query, the guardrails run on every platform, and a phase closes on computed obligations instead of prose.

## Install

```bash
/plugin install apex-dev-harness    # the Claude Code surface — carries its own engine
```

That's it for `/apex:route`, `/apex:gate`, `/apex:build`, `/apex:status`, and the
`PreToolUse`/`PostToolUse` guardrail hooks — the plugin bundles the engine (`dist/`, `bin/`,
`templates/`) under `engine/` and wires the hooks itself via `hooks/hooks.json`. No npm install
and no `apex init` are needed for any of that.

You only need the npm package separately if you want:

```bash
npm install -g apex-dev-harness     # `apex mcp start`, or the `apex` CLI from anywhere
```

The bundled engine excludes `dist/mcp/` (it is the only part that needs the
`@modelcontextprotocol/sdk` dependency); `apex mcp start` requires the npm package.

## Commands

| Command | What it does |
|---|---|
| `/apex:route <path>` | Where does this work go? |
| `/apex:gate` | What does this diff owe? |
| `/apex:build <ask>` | Orient, decide, execute, gate, done |
| `/apex:status` | Read-only orientation |

## Relationship to apex-scope-loop

`/apex:build` step 2 hands non-trivial work to `apex-plan`, and step 3 executes it with
`apex-execute` — both from the **apex-scope-loop** plugin. Install it alongside this one. Claude Code
plugins have no dependency mechanism, so this is documentation, not enforcement: without
apex-scope-loop, `/apex:build` still orients and gates, but has no planner to hand off to.
