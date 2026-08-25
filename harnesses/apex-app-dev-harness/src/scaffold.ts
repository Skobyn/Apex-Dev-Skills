// SPDX-License-Identifier: MIT
// `init` — copy the packaged templates into the user's project.

import { cp, mkdir, readdir, stat } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join, relative } from 'node:path';
import { PACKAGE_ROOT, projectRoot } from './paths.js';

export interface ScaffoldResult {
  lines: string[];
  written: string[];
  skipped: string[];
}

const TEMPLATES = join(PACKAGE_ROOT, 'templates');

async function walk(dir: string): Promise<string[]> {
  const out: string[] = [];
  for (const name of await readdir(dir)) {
    const full = join(dir, name);
    if ((await stat(full)).isDirectory()) out.push(...(await walk(full)));
    else out.push(full);
  }
  return out;
}

/**
 * Copy templates/ into the project. Never overwrites an existing file unless
 * `force` is set — a user's edited CLAUDE.md is theirs, not ours.
 */
export async function scaffold(opts: { force?: boolean } = {}): Promise<ScaffoldResult> {
  const root = projectRoot();
  const written: string[] = [];
  const skipped: string[] = [];
  const lines: string[] = [`scaffolding apex-app-harness into ${root}`, ''];

  if (!existsSync(TEMPLATES)) {
    lines.push('FAIL  templates/ missing from the installed package — reinstall apex-app-harness');
    return { lines, written, skipped };
  }

  for (const src of await walk(TEMPLATES)) {
    const rel = relative(TEMPLATES, src);
    const dest = join(root, rel);
    if (existsSync(dest) && !opts.force) {
      skipped.push(rel);
      lines.push(`  skip   ${rel} (exists — pass --force to overwrite)`);
      continue;
    }
    await mkdir(join(dest, '..'), { recursive: true });
    await cp(src, dest);
    written.push(rel);
    lines.push(`  write  ${rel}`);
  }

  lines.push('');
  lines.push(`${written.length} written, ${skipped.length} skipped`);
  lines.push('');
  lines.push('Next: `apex-app-harness doctor`, then restart Claude Code to pick up .claude/settings.json.');
  return { lines, written, skipped };
}
