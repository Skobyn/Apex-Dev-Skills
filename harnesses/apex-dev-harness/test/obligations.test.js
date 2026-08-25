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
