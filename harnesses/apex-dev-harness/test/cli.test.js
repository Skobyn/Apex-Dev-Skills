import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const CLI = join(dirname(fileURLToPath(import.meta.url)), '..', 'bin', 'apex.js');

function run(args, opts = {}) {
  return execFileSync(process.execPath, [CLI, ...args], { encoding: 'utf-8', ...opts });
}

function repo() {
  const dir = mkdtempSync(join(tmpdir(), 'apex-cli-'));
  mkdirSync(join(dir, 'tools', 'repo-lanes'), { recursive: true });
  writeFileSync(join(dir, 'tools', 'repo-lanes', 'lanes.json'), JSON.stringify({
    governedRoots: ['ui/src'],
    modules: [{ path: 'ui/src/menuDesigner/', lane: 'retired' }],
    importGuards: [],
  }));
  return dir;
}

test('--version prints a semver', () => {
  assert.match(run(['--version']).trim(), /^\d+\.\d+\.\d+$/);
});

test('help names every command', () => {
  const out = run(['--help']);
  for (const c of ['route', 'gate', 'check', 'watchlist', 'doctor', 'init', 'mcp']) {
    assert.ok(out.includes(c), `help omits ${c}`);
  }
});

test('route --json emits parseable output', () => {
  const dir = repo();
  try {
    const out = run(['route', 'ui/src/menuDesigner/x.jsx', '--json'], { env: { ...process.env, APEX_REPO_ROOT: dir } });
    assert.equal(JSON.parse(out).lane, 'retired');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('check exits 1 and names the rule for a blocked edit', () => {
  const dir = repo();
  assert.throws(() => run(['check', '.env'], { env: { ...process.env, APEX_REPO_ROOT: dir } }), (err) => {
    assert.equal(err.status, 1);
    assert.match(err.stdout, /BOUND-005/);
    return true;
  });
  rmSync(dir, { recursive: true, force: true });
});

test('doctor reports the repo it found', () => {
  const dir = repo();
  try {
    assert.match(run(['doctor'], { env: { ...process.env, APEX_REPO_ROOT: dir } }), /lanes\.json/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('doctor fails cleanly when no repo is found', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-norepo-cli-'));
  assert.throws(() => run(['doctor'], { cwd: dir, env: { ...process.env, APEX_REPO_ROOT: '' } }), (err) => {
    assert.equal(err.status, 1);
    assert.match(err.stdout, /no apex-app checkout found/);
    return true;
  });
  rmSync(dir, { recursive: true, force: true });
});

test('init installs the shim and policy, and does not clobber on re-run', () => {
  const dir = repo();
  try {
    const env = { ...process.env, APEX_REPO_ROOT: dir };
    assert.match(run(['init'], { env }), /write  \.claude/);
    assert.ok(existsSync(join(dir, '.claude', 'hooks', 'apex-hook.js')));
    assert.ok(existsSync(join(dir, '.harness', 'policy.json')));
    assert.match(run(['init'], { env }), /0 written/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('an unknown command exits 2', () => {
  assert.throws(() => run(['frobnicate']), (err) => {
    assert.equal(err.status, 2);
    return true;
  });
});

test('init writes .claude/hooks/package.json so the hook stays quiet on module-type warnings', () => {
  const dir = repo();
  try {
    const env = { ...process.env, APEX_REPO_ROOT: dir };
    run(['init'], { env });
    assert.ok(existsSync(join(dir, '.claude', 'hooks', 'package.json')));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('doctor warns when .claude/hooks/package.json is missing', () => {
  const dir = repo();
  try {
    const env = { ...process.env, APEX_REPO_ROOT: dir };
    mkdirSync(join(dir, '.claude', 'hooks'), { recursive: true });
    writeFileSync(join(dir, '.claude', 'hooks', 'apex-hook.js'), '// stub');
    const out = run(['doctor'], { env });
    assert.match(out, /MODULE_TYPELESS_PACKAGE_JSON/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
