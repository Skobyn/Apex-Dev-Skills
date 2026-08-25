// SPDX-License-Identifier: MIT
// End-to-end: the CLI is the surface users actually touch.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const CLI = join(dirname(fileURLToPath(import.meta.url)), '..', 'bin', 'cli.js');

function run(args, opts = {}) {
  return execFileSync(process.execPath, [CLI, ...args], { encoding: 'utf-8', ...opts });
}

test('--version prints the package version', () => {
  assert.match(run(['--version']).trim(), /^\d+\.\d+\.\d+$/);
});

test('help lists every documented command', () => {
  const out = run(['--help']);
  for (const cmd of ['init', 'doctor', 'mcp start', 'memory search', 'route']) {
    assert.ok(out.includes(cmd), `help omits ${cmd}`);
  }
});

test('an unknown command exits non-zero with usage', () => {
  assert.throws(() => run(['frobnicate']), (err) => {
    assert.equal(err.status, 2);
    assert.match(err.stderr, /unknown command/);
    return true;
  });
});

test('doctor runs green in the package itself', () => {
  const out = run(['doctor']);
  assert.match(out, /result: ok/);
  assert.match(out, /@metaharness\/kernel/);
});

test('init scaffolds a project, and re-running it does not clobber', () => {
  const dir = mkdtempSync(join(tmpdir(), 'harness-init-'));
  try {
    const first = run(['init'], { cwd: dir });
    assert.match(first, /write  CLAUDE\.md/);
    for (const f of ['CLAUDE.md', '.harness/manifest.json', '.claude/settings.json']) {
      assert.ok(existsSync(join(dir, f)), `init did not write ${f}`);
    }
    const second = run(['init'], { cwd: dir });
    assert.match(second, /skip   CLAUDE\.md/);
    assert.match(second, /0 written/);

    // doctor must pass in the scaffolded project, not just in the package
    assert.match(run(['doctor'], { cwd: dir }), /result: ok/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('route prints a tier and the signals behind it', () => {
  const out = run(['route', 'fix a typo in the docs']);
  assert.match(out, /tier:\s+barbarian/);
  assert.match(out, /signals:/);
});

test('memory store then search round-trips through the CLI', () => {
  const dir = mkdtempSync(join(tmpdir(), 'harness-cli-mem-'));
  try {
    const env = { ...process.env, HARNESS_MEMORY_PATH: join(dir, 'memory.jsonl') };
    run(['memory', 'store', 'always gate tool calls through the policy'], { env });
    assert.match(run(['memory', 'search', 'gate tool calls'], { env }), /policy/);
    assert.match(run(['memory', 'search', 'unrelated topic'], { env }), /no matches/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('mcp rejects an unknown subcommand', () => {
  assert.throws(() => run(['mcp', 'launch']), (err) => {
    assert.equal(err.status, 2);
    assert.match(err.stderr, /unknown mcp subcommand/);
    return true;
  });
});
