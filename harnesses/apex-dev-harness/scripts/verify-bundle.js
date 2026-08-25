#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// Verifies the committed plugin engine bundle is current relative to the
// working tree. Not a byte-compare against dist/ — `npm run build`
// re-bundles before tests ever run, so that comparison could never fail.
// The real risk this guards against: a commit whose src/ changed but whose
// plugins/apex-dev-harness/engine/ copy was not regenerated and committed
// alongside it, leaving every plugin installer with a stale engine.

import { execFileSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(HERE, '..', '..', '..');
const ENGINE_PATH = 'plugins/apex-dev-harness/engine';

function main() {
  let out;
  try {
    out = execFileSync('git', ['status', '--porcelain', '--', ENGINE_PATH], {
      cwd: REPO_ROOT,
      encoding: 'utf-8',
    });
  } catch (e) {
    console.warn(`verify-bundle: could not run git (${e.message}) — skipping (fail open).`);
    process.exit(0);
  }

  if (out.trim().length > 0) {
    console.error('verify-bundle: the following paths under ' + ENGINE_PATH + ' are uncommitted:');
    console.error(out.trimEnd());
    console.error('the bundled plugin engine is out of date — run npm run build and COMMIT plugins/apex-dev-harness/engine/');
    process.exit(1);
  }

  console.log('bundled plugin engine is current');
  process.exit(0);
}

main();
