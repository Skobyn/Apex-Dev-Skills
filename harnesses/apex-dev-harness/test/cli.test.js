import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const CLI = join(HERE, '..', 'bin', 'apex.js');
const BUILTIN_POLICY_PATH = join(HERE, '..', 'templates', 'policy.json');

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

test('init writes a minimal DELTA overlay, not a full copy of the built-in policy', () => {
  // The defect this release fixes: `init` used to write a full snapshot,
  // which — once present — froze the repo out of every future engine
  // update. The written file must be small and carry no rules/hints of
  // its own; everything is inherited at read time via loadPolicy's merge.
  const dir = repo();
  try {
    const env = { ...process.env, APEX_REPO_ROOT: dir };
    run(['init'], { env });
    const written = JSON.parse(readFileSync(join(dir, '.harness', 'policy.json'), 'utf-8'));
    assert.equal(written.rules, undefined);
    assert.equal(written.surfaceHints, undefined);
    assert.ok(written.disabled);
    assert.match(written._readme ?? '', /inherited/);
    // and `apex check` still resolves the full built-in rule set through it
    assert.throws(() => run(['check', 'package-lock.json'], { env }), (err) => {
      assert.match(err.stdout, /GUARD-SENSITIVE-FILE/);
      return true;
    });
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('apex policy prune drops a project policy entry byte-identical to the built-in', () => {
  const dir = repo();
  try {
    const env = { ...process.env, APEX_REPO_ROOT: dir };
    mkdirSync(join(dir, '.harness'), { recursive: true });
    // Simulate an old full-snapshot install: BOUND-005 copied verbatim
    // from the built-in, plus one genuinely local rule.
    writeFileSync(join(dir, '.harness', 'policy.json'), JSON.stringify({
      version: 1,
      rules: [
        { id: 'BOUND-005', tier: 'block', scope: 'repo', check: 'no-dotenv-files', source: '.agents/rules/boundaries.md' },
        { id: 'LOCAL-ONLY', tier: 'block', scope: 'repo', source: 'local' },
      ],
    }, null, 2));
    const out = run(['policy', 'prune'], { env });
    assert.match(out, /removed 1 entr/);
    assert.match(out, /BOUND-005/);
    const after = JSON.parse(readFileSync(join(dir, '.harness', 'policy.json'), 'utf-8'));
    assert.equal(after.rules.some((r) => r.id === 'BOUND-005'), false);
    assert.ok(after.rules.some((r) => r.id === 'LOCAL-ONLY'));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('apex policy prune on a pure snapshot empties the local sections and says so', () => {
  const dir = repo();
  try {
    const env = { ...process.env, APEX_REPO_ROOT: dir };
    mkdirSync(join(dir, '.harness'), { recursive: true });
    // Write a byte-identical copy of the built-in policy (the historical bug).
    const builtin = JSON.parse(readFileSync(BUILTIN_POLICY_PATH, 'utf-8'));
    writeFileSync(join(dir, '.harness', 'policy.json'), JSON.stringify(builtin));
    const out = run(['policy', 'prune'], { env });
    assert.match(out, /no local entries remain/);
    const after = JSON.parse(readFileSync(join(dir, '.harness', 'policy.json'), 'utf-8'));
    assert.deepEqual(after.rules, []);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('apex policy prune is a no-op (does not rewrite) when nothing is identical', () => {
  const dir = repo();
  try {
    const env = { ...process.env, APEX_REPO_ROOT: dir };
    mkdirSync(join(dir, '.harness'), { recursive: true });
    writeFileSync(join(dir, '.harness', 'policy.json'), JSON.stringify({
      version: 1, rules: [{ id: 'LOCAL-ONLY', tier: 'block', scope: 'repo', source: 'local' }],
    }));
    const before = readFileSync(join(dir, '.harness', 'policy.json'), 'utf-8');
    const out = run(['policy', 'prune'], { env });
    assert.match(out, /nothing to prune|nothing changed/);
    const after = readFileSync(join(dir, '.harness', 'policy.json'), 'utf-8');
    assert.equal(before, after);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('doctor warns when the project policy is a verbatim snapshot', () => {
  const dir = repo();
  try {
    const env = { ...process.env, APEX_REPO_ROOT: dir };
    mkdirSync(join(dir, '.harness'), { recursive: true });
    const builtin = JSON.parse(readFileSync(BUILTIN_POLICY_PATH, 'utf-8'));
    writeFileSync(join(dir, '.harness', 'policy.json'), JSON.stringify(builtin));
    const out = run(['doctor'], { env });
    assert.match(out, /snapshot, not config/);
    assert.match(out, /apex policy prune/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('doctor warns about a bare-string disabled entry with no reason', () => {
  const dir = repo();
  try {
    const env = { ...process.env, APEX_REPO_ROOT: dir };
    mkdirSync(join(dir, '.harness'), { recursive: true });
    writeFileSync(join(dir, '.harness', 'policy.json'), JSON.stringify({
      version: 1, disabled: { rules: ['ARCH-003'], surfaceHints: [] },
    }));
    const out = run(['doctor'], { env });
    assert.match(out, /disabled entry ARCH-003 has no reason/);
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
