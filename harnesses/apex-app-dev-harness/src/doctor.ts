// SPDX-License-Identifier: MIT
// Health check: report what is actually wired, and say plainly what is not.

import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { init } from './init.js';
import { POLICY } from './mcp/policy.js';
import { TOOLS } from './mcp/tools.js';
import { RESOURCES } from './mcp/resources.js';
import { PROMPTS } from './mcp/prompts.js';
import { agents } from './agents/index.js';
import { projectRoot, projectHarnessDir, resolveHarnessFile } from './paths.js';

export interface DoctorReport {
  ok: boolean;
  lines: string[];
}

export async function doctor(): Promise<DoctorReport> {
  const lines: string[] = [];
  let ok = true;

  const pass = (m: string) => lines.push(`  ok    ${m}`);
  const warn = (m: string) => lines.push(`  warn  ${m}`);
  const fail = (m: string) => { ok = false; lines.push(`  FAIL  ${m}`); };

  lines.push('apex-app-harness doctor');
  lines.push('');
  lines.push(`project: ${projectRoot()}`);
  lines.push('');

  lines.push('kernel');
  try {
    const runtime = await init();
    pass(`@metaharness/kernel ${runtime.kernel.version} (backend: ${runtime.backend}, target: ${runtime.kernel.target})`);
    if (runtime.backend === 'js') {
      warn('running the pure-JS kernel backend — native/wasm unavailable on this platform');
    }
  } catch (err) {
    fail(`kernel failed to load: ${err instanceof Error ? err.message : String(err)}`);
  }
  lines.push('');

  lines.push('project files');
  const manifest = resolveHarnessFile('manifest.json');
  if (!manifest) {
    fail('.harness/manifest.json not found — run `apex-app-harness init`');
  } else if (manifest.startsWith(projectHarnessDir())) {
    pass('.harness/ scaffolded in this project');
  } else {
    warn('.harness/ not in this project — falling back to the bundled defaults (run `apex-app-harness init`)');
  }
  for (const rel of ['CLAUDE.md', join('.claude', 'settings.json')]) {
    if (existsSync(join(projectRoot(), rel))) pass(`${rel} present`);
    else warn(`${rel} missing — run \`apex-app-harness init\``);
  }
  lines.push('');

  lines.push('mcp');
  pass(`${TOOLS.length} tools, ${RESOURCES.length} resources, ${PROMPTS.length} prompts`);
  pass(`${agents.length} agents: ${agents.map((a) => a.id).join(', ')}`);
  lines.push(
    `  info  policy: defaultDeny=${POLICY.defaultDeny} network=${POLICY.allowNetwork} ` +
      `shell=${POLICY.allowShell} fileWrite=${POLICY.allowFileWrite} timeout=${POLICY.toolTimeoutMs}ms`,
  );
  const blocked = TOOLS.filter(
    (t) =>
      (t.ctx.needs.fileWrite && !POLICY.allowFileWrite) ||
      (t.ctx.needs.network && !POLICY.allowNetwork) ||
      (t.ctx.needs.shell && !POLICY.allowShell),
  );
  if (blocked.length > 0) {
    warn(
      `denied by policy until you grant the capability in .harness/mcp-policy.json: ${blocked.map((t) => t.name).join(', ')}`,
    );
  }
  lines.push('');

  lines.push('not implemented in 0.1.0');
  lines.push('  info  witness.json is an unsigned provenance stub — no Ed25519 signing yet');
  lines.push('  info  memory search is lexical + recency decay, not embedding-based semantic search');
  lines.push('  info  routing is a deterministic heuristic, not a learned router');
  lines.push('  info  the manifest\'s darwin/self-evolution block is configuration data only');
  lines.push('');
  lines.push(ok ? 'result: ok' : 'result: FAILED');

  return { ok, lines };
}
