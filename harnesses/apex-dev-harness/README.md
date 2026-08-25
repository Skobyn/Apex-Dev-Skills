# apex-dev-harness

A routing and gate engine for the apex-app codebase. It reads apex-app's own
truth files — `tools/repo-lanes/lanes.json`, the surface ledger at
`.claude/tasks/apex-studio-surface-ledger.md`, and `.agents/rules/*.md` — and
answers three questions on demand:

- **`apex route <path|route>`** — what applies here: lane, surface status,
  the ledger's routing sentence, in-scope rules, and any surface-parity
  warning.
- **`apex check <path>`** — block-tier decision for one pending edit
  (`allow` or `deny [RULE-ID] reason`), used by the Claude Code hook.
- **`apex gate [--base <ref>]`** — what a diff owes: the obligations it
  triggers, and (unless `--dry-run`) the real commands run to prove them.

It also ships `apex doctor` (what the harness can see, and what it can't),
`apex init` (installs the hook shim and policy into an apex-app checkout),
`apex watchlist` (BOUND-006 vocabulary scan), and `apex mcp start` (the same
engine exposed as an MCP stdio server).

## Install

```bash
npm install apex-dev-harness
```

Or run it without installing, from inside (or pointed at) an apex-app
checkout:

```bash
npx apex doctor
```

Set `APEX_REPO_ROOT` to point the CLI at a checkout when it isn't run from
inside one:

```bash
APEX_REPO_ROOT=/path/to/apex-app npx apex route ui/src/marketing/CampaignCockpit.jsx
```

## Commands

| Command | What it does |
|---|---|
| `apex route <path\|route>` | Lane, surface status, the ledger's routing sentence, in-scope rules, and any parity warning for a path or a `/route` |
| `apex check <path> [--content -]` | Block-tier allow/deny decision for one edit — what the pre-tool-use hook calls |
| `apex gate [--base <ref>] [--message <text>] [--paths a,b]` | Computes the obligations a diff owes and runs the commands that prove them |
| `apex gate --dry-run` | Same computation, but lists the obligations and the commands each would run without executing anything |
| `apex watchlist <file\|->` | BOUND-006 vocabulary scan over a file or stdin |
| `apex doctor` | Reports what the harness can see: truth files, wrapped commands on disk, hook install state |
| `apex init [--force]` | Installs `.claude/hooks/apex-hook.js` and `.harness/policy.json` into an apex-app checkout, and prints the `.claude/settings.json` snippet to wire it in |
| `apex mcp start` | Runs the same route/gate/check/doctor engine as an MCP stdio server |

Add `--json` to `route`, `gate`, or `check` for machine-readable output.

## What this does not do

- **It introduces no new rules.** Every block, warn, and obligation the
  engine enforces is read from apex-app's own `.agents/rules/*.md`,
  `tools/repo-lanes/lanes.json`, `.harness/policy.json`, and the surface
  ledger. The harness composes and evaluates that truth; it does not author
  policy of its own.
- **The ledger is read live, never remembered.** Every `route` and `gate`
  call re-parses the surface ledger and lane data from disk at call time.
  There is no cache, snapshot, or embedded copy that could drift from the
  files in the checkout.
- **`no-row` is a finding, not a guess.** When a query matches no ledger row
  and no curated surface hint, the harness reports that plainly rather than
  inferring a status. It does not pattern-match its way to an answer the
  data doesn't support.
- **Every wrapped check belongs to apex-app, not to the harness.** `apex
  gate` shells out to apex-app's own pytest suites, capability-manifest
  generators, and style checkers. The harness does not reimplement or
  approximate what those commands verify — it runs the real ones and
  reports what they said, including when they fail for an environment
  reason (a missing venv, absent `node_modules`).

## License

MIT — see [LICENSE](./LICENSE).
