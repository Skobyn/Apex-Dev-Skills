# apex-dev-harness 0.3.0 — release report

Branch: `feat/delta-policy` (from `fix/sensitive-file-guard`), worktree `/tmp/apex-030`.

## 1. Delta policy overlay

- `harnesses/apex-dev-harness/templates/policy-overlay.json` — new minimal overlay `apex init` now writes to `.harness/policy.json` (version, `_readme`, empty `disabled`). `templates/policy.json` remains the built-in the engine loads.
- `src/scaffold.ts` — `FILES` now points the `.harness/policy.json` entry at `policy-overlay.json`.
- `src/truth/policy.ts` — rewritten. `loadPolicy()` merges built-in with project per section: `rules`/`obligations` by `id`; `surfaceHints`/`mwgTargets`/`skillRules`/`parityRules`/`excludedFiles` by `match`; `watchlist` as a case-insensitive union. Per section: key omitted → inherit built-in wholesale; key present non-empty → merge, project wins on id/match collision; key present as `[]` → clears the section entirely (preserves the pre-existing "`[]` means none" test, which still passes unmodified).
- `src/types.ts` — added `DisabledBlock`/`DisabledRuleEntry`/`DisabledHintEntry`/`ExcludedFile`, and `Policy.disabled`/`Policy.excludedFiles`.
- Explicit removal is the single `disabled` block (`rules`, `surfaceHints`), applied after merging. Entries may be a bare string or `{id|match, reason}`; the object form's `reason` is enforced by convention (not schema-rejected) and `apex doctor` warns on any bare-string entry.

## 2. Migration

- `src/policyPrune.ts` (new) + `apex policy prune` CLI verb (`bin/apex.js`). Compares each project entry against the built-in via sorted-key JSON; drops byte-identical entries; preserves `version`/`_readme`/`disabled`/divergent entries; never rewrites the file if nothing changed; reports what it removed/kept, or says plainly when nothing local remains.
- `doctor.ts` — new snapshot-detection warning (`N/M entries are verbatim built-in... Run 'apex policy prune'`) and the bare-string `disabled` entry warning.

## 3. Manifest-staleness feedback restored (+ a bug found and fixed mid-build)

- `templates/apex-hook.js` `post-tool-use`: genuine capability-manifest staleness now writes to stderr and sets `exitCode = 2` (never `process.exit()`); could-not-run stays advisory at exit 0; style-generator check stays advisory at exit 0. Every path still emits exactly one `{}` on stdout — verified in tests (byte-exact single-line JSON on every branch).
- **Separate finding, not part of the original brief:** the pre-existing `runQuiet` helper computed `e.stdout || e.stderr`. `execSync`'s thrown error carries `stdout`/`stderr` as Buffers, and an *empty* Buffer is truthy — so whenever a checker wrote only to stderr (which `gen_studio_capability_manifest --check` does), the empty stdout Buffer won the `||` and the real failure text was silently discarded as `""`. This made the staleness branch — and therefore the new exit-2 restoration — unreachable regardless of actual drift. Fixed by concatenating (`String(e.stdout) + String(e.stderr)`) instead of choosing. Verified independently with a standalone repro before applying (empty-stdout-Buffer truthiness confirmed under Node). `runQuiet` is now exported from `apex-hook.js` and unit-tested directly, plus an integration test `post-tool-use: a stderr-only check failure is reported, not swallowed`. The exit-2 tests were written and verified *after* this fix — they were not passing against the old buggy `runQuiet` (confirmed by temporarily reverting: it reproduces the discard).
- Canonical-hint suppression: `post-tool-use` now loads the merged policy, finds the longest-matching `surfaceHints` entry for the edited file, and suppresses the STUDIO legacy-twin advisory when that hint has `canonical: true`. The `apexStudio`-path check remains the default for unhinted files.
- `templates/apex-hook.js` also gained `APEX_STYLE_CHECK_CMD` / `APEX_MANIFEST_CHECK_CMD` env overrides so these checks are testable without a real python/backend checkout, and an `isMain` guard so `runQuiet` can be imported directly in tests without blocking on stdin.

## 4. Hints expansion

- Removed 2 defective hints: `ui/src/pages/BrandPage.jsx` (file deleted), `ui/src/pages/HouseGuideAdminPage.jsx` (portal-only mount, false STUDIO advisory on legitimate OOS work).
- Merged the 40 validated hints from the field engineers' `hints.json`.
- Added `canonical?: boolean` to `SurfaceHint` (`src/types.ts`). Set on 2 entries not present in either the original 6 or the 40: `ui/src/marketing/EmailDesignerPage.jsx` → `Email designer (legacy twin)`, `ui/src/pages/BrandBookPrintPage.jsx` → `Brand book (tokens)`. Both files exist on disk and both surface strings appear verbatim in the live ledger (ledger lines 207 and 85) — verified before committing.
- Added `excludedFiles` (7 entries, verbatim from the brief) to `Policy`/`types.ts`/`templates/policy.json`.
- **Hint count:** the point-4 expansion itself nets **44** (6 original − 2 defective + 40 new), matching the brief's stated "net result 44." Satisfying the separate canonical-flag requirement required adding 2 *additional* hint entries not present in the 44 (neither file had an existing hint), bringing the final merged `surfaceHints` table to **46**. Flagging this discrepancy explicitly rather than silently landing on a different number than stated.

## 5. Invariants (`test/invariants.test.js`, run against every hint in the merged table)

All three pass against the live consuming repo (`/mnt/c/Dev/Apex-APP-SW/apex-app`), tests skip cleanly when that repo is absent:

1. **exists-on-disk** — every non-glob `match` resolves to a real file. Pass.
2. **surface-verbatim** — every `surface` string appears verbatim as a ledger row. Pass.
3. **not-portal-only** — derived via `scripts/portal-mounts.mjs`, a brace-depth-aware parser of `ui/src/App.js` (handles multi-line `<Route>` tags and ternary `element={...}` expressions that a line-based regex would miss). It found **0 false positives** against all 46 hints, and correctly flagged all 5 known portal-only page files (`TipSheetsPage`, `HouseGuideAdminPage`, `HouseGuideEditorPage`, `PortalHouseGuidePage`, `PortalProfilePage` — exactly the file-level entries in `excludedFiles`), confirming the derivation methodology matches the field engineers' independently. Pass.
4. Control-group assertion: `MyProfilePage.jsx`, `EmailSettingsPage.jsx`, `ContestsListPage.jsx` never carry `canonical: true`. Pass.

## 6. Docs

- `plugins/apex-dev-harness/README.md` and `docs/apex-dev-harness-integration.md` updated: overlay model, merge semantics, `disabled` block requirement, `apex policy prune` migration guidance, "curated and partial" hint-coverage framing, and the restored exit-2 manifest behavior (the old "feedback channel this supersession does not preserve" section was rewritten since it's no longer true).

## Build & test

```
npm run build   → tsc clean, bundle-plugin wrote 33 files to plugins/apex-dev-harness/engine/
npm test        → 189 tests, 188 pass, 1 fail (plugin.test.js "bundle is current" — expected;
                   resolves once the rebuilt engine/ is committed alongside this change)
```

## End-to-end defect proof (read-only against the real consuming repo)

Against `/mnt/c/Dev/Apex-APP-SW/apex-app`'s **unmodified** `.harness/policy.json` (confirmed byte-different from the new built-in, and confirmed untouched — `git status` still shows it untracked, no edits made):

```
$ echo '{"tool_name":"Write","tool_input":{"file_path":"package-lock.json","content":"{}"}}' \
    | APEX_REPO_ROOT=/mnt/c/Dev/Apex-APP-SW/apex-app node templates/apex-hook.js pre-tool-use
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
"permissionDecisionReason":"[GUARD-SENSITIVE-FILE] (.claude/hooks/block-sensitive-files.ps1 (superseded))
package-lock.json is a lock file — it should change only via the package manager
(npm install / pip install), never a direct edit."}}
```

Before this fix, this ALLOWED (confirmed: the target repo's policy.json predates `GUARD-SENSITIVE-FILE` and is byte-identical to the pre-fix built-in across all checked entries — a pure snapshot). With the delta-overlay model, the rule now reaches the repo without any change to that repo's files.

```
$ echo '{"tool_name":"Write","tool_input":{"file_path":".env.example","content":"KEY=placeholder"}}' \
    | APEX_REPO_ROOT=/mnt/c/Dev/Apex-APP-SW/apex-app node templates/apex-hook.js pre-tool-use
{}
```

`.env.example` still allowed, as required (template exemption preserved).

## Not done / caveats

- Did not publish (owner holds npm 2FA), per instructions.
- Did not touch `main`'s dirty working tree or the consuming repo's files (read-only throughout).
- The final `surfaceHints` count is 46, not the literal "44" stated in the brief's point 4 — see section 4 above for why (2 additional entries were required to satisfy the canonical-flag requirement, since neither target file had an existing hint).
