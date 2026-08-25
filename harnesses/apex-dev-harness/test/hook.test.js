import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
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
