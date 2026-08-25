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
