import { test } from 'node:test';
import assert from 'node:assert/strict';
import { matchesGlob } from '../dist/glob.js';

test('exact paths match', () => {
  assert.equal(matchesGlob('backend/app/routes/studio_chat.py', 'backend/app/routes/studio_chat.py'), true);
  assert.equal(matchesGlob('backend/app/routes/studio_chat.py', 'backend/app/routes/other.py'), false);
});

test('** spans directory separators', () => {
  assert.equal(matchesGlob('ui/src/**', 'ui/src/a/b/c.jsx'), true);
  assert.equal(matchesGlob('backend/app/routes/studio_adapters/**', 'backend/app/routes/studio_adapters/globals.py'), true);
  assert.equal(matchesGlob('ui/src/**', 'backend/app/x.py'), false);
});

test('* does not span separators', () => {
  assert.equal(matchesGlob('ui/src/*.js', 'ui/src/index.js'), true);
  assert.equal(matchesGlob('ui/src/*.js', 'ui/src/deep/index.js'), false);
});

test('**/*.ext matches at any depth', () => {
  assert.equal(matchesGlob('ui/src/**/*.jsx', 'ui/src/marketing/CampaignCockpit.jsx'), true);
  assert.equal(matchesGlob('ui/src/**/*.jsx', 'ui/src/index.js'), false);
});

test('windows separators in the path still match', () => {
  assert.equal(matchesGlob('ui/src/**', 'ui\\src\\a\\b.jsx'), true);
});

test('regex metacharacters in a pattern are literal', () => {
  assert.equal(matchesGlob('backend/app/x+y.py', 'backend/app/x+y.py'), true);
  assert.equal(matchesGlob('backend/app/x+y.py', 'backend/app/xy.py'), false);
});
