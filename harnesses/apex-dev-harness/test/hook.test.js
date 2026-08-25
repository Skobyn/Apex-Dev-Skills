import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, cpSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const HOOK = join(HERE, '..', 'templates', 'apex-hook.js');
const DIST = join(HERE, '..', 'dist');

function repo() {
  const dir = mkdtempSync(join(tmpdir(), 'apex-hook-'));
  mkdirSync(join(dir, 'tools', 'repo-lanes'), { recursive: true });
  writeFileSync(join(dir, 'tools', 'repo-lanes', 'lanes.json'), JSON.stringify({
    governedRoots: ['ui/src'],
    modules: [{ path: 'ui/src/menuDesigner/', lane: 'retired', notes: 'Route retired 2026-07-18.' }],
    importGuards: [],
  }));
  return dir;
}

function runHook(phase, payload, root) {
  const out = execFileSync(process.execPath, [HOOK, phase], {
    input: JSON.stringify(payload),
    encoding: 'utf-8',
    env: { ...process.env, APEX_REPO_ROOT: root, APEX_ENGINE_DIST: DIST },
  });
  return { raw: out, json: JSON.parse(out) };
}

test('an ordinary edit is allowed with a bare {}', () => {
  const dir = repo();
  try {
    const { json } = runHook('pre-tool-use', { tool_name: 'Edit', tool_input: { file_path: 'ui/src/ok.jsx', content: 'const a=1;' } }, dir);
    assert.deepEqual(json, {});
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a blocked edit emits the deny shape both harnesses honor', () => {
  const dir = repo();
  try {
    const { json } = runHook('pre-tool-use', { tool_name: 'Write', tool_input: { file_path: '.env', content: 'placeholder' } }, dir);
    assert.equal(json.hookSpecificOutput.permissionDecision, 'deny');
    assert.match(json.hookSpecificOutput.permissionDecisionReason, /BOUND-005/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a retired-lane edit is denied with the lane note', () => {
  const dir = repo();
  try {
    const { json } = runHook('pre-tool-use', { tool_name: 'Edit', tool_input: { file_path: 'ui/src/menuDesigner/Canvas.jsx', content: 'x' } }, dir);
    assert.equal(json.hookSpecificOutput.permissionDecision, 'deny');
    assert.match(json.hookSpecificOutput.permissionDecisionReason, /RETIRED/i);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('garbage on stdin fails open with {}', () => {
  const dir = repo();
  try {
    const out = execFileSync(process.execPath, [HOOK, 'pre-tool-use'], {
      input: 'not json at all', encoding: 'utf-8',
      env: { ...process.env, APEX_REPO_ROOT: dir, APEX_ENGINE_DIST: DIST },
    });
    assert.deepEqual(JSON.parse(out), {});
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a payload with no file_path fails open', () => {
  const dir = repo();
  try {
    assert.deepEqual(runHook('pre-tool-use', { tool_name: 'Edit', tool_input: {} }, dir).json, {});
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('an unknown phase fails open rather than erroring', () => {
  const dir = repo();
  try {
    assert.deepEqual(runHook('no-such-phase', { tool_input: { file_path: 'ui/src/a.jsx' } }, dir).json, {});
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('stdout is always exactly one JSON object', () => {
  const dir = repo();
  try {
    const { raw } = runHook('pre-tool-use', { tool_name: 'Edit', tool_input: { file_path: 'ui/src/ok.jsx', content: 'x' } }, dir);
    assert.equal(raw.trim().split('\n').length, 1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('windows-style file paths are handled', () => {
  const dir = repo();
  try {
    const { json } = runHook('pre-tool-use', { tool_name: 'Edit', tool_input: { file_path: 'ui\\src\\menuDesigner\\Canvas.jsx', content: 'x' } }, dir);
    assert.equal(json.hookSpecificOutput.permissionDecision, 'deny');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('MultiEdit content is read from edits[] and reaches content rules', () => {
  const dir = repo();
  try {
    // Built from parts so this test file itself never contains a
    // credential-shaped literal (this repo's own guardrail hook rejects it).
    const secretLine = 'const ' + 'API_' + 'KEY = "sk-' + 'abcdefgh12345678' + '";';
    const { json } = runHook('pre-tool-use', {
      tool_name: 'MultiEdit',
      tool_input: {
        file_path: 'ui/src/ok.jsx',
        edits: [
          { old_string: 'a', new_string: 'const a = 1;' },
          { old_string: 'b', new_string: secretLine },
        ],
      },
    }, dir);
    assert.equal(json.hookSpecificOutput?.permissionDecision, 'deny');
    assert.match(json.hookSpecificOutput.permissionDecisionReason, /BOUND-002/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a clean MultiEdit is allowed with a bare {}', () => {
  const dir = repo();
  try {
    const { json } = runHook('pre-tool-use', {
      tool_name: 'MultiEdit',
      tool_input: {
        file_path: 'ui/src/ok.jsx',
        edits: [{ old_string: 'a', new_string: 'const a = 1;' }],
      },
    }, dir);
    assert.deepEqual(json, {});
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('post-tool-use never blocks, even on a violation', () => {
  const dir = repo();
  try {
    assert.deepEqual(runHook('post-tool-use', { tool_name: 'Edit', tool_input: { file_path: 'ui/src/menuDesigner/x.jsx' } }, dir).json, {});
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a deny response is also exactly one JSON object', () => {
  const dir = repo();
  try {
    const { raw } = runHook('pre-tool-use', { tool_name: 'Write', tool_input: { file_path: '.env', content: 'placeholder' } }, dir);
    assert.equal(raw.trim().split('\n').length, 1);
    assert.doesNotThrow(() => JSON.parse(raw));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('session-start emits the allow object and never blocks', () => {
  const dir = repo();
  try {
    const { json } = runHook('session-start', { tool_input: { file_path: 'ui/src/menuDesigner/Canvas.jsx' } }, dir);
    assert.deepEqual(json, {});
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('an absolute path with a differently-cased root prefix is still stripped', () => {
  const dir = repo();
  try {
    // BOUND-005 (the dotenv rule) matches on basename alone, so it can't
    // distinguish a correctly-stripped relative path from a strip failure
    // that leaves the path absolute -- it would pass either way. LANE-RETIRED
    // does prefix-match the relative path against the lane entry
    // ('ui/src/menuDesigner/'), so a failed strip (path stays absolute) makes
    // it match no lane and silently ALLOW the edit. That's the case this
    // test exercises: a differently-cased root prefix than findRepoRoot()
    // returned must still be stripped, or the retired-lane rule goes dark.
    const oddRoot = dir.toUpperCase();
    const { json } = runHook('pre-tool-use', {
      tool_name: 'Edit',
      tool_input: { file_path: oddRoot + '/ui/src/menuDesigner/Canvas.jsx', content: 'x' },
    }, dir);
    assert.equal(json.hookSpecificOutput?.permissionDecision, 'deny');
    assert.match(json.hookSpecificOutput.permissionDecisionReason, /RETIRED/i);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('the hook falls back to the installed package when no sibling engine exists', () => {
  // The coordinator's suggested version of this test set APEX_ENGINE_DIST
  // alongside the no-sibling-dist setup, but loadEngine() checks that env
  // override FIRST and returns immediately — so that version never reaches
  // the sibling-import try/catch at all and does not exercise the fallback
  // it claims to prove. To genuinely exercise "sibling missing -> package
  // specifier" without the override short-circuiting it, this copies the
  // hook to a directory with no sibling ../dist/ AND installs the real
  // built engine under node_modules/apex-dev-harness/dist/, so the bare
  // specifier import('apex-dev-harness/dist/...') resolves via normal
  // Node module resolution -- the same way it would for a real `npm i`.
  const dir = repo();
  try {
    const solo = join(dir, 'apex-hook.js');
    writeFileSync(solo, readFileSync(HOOK, 'utf-8'));

    const pkgDir = join(dir, 'node_modules', 'apex-dev-harness');
    mkdirSync(pkgDir, { recursive: true });
    writeFileSync(join(pkgDir, 'package.json'), JSON.stringify({ name: 'apex-dev-harness', type: 'module' }));
    cpSync(DIST, join(pkgDir, 'dist'), { recursive: true });
    // check.js reads templates/policy.json relative to the package root, so a
    // stub package with dist/ alone throws ENOENT partway through -- mirror
    // the real npm package's "files" layout (bin/, dist/, templates/).
    cpSync(join(HERE, '..', 'templates'), join(pkgDir, 'templates'), { recursive: true });

    const env = { ...process.env, APEX_REPO_ROOT: dir };
    delete env.APEX_ENGINE_DIST;

    const out = execFileSync(process.execPath, [solo, 'pre-tool-use'], {
      input: JSON.stringify({ tool_name: 'Write', tool_input: { file_path: '.env', content: 'placeholder' } }),
      encoding: 'utf-8',
      env,
    });
    const json = JSON.parse(out);
    assert.equal(json.hookSpecificOutput?.permissionDecision, 'deny');
    assert.match(json.hookSpecificOutput.permissionDecisionReason, /BOUND-005/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// ── post-tool-use: capability-manifest staleness now BLOCKS (exit 2) ──────
// The owner ruled that deleting studio-manifest-check.ps1 lost something
// load-bearing: it exited 2, feeding the failure text back into the agent
// loop. This restores that for genuine staleness, while keeping
// could-not-run (missing python etc.) and the style-generator check
// advisory (exit 0). Every path below still prints exactly `{}` on stdout.

function runHookRaw(phase, payload, env) {
  // execFileSync only returns stdout on a zero exit and discards stderr in
  // that case (it's only attached to the thrown error on a non-zero exit),
  // which is exactly wrong here: post-tool-use writes its advisory text to
  // stderr while exiting 0 on most paths. spawnSync captures both regardless
  // of exit code.
  const r = spawnSync(process.execPath, [HOOK, phase], {
    input: JSON.stringify(payload), encoding: 'utf-8', env,
  });
  return { status: r.status, stdout: r.stdout, stderr: r.stderr };
}

function manifestRepo(checkCmd) {
  const dir = repo();
  return { dir, env: {
    ...process.env, APEX_REPO_ROOT: dir, APEX_ENGINE_DIST: DIST,
    APEX_MANIFEST_CHECK_CMD: checkCmd,
    APEX_STYLE_CHECK_CMD: 'node -e "process.exit(0)"',
  } };
}

const CAPABILITY_PATH = 'ui/src/apexStudio/views/registry.js';

test('post-tool-use: a stale manifest blocks — stdout is exactly {} and exit code is 2', () => {
  const { dir, env } = manifestRepo('node -e "process.stderr.write(\'manifest drift\'); process.exit(1)"');
  try {
    const { status, stdout, stderr } = runHookRaw('post-tool-use', { tool_input: { file_path: CAPABILITY_PATH } }, env);
    assert.equal(status, 2);
    assert.deepEqual(JSON.parse(stdout), {});
    assert.equal(stdout.trim().split('\n').length, 1);
    assert.match(stderr, /capability manifest is STALE/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('post-tool-use: a could-not-run manifest check stays advisory — {} and exit 0', () => {
  const { dir, env } = manifestRepo('node -e "process.stderr.write(\'python: No module named scripts\'); process.exit(1)"');
  try {
    const { status, stdout, stderr } = runHookRaw('post-tool-use', { tool_input: { file_path: CAPABILITY_PATH } }, env);
    assert.equal(status, 0);
    assert.deepEqual(JSON.parse(stdout), {});
    assert.match(stderr, /could not run the capability-manifest check/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('post-tool-use: a clean manifest check emits {} and exit 0, no stderr noise', () => {
  const { dir, env } = manifestRepo('node -e "process.exit(0)"');
  try {
    const { status, stdout, stderr } = runHookRaw('post-tool-use', { tool_input: { file_path: CAPABILITY_PATH } }, env);
    assert.equal(status, 0);
    assert.deepEqual(JSON.parse(stdout), {});
    assert.equal(stderr, '');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('post-tool-use: a style-generator failure stays advisory — {} and exit 0', () => {
  const dir = repo();
  try {
    const env = {
      ...process.env, APEX_REPO_ROOT: dir, APEX_ENGINE_DIST: DIST,
      APEX_STYLE_CHECK_CMD: 'node -e "process.stdout.write(\'bad style\'); process.exit(1)"',
      APEX_MANIFEST_CHECK_CMD: 'node -e "process.exit(0)"',
    };
    const { status, stdout, stderr } = runHookRaw('post-tool-use', { tool_input: { file_path: 'ui/src/x.jsx' } }, env);
    assert.equal(status, 0);
    assert.deepEqual(JSON.parse(stdout), {});
    assert.match(stderr, /style-generator check failed/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('post-tool-use: a stderr-only check failure is reported, not swallowed', () => {
  // The case the previous `e.stdout || e.stderr` form silently discarded:
  // an empty stdout Buffer is truthy, so it always won over a real
  // stderr-only failure. gen_studio_capability_manifest writes only to
  // stderr, so this is the exact shape that made the exit-2 path
  // unreachable before the fix.
  const { dir, env } = manifestRepo('node -e "process.stderr.write(\'DRIFT DETECTED\'); process.exit(1)"');
  try {
    const { status, stderr } = runHookRaw('post-tool-use', { tool_input: { file_path: CAPABILITY_PATH } }, env);
    assert.equal(status, 2);
    assert.match(stderr, /DRIFT DETECTED/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// ── runQuiet unit tests (exported directly — the fastest, most honest way
// to pin the Buffer-concatenation behavior without going through a child
// process twice) ───────────────────────────────────────────────────────
test('runQuiet: concatenates stdout+stderr rather than choosing (empty stdout Buffer is truthy)', async () => {
  const { runQuiet } = await import(new URL('file://' + HOOK).href);
  const out = runQuiet('node -e "process.stderr.write(\'only on stderr\')&&process.exit(1)"', process.cwd());
  assert.match(out, /only on stderr/);
});

test('runQuiet: returns null on success', async () => {
  const { runQuiet } = await import(new URL('file://' + HOOK).href);
  assert.equal(runQuiet('node -e "process.exit(0)"', process.cwd()), null);
});

// ── post-tool-use: canonical-hint suppression ──────────────────────────
test('post-tool-use: a canonical hint suppresses the legacy-twin advisory outside apexStudio', () => {
  const dir = repo();
  mkdirSync(join(dir, '.harness'), { recursive: true });
  mkdirSync(join(dir, '.claude', 'tasks'), { recursive: true });
  writeFileSync(join(dir, '.claude', 'tasks', 'apex-studio-surface-ledger.md'), [
    '## Section',
    '| Surface | Routes | Status | Notes |',
    '| Email designer (legacy twin) | `/marketing/emails` | **STUDIO** | |',
  ].join('\n'));
  writeFileSync(join(dir, '.harness', 'policy.json'), JSON.stringify({
    version: 1,
    surfaceHints: [{ match: 'ui/src/marketing/EmailDesignerPage.jsx', surface: 'Email designer (legacy twin)', canonical: true }],
  }));
  try {
    const env = {
      ...process.env, APEX_REPO_ROOT: dir, APEX_ENGINE_DIST: DIST,
      APEX_STYLE_CHECK_CMD: 'node -e "process.exit(0)"', APEX_MANIFEST_CHECK_CMD: 'node -e "process.exit(0)"',
    };
    const { stderr } = runHookRaw('post-tool-use', { tool_input: { file_path: 'ui/src/marketing/EmailDesignerPage.jsx' } }, env);
    assert.equal(stderr.includes('STUDIO-canonical'), false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('post-tool-use: without canonical, the legacy-twin advisory still fires outside apexStudio', () => {
  const dir = repo();
  mkdirSync(join(dir, '.harness'), { recursive: true });
  mkdirSync(join(dir, '.claude', 'tasks'), { recursive: true });
  writeFileSync(join(dir, '.claude', 'tasks', 'apex-studio-surface-ledger.md'), [
    '## Section',
    '| Surface | Routes | Status | Notes |',
    '| Some legacy twin | `/legacy/thing` | **STUDIO** | |',
  ].join('\n'));
  writeFileSync(join(dir, '.harness', 'policy.json'), JSON.stringify({
    version: 1,
    surfaceHints: [{ match: 'ui/src/legacy/Thing.jsx', surface: 'Some legacy twin' }],
  }));
  try {
    const env = {
      ...process.env, APEX_REPO_ROOT: dir, APEX_ENGINE_DIST: DIST,
      APEX_STYLE_CHECK_CMD: 'node -e "process.exit(0)"', APEX_MANIFEST_CHECK_CMD: 'node -e "process.exit(0)"',
    };
    const { stderr } = runHookRaw('post-tool-use', { tool_input: { file_path: 'ui/src/legacy/Thing.jsx' } }, env);
    assert.match(stderr, /STUDIO-canonical/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
