# apex-dev-harness -> apex-app integration

This document is written for whoever reviews the PR that wires
`apex-dev-harness` into the `apex-app` repo. It is a description document,
not a PR — no branch was pushed and no PR was opened against `apex-app`.
Activating hooks in the product repo is the repo owner's call.

## The plugin is the primary delivery path

For anyone working in Claude Code, installing the `apex-dev-harness` plugin
is now the primary way to get the guardrails and commands into apex-app:
the plugin bundles its own copy of the engine under `engine/` and wires
`PreToolUse`/`PostToolUse` hooks itself via `hooks/hooks.json`
(`${CLAUDE_PLUGIN_ROOT}/engine/templates/apex-hook.js`). Installing the
plugin is sufficient on its own — **no `.claude/settings.json` edit and no
`apex init` are needed for plugin users.**

Everything below this section — the manual `.claude/settings.json` diff,
the npm-tarball install, deleting the `.ps1`/`.cmd` files — is the *manual*
path. It stays fully documented and supported for CI, Cursor, pre-commit
hooks, or any other context that isn't Claude Code loading the plugin.
The manual path's safety ordering is unchanged and must still be followed
in that order: install the engine, verify with `apex doctor`, only then
wire the hook and delete the superseded `.ps1`/`.cmd` files.

## Install prerequisite — read this before touching `.claude/settings.json`

The rest of this section applies to the **manual path** only (CI, Cursor,
pre-commit, or anywhere else the plugin isn't installed).

`apex-hook.js` resolves its engine by package specifier
(`import('apex-dev-harness/dist/…')`). If `apex-dev-harness` is not
installed as a dependency in the `apex-app` checkout, that import throws,
the hook's `main().catch()` swallows the error and prints `{}`, and every
guardrail silently allows everything — a false negative, not a crash, so
nothing in the transcript announces it happened.

Before you do anything else:

1. **Install the engine.** The package is not yet published to npm, so install it from a local
   tarball built out of this repo:

   ```bash
   cd /path/to/Apex-Dev-Skills/harnesses/apex-dev-harness
   npm install && npm run build && npm pack          # produces apex-dev-harness-0.1.0.tgz
   cd /path/to/apex-app
   npm i -D /path/to/Apex-Dev-Skills/harnesses/apex-dev-harness/apex-dev-harness-0.1.0.tgz
   ```

   Once `apex-dev-harness` is published, this becomes `npm i -D apex-dev-harness`.
2. Run `apex doctor`. Confirm its `hooks` section prints
   `ok    apex-dev-harness resolves from the project — the hook can load
   the engine`. If it instead warns that the package is NOT installed, stop
   — do not wire the hook or delete the `.ps1`/`.cmd` files yet.
3. Only after that line reads `ok` should you apply the
   `.claude/settings.json` diff below **and delete the six superseded
   `.ps1`/`.cmd` files in the same change.** Deleting them before the
   engine is proven to resolve leaves the repo with no working guardrails
   of either kind.

## What `apex init` writes

Running `npx apex init` from inside an `apex-app` checkout (with
`apex-dev-harness` installed as a dependency, or run via `npx`) writes two
files, and skips anything already present unless `--force` is passed:

| Writes | From |
|---|---|
| `.claude/hooks/apex-hook.js` | `apex-dev-harness/templates/apex-hook.js` |
| `.harness/policy.json` | `apex-dev-harness/templates/policy.json` |

`apex-hook.js` is a single Node file invoked three ways —
`pre-tool-use`, `post-tool-use`, `session-start` — chosen by the hook
matcher in `.claude/settings.json`. It always prints exactly one JSON object
on stdout and fails open (`{}`, i.e. allow) on any internal error, because a
harness bug must never block editing outright. `.harness/policy.json` is a
starting policy (rules + obligations) that `doctor` and `gate` read; the repo
can edit it in place once it's confirmed to be the right starting set.

`init` does not touch `.claude/settings.json` — it prints the snippet below
for a human to apply.

## The exact `.claude/settings.json` diff

Today's `PreToolUse`/`PostToolUse` blocks:

```json
  "PreToolUse": [
    {
      "matcher": "Edit|Write|MultiEdit",
      "hooks": [
        { "type": "command", "command": "powershell -NoProfile -ExecutionPolicy Bypass -File .claude/hooks/block-sensitive-files.ps1" }
      ]
    }
  ],
  "PostToolUse": [
    {
      "matcher": "Edit|Write|MultiEdit",
      "hooks": [
        { "type": "command", "command": "cmd //c \".claude\\hooks\\studio-manifest-check.cmd\"" },
        { "type": "command", "command": "cmd //c \".claude\\hooks\\quality-style-check.cmd\"" }
      ]
    }
  ]
```

become:

```json
  "PreToolUse": [
    {
      "matcher": "Edit|Write|MultiEdit",
      "hooks": [
        { "type": "command", "command": "node .claude/hooks/apex-hook.js pre-tool-use" }
      ]
    }
  ],
  "PostToolUse": [
    {
      "matcher": "Edit|Write|MultiEdit",
      "hooks": [
        { "type": "command", "command": "node .claude/hooks/apex-hook.js post-tool-use" }
      ]
    }
  ]
```

`SessionStart` gains one additional hook entry alongside the existing
`agent-coord-session-start.cmd` (order doesn't matter — Claude Code runs all
matched hooks for an event):

```json
  "SessionStart": [
    {
      "matcher": "",
      "hooks": [
        { "type": "command", "command": "cmd //c \".claude\\hooks\\agent-coord-session-start.cmd\"" },
        { "type": "command", "command": "node .claude/hooks/apex-hook.js session-start" }
      ]
    }
  ],
```

Everything else in `.claude/settings.json` — `UserPromptSubmit`, `Stop`,
`SessionEnd`, `permissions` — is untouched.

## Which `.ps1`/`.cmd` hooks this supersedes, and why

`apex-hook.js` supersedes exactly the three pairs wired to
`PreToolUse`/`PostToolUse` today:

- `block-sensitive-files.ps1` / `.cmd`
- `studio-manifest-check.ps1` / `.cmd`
- `quality-style-check.ps1` / `.cmd`

These are PowerShell scripts (or `.cmd` wrappers that invoke them) — they
no-op on macOS, Linux, and WSL today, which is exactly the gap
`apex-dev-harness` closes: `apex-hook.js` is a cross-platform Node script
that runs identically everywhere Node runs, dispatching to the same
`check`/`route`/`gate` engine the `apex` CLI uses directly. **Once, and only
once, `apex doctor` in the target checkout reports that `apex-dev-harness`
resolves** (see the install prerequisite at the top of this document), the
six `.ps1`/`.cmd` files can be deleted; the PR that flips the settings
should delete them in the same change so there is no window where both are
wired in and could disagree. Flipping the settings, or deleting the
`.ps1`/`.cmd` files, before that `doctor` check passes leaves the repo with
neither the old scripts nor a working new hook — the hook fails open and
nothing enforces anything.

**`agent-coord-*` hooks are out of scope.** They handle multi-agent session
coordination, not code-quality/boundary gating, and are unrelated to what
`apex-dev-harness` does. They are left exactly as they are.

**`session-handoff.py` (and its `session-handoff.cmd` wrapper) is kept
unchanged.** It writes `.claude/handoff/<session_id>.md` on the `Stop` event
and has nothing to do with routing, lanes, or gating — it is not superseded
and this integration does not touch it.

## Findings from the build (for the reviewer)

1. **The surface ledger's own header tally is stale.** The ledger's header
   states the count explicitly: "(+1 `DEV/ENGINE TOOL` — the IR-editor row —
   outside the five buckets; **85 table rows** total)". But
   `apex-dev-harness`'s parser — which reads every `|`-delimited row under
   every `## ` section, not just the ones a human last recounted — finds
   **110** rows against that header claim of **85**. `apex doctor`
   reports the parsed count every time it runs
   (`surface ledger — 110 rows parsed (...)` in the scratch-install run
   below), so the drift is visible on every run rather than only on the day
   someone happens to recount by hand. Fixing the header is an owner edit,
   not something the harness does — the harness does not write to the
   ledger.
2. **`ui/src/agentic/` is an empty, entirely untracked directory.**
   `git ls-files ui/src/agentic` returns nothing; the only files on disk
   under it are `.understand-anything/` scratch artifacts from an unrelated
   tool. It is safe to delete. It is also, independently, one of three
   directories the harness's real gate run below (Step 4) surfaced as
   **missing a lane row** in `tools/repo-lanes/lanes.json` — deleting it
   removes that gap rather than requiring a new lane entry for a directory
   that holds no source.
3. **`lanes.json` currently has zero RETIRED modules.** Its 54 modules
   break down as 48 `production`, 4 `legacy`, 2 `experimental`, 0
   `retired`. The harness's RETIRED-block rule (`LANE-RETIRED`) is correct
   and covered by its own fixtures, but nobody should assume it is
   exercised against real apex-app data today — there is no live module in
   the RETIRED lane for it to block an edit to. (The surface *ledger's*
   RETIRED status, which is a different axis — per-surface routing status,
   not per-module lane — does have 12 rows; that is unrelated to this
   finding.)

## Open questions from the spec, for the owner to rule on

1. **Is the ledger's stated tally worth fixing?** Its header says 85 rows;
   the parser finds 110 (see Finding 1 above). The harness can report the
   drift on every run; correcting the document itself is an owner edit.
2. **Should `apex gate` run in CI, or stay a local pre-done check?** The
   commands it wraps already have their own CI gates (e.g.
   `studio-alignment.yml`), so adding `apex gate` to CI would add value only
   for the parity and watchlist tiers, which nothing else currently checks
   in CI.
3. **Which of ARCH-003 / ARCH-004 / ARCH-005 should be `block` rather than
   `warn` inside `backend/agentic/`?** The shipped policy ships ARCH-003 and
   ARCH-005 at `warn`; ARCH-004 is not present in the shipped policy at all.
   Provider-SDK imports are already `block` under a separate rule
   (`BOUND-004`). Promoting ARCH-003/ARCH-005 to `block`, or adding an
   ARCH-004 rule, is a policy decision for the owner, not something
   inferable from the rule text alone.

## Verification performed before writing this document

- `npm test` passes 146/146, identically with and without
  `APEX_REPO_ROOT` set to the apex-app checkout.
- A packed tarball (`npm pack`) installed into a clean scratch project and
  run via `npx` against the real apex-app checkout: `apex doctor` reports
  `result: ok`; `apex route ui/src/marketing/CampaignCockpit.jsx` correctly
  names the surface DUAL and flags the grandfathered `quizBuilder` legacy
  import; `apex gate --dry-run` lists obligations without executing
  anything. `templates/policy.json` and `templates/apex-hook.js` are both
  present in the installed package (`node_modules/apex-dev-harness/templates/`).
- The real (non-dry-run) gate was run inside apex-app against `HEAD~1`:
  `node bin/apex.js gate --base HEAD~1 --message "integration test run"`.
  Two obligations fired (`stack-map`, `lane-import-guards`). The stack-map
  obligation's two commands passed. The lane-import-guards obligation's
  wrapped test — `python -m pytest tools/repo-lanes/tests/ -q` — **failed
  for real, not for an environment reason**: apex-app's own coverage test
  (`test_every_governed_module_has_a_lane`) found three governed
  directories with no lane row: `backend/app/assistant`,
  `backend/agentic/api`, and `ui/src/agentic` (see Finding 2). This is a
  genuine pre-existing gap in apex-app's lane registry that the gate
  surfaced correctly; nothing about the harness was adjusted to change or
  hide this result. Full output is in the Task 15 report.
