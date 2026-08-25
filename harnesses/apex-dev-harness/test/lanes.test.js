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

test('a path inside a governed root but matching no module is a lane GAP, not plain ungoverned', () => {
  const dir = repoWith();
  try {
    const truth = loadLanes(dir);
    // ui/src is a governedRoots entry; ui/src/agentic has no module row.
    const v = laneFor(truth, 'ui/src/agentic/index.js');
    assert.equal(v.lane, 'ungoverned');
    assert.equal(v.entry, null);
    assert.equal(v.gap, true);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a path outside every governed root is plain ungoverned, no gap flag', () => {
  const dir = repoWith();
  try {
    const truth = loadLanes(dir);
    const v = laneFor(truth, 'scripts/oneoff.sh');
    assert.equal(v.lane, 'ungoverned');
    assert.equal(v.gap, undefined);
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

test('a sibling directory sharing a module name prefix does not inherit its lane', () => {
  const dir = repoWith(JSON.stringify({
    governedRoots: ['ui/src'],
    modules: [
      { path: 'ui/src/quizBuilder', lane: 'legacy' },
      { path: 'ui/src/', lane: 'production' },
    ],
    importGuards: [],
  }));
  try {
    const truth = loadLanes(dir);
    // No trailing slash on the legacy entry — the boundary check must still
    // keep the sibling out of it.
    assert.equal(laneFor(truth, 'ui/src/quizBuilderExtra/x.js').lane, 'production');
    assert.equal(laneFor(truth, 'ui/src/quizBuilder/api.js').lane, 'legacy');
    assert.equal(laneFor(truth, 'ui/src/quizBuilder').lane, 'legacy');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
