// SPDX-License-Identifier: MIT
// Report what the harness can actually see, and say plainly what it cannot.
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { loadLanes } from './truth/lanes.js';
import { loadLedger } from './truth/ledger.js';
import { loadPolicy } from './truth/policy.js';
export async function doctor(root) {
    const lines = ['apex-dev-harness doctor', ''];
    let ok = true;
    const pass = (m) => lines.push(`  ok    ${m}`);
    const warn = (m) => lines.push(`  warn  ${m}`);
    const fail = (m) => { ok = false; lines.push(`  FAIL  ${m}`); };
    if (!root) {
        fail('no apex-app checkout found (looked for tools/repo-lanes/lanes.json above the cwd)');
        lines.push('', 'result: FAILED');
        return { ok, lines };
    }
    lines.push(`repo: ${root}`, '');
    lines.push('truth files');
    const lanes = loadLanes(root);
    if (lanes.ok)
        pass(`lanes.json — ${lanes.modules.length} modules, ${lanes.importGuards.length} import guards`);
    else
        warn(lanes.warning);
    const ledger = loadLedger(root);
    if (ledger.ok) {
        const by = {};
        for (const r of ledger.rows)
            by[r.status] = (by[r.status] ?? 0) + 1;
        pass(`surface ledger — ${ledger.rows.length} rows parsed (${Object.entries(by).map(([k, v]) => `${k}:${v}`).join(' ')})`);
        if (ledger.rowsWithoutRoutes > 0) {
            warn(`${ledger.rowsWithoutRoutes} ledger rows have no route pattern — those are name-matchable only`);
        }
        if (ledger.warning)
            warn(ledger.warning);
    }
    else
        warn(ledger.warning);
    const policy = loadPolicy(root);
    if (policy.warning)
        warn(policy.warning);
    else
        pass(`policy.json — ${policy.rules.length} rules, ${policy.obligations.length} obligations`);
    lines.push('');
    lines.push('wrapped commands');
    const wrapped = [
        ['capability manifest', 'backend/scripts/gen_studio_capability_manifest.py'],
        ['stack map', 'tools/stack-map/extract_capability.py'],
        ['ui style generators', 'ui/scripts/check-style-generators.js'],
        ['lane import guards', 'tools/repo-lanes/tests'],
    ];
    for (const [label, rel] of wrapped) {
        if (existsSync(join(root, rel)))
            pass(`${label} — ${rel}`);
        else
            warn(`${label} MISSING — ${rel} (its obligation will fail if it fires)`);
    }
    lines.push('');
    lines.push('hooks');
    const hookInstalled = existsSync(join(root, '.claude', 'hooks', 'apex-hook.js'));
    if (hookInstalled)
        pass('.claude/hooks/apex-hook.js installed');
    else
        warn('.claude/hooks/apex-hook.js not installed — run `apex init`');
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
    }
    catch {
        warn('apex-dev-harness is NOT installed in this project — the hook will fail open and NO rule will be enforced. Install it (npm i -D apex-dev-harness) or set APEX_ENGINE_DIST.');
    }
    lines.push('');
    lines.push(ok ? 'result: ok' : 'result: FAILED');
    return { ok, lines };
}
