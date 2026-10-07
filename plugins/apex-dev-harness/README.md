# apex-dev-harness

> Routing and gate engine for apex-app: lanes + surface-ledger routing, cross-platform guardrails, and phases that close on computed obligations.

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
| `/apex:build <ask>` | Orient, decide, route, execute, gate, done |
| `/apex:status` | Read-only orientation |

## Policy overlay (0.3.0+)

`apex init` writes `.harness/policy.json` as a minimal **overlay**, not a
copy of the built-in policy — anything the file omits is inherited from the
engine's built-in rules and hints at read time, so updates to
`apex-dev-harness` reach an already-`init`-ed repo automatically. Turning a
rule or hint off requires the file's `disabled` block (with a `reason`);
simply deleting it from `policy.json` no longer works, since omission means
inherit, not remove. A repo whose `policy.json` predates 0.3.0 is a full
snapshot and is silently missing every rule/hint shipped since — run `apex
policy prune` to strip it down to genuinely local config (`apex doctor`
flags this on its own). See `docs/apex-dev-harness-integration.md` for the
full merge semantics.

Surface hints (`surfaceHints`) are curated and partial: they cover
route-mounted page files only, not components, hooks, services, or backend
code.

## Relationship to apex-scope-loop and apex-dispatch

`/apex:build` runs ORIENT → DECIDE → ROUTE → EXECUTE → GATE → DONE. Step 2 (DECIDE) hands
non-trivial work to the `apex-plan` skill and step 4 (EXECUTE) works it with `apex-execute` —
both are skills of the **apex-scope-loop** plugin, loaded from the installed plugin (no
`.claude/skills/` copy in the repo is assumed). Step 3 (ROUTE) uses **apex-dispatch** when it is
installed: `/apex-dispatch:run <plan>` (or `/apex-dispatch:route adhoc …` for a bounded ask)
picks the agent, model, provider, fan-out and review shape and its hooks enforce it.

Two routers, two questions:

- **`/apex:route`** = which apex-app **lane** (STUDIO / DUAL / LEGACY / RETIRED, surface ledger, parity surfaces).
- **`/apex-dispatch:route`** = which **agent / model / provider** does the work.

Install both plugins alongside this one. Claude Code plugins have no dependency mechanism, so this
is documentation, not enforcement: without apex-scope-loop, `/apex:build` still orients and gates
but has no planner to hand off to; without apex-dispatch it skips ROUTE and executes by the plan's
`Swarm:` directive.
