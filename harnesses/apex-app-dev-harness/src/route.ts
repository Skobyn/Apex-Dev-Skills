// SPDX-License-Identifier: MIT
/**
 * 3-tier routing.
 *
 * HONEST SCOPE: a deterministic keyword + size heuristic over the three tiers
 * named in the harness manifest — not a learned router. It is transparent on
 * purpose: every decision reports the signals that produced it, so a wrong
 * tier is a one-line fix rather than a retraining run.
 */

import { readHarnessJson } from './paths.js';

export type Tier = 'barbarian' | 'scholar' | 'sage';

export interface RouteDecision {
  tier: Tier;
  model: string | null;
  confidence: number;
  signals: string[];
}

const TIER_ORDER: Tier[] = ['barbarian', 'scholar', 'sage'];

/** Cheap/fast tier: mechanical, well-specified edits. */
const BARBARIAN_SIGNALS = [
  'typo', 'rename', 'format', 'lint', 'bump', 'comment', 'changelog',
  'import', 'whitespace', 'docstring', 'boilerplate', 'stub',
];

/** Top tier: work where being wrong is expensive. */
const SAGE_SIGNALS = [
  'architect', 'architecture', 'design', 'migrate', 'migration', 'security',
  'concurrency', 'race', 'deadlock', 'refactor', 'redesign', 'protocol',
  'cryptograph', 'performance', 'schema', 'breaking change', 'trade-off',
];

interface Models {
  models?: Partial<Record<Tier, string>>;
}

export function modelFor(tier: Tier): string | null {
  const manifest = readHarnessJson<Models>('manifest.json', {});
  return manifest.models?.[tier] ?? null;
}

export function route(task: string): RouteDecision {
  const text = task.toLowerCase();
  const signals: string[] = [];

  const sageHits = SAGE_SIGNALS.filter((k) => text.includes(k));
  const barbHits = BARBARIAN_SIGNALS.filter((k) => text.includes(k));

  let index = 1; // scholar — the default middle tier
  signals.push('default:scholar');

  if (sageHits.length > 0) {
    index = 2;
    signals.push(...sageHits.map((h) => `sage:${h}`));
  } else if (barbHits.length > 0) {
    index = 0;
    signals.push(...barbHits.map((h) => `barbarian:${h}`));
  }

  // A long, detail-heavy task description escalates one tier: more stated
  // constraints means more ways to get it wrong.
  const words = text.split(/\s+/).filter(Boolean).length;
  if (words > 60 && index < 2) {
    index += 1;
    signals.push(`length:${words}w`);
  }

  const tier = TIER_ORDER[index]!;
  const matched = sageHits.length + barbHits.length;
  const confidence = matched === 0 ? 0.4 : Math.min(0.9, 0.55 + 0.15 * matched);

  return { tier, model: modelFor(tier), confidence, signals };
}
