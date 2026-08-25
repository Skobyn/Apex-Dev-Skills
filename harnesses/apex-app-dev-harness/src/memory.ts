// SPDX-License-Identifier: MIT
/**
 * Pattern store for the harness.
 *
 * HONEST SCOPE: this is a local append-only JSONL store with token-overlap
 * ranking, not a vector database. The kernel ships decay ranking
 * (`rankWithDecay`) but no embedding store, so nothing here pretends to do
 * semantic search. Recency decay is applied on top of lexical overlap so
 * newer patterns win ties.
 */

import { appendFile, readFile, mkdir } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { rankWithDecay, type MemoryHit } from '@metaharness/kernel/memory';
import { projectHarnessDir } from './paths.js';

export interface MemoryEntry {
  id: string;
  text: string;
  tags: string[];
  storedAt: number;
}

export interface SearchResult extends MemoryEntry {
  score: number;
  decayedScore: number;
}

/** Two weeks: a pattern half as relevant after a fortnight untouched. */
const DEFAULT_HALF_LIFE_MS = 14 * 24 * 60 * 60 * 1000;

export function memoryPath(): string {
  return process.env.HARNESS_MEMORY_PATH ?? join(projectHarnessDir(), 'memory.jsonl');
}

function tokenize(s: string): string[] {
  return s
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((t) => t.length > 1);
}

/** Jaccard-style overlap of query tokens present in the entry, 0..1. */
function overlap(queryTokens: string[], entryTokens: string[]): number {
  if (queryTokens.length === 0) return 0;
  const entrySet = new Set(entryTokens);
  let hits = 0;
  for (const t of new Set(queryTokens)) if (entrySet.has(t)) hits += 1;
  return hits / new Set(queryTokens).size;
}

export async function store(text: string, tags: string[] = []): Promise<MemoryEntry> {
  const entry: MemoryEntry = {
    id: `mem_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`,
    text,
    tags,
    storedAt: Date.now(),
  };
  const path = memoryPath();
  await mkdir(dirname(path), { recursive: true });
  await appendFile(path, JSON.stringify(entry) + '\n', 'utf-8');
  return entry;
}

export async function load(): Promise<MemoryEntry[]> {
  try {
    const raw = await readFile(memoryPath(), 'utf-8');
    return raw
      .split('\n')
      .filter((l) => l.trim())
      .flatMap((line) => {
        try {
          return [JSON.parse(line) as MemoryEntry];
        } catch {
          return []; // a corrupt line never takes the whole store down
        }
      });
  } catch {
    return [];
  }
}

export async function search(query: string, limit = 5): Promise<SearchResult[]> {
  const entries = await load();
  const queryTokens = tokenize(query);
  const scored = entries
    .map((e) => ({ entry: e, score: overlap(queryTokens, tokenize(`${e.text} ${e.tags.join(' ')}`)) }))
    .filter((s) => s.score > 0);

  const hits: MemoryHit[] = scored.map((s) => ({
    id: s.entry.id,
    score: s.score,
    decayedScore: s.score,
    namespace: 'apex-app-harness',
    storedAt: s.entry.storedAt,
  }));

  const ranked = await rankWithDecay(hits, { useDecay: true, halfLifeMs: DEFAULT_HALF_LIFE_MS });
  const byId = new Map(scored.map((s) => [s.entry.id, s.entry]));

  return ranked
    .slice(0, limit)
    .map((h) => ({ ...byId.get(h.id)!, score: h.score, decayedScore: h.decayedScore }));
}
