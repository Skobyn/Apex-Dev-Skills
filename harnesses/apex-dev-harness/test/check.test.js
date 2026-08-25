import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { check } from '../dist/check.js';

/** Build a credential-shaped sample at runtime — never write one literally. */
function credentialSample() {
  return ['API', '_KEY = ', JSON.stringify('x'.repeat(24))].join('');
}

function repo() {
  const dir = mkdtempSync(join(tmpdir(), 'apex-check-'));
  mkdirSync(join(dir, 'tools', 'repo-lanes'), { recursive: true });
  writeFileSync(join(dir, 'tools', 'repo-lanes', 'lanes.json'), JSON.stringify({
    governedRoots: ['ui/src', 'backend'],
    modules: [
      { path: 'ui/src/menuDesigner/', lane: 'retired' },
      { path: 'ui/src/quizBuilder/', lane: 'legacy' },
      { path: 'ui/src/marketing/', lane: 'production' },
      { path: 'backend/agentic/', lane: 'production' },
    ],
    importGuards: [{
      id: 'ui-quiz', namespace: 'ui/src/quizBuilder', language: 'js',
      internalExempt: ['ui/src/quizBuilder/'],
      allow: [{ file: 'ui/src/marketing/CampaignCockpit.jsx', reason: 'listQuizzes.' }],
    }],
  }));
  return dir;
}

test('creating a dotenv file is blocked, naming the rule', () => {
  const dir = repo();
  try {
    const d = check(dir, '.env.local', 'placeholder');
    assert.equal(d.allow, false);
    assert.equal(d.ruleId, 'BOUND-005');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a credential literal is blocked', () => {
  const dir = repo();
  try {
    const d = check(dir, 'backend/app/x.py', credentialSample());
    assert.equal(d.allow, false);
    assert.equal(d.ruleId, 'BOUND-002');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('editing a retired-lane module is blocked', () => {
  const dir = repo();
  try {
    const d = check(dir, 'ui/src/menuDesigner/Canvas.jsx', 'export const x = 1;');
    assert.equal(d.allow, false);
    assert.equal(d.ruleId, 'LANE-RETIRED');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a NEW import of a guarded namespace is blocked', () => {
  const dir = repo();
  try {
    const d = check(dir, 'ui/src/marketing/NewPage.jsx', "import { listQuizzes } from '../quizBuilder/api';");
    assert.equal(d.allow, false);
    assert.equal(d.ruleId, 'LANE-IMPORT');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a grandfathered importer may keep its import', () => {
  const dir = repo();
  try {
    const d = check(dir, 'ui/src/marketing/CampaignCockpit.jsx', "import { listQuizzes } from '../quizBuilder/api';");
    assert.equal(d.allow, true);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('projectDataJson is blocked as a dead field', () => {
  const dir = repo();
  try {
    const d = check(dir, 'backend/app/routes/x.py', 'doc["projectDataJson"] = payload');
    assert.equal(d.allow, false);
    assert.equal(d.ruleId, 'CONV-PROJECTDATA');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a provider SDK import is blocked inside backend/agentic', () => {
  const dir = repo();
  try {
    const d = check(dir, 'backend/agentic/services/sales.py', 'import anthropic');
    assert.equal(d.allow, false);
    assert.equal(d.ruleId, 'BOUND-004');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('the same import is allowed inside the abstraction layer', () => {
  const dir = repo();
  try {
    assert.equal(check(dir, 'backend/agentic/core/llm/provider_a.py', 'import anthropic').allow, true);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('the same import is NOT blocked outside agentic — the rule is scoped', () => {
  const dir = repo();
  try {
    assert.equal(check(dir, 'backend/app/agents/blog.py', 'import anthropic').allow, true);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('ordinary edits pass', () => {
  const dir = repo();
  try {
    assert.equal(check(dir, 'ui/src/marketing/CampaignCockpit.jsx', 'const a = 1;').allow, true);
    assert.equal(check(dir, 'ui/src/marketing/Other.jsx', 'const b = 2;').allow, true);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a bare repo with no truth files still allows edits — fail open', () => {
  const dir = mkdtempSync(join(tmpdir(), 'apex-bare-check-'));
  try {
    assert.equal(check(dir, 'ui/src/x.jsx', 'const a = 1;').allow, true);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
