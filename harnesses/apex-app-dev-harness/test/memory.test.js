// SPDX-License-Identifier: MIT
import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

let dir;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'harness-mem-'));
  process.env.HARNESS_MEMORY_PATH = join(dir, 'memory.jsonl');
});

test('a stored pattern is found by its own words', async () => {
  const { store, search } = await import('../dist/memory.js');
  await store('always validate MCP tool inputs at the boundary', ['mcp']);
  await store('prefer composition over inheritance', ['design']);

  const hits = await search('validate MCP tool inputs');
  assert.equal(hits.length, 1);
  assert.match(hits[0].text, /validate MCP tool inputs/);
  assert.ok(hits[0].score > 0);
  rmSync(dir, { recursive: true, force: true });
});

test('an unrelated query matches nothing rather than guessing', async () => {
  const { store, search } = await import('../dist/memory.js');
  await store('prefer composition over inheritance', ['design']);
  assert.deepEqual(await search('kubernetes ingress'), []);
  rmSync(dir, { recursive: true, force: true });
});

test('search on a missing store returns empty, not an error', async () => {
  const { search } = await import('../dist/memory.js');
  process.env.HARNESS_MEMORY_PATH = join(dir, 'does-not-exist.jsonl');
  assert.deepEqual(await search('anything'), []);
  rmSync(dir, { recursive: true, force: true });
});

test('a corrupt line does not take the whole store down', async () => {
  const path = join(dir, 'memory.jsonl');
  process.env.HARNESS_MEMORY_PATH = path;
  writeFileSync(
    path,
    '{ not json\n' + JSON.stringify({ id: 'a', text: 'retry with backoff', tags: [], storedAt: Date.now() }) + '\n',
  );
  const { search } = await import('../dist/memory.js');
  const hits = await search('retry with backoff');
  assert.equal(hits.length, 1);
  rmSync(dir, { recursive: true, force: true });
});

test('limit is respected', async () => {
  const { store, search } = await import('../dist/memory.js');
  for (let i = 0; i < 5; i++) await store(`retry policy variant ${i}`);
  assert.equal((await search('retry policy', 2)).length, 2);
  rmSync(dir, { recursive: true, force: true });
});
