// SPDX-License-Identifier: MIT
// Report what the harness can actually see, and say plainly what it cannot.

import { existsSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadLanes } from './truth/lanes.js';
import { loadLedger } from './truth/ledger.js';
import { loadPolicy, DEFAULT_POLICY } from './truth/policy.js';
import { truthPaths } from './repo.js';
import { HOOK_VERSION_MARKER } from './scaffold.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const ENGINE_PACKAGE_JSON = join(HERE, '..', 'package.json');

function engineVersion(): string {
  return JSON.parse(readFileSync(ENGINE_PACKAGE_JSON, 'utf-8')).version;
}

// The hook is a copy: read its stamped version off the second line, e.g.
//   // apex-dev-harness-hook-version: 0.3.1
// Returns null when the file predates version stamping (pre-0.3.1 `apex init`).
function stampedHookVersion(hookPath: string): string | null {
  const text = readFileSync(hookPath, 'utf-8');
  const line = text.split('\n')[1] ?? '';
  const idx = line.indexOf(HOOK_VERSION_MARKER);
  if (idx === -1) return null;
  return line.slice(idx + HOOK_VERSION_MARKER.length).trim();
}

const SNAPSHOT_SECTIONS: Array<{ name: keyof typeof DEFAULT_POLICY; keyOf: (x: any) => string }> = [
  { name: 'rules', keyOf: (r) => r.id },
  { name: 'obligations', keyOf: (o) => o.id },
  { name: 'mwgTargets', keyOf: (m) => m.match },
  { name: 'skillRules', keyOf: (s) => s.match },
  { name: 'parityRules', keyOf: (p) => p.match },
  { name: 'surfaceHints', keyOf: (h) => h.match },
  { name: 'excludedFiles', keyOf: (e) => e.match },
];

function canon(v: unknown): string {
  return JSON.stringify(v, (_k, val) => {
    if (val && typeof val === 'object' && !Array.isArray(val)) {
      return Object.fromEntries(Object.keys(val).sort().map((k) => [k, (val as Record<string, unknown>)[k]]));
    }
    return val;
  });
}

export async function doctor(root: string | null): Promise<{ ok: boolean; lines: string[] }> {
  const lines: string[] = ['apex-dev-harness doctor', ''];
  let ok = true;
  const pass = (m: string) => lines.push(`  ok    ${m}`);
  const warn = (m: string) => lines.push(`  warn  ${m}`);
  const fail = (m: string) => { ok = false; lines.push(`  FAIL  ${m}`); };

  if (!root) {
    fail('no apex-app checkout found (looked for tools/repo-lanes/lanes.json above the cwd)');
    lines.push('', 'result: FAILED');
    return { ok, lines };
  }
  lines.push(`repo: ${root}`, '');

  lines.push('truth files');
  const lanes = loadLanes(root);
  if (lanes.ok) pass(`lanes.json — ${lanes.modules.length} modules, ${lanes.importGuards.length} import guards`);
  else warn(lanes.warning!);

  const ledger = loadLedger(root);
  if (ledger.ok) {
    const by: Record<string, number> = {};
    for (const r of ledger.rows) by[r.status] = (by[r.status] ?? 0) + 1;
    pass(`surface ledger — ${ledger.rows.length} rows parsed (${Object.entries(by).map(([k, v]) => `${k}:${v}`).join(' ')})`);
    if (ledger.rowsWithoutRoutes > 0) {
      warn(`${ledger.rowsWithoutRoutes} ledger rows have no route pattern — those are name-matchable only`);
    }
    if (ledger.warning) warn(ledger.warning);
  } else warn(ledger.warning!);

  const policy = loadPolicy(root);
  if (policy.warning) warn(policy.warning);
  else pass(`policy.json — ${policy.rules.length} rules, ${policy.obligations.length} obligations`);

  // Snapshot detection: a project policy that is present and carries a lot
  // of entries byte-identical to the built-in is a leftover full copy (the
  // pre-0.3.0 `apex init` behavior), not a delta overlay — it will silently
  // miss every rule and hint the engine adds from here on.
  const policyPath = truthPaths(root).policy;
  if (existsSync(policyPath)) {
    try {
      const parsed = JSON.parse(readFileSync(policyPath, 'utf-8'));
      let total = 0;
      let identical = 0;
      for (const s of SNAPSHOT_SECTIONS) {
        const arr = parsed[s.name as string];
        if (!Array.isArray(arr)) continue;
        const builtinByKey = new Map((DEFAULT_POLICY[s.name] as any[]).map((e) => [s.keyOf(e), e]));
        for (const entry of arr) {
          total++;
          const b = builtinByKey.get(s.keyOf(entry));
          if (b !== undefined && canon(b) === canon(entry)) identical++;
        }
      }
      if (Array.isArray(parsed.watchlist)) {
        const builtinSet = new Set(DEFAULT_POLICY.watchlist);
        for (const w of parsed.watchlist) { total++; if (builtinSet.has(w)) identical++; }
      }
      if (total > 0 && identical === total) {
        warn(`.harness/policy.json: ${identical}/${total} entries are verbatim built-in. This file is a snapshot, not config — it will freeze this repo out of engine updates. Run 'apex policy prune'.`);
      } else if (total > 0 && identical > 0) {
        warn(`.harness/policy.json: ${identical}/${total} entries are verbatim built-in. Run 'apex policy prune' to drop the ones that carry no local config.`);
      }

      // A `disabled` entry without a reason is unreviewable later.
      const disabled = parsed.disabled ?? {};
      for (const [, arr] of [['rules', disabled.rules], ['surfaceHints', disabled.surfaceHints]] as const) {
        for (const entry of (arr ?? [])) {
          if (typeof entry === 'string') {
            warn(`disabled entry ${entry} has no reason — an allowlist without reasons is unreviewable later`);
          }
        }
      }
    } catch { /* already reported via policy.warning above */ }
  }
  lines.push('');

  lines.push('wrapped commands');
  const wrapped: Array<[string, string]> = [
    ['capability manifest', 'backend/scripts/gen_studio_capability_manifest.py'],
    ['stack map', 'tools/stack-map/extract_capability.py'],
    ['ui style generators', 'ui/scripts/check-style-generators.js'],
    ['lane import guards', 'tools/repo-lanes/tests'],
  ];
  for (const [label, rel] of wrapped) {
    if (existsSync(join(root, rel))) pass(`${label} — ${rel}`);
    else warn(`${label} MISSING — ${rel} (its obligation will fail if it fires)`);
  }
  lines.push('');

  lines.push('hooks');
  const hookPath = join(root, '.claude', 'hooks', 'apex-hook.js');
  const hookInstalled = existsSync(hookPath);
  if (hookInstalled) {
    // Presence alone proved nothing: `npm i` updates dist/ but the hook is a
    // COPY made by `apex init`, so it can silently go stale while doctor
    // reported it "installed". Compare the stamp against the running engine.
    const engine = engineVersion();
    const stamped = stampedHookVersion(hookPath);
    if (stamped === null) {
      warn('.claude/hooks/apex-hook.js predates version stamping — it may be stale. Run `apex init --force`.');
    } else if (stamped !== engine) {
      warn(`.claude/hooks/apex-hook.js is from ${stamped} but the installed engine is ${engine} — the hook is a COPY and npm i does not update it. Run \`apex init --force\`.`);
    } else {
      pass(`.claude/hooks/apex-hook.js installed (${engine})`);
    }
  } else {
    warn('.claude/hooks/apex-hook.js not installed — run `apex init`');
  }

  if (hookInstalled && !existsSync(join(root, '.claude', 'hooks', 'package.json'))) {
    warn('.claude/hooks/package.json missing — every hook run will print a MODULE_TYPELESS_PACKAGE_JSON warning. Re-run `apex init`.');
  }

  // The hook resolves the engine by package specifier. Checking only that the
  // hook FILE exists proved nothing: if the package is not installed the hook
  // fails open and every guardrail is silently off. Probe it the same way.
  const { createRequire } = await import('node:module');
  const req = createRequire(join(root, 'package.json'));
  try {
    req.resolve('apex-dev-harness/package.json');
    pass('apex-dev-harness resolves from the project — the hook can load the engine');
  } catch {
    warn('apex-dev-harness is NOT installed in this project — the hook will fail open and NO rule will be enforced. Install it (npm i -D apex-dev-harness) or set APEX_ENGINE_DIST.');
  }
  lines.push('');

  lines.push(ok ? 'result: ok' : 'result: FAILED');
  return { ok, lines };
}
