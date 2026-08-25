// SPDX-License-Identifier: MIT
// Locate the apex-app checkout and its truth files.

import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

/** The marker that identifies an apex-app checkout. */
const MARKER = join('tools', 'repo-lanes', 'lanes.json');

/**
 * Walk up from `start` looking for the lanes registry. Returns null rather
 * than throwing — callers degrade to a reduced verdict.
 * `APEX_REPO_ROOT` overrides discovery entirely (tests, CI, monorepo hosts).
 */
export function findRepoRoot(start: string = process.cwd()): string | null {
  const override = process.env.APEX_REPO_ROOT;
  if (override) return override;

  let dir = resolve(start);
  for (;;) {
    if (existsSync(join(dir, MARKER))) return dir;
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

export interface TruthPaths {
  lanes: string;
  ledger: string;
  policy: string;
}

export function truthPaths(root: string): TruthPaths {
  return {
    lanes: join(root, 'tools', 'repo-lanes', 'lanes.json'),
    ledger: join(root, '.claude', 'tasks', 'apex-studio-surface-ledger.md'),
    policy: join(root, '.harness', 'policy.json'),
  };
}

/** Normalize a path for matching: forward slashes, no leading './'. */
export function normalize(p: string): string {
  return p.replace(/\\/g, '/').replace(/^\.\//, '');
}
