# apex-dev-harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make apex-app's existing governance — lanes, the surface ledger, `.agents/rules`, and the Studio alignment guards — deterministic, cross-platform, and queryable, without inventing any new rules.

**Architecture:** One TypeScript engine holds all logic and reads apex-app's truth files live (never vendored). Three thin transports call it: cross-platform Node hooks, an MCP server, and Claude Code plugin commands. Every wrapped check shells out to a script that already exists in apex-app.

**Tech Stack:** TypeScript 5.9 (NodeNext, strict), Node ≥20 ESM, `node:test`, `@modelcontextprotocol/sdk` for the MCP transport. No runtime dependencies beyond the MCP SDK.

**Spec:** [`docs/superpowers/specs/2026-08-24-apex-dev-harness-design.md`](../specs/2026-08-24-apex-dev-harness-design.md)

## Global Constraints

- Package root: `/mnt/c/Dev/Apex-Dev-Skills/harnesses/apex-dev-harness`. Plugin root: `/mnt/c/Dev/Apex-Dev-Skills/plugins/apex-dev-harness`.
- npm package name `apex-dev-harness`; bin name `apex`. `"type": "module"`, `engines.node >= 20`.
- Target repo for all fixtures and manual verification: `/mnt/c/Dev/Apex-APP-SW/apex-app`.
- **Truth files are read live at every invocation.** Fixtures exist for parser tests only. No vendored snapshot is ever consulted at runtime.
- **Fail open, always.** A missing or unparseable truth file produces a warning and a reduced verdict — never a thrown error, never a non-zero exit from a hook.
- **Hook stdout protocol is non-negotiable:** always print a JSON object. `{}` to allow; `{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"..."}}` to block. Empty stdout bricked every edit in Cursor on 2026-07-04.
- `no-row` (ledger has no entry) and `unparseable` (harness could not read the file) are **distinct verdicts** and must never collapse into each other.
- `.agents/rules` scoping (owner ruling 2026-08-24): secrets rules repo-wide; isolation/venue/provider rules scoped to `backend/agentic/` only. `ui/src/agentic/` is gone and must not appear in any scope.
- **Never embed a credential-shaped literal in source or tests**, not even as a sample. Construct such strings by concatenation at runtime — apex-app's own guardrail hook blocks writes containing them, and this plan was rejected once for exactly that.
- All tests use `node:test` + `node:assert/strict`. Test command: `npm test` (builds, then runs `test/*.test.js` against `dist/`).
- Commit after every task using the message given in that task's final step.

---

## File Structure

**Phase A — engine (`harnesses/apex-dev-harness/`)**

| File | Responsibility |
|---|---|
| `src/types.ts` | Every shared type. No logic. |
| `src/repo.ts` | Find the apex-app root; resolve truth-file paths; normalize paths. |
| `src/glob.ts` | Minimal glob matching shared by all policy consumers. |
| `src/truth/lanes.ts` | Parse `lanes.json`; answer lane-for-path and import-allowed. |
| `src/truth/ledger.ts` | Parse the surface-ledger markdown; answer surface-for-query. |
| `src/truth/policy.ts` | Load `.harness/policy.json`; supply the built-in default. |
| `src/route.ts` | Compose the three truths into a `RouteVerdict`. |
| `src/check.ts` | Block-tier evaluation of one file edit. |
| `src/watchlist.ts` | Vocabulary scan over arbitrary text. |
| `src/obligations.ts` | Changed paths → obligations owed. |
| `src/gate.ts` | Run obligations; aggregate a verdict. |
| `src/doctor.ts` | Parse coverage + wrapped-command resolution + hook install state. |
| `src/scaffold.ts` | `init` — write the shim + policy into apex-app. |
| `bin/apex.js` | CLI dispatcher. |
| `templates/apex-hook.js` | The shim installed into apex-app. |
| `templates/policy.json` | The default policy installed into apex-app. |

**Phase B — transports**

| File | Responsibility |
|---|---|
| `src/mcp/server.ts` | MCP stdio server exposing route/gate/check/doctor. |
| `plugins/apex-dev-harness/commands/*.md` | `/apex:route`, `/apex:gate`, `/apex:build`, `/apex:status`. |
| `plugins/apex-dev-harness/skills/apex-orientation/SKILL.md` | The "where does this go" discipline. |

---

## Phase A — the engine

### Task 1: Package scaffold, shared types, repo discovery

**Files:**
- Create: `harnesses/apex-dev-harness/package.json`, `tsconfig.json`, `.gitignore`
- Create: `harnesses/apex-dev-harness/src/types.ts`
- Create: `harnesses/apex-dev-harness/src/repo.ts`
- Test: `harnesses/apex-dev-harness/test/repo.test.js`

**Interfaces:**
- Consumes: nothing.
- Produces: every type below (imported by all later tasks), plus
  `findRepoRoot(start?: string): string | null`,
  `truthPaths(root: string): { lanes: string; ledger: string; policy: string }`, and
  `normalize(p: string): string`.

- [ ] **Step 1: Create the package skeleton**

```bash
mkdir -p /mnt/c/Dev/Apex-Dev-Skills/harnesses/apex-dev-harness/{src/truth,src/mcp,bin,templates,test,fixtures}
cd /mnt/c/Dev/Apex-Dev-Skills/harnesses/apex-dev-harness
```

`package.json`:

```json
{
  "name": "apex-dev-harness",
  "version": "0.1.0",
  "description": "Routing and gate engine for apex-app: lanes, surface ledger, guardrails, and computed done-obligations.",
  "type": "module",
  "bin": { "apex": "bin/apex.js" },
  "main": "./dist/route.js",
  "types": "./dist/route.d.ts",
  "files": ["bin/", "dist/", "templates/", "README.md", "LICENSE"],
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "clean": "node -e \"require('node:fs').rmSync('dist',{recursive:true,force:true})\"",
    "test": "npm run build && node --test \"test/*.test.js\"",
    "prepublishOnly": "npm run clean && npm run build && npm test"
  },
  "engines": { "node": ">=20.0.0" },
  "license": "MIT",
  "publishConfig": { "access": "public" }
}
```

`tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["ES2022"],
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "rootDir": "src",
    "outDir": "dist",
    "declaration": true,
    "strict": true,
    "resolveJsonModule": true,
    "skipLibCheck": true,
    "types": ["node"]
  },
  "include": ["src/**/*.ts"]
}
```

`.gitignore`:

```
node_modules/
dist/
*.tgz
```

Then: `npm install --save-dev typescript@^5.9.0 @types/node@^22`

- [ ] **Step 2: Write `src/types.ts`**

```typescript
// SPDX-License-Identifier: MIT
// Every shared type in the engine. No logic lives here.

export type Lane = 'production' | 'legacy' | 'experimental' | 'retired' | 'ungoverned';

export interface LaneEntry {
  path: string;
  lane: Exclude<Lane, 'ungoverned'>;
  owner?: string;
  replacement?: string;
  canonicalDoc?: string;
  since?: string;
  notes?: string;
}

export interface ImportGuardAllow {
  file: string;
  reason: string;
}

export interface ImportGuard {
  id: string;
  namespace: string;
  language: string;
  internalExempt: string[];
  allow: ImportGuardAllow[];
}

export interface LanesTruth {
  ok: boolean;
  /** Present when the file was missing or unparseable. Never throws. */
  warning?: string;
  governedRoots: string[];
  modules: LaneEntry[];
  importGuards: ImportGuard[];
}

export type SurfaceStatus = 'STUDIO' | 'DUAL' | 'LEGACY' | 'OOS' | 'RETIRED';

export interface SurfaceRow {
  section: string;
  surface: string;
  routes: string[];
  status: SurfaceStatus;
  notes: string;
}

export interface LedgerTruth {
  ok: boolean;
  warning?: string;
  rows: SurfaceRow[];
  /** Rows naming a surface with no parseable route pattern. */
  rowsWithoutRoutes: number;
}

export type RuleTier = 'block' | 'warn' | 'historical';

export interface PolicyRule {
  id: string;
  tier: RuleTier;
  /** 'repo' or a path prefix such as 'backend/agentic/'. */
  scope: string;
  /** Named check implemented in check.ts. Absent for historical rules. */
  check?: string;
  source?: string;
  note?: string;
}

export interface ObligationDef {
  id: string;
  when: { anyPathMatches: string[] };
  run: string[];
  reason: string;
}

export interface MwgTarget {
  match: string;
  target: string;
}

export interface SkillRule {
  match: string;
  skills: string[];
}

export interface ParityRule {
  match: string;
  surfaces: string[];
}

export interface Policy {
  ok: boolean;
  warning?: string;
  version: number;
  rules: PolicyRule[];
  obligations: ObligationDef[];
  watchlist: string[];
  mwgTargets: MwgTarget[];
  skillRules: SkillRule[];
  parityRules: ParityRule[];
}

export interface RouteVerdict {
  query: string;
  lane: Lane;
  laneEntry: LaneEntry | null;
  surface: SurfaceRow | null;
  /** 'row' when the ledger has an entry; 'no-row' when it does not. */
  surfaceVerdict: 'row' | 'no-row';
  routing: string | null;
  mwg: string | null;
  skills: string[];
  parity: string[];
  importNotes: string[];
  /** Truth-file problems. Non-empty means a reduced verdict. */
  warnings: string[];
}

export type CheckDecision =
  | { allow: true }
  | { allow: false; ruleId: string; reason: string; source?: string };

export interface WatchlistHit {
  term: string;
  line: number;
  excerpt: string;
}

export interface Obligation {
  id: string;
  reason: string;
  commands: string[];
}

export interface CommandResult {
  command: string;
  ok: boolean;
  output: string;
}

export interface GateVerdict {
  obligations: Obligation[];
  results: CommandResult[];
  parityWarnings: string[];
  watchlistHits: WatchlistHit[];
  warnings: string[];
  ok: boolean;
}
```

- [ ] **Step 3: Write the failing test `test/repo.test.js`**

```javascript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { findRepoRoot, truthPaths, normalize } from '../dist/repo.js';

test('finds the repo root from a nested directory', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-repo-'));
  try {
    mkdirSync(join(dir, 'tools', 'repo-lanes'), { recursive: true });
    writeFileSync(join(dir, 'tools', 'repo-lanes', 'lanes.json'), '{}');
    mkdirSync(join(dir, 'ui', 'src', 'marketing'), { recursive: true });
    assert.equal(findRepoRoot(join(dir, 'ui', 'src', 'marketing')), dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('returns null when no apex-app root is above the start directory', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-norepo-'));
  try {
    assert.equal(findRepoRoot(dir), null);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('APEX_REPO_ROOT overrides discovery', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-env-'));
  try {
    process.env.APEX_REPO_ROOT = dir;
    assert.equal(findRepoRoot('/nowhere'), dir);
  } finally {
    delete process.env.APEX_REPO_ROOT;
    rmSync(dir, { recursive: true, force: true });
  }
});

test('truthPaths names all three truth files', () => {
  const p = truthPaths('/repo');
  assert.match(p.lanes, /repo[\\/]tools[\\/]repo-lanes[\\/]lanes\.json$/);
  assert.match(p.ledger, /apex-studio-surface-ledger\.md$/);
  assert.match(p.policy, /\.harness[\\/]policy\.json$/);
});

test('normalize makes windows paths comparable', () => {
  assert.equal(normalize('ui\\src\\a.jsx'), 'ui/src/a.jsx');
  assert.equal(normalize('./ui/src/a.jsx'), 'ui/src/a.jsx');
});
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `npm test`
Expected: FAIL — `Cannot find module '../dist/repo.js'`

- [ ] **Step 5: Write `src/repo.ts`**

```typescript
// SPDX-License-Identifier: MIT
// Locate the apex-app checkout and its truth files.

import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

/** The marker that identifies an apex-app checkout. */
const MARKER = join('tools', 'repo-lanes', 'lanes.json');

/**
 * Walk up from `start` looking for the lanes registry. Returns null rather
 * than throwing — callers degrade to a reduced verdict.
 * `APEX_REPO_ROOT` overrides discovery entirely (tests, CI, monorepo hosts).
 */
export function findRepoRoot(start: string = process.cwd()): string | null {
  const override = process.env.APEX_REPO_ROOT;
  if (override) return override;

  let dir = resolve(start);
  for (;;) {
    if (existsSync(join(dir, MARKER))) return dir;
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

export interface TruthPaths {
  lanes: string;
  ledger: string;
  policy: string;
}

export function truthPaths(root: string): TruthPaths {
  return {
    lanes: join(root, 'tools', 'repo-lanes', 'lanes.json'),
    ledger: join(root, '.claude', 'tasks', 'apex-studio-surface-ledger.md'),
    policy: join(root, '.harness', 'policy.json'),
  };
}

/** Normalize a path for matching: forward slashes, no leading './'. */
export function normalize(p: string): string {
  return p.replace(/\\/g, '/').replace(/^\.\//, '');
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `npm test`
Expected: 5 tests pass.

- [ ] **Step 7: Commit**

```bash
git add harnesses/apex-dev-harness
git commit -m "feat(apex-dev-harness): package scaffold, shared types, repo discovery"
```

---

### Task 2: Lanes parser

**Files:**
- Create: `src/truth/lanes.ts`
- Create: `fixtures/lanes.json` (trimmed copy of the real file)
- Test: `test/lanes.test.js`

**Interfaces:**
- Consumes: `LanesTruth`, `LaneEntry`, `Lane`, `ImportGuard` from `src/types.ts`; `normalize`, `truthPaths` from `src/repo.ts`.
- Produces:
  - `loadLanes(root: string): LanesTruth`
  - `laneFor(truth: LanesTruth, relPath: string): { lane: Lane; entry: LaneEntry | null }`
  - `importAllowed(truth: LanesTruth, importerPath: string, importedNamespace: string): { allowed: boolean; reason?: string }`

- [ ] **Step 1: Create the fixture**

```bash
cd /mnt/c/Dev/Apex-Dev-Skills/harnesses/apex-dev-harness
python3 - <<'PY'
import json
src='/mnt/c/Dev/Apex-APP-SW/apex-app/tools/repo-lanes/lanes.json'
d=json.load(open(src,encoding='utf-8'))
keep={'backend/app/routes/','backend/app/funnel_builder/','ui/src/apexStudio/',
      'ui/src/quizBuilder/','ui/src/apexDocs/','ui/src/menuDesigner/'}
d['modules']=[m for m in d['modules'] if m['path'] in keep]
d['importGuards']=[g for g in d['importGuards'] if 'quiz' in g['id'] or 'funnel' in g['id']]
json.dump(d, open('fixtures/lanes.json','w',encoding='utf-8'), indent=2)
print('modules:', len(d['modules']), 'guards:', len(d['importGuards']))
PY
```

The fixture must contain at least one `legacy` module with an import guard, one `experimental`, and one `production`. Verify the printed counts are non-zero before continuing.

- [ ] **Step 2: Write the failing test `test/lanes.test.js`**

```javascript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, copyFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadLanes, laneFor, importAllowed } from '../dist/truth/lanes.js';

const HERE = dirname(fileURLToPath(import.meta.url));

/** Build a throwaway repo whose lanes.json is `content` (or the fixture). */
function repoWith(content) {
  const dir = mkdtempSync(join(tmpdir(), 'apex-lanes-'));
  mkdirSync(join(dir, 'tools', 'repo-lanes'), { recursive: true });
  const dest = join(dir, 'tools', 'repo-lanes', 'lanes.json');
  if (content === undefined) copyFileSync(join(HERE, '..', 'fixtures', 'lanes.json'), dest);
  else writeFileSync(dest, content);
  return dir;
}

test('parses modules and import guards from the real-shaped file', () => {
  const dir = repoWith();
  try {
    const truth = loadLanes(dir);
    assert.equal(truth.ok, true);
    assert.ok(truth.modules.length > 0);
    assert.ok(truth.importGuards.length > 0);
    assert.ok(truth.governedRoots.includes('ui/src'));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('lane lookup uses longest-prefix match', () => {
  const dir = repoWith();
  try {
    const truth = loadLanes(dir);
    assert.equal(laneFor(truth, 'ui/src/quizBuilder/api/index.js').lane, 'legacy');
    assert.equal(laneFor(truth, 'ui/src/apexStudio/views/registry.js').lane, 'production');
    assert.equal(laneFor(truth, 'ui/src/apexDocs/Viewer.jsx').lane, 'experimental');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a path under no governed root is ungoverned, not production', () => {
  const dir = repoWith();
  try {
    const truth = loadLanes(dir);
    const v = laneFor(truth, 'scripts/oneoff.sh');
    assert.equal(v.lane, 'ungoverned');
    assert.equal(v.entry, null);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('windows-style separators match the same module', () => {
  const dir = repoWith();
  try {
    const truth = loadLanes(dir);
    assert.equal(laneFor(truth, 'ui\\src\\quizBuilder\\api\\index.js').lane, 'legacy');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a grandfathered importer is allowed, with its reason', () => {
  const dir = repoWith();
  try {
    const truth = loadLanes(dir);
    const guard = truth.importGuards[0];
    const allowedFile = guard.allow[0].file;
    const v = importAllowed(truth, allowedFile, guard.namespace);
    assert.equal(v.allowed, true);
    assert.equal(v.reason, guard.allow[0].reason);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a new importer of a guarded namespace is refused', () => {
  const dir = repoWith();
  try {
    const truth = loadLanes(dir);
    const guard = truth.importGuards[0];
    assert.equal(importAllowed(truth, 'ui/src/brand-new/File.jsx', guard.namespace).allowed, false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a file inside the guarded namespace itself is exempt', () => {
  const dir = repoWith();
  try {
    const truth = loadLanes(dir);
    const guard = truth.importGuards[0];
    const inside = guard.internalExempt[0] + 'anything.py';
    assert.equal(importAllowed(truth, inside, guard.namespace).allowed, true);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a missing lanes.json warns and returns an empty truth — it never throws', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-nolanes-'));
  try {
    const truth = loadLanes(dir);
    assert.equal(truth.ok, false);
    assert.match(truth.warning, /lanes\.json/);
    assert.deepEqual(truth.modules, []);
    assert.equal(laneFor(truth, 'ui/src/anything.js').lane, 'ungoverned');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('malformed JSON warns rather than throwing', () => {
  const dir = repoWith('{ this is not json');
  try {
    const truth = loadLanes(dir);
    assert.equal(truth.ok, false);
    assert.match(truth.warning, /pars/i);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `npm test`
Expected: FAIL — `Cannot find module '../dist/truth/lanes.js'`

- [ ] **Step 4: Write `src/truth/lanes.ts`**

```typescript
// SPDX-License-Identifier: MIT
// Parse tools/repo-lanes/lanes.json — the machine source for module lanes.

import { readFileSync } from 'node:fs';
import type { ImportGuard, Lane, LaneEntry, LanesTruth } from '../types.js';
import { normalize, truthPaths } from '../repo.js';

const EMPTY: Omit<LanesTruth, 'ok' | 'warning'> = {
  governedRoots: [],
  modules: [],
  importGuards: [],
};

export function loadLanes(root: string): LanesTruth {
  const path = truthPaths(root).lanes;
  let raw: string;
  try {
    raw = readFileSync(path, 'utf-8');
  } catch {
    return { ok: false, warning: `lanes.json not found at ${path} — lane verdicts unavailable`, ...EMPTY };
  }
  try {
    const data = JSON.parse(raw) as Partial<LanesTruth>;
    return {
      ok: true,
      governedRoots: data.governedRoots ?? [],
      modules: (data.modules ?? []) as LaneEntry[],
      importGuards: (data.importGuards ?? []) as ImportGuard[],
    };
  } catch (err) {
    const why = err instanceof Error ? err.message : String(err);
    return { ok: false, warning: `could not parse ${path}: ${why}`, ...EMPTY };
  }
}

/**
 * Longest-prefix match. A path under a governed root but matching no module
 * is still 'ungoverned' — the registry has a gap, and guessing 'production'
 * would hide it.
 */
export function laneFor(truth: LanesTruth, relPath: string): { lane: Lane; entry: LaneEntry | null } {
  const p = normalize(relPath);
  let best: LaneEntry | null = null;
  for (const m of truth.modules) {
    const prefix = normalize(m.path);
    if (p === prefix || p.startsWith(prefix)) {
      if (!best || prefix.length > normalize(best.path).length) best = m;
    }
  }
  return best ? { lane: best.lane, entry: best } : { lane: 'ungoverned', entry: null };
}

/**
 * May `importerPath` import `importedNamespace`? Files inside the guarded
 * namespace are exempt; everyone else must be on the grandfathered allowlist,
 * which only ever shrinks.
 */
export function importAllowed(
  truth: LanesTruth,
  importerPath: string,
  importedNamespace: string,
): { allowed: boolean; reason?: string } {
  const importer = normalize(importerPath);
  const ns = normalize(importedNamespace);
  const guard = truth.importGuards.find((g) => normalize(g.namespace) === ns);
  if (!guard) return { allowed: true };

  for (const exempt of guard.internalExempt) {
    if (importer.startsWith(normalize(exempt))) return { allowed: true, reason: 'inside the guarded namespace' };
  }
  const entry = guard.allow.find((a) => normalize(a.file) === importer);
  if (entry) return { allowed: true, reason: entry.reason };

  return { allowed: false };
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `npm test`
Expected: all lanes tests pass.

- [ ] **Step 6: Verify against the live repo**

```bash
cd /mnt/c/Dev/Apex-Dev-Skills/harnesses/apex-dev-harness && npm run build
node -e "
import('./dist/truth/lanes.js').then(m => {
  const t = m.loadLanes('/mnt/c/Dev/Apex-APP-SW/apex-app');
  console.log('ok', t.ok, 'modules', t.modules.length, 'guards', t.importGuards.length);
  console.log(m.laneFor(t, 'backend/app/funnel_builder/routes.py'));
});"
```

Expected: `ok true modules 54 guards 3` (or more), and lane `legacy` for the funnel_builder path.

- [ ] **Step 7: Commit**

```bash
git add harnesses/apex-dev-harness
git commit -m "feat(apex-dev-harness): lanes parser with longest-prefix and import-guard lookup"
```

---

### Task 3: Surface-ledger parser

**Files:**
- Create: `src/truth/ledger.ts`
- Create: `fixtures/ledger.md` (excerpt of the real ledger)
- Test: `test/ledger.test.js`

**Interfaces:**
- Consumes: `LedgerTruth`, `SurfaceRow`, `SurfaceStatus` from `src/types.ts`; `normalize`, `truthPaths` from `src/repo.ts`.
- Produces:
  - `loadLedger(root: string): LedgerTruth`
  - `surfaceFor(truth: LedgerTruth, query: string): SurfaceRow | null`

- [ ] **Step 1: Create the fixture**

```bash
cd /mnt/c/Dev/Apex-Dev-Skills/harnesses/apex-dev-harness
sed -n '55,130p' /mnt/c/Dev/Apex-APP-SW/apex-app/.claude/tasks/apex-studio-surface-ledger.md > fixtures/ledger.md
grep -c '^|' fixtures/ledger.md
```

Expected: a non-zero count. The excerpt must include the status-vocabulary table (which the parser must skip), at least one `**DUAL**` row, one `**STUDIO**` row, and one `**RETIRED**` row.

- [ ] **Step 2: Write the failing test `test/ledger.test.js`**

```javascript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, copyFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadLedger, surfaceFor } from '../dist/truth/ledger.js';

const HERE = dirname(fileURLToPath(import.meta.url));

function repoWith(content) {
  const dir = mkdtempSync(join(tmpdir(), 'apex-ledger-'));
  mkdirSync(join(dir, '.claude', 'tasks'), { recursive: true });
  const dest = join(dir, '.claude', 'tasks', 'apex-studio-surface-ledger.md');
  if (content === undefined) copyFileSync(join(HERE, '..', 'fixtures', 'ledger.md'), dest);
  else writeFileSync(dest, content);
  return dir;
}

test('parses rows with their statuses', () => {
  const dir = repoWith();
  try {
    const truth = loadLedger(dir);
    assert.equal(truth.ok, true);
    assert.ok(truth.rows.length > 0);
    for (const r of truth.rows) {
      assert.ok(['STUDIO', 'DUAL', 'LEGACY', 'OOS', 'RETIRED'].includes(r.status));
      assert.ok(r.surface.length > 0);
    }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('the status-vocabulary table is not mistaken for surface rows', () => {
  const dir = repoWith();
  try {
    const truth = loadLedger(dir);
    // The vocabulary table's first cell is the bare status name.
    assert.equal(truth.rows.some((r) => r.surface.replace(/\*/g, '') === 'STUDIO'), false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a route lookup finds its row', () => {
  const md = [
    '## 02 Menus',
    '',
    '| Surface | Routes | Status | Notes |',
    '|---|---|---|---|',
    '| Menu designer (Konva) | `/menu-designer` | **RETIRED** | redirects |',
    '| Menu Manager core | `/menu-manager`, `/menu-manager/recipes` | **DUAL** | studio catalog |',
  ].join('\n');
  const dir = repoWith(md);
  try {
    const truth = loadLedger(dir);
    assert.equal(surfaceFor(truth, '/menu-designer').status, 'RETIRED');
    assert.equal(surfaceFor(truth, '/menu-manager/recipes').status, 'DUAL');
    assert.equal(surfaceFor(truth, '/menu-manager').section, '02 Menus');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('longest route match wins over a shorter prefix', () => {
  const md = [
    '## 02 Menus',
    '',
    '| Surface | Routes | Status | Notes |',
    '|---|---|---|---|',
    '| Menu core | `/menu` | **LEGACY** | |',
    '| Menu analytics | `/menu/analytics` | **DUAL** | |',
  ].join('\n');
  const dir = repoWith(md);
  try {
    const truth = loadLedger(dir);
    assert.equal(surfaceFor(truth, '/menu/analytics').surface, 'Menu analytics');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a surface can also be found by name', () => {
  const dir = repoWith();
  try {
    const truth = loadLedger(dir);
    const first = truth.rows[0];
    assert.equal(surfaceFor(truth, first.surface).status, first.status);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('an unknown query returns null — the caller reports no-row, never a guess', () => {
  const dir = repoWith();
  try {
    assert.equal(surfaceFor(loadLedger(dir), '/nothing-like-this-exists'), null);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('route-less rows are counted, not dropped silently', () => {
  const md = [
    '## 09 Org',
    '',
    '| Surface | Routes | Status | Notes |',
    '|---|---|---|---|',
    '| Org rollup | no route | **LEGACY** | name-matchable only |',
  ].join('\n');
  const dir = repoWith(md);
  try {
    const truth = loadLedger(dir);
    assert.equal(truth.rows.length, 1);
    assert.equal(truth.rowsWithoutRoutes, 1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a missing ledger warns and returns no rows — it never throws', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-noledger-'));
  try {
    const truth = loadLedger(dir);
    assert.equal(truth.ok, false);
    assert.match(truth.warning, /ledger/i);
    assert.deepEqual(truth.rows, []);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `npm test`
Expected: FAIL — `Cannot find module '../dist/truth/ledger.js'`

- [ ] **Step 4: Write `src/truth/ledger.ts`**

```typescript
// SPDX-License-Identifier: MIT
// Parse .claude/tasks/apex-studio-surface-ledger.md — the per-surface answer
// to "where does new work go?".

import { readFileSync } from 'node:fs';
import type { LedgerTruth, SurfaceRow, SurfaceStatus } from '../types.js';
import { normalize, truthPaths } from '../repo.js';

const STATUSES: SurfaceStatus[] = ['STUDIO', 'DUAL', 'LEGACY', 'OOS', 'RETIRED'];
const STATUS_RE = /\*\*(STUDIO|DUAL|LEGACY|OOS|RETIRED)\*\*/;

/** Pull route patterns out of a Routes cell: backticked tokens and bare /paths. */
function extractRoutes(cell: string): string[] {
  const out = new Set<string>();
  for (const m of cell.matchAll(/`([^`]+)`/g)) {
    for (const piece of m[1]!.split(/[,\s]+/)) {
      const t = piece.trim().replace(/[.,;]+$/, '');
      if (t.startsWith('/')) out.add(t);
    }
  }
  for (const m of cell.matchAll(/(^|[\s,(])(\/[A-Za-z0-9:_\-*/{}]+)/g)) {
    out.add(m[2]!.replace(/[.,;]+$/, ''));
  }
  return [...out];
}

function splitRow(line: string): string[] {
  return line.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((c) => c.trim());
}

export function loadLedger(root: string): LedgerTruth {
  const path = truthPaths(root).ledger;
  let raw: string;
  try {
    raw = readFileSync(path, 'utf-8');
  } catch {
    return { ok: false, warning: `surface ledger not found at ${path} — surface routing unavailable`, rows: [], rowsWithoutRoutes: 0 };
  }

  const rows: SurfaceRow[] = [];
  let section = '';
  let withoutRoutes = 0;

  for (const line of raw.split('\n')) {
    if (line.startsWith('## ')) {
      section = line.slice(3).trim();
      continue;
    }
    if (!line.startsWith('|')) continue;

    const cells = splitRow(line);
    if (cells.length < 4) continue;
    if (/^[-: ]+$/.test(cells[0]!)) continue;                    // separator row
    if (/^(surface|status)$/i.test(cells[0]!)) continue;         // header row

    const statusCell = cells[2]!;
    const m = STATUS_RE.exec(statusCell);
    if (!m) continue;

    // The status-vocabulary table's first cell IS the status name — skip it.
    const surface = cells[0]!.replace(/\*\*/g, '').trim();
    if (STATUSES.includes(surface.toUpperCase() as SurfaceStatus)) continue;

    const routes = extractRoutes(cells[1]!);
    if (routes.length === 0) withoutRoutes += 1;

    rows.push({ section, surface, routes, status: m[1] as SurfaceStatus, notes: cells[3] ?? '' });
  }

  return { ok: true, rows, rowsWithoutRoutes: withoutRoutes };
}

/**
 * Find the row for a route or a surface name. Longest route match wins.
 * Returns null when nothing matches — the caller renders that as `no-row`
 * ("the ledger has a bug; add the row, don't guess"), never as a guess.
 */
export function surfaceFor(truth: LedgerTruth, query: string): SurfaceRow | null {
  const q = normalize(query);

  let best: SurfaceRow | null = null;
  let bestLen = -1;
  for (const row of truth.rows) {
    for (const route of row.routes) {
      const r = normalize(route);
      if (q === r || q.startsWith(r.endsWith('/') ? r : r + '/')) {
        if (r.length > bestLen) { best = row; bestLen = r.length; }
      }
    }
  }
  if (best) return best;

  const lower = q.toLowerCase();
  return truth.rows.find((r) => r.surface.toLowerCase() === lower) ?? null;
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `npm test`
Expected: all ledger tests pass.

- [ ] **Step 6: Verify parse coverage against the live ledger**

```bash
npm run build && node -e "
import('./dist/truth/ledger.js').then(m => {
  const t = m.loadLedger('/mnt/c/Dev/Apex-APP-SW/apex-app');
  const by = {};
  for (const r of t.rows) by[r.status] = (by[r.status] ?? 0) + 1;
  console.log('rows', t.rows.length, by, 'route-less', t.rowsWithoutRoutes);
});"
```

Expected: roughly 106 rows, distribution near `{STUDIO:52, DUAL:23, LEGACY:16, RETIRED:12, OOS:3}`, ~9 route-less. If the count is dramatically lower, the parser is dropping table shapes — fix before continuing.

- [ ] **Step 7: Commit**

```bash
git add harnesses/apex-dev-harness
git commit -m "feat(apex-dev-harness): surface-ledger parser with route and name lookup"
```

---

### Task 4: Policy loader and the default policy

**Files:**
- Create: `src/truth/policy.ts`
- Create: `templates/policy.json`
- Test: `test/policy.test.js`

**Interfaces:**
- Consumes: `Policy`, `PolicyRule` from `src/types.ts`; `normalize`, `truthPaths` from `src/repo.ts`.
- Produces:
  - `DEFAULT_POLICY: Policy` — the built-in used when apex-app has no `.harness/policy.json`
  - `loadPolicy(root: string): Policy`
  - `rulesInScope(policy: Policy, relPath: string): PolicyRule[]`

- [ ] **Step 1: Write `templates/policy.json`**

This is the file `apex init` installs into apex-app. It encodes the owner ruling of 2026-08-24.

```json
{
  "version": 1,
  "rules": [
    { "id": "BOUND-005", "tier": "block", "scope": "repo", "check": "no-dotenv-files",
      "source": ".agents/rules/boundaries.md" },
    { "id": "BOUND-002", "tier": "block", "scope": "repo", "check": "no-credential-literals",
      "source": ".agents/rules/boundaries.md" },
    { "id": "LANE-RETIRED", "tier": "block", "scope": "repo", "check": "no-retired-lane-edit",
      "source": "tools/repo-lanes/lanes.json" },
    { "id": "LANE-IMPORT", "tier": "block", "scope": "repo", "check": "no-new-legacy-import",
      "source": "tools/repo-lanes/lanes.json" },
    { "id": "CONV-PROJECTDATA", "tier": "block", "scope": "repo", "check": "no-project-data-json",
      "source": "CLAUDE.md Key Conventions" },
    { "id": "BOUND-004", "tier": "block", "scope": "backend/agentic/", "check": "no-provider-sdk-import",
      "source": ".agents/rules/boundaries.md" },
    { "id": "ARCH-003", "tier": "warn", "scope": "backend/agentic/", "check": "no-mutable-venue-scope",
      "source": ".agents/rules/architecture.md" },
    { "id": "ARCH-005", "tier": "warn", "scope": "backend/agentic/", "check": "no-untrusted-venue-header",
      "source": ".agents/rules/architecture.md" },
    { "id": "BOUND-001", "tier": "historical", "scope": "backend/agentic/",
      "source": ".agents/rules/boundaries.md",
      "note": "The repo-wide isolation clause governed the AgentLoop framework deleted 2026-07-05 (ADR-002). ui/src/agentic/ no longer exists. Enforcing it repo-wide would block nearly all work, so it is recorded, not enforced." }
  ],
  "obligations": [
    {
      "id": "studio-capability-manifest",
      "reason": "diff touches a Studio capability surface",
      "when": { "anyPathMatches": [
        "backend/app/routes/studio_chat.py",
        "backend/agentic/core/mutations/registry.py",
        "backend/app/routes/studio_adapters/**",
        "backend/app/routes/studio_rest_write_exceptions.py",
        "ui/src/apexStudio/views/registry.js",
        "ui/src/apexStudio/rail/navDirective.js"
      ] },
      "run": [
        "cd backend && python -m scripts.gen_studio_capability_manifest --check",
        "cd backend && python -m pytest app/routes/tests/test_studio_capability_manifest.py app/routes/tests/test_studio_write_read_parity.py app/routes/tests/test_studio_resolver_tenancy.py -q"
      ]
    },
    {
      "id": "stack-map",
      "reason": "diff touches the capability manifest, the stack map, or the entity tree",
      "when": { "anyPathMatches": [
        "backend/app/routes/studio_capability_manifest.json",
        "tools/stack-map/**",
        "ui/src/apexStudio/docs/07-entity-tree.md"
      ] },
      "run": [
        "python tools/stack-map/extract_capability.py --check",
        "python -m pytest tools/stack-map/tests/ -q"
      ]
    },
    {
      "id": "ui-style-generators",
      "reason": "diff touches ui/src styles",
      "when": { "anyPathMatches": ["ui/src/**/*.js", "ui/src/**/*.jsx", "ui/src/**/*.css"] },
      "run": ["cd ui && node scripts/check-style-generators.js"]
    },
    {
      "id": "lane-import-guards",
      "reason": "diff touches a governed root, so import guards must still pass",
      "when": { "anyPathMatches": ["backend/**", "ui/src/**", "tools/repo-lanes/**"] },
      "run": ["python -m pytest tools/repo-lanes/tests/ -q"]
    }
  ],
  "watchlist": [
    "quick win", "quick fix", "fallback", "workaround", "bandaid", "band-aid",
    "temporary", "interim", "simplified version", "for now", "good enough",
    "sufficient for now", "small change", "minor tweak", "for consistency",
    "just using", "tests coming later", "will add tests"
  ],
  "mwgTargets": [
    { "match": "ui/src/**", "target": "Baseline Newly Available (apex-app SaaS surface)" },
    { "match": "backend/app/config/site_builder_kits/**", "target": "Baseline Widely Available (guest-facing venue site)" },
    { "match": "website-edge-service/**", "target": "Baseline Widely Available (guest-facing funnel/landing)" }
  ],
  "skillRules": [
    { "match": "ui/src/**", "skills": ["awesome-design (before AND after)", "modern-web-guidance"] },
    { "match": "backend/app/routes/website_builder_studio.py", "skills": ["apex-globals-pipeline", "apex-publishing-pipeline"] },
    { "match": "backend/app/config/site_builder_kits/**", "skills": ["awesome-design", "modern-web-guidance", "apex-starter-pages"] },
    { "match": "ui/src/apexStudio/**", "skills": ["awesome-design", "modern-web-guidance"] }
  ],
  "parityRules": [
    { "match": "ui/src/pages/HouseGuideAdminPage.jsx", "surfaces": ["ui/src/portal/PortalHouseGuidePage.jsx (staff view)"] },
    { "match": "ui/src/**", "surfaces": ["desktop layout vs mobile branch (search isMobile)", "roles: super admin, org, venue manager, staff"] }
  ]
}
```

- [ ] **Step 2: Write the failing test `test/policy.test.js`**

```javascript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadPolicy, rulesInScope, DEFAULT_POLICY } from '../dist/truth/policy.js';

test('the default policy scopes the secrets rules repo-wide', () => {
  const r = DEFAULT_POLICY.rules.find((x) => x.id === 'BOUND-005');
  assert.equal(r.tier, 'block');
  assert.equal(r.scope, 'repo');
});

test('BOUND-001 is recorded as historical, never enforced', () => {
  const r = DEFAULT_POLICY.rules.find((x) => x.id === 'BOUND-001');
  assert.equal(r.tier, 'historical');
  assert.match(r.note, /2026-07-05/);
});

test('no rule mentions ui/src/agentic — that path no longer exists', () => {
  assert.equal(JSON.stringify(DEFAULT_POLICY).includes('ui/src/agentic'), false);
});

test('agentic-scoped rules do not apply to app code', () => {
  const appRules = rulesInScope(DEFAULT_POLICY, 'ui/src/marketing/Page.jsx').map((r) => r.id);
  assert.equal(appRules.includes('BOUND-004'), false);
  assert.equal(appRules.includes('BOUND-005'), true);
});

test('agentic-scoped rules apply inside backend/agentic', () => {
  const ids = rulesInScope(DEFAULT_POLICY, 'backend/agentic/core/llm/foo.py').map((r) => r.id);
  assert.equal(ids.includes('BOUND-004'), true);
});

test('historical rules are never returned as in-scope', () => {
  const ids = rulesInScope(DEFAULT_POLICY, 'backend/agentic/core/x.py').map((r) => r.id);
  assert.equal(ids.includes('BOUND-001'), false);
});

test('a project policy overrides the default', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-policy-'));
  try {
    mkdirSync(join(dir, '.harness'), { recursive: true });
    writeFileSync(join(dir, '.harness', 'policy.json'), JSON.stringify({
      version: 1, rules: [], obligations: [], watchlist: ['bespoke'],
      mwgTargets: [], skillRules: [], parityRules: [],
    }));
    const p = loadPolicy(dir);
    assert.equal(p.ok, true);
    assert.deepEqual(p.watchlist, ['bespoke']);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a missing policy falls back to the default with a warning', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-nopolicy-'));
  try {
    const p = loadPolicy(dir);
    assert.match(p.warning, /policy\.json/);
    assert.equal(p.rules.length, DEFAULT_POLICY.rules.length);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a malformed policy falls back to the default rather than throwing', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-badpolicy-'));
  try {
    mkdirSync(join(dir, '.harness'), { recursive: true });
    writeFileSync(join(dir, '.harness', 'policy.json'), '{ nope');
    const p = loadPolicy(dir);
    assert.equal(p.ok, false);
    assert.equal(p.rules.length, DEFAULT_POLICY.rules.length);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `npm test`
Expected: FAIL — `Cannot find module '../dist/truth/policy.js'`

- [ ] **Step 4: Write `src/truth/policy.ts`**

```typescript
// SPDX-License-Identifier: MIT
// Load .harness/policy.json — the only NEW truth the harness introduces.
// It holds policy (which rules bite, and where), never facts about the repo.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { Policy, PolicyRule } from '../types.js';
import { normalize, truthPaths } from '../repo.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const BUNDLED = join(HERE, '..', '..', 'templates', 'policy.json');

function readBundled(): Omit<Policy, 'ok' | 'warning'> {
  return JSON.parse(readFileSync(BUNDLED, 'utf-8'));
}

/** The built-in policy, used when the project ships none. */
export const DEFAULT_POLICY: Policy = { ok: true, ...readBundled() };

export function loadPolicy(root: string): Policy {
  const path = truthPaths(root).policy;
  let raw: string;
  try {
    raw = readFileSync(path, 'utf-8');
  } catch {
    return { ...DEFAULT_POLICY, ok: true, warning: `no ${path} — using the harness's built-in policy` };
  }
  try {
    return { ok: true, ...(JSON.parse(raw) as Omit<Policy, 'ok'>) };
  } catch (err) {
    const why = err instanceof Error ? err.message : String(err);
    return { ...DEFAULT_POLICY, ok: false, warning: `could not parse ${path}: ${why} — using the built-in policy` };
  }
}

/**
 * The enforceable rules that apply to a path. `historical` rules are recorded
 * in the policy for provenance and are never returned here.
 */
export function rulesInScope(policy: Policy, relPath: string): PolicyRule[] {
  const p = normalize(relPath);
  return policy.rules.filter((r) => {
    if (r.tier === 'historical') return false;
    if (r.scope === 'repo') return true;
    return p.startsWith(normalize(r.scope));
  });
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `npm test`
Expected: all policy tests pass.

- [ ] **Step 6: Commit**

```bash
git add harnesses/apex-dev-harness
git commit -m "feat(apex-dev-harness): policy loader with scoped rules and the 2026-08-24 owner ruling"
```

---

### Task 5: Glob matching

**Files:**
- Create: `src/glob.ts`
- Test: `test/glob.test.js`

**Interfaces:**
- Consumes: `normalize` from `src/repo.ts`.
- Produces: `matchesGlob(pattern: string, path: string): boolean`

Its own task because four later units depend on identical semantics; a bug here would surface as four unrelated-looking bugs.

- [ ] **Step 1: Write the failing test `test/glob.test.js`**

```javascript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { matchesGlob } from '../dist/glob.js';

test('exact paths match', () => {
  assert.equal(matchesGlob('backend/app/routes/studio_chat.py', 'backend/app/routes/studio_chat.py'), true);
  assert.equal(matchesGlob('backend/app/routes/studio_chat.py', 'backend/app/routes/other.py'), false);
});

test('** spans directory separators', () => {
  assert.equal(matchesGlob('ui/src/**', 'ui/src/a/b/c.jsx'), true);
  assert.equal(matchesGlob('backend/app/routes/studio_adapters/**', 'backend/app/routes/studio_adapters/globals.py'), true);
  assert.equal(matchesGlob('ui/src/**', 'backend/app/x.py'), false);
});

test('* does not span separators', () => {
  assert.equal(matchesGlob('ui/src/*.js', 'ui/src/index.js'), true);
  assert.equal(matchesGlob('ui/src/*.js', 'ui/src/deep/index.js'), false);
});

test('**/*.ext matches at any depth', () => {
  assert.equal(matchesGlob('ui/src/**/*.jsx', 'ui/src/marketing/CampaignCockpit.jsx'), true);
  assert.equal(matchesGlob('ui/src/**/*.jsx', 'ui/src/index.js'), false);
});

test('windows separators in the path still match', () => {
  assert.equal(matchesGlob('ui/src/**', 'ui\\src\\a\\b.jsx'), true);
});

test('regex metacharacters in a pattern are literal', () => {
  assert.equal(matchesGlob('backend/app/x+y.py', 'backend/app/x+y.py'), true);
  assert.equal(matchesGlob('backend/app/x+y.py', 'backend/app/xy.py'), false);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test`
Expected: FAIL — `Cannot find module '../dist/glob.js'`

- [ ] **Step 3: Write `src/glob.ts`**

```typescript
// SPDX-License-Identifier: MIT
// Minimal glob matching. Deliberately not a dependency: the patterns we need
// are `**`, `*`, and literals, and a tiny implementation we can test beats a
// package whose semantics we would have to look up.

import { normalize } from './repo.js';

/** Escape everything regex-special except the wildcards we implement. */
function toRegex(pattern: string): RegExp {
  let out = '';
  for (let i = 0; i < pattern.length; i++) {
    const c = pattern[i]!;
    if (c === '*') {
      if (pattern[i + 1] === '*') {
        // `**/` should also match zero directories, so a/**/b.js matches a/b.js
        if (pattern[i + 2] === '/') { out += '(?:.*/)?'; i += 2; }
        else { out += '.*'; i += 1; }
      } else {
        out += '[^/]*';
      }
      continue;
    }
    out += c.replace(/[.+?^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${out}$`);
}

export function matchesGlob(pattern: string, path: string): boolean {
  return toRegex(normalize(pattern)).test(normalize(path));
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm test`
Expected: all glob tests pass.

- [ ] **Step 5: Commit**

```bash
git add harnesses/apex-dev-harness
git commit -m "feat(apex-dev-harness): minimal glob matcher shared by policy consumers"
```

---

### Task 6: `route()`

**Files:**
- Create: `src/route.ts`
- Test: `test/route.test.js`

**Interfaces:**
- Consumes: `loadLanes`/`laneFor`/`importAllowed` (Task 2), `loadLedger`/`surfaceFor` (Task 3), `loadPolicy` (Task 4), `matchesGlob` (Task 5), `RouteVerdict` (Task 1).
- Produces:
  - `route(root: string, query: string): RouteVerdict`
  - `formatRoute(v: RouteVerdict): string` — the human rendering used by the CLI

- [ ] **Step 1: Write the failing test `test/route.test.js`**

```javascript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { route, formatRoute } from '../dist/route.js';

function repo() {
  const dir = mkdtempSync(join(tmpdir(), 'apex-route-'));
  mkdirSync(join(dir, 'tools', 'repo-lanes'), { recursive: true });
  mkdirSync(join(dir, '.claude', 'tasks'), { recursive: true });
  writeFileSync(join(dir, 'tools', 'repo-lanes', 'lanes.json'), JSON.stringify({
    governedRoots: ['ui/src', 'backend/app'],
    modules: [
      { path: 'ui/src/marketing/', lane: 'production', notes: 'Marketing zone.' },
      { path: 'ui/src/quizBuilder/', lane: 'legacy', replacement: 'Marketing - Forms' },
      { path: 'ui/src/menuDesigner/', lane: 'retired', notes: 'Route retired 2026-07-18.' },
    ],
    importGuards: [{
      id: 'ui-quiz', namespace: 'ui/src/quizBuilder', language: 'js',
      internalExempt: ['ui/src/quizBuilder/'],
      allow: [{ file: 'ui/src/marketing/CampaignCockpit.jsx', reason: 'listQuizzes via quizBuilder/api.' }],
    }],
  }));
  writeFileSync(join(dir, '.claude', 'tasks', 'apex-studio-surface-ledger.md'), [
    '## 06 Marketing',
    '',
    '| Surface | Routes | Status | Notes |',
    '|---|---|---|---|',
    '| Campaigns | `/marketing/campaigns` | **DUAL** | studio campaign surface |',
  ].join('\n'));
  return dir;
}

test('a production UI file gets lane, mwg, skills and parity', () => {
  const dir = repo();
  try {
    const v = route(dir, 'ui/src/marketing/CampaignCockpit.jsx');
    assert.equal(v.lane, 'production');
    assert.match(v.mwg, /Baseline Newly Available/);
    assert.ok(v.skills.some((s) => s.startsWith('awesome-design')));
    assert.ok(v.parity.length > 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a route query resolves the surface and its routing sentence', () => {
  const dir = repo();
  try {
    const v = route(dir, '/marketing/campaigns');
    assert.equal(v.surfaceVerdict, 'row');
    assert.equal(v.surface.status, 'DUAL');
    assert.match(v.routing, /New features/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('an unknown surface reports no-row, not a guess', () => {
  const dir = repo();
  try {
    const v = route(dir, '/some/unlisted/route');
    assert.equal(v.surfaceVerdict, 'no-row');
    assert.equal(v.surface, null);
    assert.match(formatRoute(v), /add the row/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a grandfathered importer is named as such', () => {
  const dir = repo();
  try {
    const v = route(dir, 'ui/src/marketing/CampaignCockpit.jsx');
    assert.ok(v.importNotes.some((n) => /grandfathered/i.test(n)));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a retired module is flagged in the verdict', () => {
  const dir = repo();
  try {
    const v = route(dir, 'ui/src/menuDesigner/Canvas.jsx');
    assert.equal(v.lane, 'retired');
    assert.match(formatRoute(v), /RETIRED/i);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('an ungoverned path says so instead of assuming production', () => {
  const dir = repo();
  try {
    assert.equal(route(dir, 'scripts/oneoff.sh').lane, 'ungoverned');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('missing truth files degrade to warnings, not an exception', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-bare-'));
  try {
    const v = route(dir, 'ui/src/x.jsx');
    assert.equal(v.lane, 'ungoverned');
    assert.ok(v.warnings.length >= 2);
    assert.ok(formatRoute(v).length > 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test`
Expected: FAIL — `Cannot find module '../dist/route.js'`

- [ ] **Step 3: Write `src/route.ts`**

```typescript
// SPDX-License-Identifier: MIT
// Compose lanes + ledger + policy into the answer to "what applies here?".

import type { RouteVerdict, SurfaceStatus } from './types.js';
import { loadLanes, laneFor, importAllowed } from './truth/lanes.js';
import { loadLedger, surfaceFor } from './truth/ledger.js';
import { loadPolicy } from './truth/policy.js';
import { matchesGlob } from './glob.js';
import { normalize } from './repo.js';

/** The ledger's own routing sentences, keyed by status. */
const ROUTING: Record<SurfaceStatus, string> = {
  STUDIO: 'Build in Studio. Touching the legacy twin is a smell.',
  DUAL: 'New features go to the Studio side (unless a named parity gap blocks). Fixes go wherever the bug lives. Behavior changes must keep both sides consistent (surface-parity rule).',
  LEGACY: 'Build in the legacy surface, guilt-free. If the ask is big, raise "is this the moment to port the domain?" first.',
  OOS: 'Different audience, not a deferred port. Never a Studio TODO.',
  RETIRED: "Route redirects or the surface is dead. Don't touch.",
};

export function route(root: string, query: string): RouteVerdict {
  const lanes = loadLanes(root);
  const ledger = loadLedger(root);
  const policy = loadPolicy(root);

  const warnings: string[] = [];
  for (const t of [lanes, ledger, policy]) if (t.warning) warnings.push(t.warning);

  const q = normalize(query);
  const { lane, entry } = laneFor(lanes, q);
  const surface = surfaceFor(ledger, q);

  const mwg = policy.mwgTargets.find((m) => matchesGlob(m.match, q))?.target ?? null;

  const skills: string[] = [];
  for (const rule of policy.skillRules) {
    if (matchesGlob(rule.match, q)) for (const s of rule.skills) if (!skills.includes(s)) skills.push(s);
  }

  const parity: string[] = [];
  for (const rule of policy.parityRules) {
    if (matchesGlob(rule.match, q)) for (const s of rule.surfaces) if (!parity.includes(s)) parity.push(s);
  }

  // Which guarded namespaces does this file already have permission to import?
  const importNotes: string[] = [];
  for (const guard of lanes.importGuards) {
    const hit = guard.allow.find((a) => normalize(a.file) === q);
    if (hit) {
      importNotes.push(
        `${guard.namespace} is LEGACY — this file is a grandfathered importer (${hit.reason}) Do not add new imports.`,
      );
      continue;
    }
    if (!importAllowed(lanes, q, guard.namespace).allowed) {
      importNotes.push(`${guard.namespace} is guarded — a new import from this file fails CI.`);
    }
  }

  return {
    query,
    lane,
    laneEntry: entry,
    surface,
    surfaceVerdict: surface ? 'row' : 'no-row',
    routing: surface ? ROUTING[surface.status] : null,
    mwg,
    skills,
    parity,
    importNotes,
    warnings,
  };
}

function pad(label: string): string {
  return (label + '           ').slice(0, 11);
}

export function formatRoute(v: RouteVerdict): string {
  const lines: string[] = [];
  const laneNote = v.laneEntry?.notes ? ` — ${v.laneEntry.notes}` : '';
  lines.push(`${pad('lane')}${v.lane.toUpperCase()}${laneNote}`);
  if (v.laneEntry?.replacement) lines.push(`${pad('replacement')}${v.laneEntry.replacement}`);

  if (v.surface) {
    lines.push(`${pad('surface')}${v.surface.surface}  ·  ${v.surface.status}   [${v.surface.section}]`);
    lines.push(`${pad('routing')}${v.routing}`);
  } else {
    lines.push(`${pad('surface')}no row — the ledger has a bug; add the row, don't guess`);
  }

  if (v.mwg) lines.push(`${pad('mwg')}${v.mwg}`);
  if (v.skills.length) lines.push(`${pad('skills')}${v.skills.join(', ')}`);
  if (v.parity.length) lines.push(`${pad('parity')}${v.parity.join(' · ')}`);
  for (const n of v.importNotes) lines.push(`${pad('imports')}${n}`);
  for (const w of v.warnings) lines.push(`${pad('warn')}${w}`);
  return lines.join('\n');
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm test`
Expected: all route tests pass.

- [ ] **Step 5: Verify against the live repo**

```bash
npm run build && node -e "
import('./dist/route.js').then(m => {
  const R='/mnt/c/Dev/Apex-APP-SW/apex-app';
  for (const q of ['ui/src/marketing/CampaignCockpit.jsx','/menu-designer','ui/src/menuDesigner/x.jsx'])
    console.log('###', q, '\n' + m.formatRoute(m.route(R, q)) + '\n');
});"
```

Expected: the CampaignCockpit query names its grandfathered `quizBuilder` import; `/menu-designer` resolves RETIRED.

- [ ] **Step 6: Commit**

```bash
git add harnesses/apex-dev-harness
git commit -m "feat(apex-dev-harness): route() composing lanes, ledger and policy"
```

---

### Task 7: `check()` — the block tier

**Files:**
- Create: `src/check.ts`
- Test: `test/check.test.js`

**Interfaces:**
- Consumes: `loadLanes`/`laneFor`/`importAllowed` (Task 2), `loadPolicy`/`rulesInScope` (Task 4), `CheckDecision` (Task 1).
- Produces: `check(root: string, relPath: string, content: string | null): CheckDecision`

`content` is null when the tool provides no new text (e.g. a rename); path-only rules still apply.

**Constraint reminder:** build every credential-shaped sample by concatenation. A literal one in this file will be rejected by apex-app's own hook.

- [ ] **Step 1: Write the failing test `test/check.test.js`**

```javascript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { check } from '../dist/check.js';

/** Build a credential-shaped sample at runtime — never write one literally. */
function credentialSample() {
  return ['API', '_KEY = ', JSON.stringify('x'.repeat(24))].join('');
}

function repo() {
  const dir = mkdtempSync(join(tmpdir(), 'apex-check-'));
  mkdirSync(join(dir, 'tools', 'repo-lanes'), { recursive: true });
  writeFileSync(join(dir, 'tools', 'repo-lanes', 'lanes.json'), JSON.stringify({
    governedRoots: ['ui/src', 'backend'],
    modules: [
      { path: 'ui/src/menuDesigner/', lane: 'retired' },
      { path: 'ui/src/quizBuilder/', lane: 'legacy' },
      { path: 'ui/src/marketing/', lane: 'production' },
      { path: 'backend/agentic/', lane: 'production' },
    ],
    importGuards: [{
      id: 'ui-quiz', namespace: 'ui/src/quizBuilder', language: 'js',
      internalExempt: ['ui/src/quizBuilder/'],
      allow: [{ file: 'ui/src/marketing/CampaignCockpit.jsx', reason: 'listQuizzes.' }],
    }],
  }));
  return dir;
}

test('creating a dotenv file is blocked, naming the rule', () => {
  const dir = repo();
  try {
    const d = check(dir, '.env.local', 'placeholder');
    assert.equal(d.allow, false);
    assert.equal(d.ruleId, 'BOUND-005');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a credential literal is blocked', () => {
  const dir = repo();
  try {
    const d = check(dir, 'backend/app/x.py', credentialSample());
    assert.equal(d.allow, false);
    assert.equal(d.ruleId, 'BOUND-002');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('editing a retired-lane module is blocked', () => {
  const dir = repo();
  try {
    const d = check(dir, 'ui/src/menuDesigner/Canvas.jsx', 'export const x = 1;');
    assert.equal(d.allow, false);
    assert.equal(d.ruleId, 'LANE-RETIRED');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a NEW import of a guarded namespace is blocked', () => {
  const dir = repo();
  try {
    const d = check(dir, 'ui/src/marketing/NewPage.jsx', "import { listQuizzes } from '../quizBuilder/api';");
    assert.equal(d.allow, false);
    assert.equal(d.ruleId, 'LANE-IMPORT');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a grandfathered importer may keep its import', () => {
  const dir = repo();
  try {
    const d = check(dir, 'ui/src/marketing/CampaignCockpit.jsx', "import { listQuizzes } from '../quizBuilder/api';");
    assert.equal(d.allow, true);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('projectDataJson is blocked as a dead field', () => {
  const dir = repo();
  try {
    const d = check(dir, 'backend/app/routes/x.py', 'doc["projectDataJson"] = payload');
    assert.equal(d.allow, false);
    assert.equal(d.ruleId, 'CONV-PROJECTDATA');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a provider SDK import is blocked inside backend/agentic', () => {
  const dir = repo();
  try {
    const d = check(dir, 'backend/agentic/services/sales.py', 'import anthropic');
    assert.equal(d.allow, false);
    assert.equal(d.ruleId, 'BOUND-004');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('the same import is allowed inside the abstraction layer', () => {
  const dir = repo();
  try {
    assert.equal(check(dir, 'backend/agentic/core/llm/provider_a.py', 'import anthropic').allow, true);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('the same import is NOT blocked outside agentic — the rule is scoped', () => {
  const dir = repo();
  try {
    assert.equal(check(dir, 'backend/app/agents/blog.py', 'import anthropic').allow, true);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('ordinary edits pass', () => {
  const dir = repo();
  try {
    assert.equal(check(dir, 'ui/src/marketing/CampaignCockpit.jsx', 'const a = 1;').allow, true);
    assert.equal(check(dir, 'ui/src/marketing/Other.jsx', 'const b = 2;').allow, true);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a bare repo with no truth files still allows edits — fail open', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-bare-check-'));
  try {
    assert.equal(check(dir, 'ui/src/x.jsx', 'const a = 1;').allow, true);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test`
Expected: FAIL — `Cannot find module '../dist/check.js'`

- [ ] **Step 3: Write `src/check.ts`**

```typescript
// SPDX-License-Identifier: MIT
// Block-tier evaluation of a single pending edit. Every refusal names its
// rule and the document that rule came from.

import { basename } from 'node:path';
import type { CheckDecision, PolicyRule } from './types.js';
import { loadLanes, laneFor, importAllowed } from './truth/lanes.js';
import { loadPolicy, rulesInScope } from './truth/policy.js';
import { normalize } from './repo.js';

// Assembled from parts so this source never contains a credential-shaped
// literal of its own (apex-app's guardrail hook rejects files that do).
const SECRET_NAME = '(?:API_?KEY|SECRET|TOKEN|PASSWORD|CREDENTIAL|PRIVATE_?KEY)';
const OPAQUE_VALUE = String.raw`['"][^'"\s]{16,}['"]`;
const CREDENTIAL_RE = new RegExp(
  String.raw`\b[A-Za-z_]*${SECRET_NAME}[A-Za-z_]*\s*[:=]\s*${OPAQUE_VALUE}`,
  'i',
);

const PROVIDER_IMPORT_RE =
  /^\s*(?:from\s+(?:anthropic|openai|google\.generativeai|vertexai)\b|import\s+(?:anthropic|openai|vertexai)\b)/m;

/** The LLM abstraction layer is the one place provider SDKs may be imported. */
const LLM_LAYER = 'backend/agentic/core/llm/';

function deny(rule: PolicyRule, reason: string): CheckDecision {
  return { allow: false, ruleId: rule.id, reason, source: rule.source };
}

export function check(root: string, relPath: string, content: string | null): CheckDecision {
  const p = normalize(relPath);
  const lanes = loadLanes(root);
  const policy = loadPolicy(root);
  const active = rulesInScope(policy, p);
  const rule = (id: string) => active.find((r) => r.id === id && r.tier === 'block');

  // BOUND-005 — no dotenv files, anywhere.
  const dotenv = rule('BOUND-005');
  if (dotenv && /^\.env(\..+)?$/.test(basename(p))) {
    return deny(dotenv, `${p} is a dotenv file. Credentials belong in Google Secret Manager.`);
  }

  // LANE-RETIRED — a retired module is delete-on-sight, not edit-on-sight.
  const retired = rule('LANE-RETIRED');
  if (retired) {
    const { lane, entry } = laneFor(lanes, p);
    if (lane === 'retired') {
      return deny(retired, `${entry?.path ?? p} is in the RETIRED lane. ${entry?.notes ?? ''}`.trim());
    }
  }

  if (content !== null) {
    // BOUND-002 — no credential literals.
    const creds = rule('BOUND-002');
    if (creds && CREDENTIAL_RE.test(content)) {
      return deny(creds, 'Credential-shaped literal. Retrieve it from Google Secret Manager instead.');
    }

    // CONV-PROJECTDATA — the dead legacy field.
    const pdj = rule('CONV-PROJECTDATA');
    if (pdj && content.includes('projectDataJson')) {
      return deny(pdj, 'projectDataJson is a dead legacy field — never read it, never write it.');
    }

    // BOUND-004 — provider SDKs only inside the abstraction layer.
    const provider = rule('BOUND-004');
    if (provider && !p.startsWith(LLM_LAYER) && PROVIDER_IMPORT_RE.test(content)) {
      return deny(provider, `Direct LLM provider SDK import. Use the abstraction layer in ${LLM_LAYER}.`);
    }

    // LANE-IMPORT — no NEW importers of a guarded namespace.
    // Deliberately narrow: only an import/from statement naming the namespace's
    // leaf counts. A false block is the worst failure this harness can produce,
    // and the authoritative check is pytest tools/repo-lanes/tests/.
    const importRule = rule('LANE-IMPORT');
    if (importRule) {
      for (const guard of lanes.importGuards) {
        const leaf = normalize(guard.namespace).split('/').filter(Boolean).pop();
        if (!leaf) continue;
        const importRe = new RegExp(
          String.raw`(?:^\s*import\s|^\s*from\s|\bfrom\s+['"][^'"]*)\b${leaf}\b`,
          'm',
        );
        if (!importRe.test(content)) continue;
        if (!importAllowed(lanes, p, guard.namespace).allowed) {
          return deny(
            importRule,
            `New import of ${guard.namespace}, a guarded legacy namespace. The allowlist only shrinks — new importers fail CI.`,
          );
        }
      }
    }
  }

  return { allow: true };
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm test`
Expected: all check tests pass. If the LANE-IMPORT rule fires on the "ordinary edits pass" case, tighten `importRe` before continuing — a false block is the worst failure this harness can produce.

- [ ] **Step 5: Commit**

```bash
git add harnesses/apex-dev-harness
git commit -m "feat(apex-dev-harness): block-tier check with scoped rules and named refusals"
```

---

### Task 8: Watchlist scan

**Files:**
- Create: `src/watchlist.ts`
- Test: `test/watchlist.test.js`

**Interfaces:**
- Consumes: `Policy`, `WatchlistHit` (Task 1).
- Produces: `scanWatchlist(policy: Policy, text: string): WatchlistHit[]`

- [ ] **Step 1: Write the failing test `test/watchlist.test.js`**

```javascript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { scanWatchlist } from '../dist/watchlist.js';
import { DEFAULT_POLICY } from '../dist/truth/policy.js';

test('finds a watchlist term with its line number', () => {
  const hits = scanWatchlist(DEFAULT_POLICY, 'all good\nthis is fine for now\ndone');
  assert.equal(hits.length, 1);
  assert.equal(hits[0].term, 'for now');
  assert.equal(hits[0].line, 2);
  assert.match(hits[0].excerpt, /fine for now/);
});

test('matching is case-insensitive', () => {
  assert.equal(scanWatchlist(DEFAULT_POLICY, 'Tests Coming Later').length, 1);
});

test('clean text produces no hits', () => {
  assert.deepEqual(scanWatchlist(DEFAULT_POLICY, 'Implemented the resolver and its tests.'), []);
});

test('a term inside a longer word does not match', () => {
  assert.deepEqual(scanWatchlist(DEFAULT_POLICY, 'the informant reported'), []);
});

test('each term reports once per text, not once per occurrence', () => {
  assert.equal(scanWatchlist(DEFAULT_POLICY, 'for now, for now, for now').length, 1);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test`
Expected: FAIL — `Cannot find module '../dist/watchlist.js'`

- [ ] **Step 3: Write `src/watchlist.ts`**

```typescript
// SPDX-License-Identifier: MIT
// The BOUND-006 vocabulary watchlist. A hit is not a violation — it is a
// prompt to verify the work underneath is sound.

import type { Policy, WatchlistHit } from './types.js';

function escape(term: string): string {
  return term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export function scanWatchlist(policy: Policy, text: string): WatchlistHit[] {
  const hits: WatchlistHit[] = [];
  const lines = text.split('\n');

  for (const term of policy.watchlist) {
    const re = new RegExp(`\\b${escape(term)}\\b`, 'i');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i]!;
      if (!re.test(line)) continue;
      hits.push({ term, line: i + 1, excerpt: line.trim().slice(0, 120) });
      break; // one report per term keeps the output readable
    }
  }
  return hits;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm test`
Expected: all watchlist tests pass.

- [ ] **Step 5: Commit**

```bash
git add harnesses/apex-dev-harness
git commit -m "feat(apex-dev-harness): BOUND-006 vocabulary watchlist scan"
```

---

### Task 9: `obligations()`

**Files:**
- Create: `src/obligations.ts`
- Test: `test/obligations.test.js`

**Interfaces:**
- Consumes: `matchesGlob` (Task 5), `normalize` (Task 1), `Obligation`/`Policy` (Task 1).
- Produces:
  - `changedPaths(root: string, base?: string): string[]`
  - `obligationsFor(policy: Policy, paths: string[]): Obligation[]`
  - `parityWarningsFor(policy: Policy, paths: string[]): string[]`

- [ ] **Step 1: Write the failing test `test/obligations.test.js`**

```javascript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { obligationsFor, parityWarningsFor } from '../dist/obligations.js';
import { DEFAULT_POLICY } from '../dist/truth/policy.js';

test('touching a capability surface owes the manifest obligation', () => {
  const obs = obligationsFor(DEFAULT_POLICY, ['backend/app/routes/studio_chat.py']);
  assert.ok(obs.map((o) => o.id).includes('studio-capability-manifest'));
  assert.ok(obs.find((o) => o.id === 'studio-capability-manifest').commands.length >= 1);
});

test('a studio adapter matches the ** pattern', () => {
  const ids = obligationsFor(DEFAULT_POLICY, ['backend/app/routes/studio_adapters/globals.py']).map((o) => o.id);
  assert.ok(ids.includes('studio-capability-manifest'));
});

test('a ui/src edit owes the style-generator check but not the manifest', () => {
  const ids = obligationsFor(DEFAULT_POLICY, ['ui/src/marketing/CampaignCockpit.jsx']).map((o) => o.id);
  assert.ok(ids.includes('ui-style-generators'));
  assert.equal(ids.includes('studio-capability-manifest'), false);
});

test('a docs-only change owes nothing', () => {
  assert.deepEqual(obligationsFor(DEFAULT_POLICY, ['README.md']), []);
});

test('an obligation fires once no matter how many paths match', () => {
  const obs = obligationsFor(DEFAULT_POLICY, ['ui/src/a.jsx', 'ui/src/b.jsx', 'ui/src/c.css']);
  assert.equal(obs.filter((o) => o.id === 'ui-style-generators').length, 1);
});

test('an obligation carries the reason it fired', () => {
  const o = obligationsFor(DEFAULT_POLICY, ['backend/app/routes/studio_chat.py'])[0];
  assert.match(o.reason, /capability surface/i);
});

test('parity warnings fire for a UI change', () => {
  const w = parityWarningsFor(DEFAULT_POLICY, ['ui/src/pages/HouseGuideAdminPage.jsx']);
  assert.ok(w.some((x) => /Portal/i.test(x)));
});

test('parity warnings do not fire for backend-only changes', () => {
  assert.deepEqual(parityWarningsFor(DEFAULT_POLICY, ['backend/app/services/x.py']), []);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test`
Expected: FAIL — `Cannot find module '../dist/obligations.js'`

- [ ] **Step 3: Write `src/obligations.ts`**

```typescript
// SPDX-License-Identifier: MIT
// What does this diff owe? Obligations are computed, never remembered.

import { execFileSync } from 'node:child_process';
import type { Obligation, Policy } from './types.js';
import { matchesGlob } from './glob.js';
import { normalize } from './repo.js';

function git(root: string, args: string[]): string {
  try {
    return execFileSync('git', args, { cwd: root, encoding: 'utf-8', stdio: ['ignore', 'pipe', 'ignore'] });
  } catch {
    return '';
  }
}

/** The changed files in the working tree, unstaged and staged, relative to `base`. */
export function changedPaths(root: string, base = 'HEAD'): string[] {
  const unstaged = git(root, ['diff', '--name-only', base]);
  const staged = git(root, ['diff', '--name-only', '--cached']);
  const all = new Set(
    [...unstaged.split('\n'), ...staged.split('\n')].map((s) => s.trim()).filter(Boolean),
  );
  return [...all].map(normalize);
}

export function obligationsFor(policy: Policy, paths: string[]): Obligation[] {
  const out: Obligation[] = [];
  for (const def of policy.obligations) {
    const fired = paths.some((p) => def.when.anyPathMatches.some((pattern) => matchesGlob(pattern, p)));
    if (fired) out.push({ id: def.id, reason: def.reason, commands: def.run });
  }
  return out;
}

export function parityWarningsFor(policy: Policy, paths: string[]): string[] {
  const out: string[] = [];
  for (const rule of policy.parityRules) {
    if (!paths.some((p) => matchesGlob(rule.match, p))) continue;
    for (const s of rule.surfaces) if (!out.includes(s)) out.push(s);
  }
  return out;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm test`
Expected: all obligations tests pass.

- [ ] **Step 5: Commit**

```bash
git add harnesses/apex-dev-harness
git commit -m "feat(apex-dev-harness): compute obligations and parity warnings from a diff"
```

---

### Task 10: `gate()`

**Files:**
- Create: `src/gate.ts`
- Test: `test/gate.test.js`

**Interfaces:**
- Consumes: `obligationsFor`/`parityWarningsFor`/`changedPaths` (Task 9), `scanWatchlist` (Task 8), `loadPolicy` (Task 4), `GateVerdict`/`CommandResult` (Task 1).
- Produces:
  - `runCommand(root: string, command: string): CommandResult`
  - `gate(root: string, opts?: GateOptions): GateVerdict`
  - `formatGate(v: GateVerdict): string`

`GateOptions.runner` is injectable so tests never execute pytest.

- [ ] **Step 1: Write the failing test `test/gate.test.js`**

```javascript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { gate, formatGate, runCommand } from '../dist/gate.js';

const okRunner = (_root, command) => ({ command, ok: true, output: '' });
const failRunner = (_root, command) => ({ command, ok: false, output: 'STALE' });

function bare() { return mkdtempSync(join(tmpdir(), 'apex-gate-')); }

test('a clean diff with no obligations passes', () => {
  const dir = bare();
  try {
    const v = gate(dir, { paths: ['README.md'], message: 'docs: tidy', runner: okRunner });
    assert.equal(v.ok, true);
    assert.deepEqual(v.obligations, []);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a capability-surface diff runs its commands and passes when they pass', () => {
  const dir = bare();
  try {
    const v = gate(dir, { paths: ['backend/app/routes/studio_chat.py'], message: 'feat: x', runner: okRunner });
    assert.ok(v.obligations.length > 0);
    assert.ok(v.results.length > 0);
    assert.equal(v.ok, true);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a failing obligation fails the gate and is listed', () => {
  const dir = bare();
  try {
    const v = gate(dir, { paths: ['backend/app/routes/studio_chat.py'], message: 'feat: x', runner: failRunner });
    assert.equal(v.ok, false);
    assert.ok(v.results.every((r) => r.ok === false));
    assert.match(formatGate(v), /NOT DONE/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a watchlist hit in the message fails the gate', () => {
  const dir = bare();
  try {
    const v = gate(dir, { paths: ['README.md'], message: 'fix: good enough for now', runner: okRunner });
    assert.ok(v.watchlistHits.length > 0);
    assert.equal(v.ok, false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('parity warnings appear but do not by themselves fail the gate', () => {
  const dir = bare();
  try {
    const v = gate(dir, { paths: ['ui/src/marketing/X.jsx'], message: 'feat: x', runner: okRunner });
    assert.ok(v.parityWarnings.length > 0);
    assert.equal(v.ok, true);
    assert.match(formatGate(v), /parity/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('formatGate marks a failed command', () => {
  const dir = bare();
  try {
    assert.match(formatGate(gate(dir, { paths: ['ui/src/a.jsx'], message: 'ok', runner: failRunner })), /FAILED/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('runCommand reports failure for a non-zero exit', () => {
  const dir = bare();
  try {
    assert.equal(runCommand(dir, 'node -e "process.exit(3)"').ok, false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('runCommand reports success for a zero exit', () => {
  const dir = bare();
  try {
    assert.equal(runCommand(dir, 'node -e "process.exit(0)"').ok, true);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test`
Expected: FAIL — `Cannot find module '../dist/gate.js'`

- [ ] **Step 3: Write `src/gate.ts`**

```typescript
// SPDX-License-Identifier: MIT
// The done-gate. A phase closes when its obligations pass, not when someone
// says the work is finished.

import { execSync } from 'node:child_process';
import type { CommandResult, GateVerdict } from './types.js';
import { loadPolicy } from './truth/policy.js';
import { changedPaths, obligationsFor, parityWarningsFor } from './obligations.js';
import { scanWatchlist } from './watchlist.js';

export function runCommand(root: string, command: string): CommandResult {
  try {
    const output = execSync(command, {
      cwd: root,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 10 * 60 * 1000,
    });
    return { command, ok: true, output };
  } catch (err) {
    const e = err as { stdout?: string; stderr?: string; message?: string };
    return { command, ok: false, output: (e.stdout ?? '') + (e.stderr ?? '') || (e.message ?? 'failed') };
  }
}

export interface GateOptions {
  base?: string;
  message?: string;
  /** Override the diff (tests, and `--paths` on the CLI). */
  paths?: string[];
  runner?: (root: string, command: string) => CommandResult;
}

export function gate(root: string, opts: GateOptions = {}): GateVerdict {
  const policy = loadPolicy(root);
  const runner = opts.runner ?? runCommand;
  const warnings: string[] = [];
  if (policy.warning) warnings.push(policy.warning);

  const paths = opts.paths ?? changedPaths(root, opts.base ?? 'HEAD');
  if (paths.length === 0) warnings.push('no changed files detected — the gate ran against an empty diff');

  const obligations = obligationsFor(policy, paths);
  const results: CommandResult[] = [];
  for (const o of obligations) for (const c of o.commands) results.push(runner(root, c));

  const parityWarnings = parityWarningsFor(policy, paths);
  const watchlistHits = opts.message ? scanWatchlist(policy, opts.message) : [];

  const ok = results.every((r) => r.ok) && watchlistHits.length === 0;
  return { obligations, results, parityWarnings, watchlistHits, warnings, ok };
}

export function formatGate(v: GateVerdict): string {
  const lines: string[] = [];
  for (const o of v.obligations) lines.push(`${o.reason} -> ${o.id}`);
  for (const r of v.results) lines.push(`  ${r.ok ? 'PASS' : 'FAILED'}  ${r.command}`);
  for (const p of v.parityWarnings) lines.push(`parity      ${p} — verify, or state why it diverges.`);
  for (const h of v.watchlistHits) lines.push(`watchlist   "${h.term}" (line ${h.line}) — BOUND-006`);
  for (const w of v.warnings) lines.push(`warn        ${w}`);

  const unmet = v.results.filter((r) => !r.ok).length + v.watchlistHits.length;
  lines.push(v.ok ? 'VERDICT     DONE — every obligation met' : `VERDICT     NOT DONE — ${unmet} obligation(s) unmet`);
  return lines.join('\n');
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm test`
Expected: all gate tests pass.

- [ ] **Step 5: Commit**

```bash
git add harnesses/apex-dev-harness
git commit -m "feat(apex-dev-harness): done-gate running computed obligations"
```

---

### Task 11: `doctor`, `init`, and the CLI

**Files:**
- Create: `src/doctor.ts`, `src/scaffold.ts`, `bin/apex.js`
- Create: `templates/apex-hook.js` (stub; Task 12 replaces it)
- Test: `test/cli.test.js`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `doctor(root: string | null): { ok: boolean; lines: string[] }`
  - `scaffold(root: string, opts?: { force?: boolean }): { lines: string[]; written: string[]; skipped: string[] }`
  - CLI verbs: `route`, `gate`, `check`, `watchlist`, `doctor`, `init`, `mcp`

- [ ] **Step 1: Write the stub `templates/apex-hook.js`**

```javascript
#!/usr/bin/env node
// Placeholder — replaced in Task 12 with the real hook dispatcher.
process.stdout.write('{}\n');
```

- [ ] **Step 2: Write `src/doctor.ts`**

```typescript
// SPDX-License-Identifier: MIT
// Report what the harness can actually see, and say plainly what it cannot.

import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { loadLanes } from './truth/lanes.js';
import { loadLedger } from './truth/ledger.js';
import { loadPolicy } from './truth/policy.js';

export function doctor(root: string | null): { ok: boolean; lines: string[] } {
  const lines: string[] = ['apex-dev-harness doctor', ''];
  let ok = true;
  const pass = (m: string) => lines.push(`  ok    ${m}`);
  const warn = (m: string) => lines.push(`  warn  ${m}`);
  const fail = (m: string) => { ok = false; lines.push(`  FAIL  ${m}`); };

  if (!root) {
    fail('no apex-app checkout found (looked for tools/repo-lanes/lanes.json above the cwd)');
    lines.push('', 'result: FAILED');
    return { ok, lines };
  }
  lines.push(`repo: ${root}`, '');

  lines.push('truth files');
  const lanes = loadLanes(root);
  if (lanes.ok) pass(`lanes.json — ${lanes.modules.length} modules, ${lanes.importGuards.length} import guards`);
  else fail(lanes.warning!);

  const ledger = loadLedger(root);
  if (ledger.ok) {
    const by: Record<string, number> = {};
    for (const r of ledger.rows) by[r.status] = (by[r.status] ?? 0) + 1;
    pass(`surface ledger — ${ledger.rows.length} rows parsed (${Object.entries(by).map(([k, v]) => `${k}:${v}`).join(' ')})`);
    if (ledger.rowsWithoutRoutes > 0) {
      warn(`${ledger.rowsWithoutRoutes} ledger rows have no route pattern — those are name-matchable only`);
    }
  } else fail(ledger.warning!);

  const policy = loadPolicy(root);
  if (policy.warning) warn(policy.warning);
  else pass(`policy.json — ${policy.rules.length} rules, ${policy.obligations.length} obligations`);
  lines.push('');

  lines.push('wrapped commands');
  const wrapped: Array<[string, string]> = [
    ['capability manifest', 'backend/scripts/gen_studio_capability_manifest.py'],
    ['stack map', 'tools/stack-map/extract_capability.py'],
    ['ui style generators', 'ui/scripts/check-style-generators.js'],
    ['lane import guards', 'tools/repo-lanes/tests'],
  ];
  for (const [label, rel] of wrapped) {
    if (existsSync(join(root, rel))) pass(`${label} — ${rel}`);
    else warn(`${label} MISSING — ${rel} (its obligation will fail if it fires)`);
  }
  lines.push('');

  lines.push('hooks');
  if (existsSync(join(root, '.claude', 'hooks', 'apex-hook.js'))) pass('.claude/hooks/apex-hook.js installed');
  else warn('.claude/hooks/apex-hook.js not installed — run `apex init`');
  lines.push('');

  lines.push(ok ? 'result: ok' : 'result: FAILED');
  return { ok, lines };
}
```

- [ ] **Step 3: Write `src/scaffold.ts`**

```typescript
// SPDX-License-Identifier: MIT
// `apex init` — install the hook shim and the policy into apex-app.

import { copyFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const TEMPLATES = join(HERE, '..', 'templates');

const FILES: Array<[string, string]> = [
  ['apex-hook.js', join('.claude', 'hooks', 'apex-hook.js')],
  ['policy.json', join('.harness', 'policy.json')],
];

const SETTINGS_SNIPPET = `
Apply these entries to .claude/settings.json (they replace the .ps1/.cmd pairs):

  "PreToolUse":  [{ "matcher": "Edit|Write|MultiEdit",
                    "hooks": [{ "type": "command", "command": "node .claude/hooks/apex-hook.js pre-tool-use" }] }],
  "PostToolUse": [{ "matcher": "Edit|Write|MultiEdit",
                    "hooks": [{ "type": "command", "command": "node .claude/hooks/apex-hook.js post-tool-use" }] }],
  "SessionStart":[{ "matcher": "",
                    "hooks": [{ "type": "command", "command": "node .claude/hooks/apex-hook.js session-start" }] }]
`;

export function scaffold(root: string, opts: { force?: boolean } = {}) {
  const written: string[] = [];
  const skipped: string[] = [];
  const lines: string[] = [`installing apex-dev-harness into ${root}`, ''];

  for (const [src, rel] of FILES) {
    const dest = join(root, rel);
    if (existsSync(dest) && !opts.force) {
      skipped.push(rel);
      lines.push(`  skip   ${rel} (exists — pass --force to overwrite)`);
      continue;
    }
    mkdirSync(dirname(dest), { recursive: true });
    copyFileSync(join(TEMPLATES, src), dest);
    written.push(rel);
    lines.push(`  write  ${rel}`);
  }

  lines.push('', `${written.length} written, ${skipped.length} skipped`, SETTINGS_SNIPPET);
  return { lines, written, skipped };
}
```

- [ ] **Step 4: Write `bin/apex.js`, then `chmod +x bin/apex.js`**

```javascript
#!/usr/bin/env node
// SPDX-License-Identifier: MIT
import { readFileSync } from 'node:fs';

const USAGE = `apex — routing and gate engine for apex-app

  apex route <path|route>          What applies here: lane, surface, mwg, skills, parity
  apex gate [--base <ref>] [--message <text>] [--paths a,b]
                                   What this diff owes, run and verdicted
  apex check <path> [--content -]  Block-tier decision for one edit (used by hooks)
  apex watchlist <file|->          BOUND-006 vocabulary scan
  apex doctor                      What the harness can see
  apex init [--force]              Install the hook shim + policy into apex-app
  apex mcp start                   Run the MCP server on stdio

  --json                           Machine-readable output (route, gate, check)
`;

function arg(args, name) {
  const i = args.indexOf(name);
  return i === -1 ? undefined : args[i + 1];
}

async function readStdin() {
  const chunks = [];
  for await (const c of process.stdin) chunks.push(c);
  return Buffer.concat(chunks).toString('utf-8');
}

async function main(argv) {
  const [cmd, ...args] = argv;
  const json = args.includes('--json');
  const { findRepoRoot } = await import('../dist/repo.js');
  const root = findRepoRoot();

  const needRoot = () => {
    if (!root) {
      console.error('apex: no apex-app checkout found. Run inside the repo, or set APEX_REPO_ROOT.');
      process.exit(1);
    }
    return root;
  };

  switch (cmd) {
    case undefined: case 'help': case '--help': case '-h':
      console.log(USAGE); return 0;
    case 'version': case '--version': case '-v': {
      const url = new URL('../package.json', import.meta.url);
      console.log(JSON.parse(readFileSync(url, 'utf-8')).version); return 0;
    }
    case 'route': {
      const q = args.filter((a) => !a.startsWith('--'))[0];
      if (!q) { console.error('usage: apex route <path|route>'); return 2; }
      const m = await import('../dist/route.js');
      const v = m.route(needRoot(), q);
      console.log(json ? JSON.stringify(v, null, 2) : m.formatRoute(v));
      return 0;
    }
    case 'gate': {
      const m = await import('../dist/gate.js');
      const paths = arg(args, '--paths')?.split(',').map((s) => s.trim()).filter(Boolean);
      const v = m.gate(needRoot(), { base: arg(args, '--base'), message: arg(args, '--message'), paths });
      console.log(json ? JSON.stringify(v, null, 2) : m.formatGate(v));
      return v.ok ? 0 : 1;
    }
    case 'check': {
      const p = args.filter((a) => !a.startsWith('--'))[0];
      if (!p) { console.error('usage: apex check <path> [--content -]'); return 2; }
      const content = arg(args, '--content') === '-' ? await readStdin() : null;
      const { check } = await import('../dist/check.js');
      const d = check(needRoot(), p, content);
      if (json) console.log(JSON.stringify(d));
      else console.log(d.allow ? 'allow' : `deny [${d.ruleId}] ${d.reason}`);
      return d.allow ? 0 : 1;
    }
    case 'watchlist': {
      const f = args.filter((a) => !a.startsWith('--'))[0];
      const text = !f || f === '-' ? await readStdin() : readFileSync(f, 'utf-8');
      const [{ scanWatchlist }, { loadPolicy }] = await Promise.all([
        import('../dist/watchlist.js'), import('../dist/truth/policy.js'),
      ]);
      const hits = scanWatchlist(loadPolicy(root ?? '.'), text);
      if (hits.length === 0) { console.log('no watchlist hits'); return 0; }
      for (const h of hits) console.log(`line ${h.line}: "${h.term}" — ${h.excerpt}`);
      return 1;
    }
    case 'doctor': {
      const { doctor } = await import('../dist/doctor.js');
      const r = doctor(root);
      for (const l of r.lines) console.log(l);
      return r.ok ? 0 : 1;
    }
    case 'init': {
      const { scaffold } = await import('../dist/scaffold.js');
      const r = scaffold(needRoot(), { force: args.includes('--force') });
      for (const l of r.lines) console.log(l);
      return 0;
    }
    case 'mcp': {
      if ((args[0] ?? 'start') !== 'start') { console.error('usage: apex mcp start'); return 2; }
      const { start } = await import('../dist/mcp/server.js');
      await start();
      return null;
    }
    default:
      console.error(`unknown command: ${cmd}\n`); console.error(USAGE); return 2;
  }
}

main(process.argv.slice(2))
  .then((code) => { if (code !== null) process.exit(code); })
  .catch((err) => { console.error(`apex: ${err?.message ?? err}`); process.exit(1); });
```

- [ ] **Step 5: Write the test `test/cli.test.js`**

```javascript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const CLI = join(dirname(fileURLToPath(import.meta.url)), '..', 'bin', 'apex.js');

function run(args, opts = {}) {
  return execFileSync(process.execPath, [CLI, ...args], { encoding: 'utf-8', ...opts });
}

function repo() {
  const dir = mkdtempSync(join(tmpdir(), 'apex-cli-'));
  mkdirSync(join(dir, 'tools', 'repo-lanes'), { recursive: true });
  writeFileSync(join(dir, 'tools', 'repo-lanes', 'lanes.json'), JSON.stringify({
    governedRoots: ['ui/src'],
    modules: [{ path: 'ui/src/menuDesigner/', lane: 'retired' }],
    importGuards: [],
  }));
  return dir;
}

test('--version prints a semver', () => {
  assert.match(run(['--version']).trim(), /^\d+\.\d+\.\d+$/);
});

test('help names every command', () => {
  const out = run(['--help']);
  for (const c of ['route', 'gate', 'check', 'watchlist', 'doctor', 'init', 'mcp']) {
    assert.ok(out.includes(c), `help omits ${c}`);
  }
});

test('route --json emits parseable output', () => {
  const dir = repo();
  try {
    const out = run(['route', 'ui/src/menuDesigner/x.jsx', '--json'], { env: { ...process.env, APEX_REPO_ROOT: dir } });
    assert.equal(JSON.parse(out).lane, 'retired');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('check exits 1 and names the rule for a blocked edit', () => {
  const dir = repo();
  assert.throws(() => run(['check', '.env'], { env: { ...process.env, APEX_REPO_ROOT: dir } }), (err) => {
    assert.equal(err.status, 1);
    assert.match(err.stdout, /BOUND-005/);
    return true;
  });
  rmSync(dir, { recursive: true, force: true });
});

test('doctor reports the repo it found', () => {
  const dir = repo();
  try {
    assert.match(run(['doctor'], { env: { ...process.env, APEX_REPO_ROOT: dir } }), /lanes\.json/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('doctor fails cleanly when no repo is found', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-norepo-cli-'));
  assert.throws(() => run(['doctor'], { cwd: dir, env: { ...process.env, APEX_REPO_ROOT: '' } }), (err) => {
    assert.equal(err.status, 1);
    assert.match(err.stdout, /no apex-app checkout found/);
    return true;
  });
  rmSync(dir, { recursive: true, force: true });
});

test('init installs the shim and policy, and does not clobber on re-run', () => {
  const dir = repo();
  try {
    const env = { ...process.env, APEX_REPO_ROOT: dir };
    assert.match(run(['init'], { env }), /write  \.claude/);
    assert.ok(existsSync(join(dir, '.claude', 'hooks', 'apex-hook.js')));
    assert.ok(existsSync(join(dir, '.harness', 'policy.json')));
    assert.match(run(['init'], { env }), /0 written/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('an unknown command exits 2', () => {
  assert.throws(() => run(['frobnicate']), (err) => {
    assert.equal(err.status, 2);
    return true;
  });
});
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `npm test`
Expected: all CLI tests pass. (Steps 2–4 wrote the implementation; this test is the task's verification gate.)

- [ ] **Step 7: Verify `doctor` against the live repo**

```bash
cd /mnt/c/Dev/Apex-APP-SW/apex-app && node /mnt/c/Dev/Apex-Dev-Skills/harnesses/apex-dev-harness/bin/apex.js doctor
```

Expected: `result: ok`, ~54 modules, ~106 ledger rows, all four wrapped commands found, and a warning that the hook is not installed.

- [ ] **Step 8: Commit**

```bash
git add harnesses/apex-dev-harness
git commit -m "feat(apex-dev-harness): doctor, init and the apex CLI"
```

---

## Phase B — transports

### Task 12: Cross-platform Node hooks

**Files:**
- Rewrite: `templates/apex-hook.js`
- Test: `test/hook.test.js`

**Interfaces:**
- Consumes: `check` (Task 7), `route` (Task 6), `findRepoRoot` (Task 1).
- Produces: a dispatcher invoked as `node .claude/hooks/apex-hook.js <phase>`, phases `pre-tool-use`, `post-tool-use`, `session-start`.

**The protocol is the deliverable.** Always print a JSON object. `{}` allows; a `deny` object blocks. Empty stdout bricked every edit in Cursor on 2026-07-04.

- [ ] **Step 1: Write the failing test `test/hook.test.js`**

```javascript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const HOOK = join(HERE, '..', 'templates', 'apex-hook.js');
const DIST = join(HERE, '..', 'dist');

function repo() {
  const dir = mkdtempSync(join(tmpdir(), 'apex-hook-'));
  mkdirSync(join(dir, 'tools', 'repo-lanes'), { recursive: true });
  writeFileSync(join(dir, 'tools', 'repo-lanes', 'lanes.json'), JSON.stringify({
    governedRoots: ['ui/src'],
    modules: [{ path: 'ui/src/menuDesigner/', lane: 'retired', notes: 'Route retired 2026-07-18.' }],
    importGuards: [],
  }));
  return dir;
}

function runHook(phase, payload, root) {
  const out = execFileSync(process.execPath, [HOOK, phase], {
    input: JSON.stringify(payload),
    encoding: 'utf-8',
    env: { ...process.env, APEX_REPO_ROOT: root, APEX_ENGINE_DIST: DIST },
  });
  return { raw: out, json: JSON.parse(out) };
}

test('an ordinary edit is allowed with a bare {}', () => {
  const dir = repo();
  try {
    const { json } = runHook('pre-tool-use', { tool_name: 'Edit', tool_input: { file_path: 'ui/src/ok.jsx', content: 'const a=1;' } }, dir);
    assert.deepEqual(json, {});
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a blocked edit emits the deny shape both harnesses honor', () => {
  const dir = repo();
  try {
    const { json } = runHook('pre-tool-use', { tool_name: 'Write', tool_input: { file_path: '.env', content: 'placeholder' } }, dir);
    assert.equal(json.hookSpecificOutput.permissionDecision, 'deny');
    assert.match(json.hookSpecificOutput.permissionDecisionReason, /BOUND-005/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a retired-lane edit is denied with the lane note', () => {
  const dir = repo();
  try {
    const { json } = runHook('pre-tool-use', { tool_name: 'Edit', tool_input: { file_path: 'ui/src/menuDesigner/Canvas.jsx', content: 'x' } }, dir);
    assert.equal(json.hookSpecificOutput.permissionDecision, 'deny');
    assert.match(json.hookSpecificOutput.permissionDecisionReason, /RETIRED/i);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('garbage on stdin fails open with {}', () => {
  const dir = repo();
  try {
    const out = execFileSync(process.execPath, [HOOK, 'pre-tool-use'], {
      input: 'not json at all', encoding: 'utf-8',
      env: { ...process.env, APEX_REPO_ROOT: dir, APEX_ENGINE_DIST: DIST },
    });
    assert.deepEqual(JSON.parse(out), {});
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a payload with no file_path fails open', () => {
  const dir = repo();
  try {
    assert.deepEqual(runHook('pre-tool-use', { tool_name: 'Edit', tool_input: {} }, dir).json, {});
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('an unknown phase fails open rather than erroring', () => {
  const dir = repo();
  try {
    assert.deepEqual(runHook('no-such-phase', { tool_input: { file_path: 'ui/src/a.jsx' } }, dir).json, {});
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('stdout is always exactly one JSON object', () => {
  const dir = repo();
  try {
    const { raw } = runHook('pre-tool-use', { tool_name: 'Edit', tool_input: { file_path: 'ui/src/ok.jsx', content: 'x' } }, dir);
    assert.equal(raw.trim().split('\n').length, 1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('windows-style file paths are handled', () => {
  const dir = repo();
  try {
    const { json } = runHook('pre-tool-use', { tool_name: 'Edit', tool_input: { file_path: 'ui\\src\\menuDesigner\\Canvas.jsx', content: 'x' } }, dir);
    assert.equal(json.hookSpecificOutput.permissionDecision, 'deny');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('post-tool-use never blocks, even on a violation', () => {
  const dir = repo();
  try {
    assert.deepEqual(runHook('post-tool-use', { tool_name: 'Edit', tool_input: { file_path: 'ui/src/menuDesigner/x.jsx' } }, dir).json, {});
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test`
Expected: FAIL — the stub always emits `{}`, so the three deny tests fail.

- [ ] **Step 3: Write the real `templates/apex-hook.js`**

```javascript
#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// apex-dev-harness hook dispatcher. ONE file, invoked as:
//   node .claude/hooks/apex-hook.js <pre-tool-use|post-tool-use|session-start>
//
// OUTPUT PROTOCOL — do not change without reading this comment:
// ALWAYS print exactly one JSON object on stdout. `{}` allows; a deny object
// blocks. Claude Code accepts the bare exit-code protocol, but Cursor runs
// these same hooks and REQUIRES valid JSON — on 2026-07-04 an empty stdout
// made Cursor treat the hook as broken and block EVERY Edit/Write in the
// workspace. Fail open on every internal error: a harness bug must never
// wedge editing.

function emit(obj) {
  process.stdout.write(JSON.stringify(obj ?? {}) + '\n');
  process.exit(0);
}

function deny(reason) {
  emit({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason,
    },
  });
}

async function readStdin() {
  const chunks = [];
  for await (const c of process.stdin) chunks.push(c);
  return Buffer.concat(chunks).toString('utf-8');
}

/**
 * Resolve the engine. Normally it is a dependency of the repo or installed
 * globally; APEX_ENGINE_DIST overrides for tests and local development.
 */
async function loadEngine(name) {
  const dist = process.env.APEX_ENGINE_DIST;
  if (dist) return import(new URL(`file://${dist.replace(/\\/g, '/')}/${name}`).href);
  return import(`apex-dev-harness/dist/${name}`);
}

/** Make an absolute or windows-style path repo-relative. */
function toRelative(root, filePath) {
  const p = String(filePath).replace(/\\/g, '/');
  const r = root.replace(/\\/g, '/').replace(/\/$/, '');
  return p.startsWith(r + '/') ? p.slice(r.length + 1) : p;
}

async function main() {
  const phase = process.argv[2];

  let payload;
  try {
    payload = JSON.parse(await readStdin());
  } catch {
    return emit(); // unparseable stdin — not our business
  }

  const rawPath = payload?.tool_input?.file_path;
  if (!rawPath) return emit();

  const { findRepoRoot } = await loadEngine('repo.js');
  const root = findRepoRoot();
  if (!root) return emit();
  const rel = toRelative(root, rawPath);

  if (phase === 'pre-tool-use') {
    const { check } = await loadEngine('check.js');
    const content = payload.tool_input.content ?? payload.tool_input.new_string ?? null;
    const decision = check(root, rel, content);
    if (decision.allow) return emit();
    const src = decision.source ? ` (${decision.source})` : '';
    return deny(`[${decision.ruleId}]${src} ${decision.reason}`);
  }

  if (phase === 'post-tool-use') {
    // Advisory only — this phase must never block. Warnings go to stderr so
    // stdout stays a single clean JSON object, and stay quiet on the happy
    // path: a hook that prints on every edit trains people to ignore it.
    try {
      const { route } = await loadEngine('route.js');
      const v = route(root, rel);
      if (v.surface?.status === 'STUDIO' && !rel.includes('apexStudio')) {
        process.stderr.write(`[apex] ${v.surface.surface} is STUDIO-canonical — touching the legacy twin is a smell.\n`);
      }
    } catch { /* advisory only */ }
    return emit();
  }

  return emit(); // session-start and anything unknown
}

main().catch(() => process.stdout.write('{}\n'));
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm test`
Expected: all hook tests pass.

- [ ] **Step 5: Commit**

```bash
git add harnesses/apex-dev-harness
git commit -m "feat(apex-dev-harness): cross-platform Node hook dispatcher with the Cursor-safe protocol"
```

---

### Task 13: MCP server

**Files:**
- Create: `src/mcp/server.ts`
- Test: `test/mcp.test.js`

**Interfaces:**
- Consumes: `route` (6), `gate` (10), `check` (7), `doctor` (11), `findRepoRoot` (1).
- Produces: `TOOLS: McpTool[]`, `createServer(): Server`, `start(): Promise<void>`.

- [ ] **Step 1: Install the SDK**

```bash
cd /mnt/c/Dev/Apex-Dev-Skills/harnesses/apex-dev-harness
npm install --save @modelcontextprotocol/sdk@^1.30.0
```

- [ ] **Step 2: Write the failing test `test/mcp.test.js`**

```javascript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { TOOLS, createServer } from '../dist/mcp/server.js';

function repo() {
  const dir = mkdtempSync(join(tmpdir(), 'apex-mcp-'));
  mkdirSync(join(dir, 'tools', 'repo-lanes'), { recursive: true });
  writeFileSync(join(dir, 'tools', 'repo-lanes', 'lanes.json'), JSON.stringify({
    governedRoots: ['ui/src'],
    modules: [{ path: 'ui/src/menuDesigner/', lane: 'retired' }],
    importGuards: [],
  }));
  return dir;
}

test('every tool declares name, description and an object schema', () => {
  assert.ok(TOOLS.length >= 4);
  for (const t of TOOLS) {
    assert.ok(t.name && t.description, `${t.name} missing metadata`);
    assert.equal(t.inputSchema.type, 'object');
  }
  assert.equal(new Set(TOOLS.map((t) => t.name)).size, TOOLS.length);
});

test('apex_route returns a verdict', async () => {
  const dir = repo();
  try {
    process.env.APEX_REPO_ROOT = dir;
    const tool = TOOLS.find((t) => t.name === 'apex_route');
    assert.equal((await tool.run({ query: 'ui/src/menuDesigner/x.jsx' })).lane, 'retired');
  } finally { delete process.env.APEX_REPO_ROOT; rmSync(dir, { recursive: true, force: true }); }
});

test('apex_check refuses a blocked edit', async () => {
  const dir = repo();
  try {
    process.env.APEX_REPO_ROOT = dir;
    const tool = TOOLS.find((t) => t.name === 'apex_check');
    assert.equal((await tool.run({ path: '.env', content: 'placeholder' })).allow, false);
  } finally { delete process.env.APEX_REPO_ROOT; rmSync(dir, { recursive: true, force: true }); }
});

test('a missing required argument produces a clear error', async () => {
  await assert.rejects(() => TOOLS.find((t) => t.name === 'apex_route').run({}), /query/);
});

test('the server constructs', () => {
  assert.ok(createServer());
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `npm test`
Expected: FAIL — `Cannot find module '../dist/mcp/server.js'`

- [ ] **Step 4: Write `src/mcp/server.ts`**

```typescript
// SPDX-License-Identifier: MIT
// MCP stdio server — the same engine, available to the agent without asking.

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema, ListToolsRequestSchema, ErrorCode, McpError,
} from '@modelcontextprotocol/sdk/types.js';

import { findRepoRoot } from '../repo.js';
import { route } from '../route.js';
import { gate } from '../gate.js';
import { check } from '../check.js';
import { doctor } from '../doctor.js';

export interface McpTool {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  run: (args: Record<string, unknown>) => Promise<unknown>;
}

function requireRoot(): string {
  const root = findRepoRoot();
  if (!root) throw new Error('no apex-app checkout found; set APEX_REPO_ROOT');
  return root;
}

function str(args: Record<string, unknown>, key: string): string {
  const v = args[key];
  if (typeof v !== 'string' || !v.trim()) throw new Error(`\`${key}\` is required and must be a non-empty string`);
  return v;
}

export const TOOLS: McpTool[] = [
  {
    name: 'apex_route',
    description:
      'Where does this work go? Returns lane, surface-ledger status and its routing sentence, MWG target, required skills, parity surfaces, and import-guard notes for a path or route. Call this BEFORE building any operator-facing surface.',
    inputSchema: {
      type: 'object',
      properties: { query: { type: 'string', description: 'A repo-relative file path or an app route.' } },
      required: ['query'], additionalProperties: false,
    },
    run: async (args) => route(requireRoot(), str(args, 'query')),
  },
  {
    name: 'apex_gate',
    description:
      'What does the current diff owe before the work can be called done? Computes obligations (manifest regeneration, guard suites, style checks), runs them, and returns a verdict. Call this BEFORE claiming a task or phase is complete.',
    inputSchema: {
      type: 'object',
      properties: {
        base: { type: 'string', description: 'Git ref to diff against (default HEAD).' },
        message: { type: 'string', description: 'Completion report or commit message, scanned for watchlist vocabulary.' },
      },
      additionalProperties: false,
    },
    run: async (args) => gate(requireRoot(), {
      base: typeof args.base === 'string' ? args.base : undefined,
      message: typeof args.message === 'string' ? args.message : undefined,
    }),
  },
  {
    name: 'apex_check',
    description: 'Would this edit violate a blocking guardrail? Returns allow, or the rule id and reason for a refusal.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'Repo-relative path to be edited.' },
        content: { type: 'string', description: 'The proposed new content, if any.' },
      },
      required: ['path'], additionalProperties: false,
    },
    run: async (args) => check(requireRoot(), str(args, 'path'), typeof args.content === 'string' ? args.content : null),
  },
  {
    name: 'apex_doctor',
    description: 'What can the harness see? Truth-file parse coverage, wrapped-command availability, hook install state.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    run: async () => doctor(findRepoRoot()),
  },
];

export function createServer(): Server {
  const server = new Server(
    { name: 'apex-dev-harness', version: '0.1.0' },
    { capabilities: { tools: {} } },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: TOOLS.map((t) => ({
      name: t.name, description: t.description, inputSchema: t.inputSchema as { type: 'object' },
    })),
  }));

  server.setRequestHandler(CallToolRequestSchema, async (req) => {
    const tool = TOOLS.find((t) => t.name === req.params.name);
    if (!tool) throw new McpError(ErrorCode.MethodNotFound, `unknown tool: ${req.params.name}`);
    try {
      const out = await tool.run(req.params.arguments ?? {});
      return { content: [{ type: 'text' as const, text: JSON.stringify(out, null, 2) }] };
    } catch (err) {
      throw new McpError(ErrorCode.InternalError, err instanceof Error ? err.message : String(err));
    }
  });

  return server;
}

export async function start(): Promise<void> {
  await createServer().connect(new StdioServerTransport());
  console.error('[apex-dev-harness] MCP server ready —', TOOLS.length, 'tools');
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `npm test`
Expected: all MCP tests pass.

- [ ] **Step 6: Drive the server over stdio end-to-end**

```bash
npm run build
printf '%s\n' \
'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"s","version":"1"}}}' \
'{"jsonrpc":"2.0","method":"notifications/initialized"}' \
'{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
| APEX_REPO_ROOT=/mnt/c/Dev/Apex-APP-SW/apex-app timeout 20 node bin/apex.js mcp start 2>/dev/null
```

Expected: an `initialize` result and a `tools/list` naming all four tools.

- [ ] **Step 7: Commit**

```bash
git add harnesses/apex-dev-harness
git commit -m "feat(apex-dev-harness): MCP stdio server exposing route, gate, check and doctor"
```

---

### Task 14: The plugin

**Files:**
- Create: `plugins/apex-dev-harness/.claude-plugin/plugin.json`
- Create: `plugins/apex-dev-harness/README.md`
- Create: `plugins/apex-dev-harness/commands/{route,gate,build,status}.md`
- Create: `plugins/apex-dev-harness/skills/apex-orientation/SKILL.md`
- Modify: `.claude-plugin/marketplace.json`
- Test: `harnesses/apex-dev-harness/test/plugin.test.js`

**Interfaces:**
- Consumes: the `apex` CLI (Task 11).
- Produces: the installable plugin. No code interface.

- [ ] **Step 1: Write the failing test `test/plugin.test.js`**

```javascript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const PLUGIN = join(ROOT, 'plugins', 'apex-dev-harness');

test('plugin.json is valid and names the plugin', () => {
  const p = JSON.parse(readFileSync(join(PLUGIN, '.claude-plugin', 'plugin.json'), 'utf-8'));
  assert.equal(p.name, 'apex-dev-harness');
  assert.ok(p.description.length > 0);
});

test('every command file exists and has description frontmatter', () => {
  for (const c of ['route', 'gate', 'build', 'status']) {
    const f = join(PLUGIN, 'commands', `${c}.md`);
    assert.ok(existsSync(f), `missing command ${c}`);
    assert.match(readFileSync(f, 'utf-8'), /^---\n[\s\S]*?description:/);
  }
});

test('the orientation skill has name and description frontmatter', () => {
  const s = readFileSync(join(PLUGIN, 'skills', 'apex-orientation', 'SKILL.md'), 'utf-8');
  assert.match(s, /^---\n[\s\S]*?name: apex-orientation/);
  assert.match(s, /description:/);
});

test('the marketplace lists the plugin alongside apex-plan-loop', () => {
  const m = JSON.parse(readFileSync(join(ROOT, '.claude-plugin', 'marketplace.json'), 'utf-8'));
  const names = m.plugins.map((p) => p.name);
  assert.ok(names.includes('apex-dev-harness'));
  assert.ok(names.includes('apex-plan-loop'));
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test`
Expected: FAIL — plugin.json does not exist.

- [ ] **Step 3: Create `plugins/apex-dev-harness/.claude-plugin/plugin.json`**

```json
{
  "name": "apex-dev-harness",
  "description": "Routing and gate engine for apex-app: answers where work goes (lanes + surface ledger), enforces the guardrails cross-platform, and closes phases on computed obligations instead of prose.",
  "version": "0.1.0",
  "author": { "name": "Apex Insights", "url": "https://getapexinsights.com" },
  "license": "MIT",
  "keywords": ["apex", "guardrails", "lanes", "surface-ledger", "gate", "routing"]
}
```

- [ ] **Step 4: Write `commands/route.md`**

```markdown
---
description: Where does this work go? Lane, surface-ledger status, MWG target, required skills, and parity surfaces for a path or route.
---

Run the harness router for `$ARGUMENTS` (a repo-relative path or an app route):

!`apex route "$ARGUMENTS"`

Read the verdict and act on it:

- **`no row`** means the ledger has a gap. Add the row — do not guess the status.
- **STUDIO** — build in Studio; touching the legacy twin is a smell.
- **DUAL** — new features go Studio-side; keep both sides consistent.
- **LEGACY** — extend the existing surface guilt-free; if the ask is large, ask whether this is the moment to port the domain.
- **RETIRED** — do not touch.

Invoke every skill the verdict names before writing code, and hold the parity surfaces it lists until the change is applied to each.
```

- [ ] **Step 5: Write `commands/gate.md`**

```markdown
---
description: Run the done-gate — compute what the current diff owes, run those checks, and report a verdict.
---

!`apex gate --message "$ARGUMENTS"`

A `NOT DONE` verdict is not advisory. Fix every unmet obligation, then run this again.

A guard failure is a real drift, not a flaky test: add the missing resolver, view, or branch, regenerate the manifest, or register a reason-stringed exception in the documented allowlist.

Watchlist hits are BOUND-006 prompts — verify the work underneath is sound, or say plainly what is incomplete and why.
```

- [ ] **Step 6: Write `commands/status.md`**

```markdown
---
description: Read-only orientation — what the harness can see, and what the current diff owes.
---

!`apex doctor`

Then summarize what the working diff would owe, without running the wrapped commands:

!`apex gate --paths "$(git diff --name-only HEAD | tr '\n' ',')" --json`

Report: the lane and surface of the files in flight, outstanding obligations, and anything the doctor flagged as missing.
```

- [ ] **Step 7: Write `commands/build.md`**

```markdown
---
description: Orient, decide, execute and gate a piece of apex-app work end to end.
---

Run the full apex build lifecycle for: **$ARGUMENTS**

## 1. ORIENT

Route the ask before designing anything:

!`apex route "$ARGUMENTS"`

If the ask names a surface rather than a path, route the most likely path too. Report the lane, the surface status, and the skills the verdict named. Check the agent-coordination preamble for a partner already working this surface — if one exists, surface the overlap before touching code.

## 2. DECIDE

Judge triviality by the `decide-plan-loop` skill's own criteria: three or more phases, crossing a bounded context, or a decision someone will ask about in six months.

- **Non-trivial** → invoke the `decide-plan-loop` skill. It produces an ADR at `.claude/tasks/<slug>-adr.md` and a phased plan at `.claude/plans/<slug>-plan.md`.
- **Bounded** → skip to step 3, and say why you judged it bounded.

## 3. EXECUTE

Work the plan one phase at a time via the `dev-plan-loop` skill. Do not start a phase before its predecessor has passed step 4.

## 4. GATE — every phase, no exceptions

!`apex gate --message "phase complete"`

A phase closes when its obligations pass, never because the work feels finished. If the gate says `NOT DONE`, the phase is open.

## 5. DONE

Enumerate the parity surfaces the router named and confirm each one, or state explicitly why a surface diverges. Then run the gate once more over the whole change.
```

- [ ] **Step 8: Write `skills/apex-orientation/SKILL.md`**

```markdown
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
```

- [ ] **Step 9: Write `plugins/apex-dev-harness/README.md`**

```markdown
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
```

- [ ] **Step 10: Register the plugin in the marketplace**

Add to the `plugins` array in `/mnt/c/Dev/Apex-Dev-Skills/.claude-plugin/marketplace.json`, after the `apex-plan-loop` entry:

```json
    {
      "name": "apex-dev-harness",
      "description": "Routing and gate engine for apex-app: lanes + surface-ledger routing, cross-platform guardrails, and phases that close on computed obligations.",
      "author": { "name": "Apex Insights", "url": "https://getapexinsights.com" },
      "category": "development",
      "source": "./plugins/apex-dev-harness",
      "keywords": ["apex", "guardrails", "lanes", "surface-ledger", "gate", "routing"]
    }
```

- [ ] **Step 11: Run the test to verify it passes**

Run: `npm test`
Then: `python3 -c "import json;json.load(open('/mnt/c/Dev/Apex-Dev-Skills/.claude-plugin/marketplace.json'))"`
Expected: all plugin tests pass; the marketplace JSON parses.

- [ ] **Step 12: Commit**

```bash
git add plugins/apex-dev-harness .claude-plugin/marketplace.json harnesses/apex-dev-harness
git commit -m "feat(apex-dev-harness): Claude Code plugin with route/gate/build/status and the orientation skill"
```

---

### Task 15: End-to-end verification and the apex-app integration PR

**Files:**
- Create: `harnesses/apex-dev-harness/README.md`, `harnesses/apex-dev-harness/LICENSE`
- Create: `docs/apex-dev-harness-integration.md`
- Test: manual, against the live repo

**Interfaces:**
- Consumes: everything.
- Produces: a publishable package and a reviewable integration.

- [ ] **Step 1: Write the package README and LICENSE**

`README.md` must include a **"What this does not do"** section stating plainly: it introduces no new rules; the ledger is read, never remembered; `no-row` is a finding, not a guess; and every wrapped check belongs to apex-app, not to the harness. Copy the MIT `LICENSE` from `harnesses/apex-app-dev-harness/LICENSE`.

- [ ] **Step 2: Run the full suite**

Run: `npm test`
Expected: every test from Tasks 1–14 passes. Record the count.

- [ ] **Step 3: Pack and install into a scratch project**

```bash
cd /mnt/c/Dev/Apex-Dev-Skills/harnesses/apex-dev-harness
S=$(mktemp -d) && npm pack --pack-destination "$S" >/dev/null
mkdir -p "$S/proj" && cd "$S/proj" && npm init -y >/dev/null
npm install "$S"/apex-dev-harness-0.1.0.tgz
APEX_REPO_ROOT=/mnt/c/Dev/Apex-APP-SW/apex-app npx apex doctor
APEX_REPO_ROOT=/mnt/c/Dev/Apex-APP-SW/apex-app npx apex route ui/src/marketing/CampaignCockpit.jsx
```

Expected: `result: ok` from doctor; the route verdict names the DUAL marketing surface and the grandfathered `quizBuilder` import. This step catches missing `files` entries — the failure mode a passing local suite cannot.

- [ ] **Step 4: Dry-run the gate against a real branch**

```bash
cd /mnt/c/Dev/Apex-APP-SW/apex-app
node /mnt/c/Dev/Apex-Dev-Skills/harnesses/apex-dev-harness/bin/apex.js gate --base HEAD~1 --message "test run"
```

Expected: obligations fire for whatever the last commit touched, and each wrapped command actually runs.

**If a wrapped command errors for an environment reason (missing Python venv, absent node_modules), that is a finding to report to the user — not something to paper over.** The gate's honesty is the whole product.

- [ ] **Step 5: Write the integration PR description**

Create `docs/apex-dev-harness-integration.md` covering, for the apex-app reviewer:

- what `apex init` writes (`.claude/hooks/apex-hook.js`, `.harness/policy.json`)
- the exact `.claude/settings.json` diff
- which `.ps1`/`.cmd` hooks are superseded, and why (they no-op on macOS/Linux/WSL today)
- that `session-handoff.py` is kept unchanged
- the two findings from the design: the ledger's header tally says 85 rows while the parser finds 106, and `ui/src/agentic/` is an empty untracked directory that can be deleted
- the three open questions from the spec, for the owner to rule on

- [ ] **Step 6: Report — do not merge**

Do **not** open or merge the apex-app PR. Present the branch and the description to the user for review. Activating hooks in the product repo is their call.

- [ ] **Step 7: Commit**

```bash
git add harnesses/apex-dev-harness docs/apex-dev-harness-integration.md
git commit -m "docs(apex-dev-harness): README, license, and the apex-app integration PR description"
```

---

## Self-review

**Spec coverage:** engine units → Tasks 1–11; `route` → 6; obligations/gate → 9–10; block/warn tiers → 4 (data) + 7 (evaluation); `.agents/rules` scoping → 4; fail-open behavior → tested in 2, 3, 4, 6, 7, 12; hooks and the stdout protocol → 12; MCP → 13; plugin and the `/apex:build` lifecycle → 14; packaging and the apex-app PR → 15; `doctor`/`init` → 11. The `/apex:status` and `apex init` surfaces added during spec self-review are covered by Tasks 14 and 11.

**Type consistency:** `RouteVerdict`, `CheckDecision`, `Obligation`, `GateVerdict`, `Policy`, `LanesTruth`, `LedgerTruth`, and `WatchlistHit` are defined once in Task 1 and imported unchanged thereafter. `normalize` (Task 1) is the single path-normalization function used by lanes, ledger, glob, check, and obligations. `loadPolicy`/`DEFAULT_POLICY`/`rulesInScope` keep the same names in Tasks 4, 6, 7, 9, 10, 11.

**Known gap, deliberate:** `check.ts`'s LANE-IMPORT detection is a regex over file content, not a real import parse. Task 7 Step 4 calls this out and instructs tightening on any false positive, because a false block is the worst failure this harness can produce. The authoritative check remains `pytest tools/repo-lanes/tests/`, which the gate runs.

**Constraint added after the first draft was rejected:** apex-app's guardrail hook blocked the original version of this plan for containing a credential-shaped literal in a test fixture. Task 7 now builds that sample by concatenation, and `check.ts` assembles its detector regex from parts. The Global Constraints section records the rule.
