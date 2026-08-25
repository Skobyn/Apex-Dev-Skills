// SPDX-License-Identifier: MIT
import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { dispatch, createServer } from '../dist/mcp/server.js';
import { TOOLS } from '../dist/mcp/tools.js';
import { RESOURCES } from '../dist/mcp/resources.js';
import { POLICY } from '../dist/mcp/policy.js';

beforeEach(() => {
  const dir = mkdtempSync(join(tmpdir(), 'harness-audit-'));
  process.env.HARNESS_AUDIT_LOG = join(dir, 'audit.log');
});

const fresh = () => ({ callsThisTurn: 0 });

test('every tool declares a name, description and object input schema', () => {
  assert.ok(TOOLS.length > 0);
  for (const t of TOOLS) {
    assert.ok(t.name && t.description, `${t.name} missing metadata`);
    assert.equal(t.inputSchema.type, 'object', `${t.name} schema is not an object`);
    assert.equal(typeof t.run, 'function');
  }
  assert.equal(new Set(TOOLS.map((t) => t.name)).size, TOOLS.length, 'duplicate tool name');
});

test('ping dispatches and reports the harness', async () => {
  const out = await dispatch('ping', {}, fresh());
  assert.equal(out.harness, 'apex-app-harness');
  assert.equal(out.ok, true);
});

test('an unknown tool is rejected, not silently ignored', async () => {
  await assert.rejects(() => dispatch('no-such-tool', {}, fresh()), /unknown tool/);
});

test('a tool needing an ungranted capability is denied by the policy', async () => {
  await assert.rejects(() => dispatch('memory-store', { text: 'x' }, fresh()), /denied: file-write not permitted/);
});

test('missing required arguments produce a clear error', async () => {
  await assert.rejects(() => dispatch('route', {}, fresh()), /`task` is required/);
});

test('the per-turn call budget is enforced', async () => {
  const state = { callsThisTurn: POLICY.maxToolCallsPerTurn };
  await assert.rejects(() => dispatch('ping', {}, state), /budget exhausted/);
});

test('a successful call consumes exactly one unit of budget', async () => {
  const state = fresh();
  await dispatch('ping', {}, state);
  assert.equal(state.callsThisTurn, 1);
});

test('route dispatches through MCP and returns a tier', async () => {
  const out = await dispatch('route', { task: 'design the auth migration' }, fresh());
  assert.equal(out.tier, 'sage');
});

test('every resource is readable from a clean checkout', async () => {
  for (const r of RESOURCES) {
    const text = await r.read();
    assert.doesNotThrow(() => JSON.parse(text), `${r.uri} is not valid JSON`);
  }
});

test('the server constructs with all three capabilities', () => {
  assert.ok(createServer());
});
