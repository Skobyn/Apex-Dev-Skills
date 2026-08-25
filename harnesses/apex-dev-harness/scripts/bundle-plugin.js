#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// Copies the built engine (dist/, bin/, templates/) into the Claude Code
// plugin at plugins/apex-dev-harness/engine/, so the plugin is self-
// sufficient and needs no separate npm install of apex-dev-harness for
// route/gate/check/doctor. dist/mcp/ is deliberately excluded — it is the
// only part of the engine that needs the (5.2M, unbundled) MCP SDK, and
// shipping a module that throws on import is worse than omitting it.

import { existsSync, rmSync, mkdirSync, readdirSync, copyFileSync } from 'node:fs';
import { join, dirname, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const HARNESS_ROOT = join(HERE, '..');
const DIST = join(HARNESS_ROOT, 'dist');
const BIN = join(HARNESS_ROOT, 'bin');
const TEMPLATES = join(HARNESS_ROOT, 'templates');
const PLUGIN_ENGINE = join(HARNESS_ROOT, '..', '..', 'plugins', 'apex-dev-harness', 'engine');

if (!existsSync(DIST)) {
  console.error('bundle-plugin: dist/ is missing. Run `npm run build` (tsc) first.');
  process.exit(1);
}

function copyTree(src, dest, { skip } = {}) {
  const written = [];
  const entries = readdirSync(src, { withFileTypes: true });
  mkdirSync(dest, { recursive: true });
  for (const entry of entries) {
    const srcPath = join(src, entry.name);
    const destPath = join(dest, entry.name);
    if (skip && skip(srcPath)) continue;
    if (entry.isDirectory()) {
      written.push(...copyTree(srcPath, destPath, { skip }));
    } else {
      mkdirSync(dirname(destPath), { recursive: true });
      copyFileSync(srcPath, destPath);
      written.push(destPath);
    }
  }
  return written;
}

// Start clean so removals in the source tree propagate to the plugin copy.
rmSync(PLUGIN_ENGINE, { recursive: true, force: true });
mkdirSync(PLUGIN_ENGINE, { recursive: true });

const distDest = join(PLUGIN_ENGINE, 'dist');
const mcpDir = join(DIST, 'mcp');
const written = [
  ...copyTree(DIST, distDest, { skip: (p) => p === mcpDir }),
  ...copyTree(BIN, join(PLUGIN_ENGINE, 'bin')),
  ...copyTree(TEMPLATES, join(PLUGIN_ENGINE, 'templates')),
];

console.log(`bundle-plugin: dist/mcp/ excluded — MCP (\`apex mcp start\`) still requires the npm package.`);
console.log(`bundle-plugin: wrote ${written.length} files to ${relative(HARNESS_ROOT, PLUGIN_ENGINE)}/`);
for (const f of written) {
  console.log(`  ${relative(PLUGIN_ENGINE, f)}`);
}
