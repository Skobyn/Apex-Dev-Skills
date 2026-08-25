import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const PLUGIN = join(ROOT, 'plugins', 'apex-dev-harness');

test('plugin.json is valid and names the plugin', () => {
  const p = JSON.parse(readFileSync(join(PLUGIN, '.claude-plugin', 'plugin.json'), 'utf-8'));
  assert.equal(p.name, 'apex-dev-harness');
  assert.ok(p.description.length > 0);
});

test('every command file exists and has description frontmatter', () => {
  for (const c of ['route', 'gate', 'build', 'status']) {
    const f = join(PLUGIN, 'commands', `${c}.md`);
    assert.ok(existsSync(f), `missing command ${c}`);
    assert.match(readFileSync(f, 'utf-8'), /^---\n[\s\S]*?description:/);
  }
});

test('the orientation skill has name and description frontmatter', () => {
  const s = readFileSync(join(PLUGIN, 'skills', 'apex-orientation', 'SKILL.md'), 'utf-8');
  assert.match(s, /^---\n[\s\S]*?name: apex-orientation/);
  assert.match(s, /description:/);
});

test('the marketplace lists the plugin alongside apex-plan-loop', () => {
  const m = JSON.parse(readFileSync(join(ROOT, '.claude-plugin', 'marketplace.json'), 'utf-8'));
  const names = m.plugins.map((p) => p.name);
  assert.ok(names.includes('apex-dev-harness'));
  assert.ok(names.includes('apex-plan-loop'));
});
