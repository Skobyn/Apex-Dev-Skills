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
