// SPDX-License-Identifier: MIT
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { route } from '../dist/route.js';

test('mechanical work routes to the cheap tier', () => {
  const d = route('fix a typo in the README');
  assert.equal(d.tier, 'barbarian');
  assert.ok(d.signals.some((s) => s.startsWith('barbarian:')));
});

test('high-stakes work routes to the top tier', () => {
  assert.equal(route('design the migration for the auth schema').tier, 'sage');
  assert.equal(route('fix a race condition in the scheduler').tier, 'sage');
});

test('unremarkable work falls to the middle tier', () => {
  const d = route('add a button to the settings page');
  assert.equal(d.tier, 'scholar');
  assert.deepEqual(d.signals, ['default:scholar']);
});

test('a long description escalates one tier', () => {
  const long = 'add a button to the settings page ' + 'with a constraint '.repeat(40);
  const d = route(long);
  assert.equal(d.tier, 'sage');
  assert.ok(d.signals.some((s) => s.startsWith('length:')));
});

test('escalation never runs past the top tier', () => {
  const d = route('redesign the concurrency model ' + 'and also '.repeat(40));
  assert.equal(d.tier, 'sage');
});

test('a decision always names a configured model and a confidence', () => {
  const d = route('refactor the payment protocol');
  assert.equal(typeof d.model, 'string');
  assert.ok(d.confidence > 0 && d.confidence <= 0.9);
});
