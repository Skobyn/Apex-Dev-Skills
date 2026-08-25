// SPDX-License-Identifier: MIT
// Load .harness/policy.json — the only NEW truth the harness introduces.
// It holds policy (which rules bite, and where), never facts about the repo.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { Policy, PolicyRule } from '../types.js';
import { normalize, truthPaths } from '../repo.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const BUNDLED = join(HERE, '..', '..', 'templates', 'policy.json');

function readBundled(): Omit<Policy, 'ok' | 'warning'> {
  return JSON.parse(readFileSync(BUNDLED, 'utf-8'));
}

/** The built-in policy, used when the project ships none. */
export const DEFAULT_POLICY: Policy = { ok: true, ...readBundled() };

export function loadPolicy(root: string): Policy {
  const path = truthPaths(root).policy;
  let raw: string;
  try {
    raw = readFileSync(path, 'utf-8');
  } catch {
    return { ...DEFAULT_POLICY, ok: true, warning: `no ${path} — using the harness's built-in policy` };
  }
  try {
    return { ok: true, ...(JSON.parse(raw) as Omit<Policy, 'ok'>) };
  } catch (err) {
    const why = err instanceof Error ? err.message : String(err);
    return { ...DEFAULT_POLICY, ok: false, warning: `could not parse ${path}: ${why} — using the built-in policy` };
  }
}

/**
 * The enforceable rules that apply to a path. `historical` rules are recorded
 * in the policy for provenance and are never returned here.
 */
export function rulesInScope(policy: Policy, relPath: string): PolicyRule[] {
  const p = normalize(relPath);
  return policy.rules.filter((r) => {
    if (r.tier === 'historical') return false;
    if (r.scope === 'repo') return true;
    return p.startsWith(normalize(r.scope));
  });
}
