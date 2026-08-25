# apex-dev-harness — design

**Date:** 2026-08-24 · **Status:** approved for planning · **Target repo:** `/mnt/c/Dev/Apex-APP-SW/apex-app`

## Problem

apex-app's governance is mature and correct. It is also, in three specific ways, unenforceable
by the agents it governs.

1. **The hooks are Windows-only.** `.claude/hooks/` ships `.cmd` + `.ps1` pairs with exactly one
   `.sh`. `block-sensitive-files`, `quality-style-check`, and `studio-manifest-check` silently
   no-op for any developer on macOS, Linux, or WSL. The guardrails are off for part of the team
   and nothing says so.
2. **The routing knowledge is 34KB of prose.** Which lane a module is in, whether a surface is
   Studio-canonical or legacy-canonical, which MWG browser target applies, which skills are
   mandatory — all correct, none queryable. An agent that skims `CLAUDE.md` gets it wrong
   silently, and the expensive failure is building a feature in the wrong surface.
3. **Nothing computes what a diff owes.** The Studio alignment harness documents two
   regeneration commands and six guard suites. Remembering which of them a given change
   obligates is left to the agent.

The harness introduces **no new rules**. It makes the existing ones deterministic, cross-platform,
and queryable.

## Non-goals

- Replacing `decide-plan-loop`, `dev-plan-loop`, or the `architecture-decision-*` skills. The
  harness composes with them.
- Copying or vendoring apex-app's 21 skills. They stay in the repo; the harness routes to them.
- Reimplementing any existing check. The harness shells out to the repo's own scripts.
- Governing repos other than apex-app. Generality is not a goal for v1.

## Architecture

One engine, three transports.

```
        ┌─────────────────────────────────────────┐
        │  apex-dev-harness (npm) — THE ENGINE    │
        │  route · obligations · gate · check     │
        └───────────────┬─────────────────────────┘
                        │ reads live, never vendors
        ┌───────────────┴───────────────────────────────┐
        │ tools/repo-lanes/lanes.json                   │
        │ .claude/tasks/apex-studio-surface-ledger.md   │
        │ .harness/policy.json  ← the only NEW truth    │
        └───────────────────────────────────────────────┘
                        │
     ┌──────────────────┼──────────────────┐
     ▼                  ▼                  ▼
  Node hooks         MCP server        Plugin cmds
  (enforce)          (ask anytime)     (/apex:build …)
```

All logic lives in the engine. Hooks, MCP, and slash commands are thin transports over the same
functions, so a verdict cannot differ by the door you came through.

### Units

| Unit | Purpose | Depends on |
|---|---|---|
| `truth/lanes.ts` | Parse `lanes.json` → module lanes + import guards | lanes.json |
| `truth/ledger.ts` | Parse the surface ledger markdown → surface rows | ledger .md |
| `truth/policy.ts` | Load `.harness/policy.json` → rules, obligations, watchlist | policy.json |
| `route.ts` | path/route → `RouteVerdict` | the three above |
| `obligations.ts` | diff → `Obligation[]` | policy, lanes, ledger |
| `gate.ts` | run obligations, collect results → `GateVerdict` | obligations, child_process |
| `check.ts` | one file + proposed content → `allow` / `deny` | policy, lanes |
| `watchlist.ts` | text → watchlist hits | policy |

Each is independently testable against fixtures and has no knowledge of its transport.

## Truth sources

Read **live** from the repo on every invocation. No vendored snapshots — a stale copy of a lane
table is worse than no lane table.

### `tools/repo-lanes/lanes.json` (verified)

```
version, updated, adr, laneDefs, governedRoots, modules[54], importGuards[]
modules[]     : { path, lane, owner?, replacement?, canonicalDoc?, since?, notes? }
importGuards[]: { id, namespace, language, internalExempt[], allow[{file, reason}] }
```

Lane lookup is longest-prefix match on `path`. A file under no governed root has lane `ungoverned`
— a distinct verdict, not `production`.

### `.claude/tasks/apex-studio-surface-ledger.md` (verified parseable)

Markdown tables, `| Surface | Routes | Status | Notes |`, status bolded as `**STUDIO**`, `**DUAL**`,
`**LEGACY**`, `**OOS**`, or `**RETIRED**`, sometimes followed by an owner-ruling date.

A throwaway parser extracted **106 rows** (52 STUDIO · 23 DUAL · 16 LEGACY · 12 RETIRED · 3 OOS);
9 rows carry a surface name with no route pattern and are name-matchable only. Note the ledger's
own header tally says 85 rows — **the ledger's stated count is stale**, which the harness should
report rather than silently accept.

Route matching: extract backticked route patterns and `/path` tokens from the Routes cell, match
the query path or route against them, longest-match wins.

### `.harness/policy.json` (new, lives in apex-app)

The only new truth. Exists so the block/warn split is data, not code.

```jsonc
{
  "version": 1,
  "rules": [
    { "id": "BOUND-005", "tier": "block", "scope": "repo",
      "check": "no-dotenv-files", "source": ".agents/rules/boundaries.md" },
    { "id": "BOUND-004", "tier": "block", "scope": "backend/agentic/",
      "check": "no-provider-sdk-import", "source": ".agents/rules/boundaries.md" },
    { "id": "BOUND-001", "tier": "historical", "scope": "backend/agentic/",
      "note": "Repo-wide isolation clause governed the AgentLoop framework deleted 2026-07-05 (ADR-002). Not enforced repo-wide; blocking on it would block nearly all work." }
  ],
  "obligations": [
    { "id": "studio-manifest",
      "when": { "anyPathMatches": ["backend/app/routes/studio_chat.py", "backend/agentic/core/mutations/registry.py", "backend/app/routes/studio_adapters/**", "backend/app/routes/studio_rest_write_exceptions.py", "ui/src/apexStudio/views/registry.js", "ui/src/apexStudio/rail/navDirective.js"] },
      "run": ["cd backend && python -m scripts.gen_studio_capability_manifest --check"] }
  ],
  "watchlist": ["quick fix", "for now", "tests coming later", "good enough", "small change", "for consistency", "just using"]
}
```

### Failure behavior

| Situation | Behavior |
|---|---|
| Truth file missing | Warn, continue with reduced verdict. Never hard-fail. |
| Truth file unparseable | Warn naming the file, continue. Never hard-fail. |
| Surface has no ledger row | Verdict `no-row` — "the ledger has a bug; add the row, don't guess". Explicitly **not** a guess and **not** an error. |
| Hook internal error | Fail open (emit `{}`, allow the edit). A harness bug must never wedge editing. |

The distinction between `no-row` and `unparseable` is load-bearing: the first is a finding about
the repo, the second a finding about the harness.

## Commands

### `apex route <path-or-route>`

```
$ apex route ui/src/marketing/CampaignCockpit.jsx
lane        production
surface     Marketing zone — Campaigns  ·  DUAL
routing     New features → Studio side. Fixes → where the bug lives.
            Behavior changes must keep both sides consistent.
mwg         Baseline Newly Available (apex-app SaaS surface)
skills      awesome-design (before AND after), modern-web-guidance
parity      admin desktop ↔ mobile · roles: super/org/venue
imports     ui/src/quizBuilder is LEGACY — this file is a grandfathered
            importer (listQuizzes). Do not add new imports.
```

`--json` for machine consumers (MCP, hooks).

### `apex gate [--phase <n>] [--base <ref>]`

Computes obligations from `git diff` and runs them.

```
$ apex gate
diff touches 3 capability surfaces → manifest regeneration REQUIRED
  ✗ python -m scripts.gen_studio_capability_manifest --check   STALE
  ✗ tools/stack-map/extract_capability.py --check              STALE
  ✓ ui/scripts/check-style-generators.js
  ✗ pytest app/routes/tests/test_studio_capability_manifest.py FAILED
parity      touched MenuManagerPage.jsx — portal twin unchanged. Verify or state why.
watchlist   "for now" in commit message (BOUND-006)
VERDICT     NOT DONE — 3 obligations unmet
```

Exit 0 when every obligation passes, 1 otherwise. All five wrapped commands verified present in
apex-app today:

| Obligation | Command |
|---|---|
| Capability manifest | `cd backend && python -m scripts.gen_studio_capability_manifest --check` |
| Stack map | `python tools/stack-map/extract_capability.py --check` |
| UI style generators | `node ui/scripts/check-style-generators.js` |
| Studio guard suites | `pytest app/routes/tests/test_studio_{capability_manifest,write_read_parity,resolver_tenancy}.py` |
| Lane import guards | `pytest tools/repo-lanes/tests/` |

### `apex check <path> [--content -]`, `apex watchlist <file|->`, `apex doctor`

`check` is the block-tier evaluator the PreToolUse hook calls. `doctor` reports truth-file parse
coverage ("ledger: 106 rows parsed, 9 route-less; lanes: 54 modules"), which command wrappers
resolve, and whether the hooks are installed.

### `apex init [--force]`

Scaffolds `.claude/hooks/apex-hook.js` and `.harness/policy.json` into apex-app and prints the
`.claude/settings.json` hook entries to apply. Idempotent; never overwrites without `--force`.
This is what produces the reviewable PR described under Packaging.

### `/apex:status`

Plugin-side only. Prints the current orientation: active lane/surface for the working diff,
outstanding obligations from the last `gate` run, and any in-flight partner sessions from the
agent-coordination registry. A read-only summary — it runs no wrapped commands.

## Enforcement tiers

| Tier | Check | Scope |
|---|---|---|
| **block** | `.env*` file creation | repo |
| **block** | credential literals / `os.getenv` for secret-shaped keys | repo |
| **block** | edit to a RETIRED-lane module | repo |
| **block** | new import of a legacy namespace absent from the grandfathered allowlist | repo |
| **block** | read or write of `projectDataJson` | repo |
| **block** | direct LLM provider SDK import | `backend/agentic/` |
| **warn** | building in a legacy twin when the ledger row says STUDIO | repo |
| **warn** | missing parity surface | repo |
| **warn** | MWG target mismatch | web-platform files |
| **warn** | watchlist vocabulary | reports, commit messages |
| **warn** | stale capability manifest | capability surfaces |

### `.agents/rules` scoping (owner-ruled 2026-08-24)

The secrets rules (ARCH-002, BOUND-002, BOUND-005) enforce repo-wide, matching what
`block-sensitive-files` does today. The isolation, venue-scope, and provider-abstraction rules
(ARCH-001, ARCH-003, ARCH-004, ARCH-005, BOUND-001) are scoped to `backend/agentic/`.

**Verified:** `ui/src/agentic/` no longer exists as code — the directory holds one stale
`.understand-anything` folder and is entirely untracked by git, confirming CLAUDE.md's record of
the 2026-07-05 deletion. It is therefore dropped from the scope, not carried forward.

BOUND-001's repo-wide clause is recorded in `policy.json` with `tier: "historical"` and a note
explaining why, so the reasoning stays visible instead of being silently dropped.

## Hooks

One shim, `.claude/hooks/apex-hook.js`, dispatched by phase. Registered as
`node .claude/hooks/apex-hook.js <phase>` — one settings.json entry that works on Windows, WSL,
macOS, and Linux.

| Phase | Matcher | Behavior |
|---|---|---|
| PreToolUse | `Edit\|Write\|MultiEdit` | `check` — block tier |
| PostToolUse | `Edit\|Write\|MultiEdit` | style check + manifest check + lane/surface warn |
| SessionStart | — | agent-coordination preamble + durable inbox (port of the existing script) |
| UserPromptSubmit | — | agent-coordination heartbeat |
| Stop | — | `session-handoff.py` (kept as-is, already cross-platform) + gate reminder |

### Output protocol (non-negotiable)

Always print a JSON object on stdout: `{}` to allow,
`{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"..."}}` to block.

This is honored by both Claude Code and Cursor. `block-sensitive-files.ps1` records the incident
that makes it non-negotiable: on 2026-07-04, empty stdout made Cursor treat the hook as broken and
block **every** Edit/Write in the workspace. Any internal error emits `{}` and exits 0.

Hooks must also stay silent on the happy path — a hook that prints on every edit trains people to
ignore it.

## Lifecycle — `/apex:build`

Sits on top of apex-plan-loop rather than replacing it.

```
/apex:build "add sequence A/B testing to outreach"
  1 ORIENT   engine routes the ask → lane · surface · skills · parity · obligations
             + agent-coordination check: is a partner already on this?
  2 DECIDE   non-trivial → decide-plan-loop (ADR + phased plan)
             bounded    → skip to 3
  3 EXECUTE  dev-plan-loop /iterate, one phase at a time
  4 GATE     `apex gate` on THAT PHASE's diff — a phase cannot close on prose
  5 DONE     parity enumeration + watchlist + full gate
```

The integration's whole point is step 4. Today a phase closes when the agent says it is done; here
it closes when computed obligations pass. That is the one thing apex-plan-loop cannot do alone,
because it does not know what a diff owes.

Triviality routing at step 2 uses the `decide-plan-loop` skill's own criteria (≥3 phases, crosses
a bounded context, needs a durable record), not a new heuristic.

## Packaging

**npm `apex-dev-harness`** — engine, CLI, MCP server. The reusable core; callable from CI,
pre-commit, and Cursor.

**Plugin `apex-dev-harness`** in the Apex-Dev-Skills marketplace, alongside `apex-plan-loop`:

- commands: `/apex:route`, `/apex:gate`, `/apex:build`, `/apex:status`
- skills: `apex-orientation` (the "where does this go" discipline), `apex-done-gate`
- hooks: the shim + settings snippet
- declares its relationship to `apex-plan-loop` in the README (Claude Code plugins have no
  dependency mechanism, so this is documentation, not enforcement)

### What lands in apex-app (a reviewable PR)

| File | Change |
|---|---|
| `.claude/hooks/apex-hook.js` | new — thin shim delegating to the engine |
| `.claude/settings.json` | hook entries switch to `node .claude/hooks/apex-hook.js <phase>` |
| `.harness/policy.json` | new — rule/obligation/watchlist table |
| `.claude/hooks/*.ps1`, `*.cmd` | superseded; deleted in the same PR |
| `.claude/hooks/session-handoff.py` | kept unchanged |

Nothing switches on until that PR merges. `init` is idempotent and never overwrites without
`--force`.

## Testing

| Layer | Approach |
|---|---|
| Truth parsers | Fixtures snapshotted from the real files. Fixtures are for **parser tests only** — runtime always reads live. |
| `route` | Golden table: known path → expected verdict, including a `no-row` case and an `ungoverned` case. |
| `obligations` | Synthetic diffs → expected obligation set. Explicitly covers "capability surface touched" and "nothing owed". |
| `gate` | Command runner stubbed; asserts exit codes and verdict aggregation. |
| Hooks | Feed the documented JSON on stdin, assert exact stdout shape for allow, deny, and internal-error paths. |
| Cross-platform | Path normalization tests with both separators; no shell-specific invocation. |
| End-to-end | Install the tarball into a scratch dir, run `init` + `doctor` + `route` + `gate`, same gate used for `apex-app-harness`. |

## Risks

| Risk | Mitigation |
|---|---|
| Ledger parser drifts as the ledger is edited | Fail open; `doctor` reports parse coverage so drift is visible before it misleads |
| A wrong block wedges a developer | Block tier is small, mechanical, and data-driven; every block names its rule and its source file |
| Harness becomes a second source of truth | It reads live and wraps existing commands; the only new file is `policy.json`, which holds policy, not facts |
| Hook latency on every edit | Block-tier checks are pure path/content matching; the expensive wrapped commands run only in `gate` |
| Windows regression | Node hooks + path normalization tests; the `.ps1` deletion and the Node switch land in one PR so no platform runs both |

## Open questions for the owner

1. **Is the ledger's stated tally worth fixing?** Its header says 85 rows; a parser finds 106.
   The harness can report the drift; correcting the doc is an owner edit.
2. **Should `apex gate` run in CI**, or stay a local pre-done check? The wrapped commands already
   have CI gates (`studio-alignment.yml`), so CI use would be for the parity and watchlist tiers only.
3. **Which of ARCH-003 / ARCH-004 / ARCH-005** should be block rather than warn inside
   `backend/agentic/`? The design starts them at block for provider-SDK imports only.
