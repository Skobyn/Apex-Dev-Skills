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

test('a non-empty project watchlist MERGES with the built-in (union), not overrides it', () => {
  // 0.3.0: apex init writes a delta overlay, and loadPolicy MERGES it with
  // the built-in — a project addition must not blot out the built-in
  // vocabulary, or the defect this release fixes (a snapshot silently
  // freezing a repo out of engine updates) just comes back in a new shape.
  const dir = mkdtempSync(join(tmpdir(), 'apex-policy-'));
  try {
    mkdirSync(join(dir, '.harness'), { recursive: true });
    writeFileSync(join(dir, '.harness', 'policy.json'), JSON.stringify({
      version: 1, watchlist: ['bespoke'],
    }));
    const p = loadPolicy(dir);
    assert.equal(p.ok, true);
    assert.ok(p.watchlist.includes('bespoke'));
    assert.ok(p.watchlist.includes('quick win'), 'built-in terms must survive the merge');
    assert.equal(p.watchlist.length, DEFAULT_POLICY.watchlist.length + 1);
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

test('a partial policy inherits the default sections instead of yielding undefined', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-partialpolicy-'));
  try {
    mkdirSync(join(dir, '.harness'), { recursive: true });
    writeFileSync(join(dir, '.harness', 'policy.json'), JSON.stringify({ version: 1 }));
    const p = loadPolicy(dir);
    assert.equal(p.ok, true);
    assert.ok(Array.isArray(p.rules), 'rules must never be undefined');
    assert.ok(Array.isArray(p.obligations));
    assert.ok(Array.isArray(p.watchlist));
    assert.ok(Array.isArray(p.mwgTargets));
    assert.ok(Array.isArray(p.skillRules));
    assert.ok(Array.isArray(p.parityRules));
    // and the first consumer must not throw
    assert.doesNotThrow(() => rulesInScope(p, 'ui/src/x.jsx'));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('an explicitly empty section is preserved, not replaced by the default', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-emptysection-'));
  try {
    mkdirSync(join(dir, '.harness'), { recursive: true });
    writeFileSync(join(dir, '.harness', 'policy.json'), JSON.stringify({
      version: 1, rules: [], obligations: [], watchlist: [],
      mwgTargets: [], skillRules: [], parityRules: [],
    }));
    const p = loadPolicy(dir);
    assert.deepEqual(p.rules, []);
    assert.deepEqual(p.watchlist, []);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// ── Delta overlay model (0.3.0) ──────────────────────────────────────────

test('an omitted section inherits the full built-in — this IS the fix', () => {
  // The actual field defect: a repo whose policy.json was a full snapshot
  // never saw new rules. The overlay model's entire point is that omitting
  // a section (e.g. never mentioning GUARD-SENSITIVE-FILE) still yields it.
  const dir = mkdtempSync(join(tmpdir(), 'apex-omitted-'));
  try {
    mkdirSync(join(dir, '.harness'), { recursive: true });
    writeFileSync(join(dir, '.harness', 'policy.json'), JSON.stringify({ version: 1 }));
    const p = loadPolicy(dir);
    assert.ok(p.rules.some((r) => r.id === 'GUARD-SENSITIVE-FILE'));
    assert.deepEqual(p.rules, DEFAULT_POLICY.rules);
    assert.deepEqual(p.surfaceHints, DEFAULT_POLICY.surfaceHints);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a non-empty project rules array MERGES by id with the built-in, project winning on collision', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-mergerules-'));
  try {
    mkdirSync(join(dir, '.harness'), { recursive: true });
    writeFileSync(join(dir, '.harness', 'policy.json'), JSON.stringify({
      version: 1,
      rules: [
        { id: 'BOUND-005', tier: 'warn', scope: 'repo', source: 'local override' }, // collides — project wins
        { id: 'LOCAL-001', tier: 'block', scope: 'repo', source: 'local' }, // new
      ],
    }));
    const p = loadPolicy(dir);
    const b005 = p.rules.find((r) => r.id === 'BOUND-005');
    assert.equal(b005.tier, 'warn');
    assert.equal(b005.source, 'local override');
    assert.ok(p.rules.some((r) => r.id === 'LOCAL-001'));
    // every OTHER built-in rule survived the merge untouched
    assert.ok(p.rules.some((r) => r.id === 'GUARD-SENSITIVE-FILE'));
    assert.equal(p.rules.length, DEFAULT_POLICY.rules.length + 1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a non-empty project surfaceHints array MERGES by match, adding new hints without dropping built-in ones', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-mergehints-'));
  try {
    mkdirSync(join(dir, '.harness'), { recursive: true });
    writeFileSync(join(dir, '.harness', 'policy.json'), JSON.stringify({
      version: 1,
      surfaceHints: [{ match: 'ui/src/local/X.jsx', surface: 'Local surface' }],
    }));
    const p = loadPolicy(dir);
    assert.ok(p.surfaceHints.some((h) => h.match === 'ui/src/local/X.jsx'));
    assert.equal(p.surfaceHints.length, DEFAULT_POLICY.surfaceHints.length + 1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('disabled.rules drops a rule by id after merging, even a built-in one', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-disabled-rule-'));
  try {
    mkdirSync(join(dir, '.harness'), { recursive: true });
    writeFileSync(join(dir, '.harness', 'policy.json'), JSON.stringify({
      version: 1,
      disabled: { rules: [{ id: 'ARCH-003', reason: 'not applicable to this repo' }], surfaceHints: [] },
    }));
    const p = loadPolicy(dir);
    assert.equal(p.rules.some((r) => r.id === 'ARCH-003'), false);
    // everything else still present
    assert.ok(p.rules.some((r) => r.id === 'GUARD-SENSITIVE-FILE'));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('disabled.surfaceHints drops a hint by match after merging', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-disabled-hint-'));
  try {
    mkdirSync(join(dir, '.harness'), { recursive: true });
    const someHint = DEFAULT_POLICY.surfaceHints[0].match;
    writeFileSync(join(dir, '.harness', 'policy.json'), JSON.stringify({
      version: 1,
      disabled: { rules: [], surfaceHints: [{ match: someHint, reason: 'noisy in this repo' }] },
    }));
    const p = loadPolicy(dir);
    assert.equal(p.surfaceHints.some((h) => h.match === someHint), false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a bare-string disabled entry is accepted (doctor warns separately, loadPolicy still applies it)', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-disabled-bare-'));
  try {
    mkdirSync(join(dir, '.harness'), { recursive: true });
    writeFileSync(join(dir, '.harness', 'policy.json'), JSON.stringify({
      version: 1,
      disabled: { rules: ['ARCH-003'], surfaceHints: [] },
    }));
    const p = loadPolicy(dir);
    assert.equal(p.rules.some((r) => r.id === 'ARCH-003'), false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
