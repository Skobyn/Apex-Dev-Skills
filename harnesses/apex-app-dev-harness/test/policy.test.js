// SPDX-License-Identifier: MIT
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { decide, withTimeout, POLICY } from '../dist/mcp/policy.js';

test('the shipped policy is default-deny on every privileged capability', () => {
  assert.equal(POLICY.defaultDeny, true);
  assert.equal(POLICY.allowNetwork, false);
  assert.equal(POLICY.allowShell, false);
  assert.equal(POLICY.allowFileWrite, false);
});

test('an unprivileged tool is permitted', () => {
  const d = decide({ needs: {} });
  assert.equal(d.allowed, true);
  assert.equal(d.requiresApproval, false);
});

test('each ungranted capability is refused by name', () => {
  assert.match(decide({ needs: { network: true } }).reason, /network/);
  assert.match(decide({ needs: { shell: true } }).reason, /shell/);
  assert.match(decide({ needs: { fileWrite: true } }).reason, /file-write/);
  assert.equal(decide({ needs: { shell: true } }).allowed, false);
});

test('a dangerous tool requires approval even when its capability is granted', () => {
  const d = decide({ needs: {}, dangerous: true });
  assert.equal(d.allowed, true);
  assert.equal(d.requiresApproval, true);
});

test('withTimeout resolves a fast body', async () => {
  assert.equal(await withTimeout(async () => 42), 42);
});

test('withTimeout propagates the body error', async () => {
  await assert.rejects(() => withTimeout(async () => { throw new Error('boom'); }), /boom/);
});
