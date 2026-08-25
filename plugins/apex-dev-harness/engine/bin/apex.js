#!/usr/bin/env node
// SPDX-License-Identifier: MIT
import { readFileSync } from 'node:fs';

const USAGE = `apex — routing and gate engine for apex-app

  apex route <path|route>          What applies here: lane, surface, mwg, skills, parity
  apex gate [--base <ref>] [--message <text>] [--paths a,b]
                                   What this diff owes, run and verdicted
                                   --dry-run lists what is owed without running it
  apex check <path> [--content -]  Block-tier decision for one edit (used by hooks)
  apex watchlist <file|->          BOUND-006 vocabulary scan
  apex doctor                      What the harness can see
  apex init [--force]              Install the hook shim + policy into apex-app
  apex policy prune                Drop project-policy entries identical to the built-in
                                   (migration for repos whose policy.json is an old full
                                   snapshot, not a delta overlay)
  apex mcp start                   Run the MCP server on stdio

  --json                           Machine-readable output (route, gate, check)
`;

function arg(args, name) {
  const i = args.indexOf(name);
  return i === -1 ? undefined : args[i + 1];
}

async function readStdin() {
  const chunks = [];
  for await (const c of process.stdin) chunks.push(c);
  return Buffer.concat(chunks).toString('utf-8');
}

async function main(argv) {
  const [cmd, ...args] = argv;
  const json = args.includes('--json');
  const { findRepoRoot } = await import('../dist/repo.js');
  const root = findRepoRoot();

  const needRoot = () => {
    if (!root) {
      console.error('apex: no apex-app checkout found. Run inside the repo, or set APEX_REPO_ROOT.');
      process.exit(1);
    }
    return root;
  };

  switch (cmd) {
    case undefined: case 'help': case '--help': case '-h':
      console.log(USAGE); return 0;
    case 'version': case '--version': case '-v': {
      const url = new URL('../package.json', import.meta.url);
      console.log(JSON.parse(readFileSync(url, 'utf-8')).version); return 0;
    }
    case 'route': {
      const q = args.filter((a) => !a.startsWith('--'))[0];
      if (!q) { console.error('usage: apex route <path|route>'); return 2; }
      const m = await import('../dist/route.js');
      const v = m.route(needRoot(), q);
      console.log(json ? JSON.stringify(v, null, 2) : m.formatRoute(v));
      return 0;
    }
    case 'gate': {
      const m = await import('../dist/gate.js');
      const paths = arg(args, '--paths')?.split(',').map((s) => s.trim()).filter(Boolean);
      const v = m.gate(needRoot(), {
        base: arg(args, '--base'),
        message: arg(args, '--message'),
        paths,
        dryRun: args.includes('--dry-run'),
      });
      console.log(json ? JSON.stringify(v, null, 2) : m.formatGate(v));
      return v.ok ? 0 : 1;
    }
    case 'check': {
      const p = args.filter((a) => !a.startsWith('--'))[0];
      if (!p) { console.error('usage: apex check <path> [--content -]'); return 2; }
      const content = arg(args, '--content') === '-' ? await readStdin() : null;
      const { check } = await import('../dist/check.js');
      const d = check(needRoot(), p, content);
      if (json) console.log(JSON.stringify(d));
      else console.log(d.allow ? 'allow' : `deny [${d.ruleId}] ${d.reason}`);
      return d.allow ? 0 : 1;
    }
    case 'watchlist': {
      const f = args.filter((a) => !a.startsWith('--'))[0];
      const text = !f || f === '-' ? await readStdin() : readFileSync(f, 'utf-8');
      const [{ scanWatchlist }, { loadPolicy }] = await Promise.all([
        import('../dist/watchlist.js'), import('../dist/truth/policy.js'),
      ]);
      const hits = scanWatchlist(loadPolicy(root ?? '.'), text);
      if (hits.length === 0) { console.log('no watchlist hits'); return 0; }
      for (const h of hits) console.log(`line ${h.line}: "${h.term}" — ${h.excerpt}`);
      return 1;
    }
    case 'doctor': {
      const { doctor } = await import('../dist/doctor.js');
      const r = await doctor(root);
      for (const l of r.lines) console.log(l);
      return r.ok ? 0 : 1;
    }
    case 'init': {
      const { scaffold } = await import('../dist/scaffold.js');
      const r = scaffold(needRoot(), { force: args.includes('--force') });
      for (const l of r.lines) console.log(l);
      return 0;
    }
    case 'policy': {
      const sub = args[0];
      if (sub !== 'prune') { console.error('usage: apex policy prune'); return 2; }
      const { prunePolicy } = await import('../dist/policyPrune.js');
      const r = prunePolicy(needRoot());
      for (const l of r.lines) console.log(l);
      return r.ok ? 0 : 1;
    }
    case 'mcp': {
      if ((args[0] ?? 'start') !== 'start') { console.error('usage: apex mcp start'); return 2; }
      const { start } = await import('../dist/mcp/server.js');
      await start();
      return null;
    }
    default:
      console.error(`unknown command: ${cmd}\n`); console.error(USAGE); return 2;
  }
}

main(process.argv.slice(2))
  .then((code) => { if (code !== null) process.exit(code); })
  .catch((err) => { console.error(`apex: ${err?.message ?? err}`); process.exit(1); });
