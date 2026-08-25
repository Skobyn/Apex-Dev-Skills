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
