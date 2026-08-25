// SPDX-License-Identifier: MIT
// Durable invariants over the MERGED surfaceHints table — run against EVERY
// hint, pre-existing and newly added, not just the ones this release adds.
// Files get deleted under hints that were correct when written; that is
// exactly how BrandPage.jsx and HouseGuideAdminPage.jsx (both removed in
// 0.3.0) survived undetected. Guarded: skipped when the consuming repo
// (apex-app) is not present on this machine, but MUST fail loudly, not
// silently, when it is.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const CONSUMING_REPO = '/mnt/c/Dev/Apex-APP-SW/apex-app';
const HAVE_REPO = existsSync(join(CONSUMING_REPO, 'ui', 'src', 'App.js'))
  && existsSync(join(CONSUMING_REPO, '.claude', 'tasks', 'apex-studio-surface-ledger.md'));

function loadPolicy() {
  return JSON.parse(readFileSync(join(HERE, '..', 'templates', 'policy.json'), 'utf-8'));
}

function isGlob(pattern) {
  return pattern.includes('*');
}

function globToRegex(pattern) {
  let out = '';
  for (let i = 0; i < pattern.length; i++) {
    const c = pattern[i];
    if (c === '*') {
      if (pattern[i + 1] === '*') {
        if (pattern[i + 2] === '/') { out += '(?:.*/)?'; i += 2; } else { out += '.*'; i += 1; }
      } else out += '[^/]*';
      continue;
    }
    out += c.replace(/[.+?^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${out}$`);
}

test('every hint\'s non-glob match resolves to a real file on disk (exists-on-disk)', { skip: !HAVE_REPO && 'consuming repo not present on this machine' }, () => {
  const policy = loadPolicy();
  const missing = [];
  for (const hint of policy.surfaceHints) {
    if (isGlob(hint.match)) continue;
    if (!existsSync(join(CONSUMING_REPO, hint.match))) missing.push(hint.match);
  }
  assert.deepEqual(missing, [], `hints pointing at files that no longer exist: ${missing.join(', ')}`);
});

test('every hint\'s surface string appears verbatim as a ledger row (surface-verbatim)', { skip: !HAVE_REPO && 'consuming repo not present on this machine' }, () => {
  const policy = loadPolicy();
  const ledger = readFileSync(join(CONSUMING_REPO, '.claude', 'tasks', 'apex-studio-surface-ledger.md'), 'utf-8');
  const ledgerSurfaces = new Set();
  for (const line of ledger.split('\n')) {
    if (!line.startsWith('|')) continue;
    const cells = line.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((c) => c.trim());
    if (cells.length < 3) continue;
    const surface = cells[0].replace(/\*\*/g, '').trim();
    if (surface) ledgerSurfaces.add(surface);
  }
  const missing = [];
  for (const hint of policy.surfaceHints) {
    if (!ledgerSurfaces.has(hint.surface)) missing.push(`${hint.match} -> "${hint.surface}"`);
  }
  assert.deepEqual(missing, [], `hints naming a surface absent from the ledger: ${missing.join(', ')}`);
});

test('no hinted file is mounted exclusively under /portal in App.js (not-portal-only)', { skip: !HAVE_REPO && 'consuming repo not present on this machine' }, async () => {
  const { derivePortalMountsFromFile } = await import('../scripts/portal-mounts.mjs');
  const { portalOnly } = derivePortalMountsFromFile(join(CONSUMING_REPO, 'ui', 'src', 'App.js'));

  const policy = loadPolicy();
  const excludedMatches = new Set((policy.excludedFiles ?? []).map((e) => e.match));

  const falsePositives = [];
  for (const hint of policy.surfaceHints) {
    if (isGlob(hint.match)) continue;
    if (excludedMatches.has(hint.match)) continue; // deliberately excluded, not a hint at all
    const base = hint.match.split('/').pop().replace(/\.jsx?$/, '');
    if (portalOnly.has(base)) falsePositives.push(hint.match);
  }
  // Their measurement: 0 false positives across the concrete hints. If this
  // implementation produces any, DO NOT weaken the assertion — the
  // derivation differs from theirs and that is itself the finding.
  assert.deepEqual(falsePositives, [], `hinted files that App.js mounts ONLY under /portal: ${falsePositives.join(', ')}`);

  // And it must actually be ABLE to flag something: excludedFiles carries
  // the five known portal-only files precisely because they were caught by
  // this derivation and excluded rather than hinted.
  const knownPortalOnlyFiles = [
    'ui/src/pages/TipSheetsPage.jsx',
    'ui/src/pages/HouseGuideAdminPage.jsx',
    'ui/src/pages/HouseGuideEditorPage.jsx',
    'ui/src/pages/PortalHouseGuidePage.jsx',
    'ui/src/pages/PortalProfilePage.jsx',
  ];
  for (const f of knownPortalOnlyFiles) {
    const base = f.split('/').pop().replace(/\.jsx?$/, '');
    assert.ok(portalOnly.has(base), `expected the derivation to flag ${f} (${base}) as portal-only`);
  }
});

test('control group: known legacy-twin pages never carry canonical:true', { skip: !HAVE_REPO && 'consuming repo not present on this machine' }, () => {
  const policy = loadPolicy();
  const controlFiles = [
    'ui/src/pages/MyProfilePage.jsx',
    'ui/src/pages/EmailSettingsPage.jsx',
    'ui/src/marketing/contests/ContestsListPage.jsx',
  ];
  for (const f of controlFiles) {
    const hint = policy.surfaceHints.find((h) => h.match === f);
    if (hint) assert.notEqual(hint.canonical, true, `${f} is a genuine legacy twin and must not be canonical`);
  }
});

test('excludedFiles entries never also appear as a surfaceHint match', () => {
  const policy = loadPolicy();
  const excluded = new Set((policy.excludedFiles ?? []).map((e) => e.match));
  const conflicts = policy.surfaceHints.filter((h) => excluded.has(h.match)).map((h) => h.match);
  assert.deepEqual(conflicts, []);
});

test('the two canonical hints resolve on disk and to the exact ledger surface string', { skip: !HAVE_REPO && 'consuming repo not present on this machine' }, () => {
  const policy = loadPolicy();
  const canonical = policy.surfaceHints.filter((h) => h.canonical === true);
  assert.equal(canonical.length, 2);
  const ledger = readFileSync(join(CONSUMING_REPO, '.claude', 'tasks', 'apex-studio-surface-ledger.md'), 'utf-8');
  for (const hint of canonical) {
    assert.ok(existsSync(join(CONSUMING_REPO, hint.match)), `${hint.match} must exist`);
    assert.ok(ledger.includes(hint.surface), `"${hint.surface}" must appear verbatim in the ledger`);
  }
});

test('net hint count is 46 (6 original minus 2 defective, plus 40 validated new, plus 2 canonical-flag entries)', () => {
  const policy = loadPolicy();
  assert.equal(policy.surfaceHints.length, 46);
  assert.equal(policy.surfaceHints.some((h) => h.match === 'ui/src/pages/BrandPage.jsx'), false);
  assert.equal(policy.surfaceHints.some((h) => h.match === 'ui/src/pages/HouseGuideAdminPage.jsx'), false);
});
