import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const PLUGIN = join(ROOT, 'plugins', 'apex-dev-harness');
const HARNESS = join(dirname(fileURLToPath(import.meta.url)), '..');

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

test('hooks/hooks.json exists, parses, and references ${CLAUDE_PLUGIN_ROOT}', () => {
  const f = join(PLUGIN, 'hooks', 'hooks.json');
  assert.ok(existsSync(f), 'missing hooks/hooks.json');
  const raw = readFileSync(f, 'utf-8');
  const parsed = JSON.parse(raw);
  assert.ok(parsed.hooks.PreToolUse, 'missing PreToolUse hooks');
  assert.ok(parsed.hooks.PostToolUse, 'missing PostToolUse hooks');
  assert.match(raw, /\$\{CLAUDE_PLUGIN_ROOT\}/);
});

test('the bundled engine ships the binary, an engine module, and the hook shim', () => {
  assert.ok(existsSync(join(PLUGIN, 'engine', 'bin', 'apex.js')), 'missing engine/bin/apex.js');
  assert.ok(existsSync(join(PLUGIN, 'engine', 'dist', 'route.js')), 'missing engine/dist/route.js');
  assert.ok(existsSync(join(PLUGIN, 'engine', 'templates', 'apex-hook.js')), 'missing engine/templates/apex-hook.js');
});

test('the bundled engine deliberately excludes dist/mcp/', () => {
  assert.equal(existsSync(join(PLUGIN, 'engine', 'dist', 'mcp')), false);
});

test('every command file references ${CLAUDE_PLUGIN_ROOT} and none invokes a bare `apex`', () => {
  for (const c of ['route', 'gate', 'build', 'status']) {
    const f = join(PLUGIN, 'commands', `${c}.md`);
    const body = readFileSync(f, 'utf-8');
    assert.match(body, /\$\{CLAUDE_PLUGIN_ROOT\}/, `${c}.md does not reference CLAUDE_PLUGIN_ROOT`);
    assert.doesNotMatch(body, /!`apex /, `${c}.md still shells out to a bare apex binary`);
  }
});

test('the apex-done-gate skill exists with name and description frontmatter', () => {
  const f = join(PLUGIN, 'skills', 'apex-done-gate', 'SKILL.md');
  assert.ok(existsSync(f), 'missing skills/apex-done-gate/SKILL.md');
  const s = readFileSync(f, 'utf-8');
  assert.match(s, /^---\n[\s\S]*?name: apex-done-gate/);
  assert.match(s, /description:/);
});

test('staleness guard: the bundled engine is byte-identical to the built dist', () => {
  const bundled = readFileSync(join(PLUGIN, 'engine', 'dist', 'route.js'));
  const built = readFileSync(join(HARNESS, 'dist', 'route.js'));
  assert.ok(bundled.equals(built), 'engine/dist/route.js is stale — run `npm run build` (which re-bundles) or `npm run bundle:plugin`');
});

test('end-to-end: the bundled hook denies a .env write with BOUND-005 and no APEX_ENGINE_DIST set', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-plugin-hook-'));
  try {
    mkdirSync(join(dir, 'tools', 'repo-lanes'), { recursive: true });
    writeFileSync(join(dir, 'tools', 'repo-lanes', 'lanes.json'), JSON.stringify({
      governedRoots: ['ui/src'],
      modules: [],
      importGuards: [],
    }));

    const hook = join(PLUGIN, 'engine', 'templates', 'apex-hook.js');
    const env = { ...process.env, APEX_REPO_ROOT: dir };
    delete env.APEX_ENGINE_DIST;

    const out = execFileSync(process.execPath, [hook, 'pre-tool-use'], {
      input: JSON.stringify({ tool_name: 'Write', tool_input: { file_path: '.env', content: 'placeholder' } }),
      encoding: 'utf-8',
      env,
    });
    const json = JSON.parse(out);
    assert.equal(json.hookSpecificOutput.permissionDecision, 'deny');
    assert.match(json.hookSpecificOutput.permissionDecisionReason, /BOUND-005/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
