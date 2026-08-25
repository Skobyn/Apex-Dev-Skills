import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { findRepoRoot, truthPaths, normalize } from '../dist/repo.js';

test('finds the repo root from a nested directory', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-repo-'));
  try {
    mkdirSync(join(dir, 'tools', 'repo-lanes'), { recursive: true });
    writeFileSync(join(dir, 'tools', 'repo-lanes', 'lanes.json'), '{}');
    mkdirSync(join(dir, 'ui', 'src', 'marketing'), { recursive: true });
    assert.equal(findRepoRoot(join(dir, 'ui', 'src', 'marketing')), dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('returns null when no apex-app root is above the start directory', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-norepo-'));
  try {
    assert.equal(findRepoRoot(dir), null);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('APEX_REPO_ROOT overrides discovery', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-env-'));
  try {
    process.env.APEX_REPO_ROOT = dir;
    assert.equal(findRepoRoot('/nowhere'), dir);
  } finally {
    delete process.env.APEX_REPO_ROOT;
    rmSync(dir, { recursive: true, force: true });
  }
});

test('truthPaths names all three truth files', () => {
  const p = truthPaths('/repo');
  assert.match(p.lanes, /repo[\\/]tools[\\/]repo-lanes[\\/]lanes\.json$/);
  assert.match(p.ledger, /apex-studio-surface-ledger\.md$/);
  assert.match(p.policy, /\.harness[\\/]policy\.json$/);
});

test('normalize makes windows paths comparable', () => {
  assert.equal(normalize('ui\\src\\a.jsx'), 'ui/src/a.jsx');
  assert.equal(normalize('./ui/src/a.jsx'), 'ui/src/a.jsx');
});
