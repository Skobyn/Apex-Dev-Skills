// SPDX-License-Identifier: MIT
// Load .harness/policy.json — the only NEW truth the harness introduces.
// It holds policy (which rules bite, and where), never facts about the repo.
//
// DELTA MODEL (0.3.0): `apex init` writes a minimal overlay, not a full copy
// of the built-in policy. loadPolicy() MERGES the project overlay with the
// built-in on every read, so a rule or hint added to the engine later
// reaches an already-`init`-ed repo automatically. Per array-valued section:
//   - key omitted from the project file  -> inherit the built-in entries
//   - key present as []                  -> CLEARS the section (built-in and
//                                            project both empty — "[] means
//                                            none", preserved from 0.2.0)
//   - key present, non-empty             -> merge built-in + project by the
//                                            section's key (id/match),
//                                            project wins on collision
// watchlist merges as a de-duplicated (case-insensitive) union of strings
// under the same omitted/empty/non-empty rules.
//
// Explicit removal (as opposed to "this repo doesn't add anything here") is
// via the uniform `disabled` block: after merging, any rule whose `id` is
// listed under `disabled.rules`, or hint whose `match` is listed under
// `disabled.surfaceHints`, is dropped. Entries may be a bare string or an
// object carrying a `reason` — `doctor` warns on the bare-string form since
// an allowlist without reasons is unreviewable later.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type {
  DisabledBlock, DisabledHintEntry, DisabledRuleEntry, ExcludedFile,
  MwgTarget, ObligationDef, ParityRule, Policy, PolicyRule, SkillRule, SurfaceHint,
} from '../types.js';
import { normalize, truthPaths } from '../repo.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const BUNDLED = join(HERE, '..', '..', 'templates', 'policy.json');

function readBundled(): Omit<Policy, 'ok' | 'warning'> {
  const raw = JSON.parse(readFileSync(BUNDLED, 'utf-8'));
  return {
    version: raw.version,
    rules: raw.rules ?? [],
    obligations: raw.obligations ?? [],
    watchlist: raw.watchlist ?? [],
    mwgTargets: raw.mwgTargets ?? [],
    skillRules: raw.skillRules ?? [],
    parityRules: raw.parityRules ?? [],
    surfaceHints: raw.surfaceHints ?? [],
    excludedFiles: raw.excludedFiles ?? [],
    disabled: raw.disabled ?? { rules: [], surfaceHints: [] },
  };
}

/** The built-in policy, used when the project ships none. */
export const DEFAULT_POLICY: Policy = { ok: true, ...readBundled() };

/**
 * Merge a built-in array-valued section with a project overlay's section,
 * keyed by `keyOf`. `undefined` project section inherits the built-in
 * wholesale; an explicit empty array clears the section entirely (neither
 * built-in nor project entries survive); a non-empty array merges by key,
 * project winning on collision.
 */
function mergeSection<T>(builtin: T[], project: T[] | undefined, keyOf: (x: T) => string): T[] {
  if (project === undefined) return builtin;
  if (project.length === 0) return [];
  const byKey = new Map<string, T>();
  for (const b of builtin) byKey.set(keyOf(b), b);
  for (const p of project) byKey.set(keyOf(p), p);
  return [...byKey.values()];
}

function mergeWatchlist(builtin: string[], project: string[] | undefined): string[] {
  if (project === undefined) return builtin;
  if (project.length === 0) return [];
  const byLower = new Map<string, string>();
  for (const w of builtin) byLower.set(w.toLowerCase(), w);
  for (const w of project) byLower.set(w.toLowerCase(), w);
  return [...byLower.values()];
}

function disabledId(e: DisabledRuleEntry): string {
  return typeof e === 'string' ? e : e.id;
}
function disabledMatch(e: DisabledHintEntry): string {
  return typeof e === 'string' ? e : e.match;
}

function applyDisabled(policy: Omit<Policy, 'ok' | 'warning'>): Omit<Policy, 'ok' | 'warning'> {
  const disabledRuleIds = new Set(policy.disabled.rules.map(disabledId));
  const disabledHintMatches = new Set(policy.disabled.surfaceHints.map(disabledMatch));
  return {
    ...policy,
    rules: policy.rules.filter((r) => !disabledRuleIds.has(r.id)),
    surfaceHints: policy.surfaceHints.filter((h) => !disabledHintMatches.has(h.match)),
  };
}

export function loadPolicy(root: string): Policy {
  const path = truthPaths(root).policy;
  let raw: string;
  try {
    raw = readFileSync(path, 'utf-8');
  } catch {
    return { ...DEFAULT_POLICY, ok: true, warning: `no ${path} — using the harness's built-in policy` };
  }
  try {
    const parsed = JSON.parse(raw) as Partial<Policy>;
    const disabled: DisabledBlock = {
      rules: parsed.disabled?.rules ?? DEFAULT_POLICY.disabled.rules,
      surfaceHints: parsed.disabled?.surfaceHints ?? DEFAULT_POLICY.disabled.surfaceHints,
    };
    const merged: Omit<Policy, 'ok' | 'warning'> = {
      version: parsed.version ?? DEFAULT_POLICY.version,
      rules: mergeSection<PolicyRule>(DEFAULT_POLICY.rules, parsed.rules, (r) => r.id),
      obligations: mergeSection<ObligationDef>(DEFAULT_POLICY.obligations, parsed.obligations, (o) => o.id),
      watchlist: mergeWatchlist(DEFAULT_POLICY.watchlist, parsed.watchlist),
      mwgTargets: mergeSection<MwgTarget>(DEFAULT_POLICY.mwgTargets, parsed.mwgTargets, (m) => m.match),
      skillRules: mergeSection<SkillRule>(DEFAULT_POLICY.skillRules, parsed.skillRules, (s) => s.match),
      parityRules: mergeSection<ParityRule>(DEFAULT_POLICY.parityRules, parsed.parityRules, (p) => p.match),
      surfaceHints: mergeSection<SurfaceHint>(DEFAULT_POLICY.surfaceHints, parsed.surfaceHints, (h) => h.match),
      excludedFiles: mergeSection<ExcludedFile>(DEFAULT_POLICY.excludedFiles, parsed.excludedFiles, (e) => e.match),
      disabled,
    };
    return { ok: true, ...applyDisabled(merged) };
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
