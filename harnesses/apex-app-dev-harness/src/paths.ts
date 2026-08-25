// SPDX-License-Identifier: MIT
// Resolves harness config files. A file in the user's project (cwd) always wins
// over the copy shipped inside the package, so `init` output is authoritative.

import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));

/** Root of the installed package (dist/ -> package root). */
export const PACKAGE_ROOT = resolve(HERE, '..');

/** Files bundled with the package, used when the project has no copy. */
export const BUNDLED_HARNESS_DIR = join(PACKAGE_ROOT, '.harness');

/** The user's project. Overridable for tests. */
export function projectRoot(): string {
  return process.env.HARNESS_PROJECT_ROOT ?? process.cwd();
}

export function projectHarnessDir(): string {
  return join(projectRoot(), '.harness');
}

/**
 * Locate a harness config file: project copy first, bundled default second.
 * Returns null when neither exists.
 */
export function resolveHarnessFile(name: string): string | null {
  const local = join(projectHarnessDir(), name);
  if (existsSync(local)) return local;
  const bundled = join(BUNDLED_HARNESS_DIR, name);
  if (existsSync(bundled)) return bundled;
  return null;
}

export function readHarnessJson<T>(name: string, fallback: T): T {
  const path = resolveHarnessFile(name);
  if (!path) return fallback;
  try {
    return JSON.parse(readFileSync(path, 'utf-8')) as T;
  } catch {
    return fallback;
  }
}
