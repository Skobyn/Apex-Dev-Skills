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

test('a genuine 3-column table is not dropped by the 4-column filter', () => {
  const md = [
    '## Staff portal',
    '',
    '| Surface | Routes | Status |',
    '|---|---|---|',
    '| Staff schedule | `/staff/schedule` | **LEGACY** |',
  ].join('\n');
  const dir = repoWith(md);
  try {
    const truth = loadLedger(dir);
    assert.equal(truth.rows.length, 1);
    assert.equal(truth.rows[0].surface, 'Staff schedule');
    assert.equal(truth.rows[0].status, 'LEGACY');
    assert.equal(truth.rows[0].notes, '');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('an escaped pipe inside a surface name does not shift columns', () => {
  const md = [
    '## 07 Client portfolio',
    '',
    '| Surface | Routes | Status | Notes |',
    '|---|---|---|---|',
    '| Client portfolio (Overview \\| Performance \\| Docs) | `/portfolio` | **DUAL** | multi-tab surface |',
  ].join('\n');
  const dir = repoWith(md);
  try {
    const truth = loadLedger(dir);
    assert.equal(truth.rows.length, 1);
    assert.equal(truth.rows[0].surface, 'Client portfolio (Overview | Performance | Docs)');
    assert.equal(truth.rows[0].status, 'DUAL');
    assert.equal(truth.rows[0].notes, 'multi-tab surface');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a row that carries a status but cannot be parsed produces a warning, not silent loss', () => {
  const md = [
    '## 12 Broken section',
    '',
    '| Surface | Status |',
    '|---|---|',
    '| Half a table **LEGACY** |',
  ].join('\n');
  const dir = repoWith(md);
  try {
    const truth = loadLedger(dir);
    assert.equal(truth.ok, true);
    assert.equal(truth.rows.length, 0);
    assert.match(truth.warning, /could not be parsed/i);
    assert.match(truth.warning, /parser needs updating, not the ledger/i);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a real surface named like a status word is parsed, not silently dropped', () => {
  const md = [
    '## Status vocabulary',
    '',
    '| Status | Meaning | What it implies |',
    '|---|---|---|',
    '| **STUDIO** | canonical | build in Studio |',
    '',
    '## 11 Automations',
    '',
    '| Surface | Routes | Status | Notes |',
    '|---|---|---|---|',
    '| Studio | `/apex-studio` | **STUDIO** | a surface whose NAME is a status word |',
  ].join('\n');
  const dir = repoWith(md);
  try {
    const truth = loadLedger(dir);
    assert.equal(truth.rows.length, 1, 'the vocabulary row must be skipped and the real row kept');
    assert.equal(truth.rows[0].surface, 'Studio');
    assert.equal(truth.rows[0].section, '11 Automations');
    assert.equal(surfaceFor(truth, '/apex-studio').status, 'STUDIO');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
