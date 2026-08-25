import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { TOOLS, createServer } from '../dist/mcp/server.js';

function repo() {
  const dir = mkdtempSync(join(tmpdir(), 'apex-mcp-'));
  mkdirSync(join(dir, 'tools', 'repo-lanes'), { recursive: true });
  writeFileSync(join(dir, 'tools', 'repo-lanes', 'lanes.json'), JSON.stringify({
    governedRoots: ['ui/src'],
    modules: [{ path: 'ui/src/menuDesigner/', lane: 'retired' }],
    importGuards: [],
  }));
  return dir;
}

test('every tool declares name, description and an object schema', () => {
  assert.ok(TOOLS.length >= 4);
  for (const t of TOOLS) {
    assert.ok(t.name && t.description, `${t.name} missing metadata`);
    assert.equal(t.inputSchema.type, 'object');
  }
  assert.equal(new Set(TOOLS.map((t) => t.name)).size, TOOLS.length);
});

test('apex_route returns a verdict', async () => {
  const dir = repo();
  try {
    process.env.APEX_REPO_ROOT = dir;
    const tool = TOOLS.find((t) => t.name === 'apex_route');
    assert.equal((await tool.run({ query: 'ui/src/menuDesigner/x.jsx' })).lane, 'retired');
  } finally { delete process.env.APEX_REPO_ROOT; rmSync(dir, { recursive: true, force: true }); }
});

test('apex_check refuses a blocked edit', async () => {
  const dir = repo();
  try {
    process.env.APEX_REPO_ROOT = dir;
    const tool = TOOLS.find((t) => t.name === 'apex_check');
    assert.equal((await tool.run({ path: '.env', content: 'placeholder' })).allow, false);
  } finally { delete process.env.APEX_REPO_ROOT; rmSync(dir, { recursive: true, force: true }); }
});

test('a missing required argument produces a clear error', async () => {
  await assert.rejects(() => TOOLS.find((t) => t.name === 'apex_route').run({}), /query/);
});

test('the server constructs', () => {
  assert.ok(createServer());
});
