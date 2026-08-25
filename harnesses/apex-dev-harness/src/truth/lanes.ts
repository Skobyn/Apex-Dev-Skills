// SPDX-License-Identifier: MIT
// Parse tools/repo-lanes/lanes.json — the machine source for module lanes.

import { readFileSync } from 'node:fs';
import type { ImportGuard, Lane, LaneEntry, LanesTruth } from '../types.js';
import { normalize, truthPaths } from '../repo.js';

const EMPTY: Omit<LanesTruth, 'ok' | 'warning'> = {
  governedRoots: [],
  modules: [],
  importGuards: [],
};

export function loadLanes(root: string): LanesTruth {
  const path = truthPaths(root).lanes;
  let raw: string;
  try {
    raw = readFileSync(path, 'utf-8');
  } catch {
    return { ok: false, warning: `lanes.json not found at ${path} — lane verdicts unavailable`, ...EMPTY };
  }
  try {
    const data = JSON.parse(raw) as Partial<LanesTruth>;
    return {
      ok: true,
      governedRoots: data.governedRoots ?? [],
      modules: (data.modules ?? []) as LaneEntry[],
      importGuards: (data.importGuards ?? []) as ImportGuard[],
    };
  } catch (err) {
    const why = err instanceof Error ? err.message : String(err);
    return { ok: false, warning: `could not parse ${path}: ${why}`, ...EMPTY };
  }
}

/**
 * Longest-prefix match. A path under a governed root but matching no module
 * is still 'ungoverned' — the registry has a gap, and guessing 'production'
 * would hide it.
 */
export function laneFor(truth: LanesTruth, relPath: string): { lane: Lane; entry: LaneEntry | null; gap?: boolean } {
  const p = normalize(relPath);
  let best: LaneEntry | null = null;
  for (const m of truth.modules) {
    const prefix = normalize(m.path);
    const boundary = prefix.endsWith('/') ? prefix : prefix + '/';
    if (p === prefix || p.startsWith(boundary)) {
      if (!best || prefix.length > normalize(best.path).length) best = m;
    }
  }
  if (best) return { lane: best.lane, entry: best };

  // No module matched. If the path is nonetheless under a governed root,
  // that is a distinct outcome from being outside the repo's scope entirely
  // — a gap in lanes.json, not merely an ungoverned path.
  for (const root of truth.governedRoots) {
    const prefix = normalize(root);
    const boundary = prefix.endsWith('/') ? prefix : prefix + '/';
    if (p === prefix || p.startsWith(boundary)) {
      return { lane: 'ungoverned', entry: null, gap: true };
    }
  }

  return { lane: 'ungoverned', entry: null };
}

/**
 * May `importerPath` import `importedNamespace`? Files inside the guarded
 * namespace are exempt; everyone else must be on the grandfathered allowlist,
 * which only ever shrinks.
 */
export function importAllowed(
  truth: LanesTruth,
  importerPath: string,
  importedNamespace: string,
): { allowed: boolean; reason?: string } {
  const importer = normalize(importerPath);
  const ns = normalize(importedNamespace);
  const guard = truth.importGuards.find((g) => normalize(g.namespace) === ns);
  if (!guard) return { allowed: true };

  for (const exempt of guard.internalExempt) {
    if (importer.startsWith(normalize(exempt))) return { allowed: true, reason: 'inside the guarded namespace' };
  }
  const entry = guard.allow.find((a) => normalize(a.file) === importer);
  if (entry) return { allowed: true, reason: entry.reason };

  return { allowed: false };
}
