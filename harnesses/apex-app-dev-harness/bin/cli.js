#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// apex-app-harness CLI. Thin dispatcher over the compiled harness in dist/.

import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const PACKAGE_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

async function version() {
  const pkg = JSON.parse(await readFile(join(PACKAGE_ROOT, 'package.json'), 'utf-8'));
  return pkg.version;
}

const USAGE = `apex-app-harness — plan, implement, review, and test code changes

Usage:
  apex-app-harness init                Scaffold .harness/, .claude/ and CLAUDE.md into this project
  apex-app-harness doctor              Health check the install
  apex-app-harness mcp start           Run the MCP server on stdio (what Claude Code launches)
  apex-app-harness memory search <q>   Search stored patterns (lexical + recency, not embeddings)
  apex-app-harness memory store <text> Append a pattern to the store
  apex-app-harness route <task>        Recommend a routing tier
  apex-app-harness --version           Print the version

Docs: https://github.com/Skobyn/Apex-Dev-Skills
`;

async function cmdDoctor() {
  const { doctor } = await import('../dist/doctor.js');
  const report = await doctor();
  for (const line of report.lines) console.log(line);
  return report.ok ? 0 : 1;
}

async function cmdInit(args) {
  const { scaffold } = await import('../dist/scaffold.js');
  const result = await scaffold({ force: args.includes('--force') });
  for (const line of result.lines) console.log(line);
  return 0;
}

async function cmdMcp(args) {
  const sub = args[0] ?? 'start';
  if (sub !== 'start') {
    console.error(`unknown mcp subcommand: ${sub} (expected: start)`);
    return 2;
  }
  const { start } = await import('../dist/mcp/server.js');
  await start();
  return null; // long-running: do not exit
}

async function cmdMemory(args) {
  const [sub, ...rest] = args;
  const memory = await import('../dist/memory.js');
  if (sub === 'search') {
    const query = rest.join(' ').trim();
    if (!query) { console.error('usage: apex-app-harness memory search <query>'); return 2; }
    const results = await memory.search(query);
    if (results.length === 0) { console.log('no matches'); return 0; }
    for (const r of results) {
      console.log(`${r.decayedScore.toFixed(3)}  ${r.text}${r.tags.length ? `  [${r.tags.join(', ')}]` : ''}`);
    }
    return 0;
  }
  if (sub === 'store') {
    const text = rest.join(' ').trim();
    if (!text) { console.error('usage: apex-app-harness memory store <text>'); return 2; }
    const entry = await memory.store(text);
    console.log(`stored ${entry.id}`);
    return 0;
  }
  console.error('usage: apex-app-harness memory <search|store> ...');
  return 2;
}

async function cmdRoute(args) {
  const task = args.join(' ').trim();
  if (!task) { console.error('usage: apex-app-harness route <task>'); return 2; }
  const { route } = await import('../dist/route.js');
  const d = route(task);
  console.log(`tier:       ${d.tier}`);
  console.log(`model:      ${d.model ?? '(none configured)'}`);
  console.log(`confidence: ${d.confidence.toFixed(2)}`);
  console.log(`signals:    ${d.signals.join(', ')}`);
  return 0;
}

async function main(argv) {
  const [cmd, ...args] = argv;

  switch (cmd) {
    case undefined:
    case 'help':
    case '--help':
    case '-h':
      console.log(USAGE);
      return 0;
    case 'version':
    case '--version':
    case '-v':
      console.log(await version());
      return 0;
    case 'doctor': return cmdDoctor();
    case 'init': return cmdInit(args);
    case 'mcp': return cmdMcp(args);
    case 'memory': return cmdMemory(args);
    case 'route': return cmdRoute(args);
    default:
      console.error(`unknown command: ${cmd}\n`);
      console.error(USAGE);
      return 2;
  }
}

main(process.argv.slice(2))
  .then((code) => { if (code !== null) process.exit(code); })
  .catch((err) => {
    console.error(`apex-app-harness: ${err?.message ?? err}`);
    if (process.env.HARNESS_DEBUG) console.error(err);
    process.exit(1);
  });
