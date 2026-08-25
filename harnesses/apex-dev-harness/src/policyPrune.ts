// SPDX-License-Identifier: MIT
// `apex policy prune` — migration for repos that already ran the old
// snapshot-writing `apex init`. Drops any project-policy entry that is
// byte-identical (compared as sorted-key JSON) to the corresponding
// built-in entry, since it contributes nothing and only freezes the repo
// out of future engine updates. Never touches genuinely divergent entries.

import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { DEFAULT_POLICY } from './truth/policy.js';
import { truthPaths } from './repo.js';

/** Stable stringify: sorted keys, so key order never causes a false divergence. */
function canon(v: unknown): string {
  return JSON.stringify(v, (_k, val) => {
    if (val && typeof val === 'object' && !Array.isArray(val)) {
      return Object.fromEntries(Object.keys(val).sort().map((k) => [k, (val as Record<string, unknown>)[k]]));
    }
    return val;
  });
}

const SECTIONS: Array<{ name: string; keyOf: (x: any) => string }> = [
  { name: 'rules', keyOf: (r) => r.id },
  { name: 'obligations', keyOf: (o) => o.id },
  { name: 'mwgTargets', keyOf: (m) => m.match },
  { name: 'skillRules', keyOf: (s) => s.match },
  { name: 'parityRules', keyOf: (p) => p.match },
  { name: 'surfaceHints', keyOf: (h) => h.match },
  { name: 'excludedFiles', keyOf: (e) => e.match },
];

export interface PruneResult {
  ok: boolean;
  lines: string[];
  changed: boolean;
}

export function prunePolicy(root: string): PruneResult {
  const path = truthPaths(root).policy;
  const lines: string[] = [];

  if (!existsSync(path)) {
    lines.push(`no ${path} — nothing to prune (the built-in policy applies as-is)`);
    return { ok: true, lines, changed: false };
  }

  let parsed: any;
  try {
    parsed = JSON.parse(readFileSync(path, 'utf-8'));
  } catch (err) {
    const why = err instanceof Error ? err.message : String(err);
    lines.push(`could not parse ${path}: ${why} — nothing pruned`);
    return { ok: false, lines, changed: false };
  }

  const builtinById: Record<string, Map<string, unknown>> = {};
  for (const s of SECTIONS) {
    const m = new Map<string, unknown>();
    for (const entry of (DEFAULT_POLICY as any)[s.name] as unknown[]) m.set(s.keyOf(entry), entry);
    builtinById[s.name] = m;
  }

  let totalEntries = 0;
  let removedEntries = 0;
  const removedBySection: Record<string, string[]> = {};
  const keptBySection: Record<string, string[]> = {};
  const out: any = { ...parsed };

  for (const s of SECTIONS) {
    const arr: unknown[] | undefined = parsed[s.name];
    if (!Array.isArray(arr)) continue; // omitted section — nothing to prune
    const kept: unknown[] = [];
    const removed: string[] = [];
    for (const entry of arr) {
      totalEntries++;
      const key = s.keyOf(entry);
      const builtinEntry = builtinById[s.name].get(key);
      if (builtinEntry !== undefined && canon(builtinEntry) === canon(entry)) {
        removed.push(key);
        removedEntries++;
      } else {
        kept.push(entry);
      }
    }
    if (removed.length) removedBySection[s.name] = removed;
    if (kept.length) keptBySection[s.name] = kept.map((e) => s.keyOf(e));
    out[s.name] = kept;
  }

  // watchlist: string union — drop any string that is exactly present in the
  // built-in watchlist (case-sensitive: the built-in list is canonical casing).
  if (Array.isArray(parsed.watchlist)) {
    totalEntries += parsed.watchlist.length;
    const builtinSet = new Set(DEFAULT_POLICY.watchlist);
    const removed = parsed.watchlist.filter((w: string) => builtinSet.has(w));
    const kept = parsed.watchlist.filter((w: string) => !builtinSet.has(w));
    if (removed.length) { removedBySection.watchlist = removed; removedEntries += removed.length; }
    if (kept.length) keptBySection.watchlist = kept;
    out.watchlist = kept;
  }

  const changed = removedEntries > 0;

  lines.push(`.harness/policy.json: ${totalEntries} local entries checked`);
  if (removedEntries === 0) {
    lines.push('no entries are verbatim built-in — nothing to prune');
  } else {
    lines.push(`removed ${removedEntries} entr${removedEntries === 1 ? 'y' : 'ies'} identical to the built-in policy:`);
    for (const [section, keys] of Object.entries(removedBySection)) {
      lines.push(`  ${section}: ${keys.join(', ')}`);
    }
  }
  const keptCount = Object.values(keptBySection).reduce((n, ks) => n + ks.length, 0);
  if (keptCount > 0) {
    lines.push(`kept ${keptCount} genuinely divergent entr${keptCount === 1 ? 'y' : 'ies'}:`);
    for (const [section, keys] of Object.entries(keptBySection)) {
      lines.push(`  ${section}: ${keys.join(', ')}`);
    }
  } else if (removedEntries > 0) {
    lines.push('no local entries remain — this file is now a pure delta overlay (the correct outcome for a pure snapshot)');
  }

  if (changed) {
    // Preserve version, _readme, disabled, and every field prune doesn't
    // touch (already carried through via the `...parsed` spread above).
    writeFileSync(path, JSON.stringify(out, null, 2) + '\n');
    lines.push(`wrote ${path}`);
  } else {
    lines.push('nothing changed — file not rewritten');
  }

  return { ok: true, lines, changed };
}
