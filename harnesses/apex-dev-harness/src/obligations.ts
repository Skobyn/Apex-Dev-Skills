// SPDX-License-Identifier: MIT
// What does this diff owe? Obligations are computed, never remembered.

import { execFileSync } from 'node:child_process';
import type { Obligation, Policy } from './types.js';
import { matchesGlob } from './glob.js';
import { normalize } from './repo.js';

function git(root: string, args: string[]): string {
  try {
    return execFileSync('git', args, { cwd: root, encoding: 'utf-8', stdio: ['ignore', 'pipe', 'ignore'] });
  } catch {
    return '';
  }
}

/** The changed files in the working tree, unstaged and staged, relative to `base`. */
export function changedPaths(root: string, base = 'HEAD'): string[] {
  const unstaged = git(root, ['diff', '--name-only', base]);
  const staged = git(root, ['diff', '--name-only', '--cached']);
  // `git diff` never lists untracked files, so a brand-new file built in the
  // wrong surface would owe nothing — the flagship failure case. Union in
  // untracked files explicitly.
  const untracked = git(root, ['ls-files', '--others', '--exclude-standard']);
  const all = new Set(
    [...unstaged.split('\n'), ...staged.split('\n'), ...untracked.split('\n')].map((s) => s.trim()).filter(Boolean),
  );
  return [...all].map(normalize);
}

export function obligationsFor(policy: Policy, paths: string[]): Obligation[] {
  const out: Obligation[] = [];
  for (const def of policy.obligations) {
    const fired = paths.some((p) => def.when.anyPathMatches.some((pattern) => matchesGlob(pattern, p)));
    if (fired) out.push({ id: def.id, reason: def.reason, commands: def.run });
  }
  return out;
}

export function parityWarningsFor(policy: Policy, paths: string[]): string[] {
  const out: string[] = [];
  for (const rule of policy.parityRules) {
    if (!paths.some((p) => matchesGlob(rule.match, p))) continue;
    for (const s of rule.surfaces) if (!out.includes(s)) out.push(s);
  }
  return out;
}
