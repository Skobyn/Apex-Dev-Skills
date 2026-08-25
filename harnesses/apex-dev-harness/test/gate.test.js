import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { gate, formatGate, runCommand } from '../dist/gate.js';

const okRunner = (_root, command) => ({ command, ok: true, output: '' });
const failRunner = (_root, command) => ({ command, ok: false, output: 'STALE' });

function bare() { return mkdtempSync(join(tmpdir(), 'apex-gate-')); }

test('a clean diff with no obligations passes', () => {
  const dir = bare();
  try {
    const v = gate(dir, { paths: ['README.md'], message: 'docs: tidy', runner: okRunner });
    assert.equal(v.ok, true);
    assert.deepEqual(v.obligations, []);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a capability-surface diff runs its commands and passes when they pass', () => {
  const dir = bare();
  try {
    const v = gate(dir, { paths: ['backend/app/routes/studio_chat.py'], message: 'feat: x', runner: okRunner });
    assert.ok(v.obligations.length > 0);
    assert.ok(v.results.length > 0);
    assert.equal(v.ok, true);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a failing obligation fails the gate and is listed', () => {
  const dir = bare();
  try {
    const v = gate(dir, { paths: ['backend/app/routes/studio_chat.py'], message: 'feat: x', runner: failRunner });
    assert.equal(v.ok, false);
    assert.ok(v.results.every((r) => r.ok === false));
    assert.match(formatGate(v), /NOT DONE/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a watchlist hit in the message fails the gate', () => {
  const dir = bare();
  try {
    const v = gate(dir, { paths: ['README.md'], message: 'fix: good enough for now', runner: okRunner });
    assert.ok(v.watchlistHits.length > 0);
    assert.equal(v.ok, false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('parity warnings appear but do not by themselves fail the gate', () => {
  const dir = bare();
  try {
    const v = gate(dir, { paths: ['ui/src/marketing/X.jsx'], message: 'feat: x', runner: okRunner });
    assert.ok(v.parityWarnings.length > 0);
    assert.equal(v.ok, true);
    assert.match(formatGate(v), /parity/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('formatGate marks a failed command', () => {
  const dir = bare();
  try {
    assert.match(formatGate(gate(dir, { paths: ['ui/src/a.jsx'], message: 'ok', runner: failRunner })), /FAILED/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('runCommand reports failure for a non-zero exit', () => {
  const dir = bare();
  try {
    assert.equal(runCommand(dir, 'node -e "process.exit(3)"').ok, false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('runCommand reports success for a zero exit', () => {
  const dir = bare();
  try {
    assert.equal(runCommand(dir, 'node -e "process.exit(0)"').ok, true);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
