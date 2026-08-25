// SPDX-License-Identifier: MIT
// Parse .claude/tasks/apex-studio-surface-ledger.md — the per-surface answer
// to "where does new work go?".

import { readFileSync } from 'node:fs';
import type { LedgerTruth, SurfaceRow, SurfaceStatus } from '../types.js';
import { normalize, truthPaths } from '../repo.js';

const STATUSES: SurfaceStatus[] = ['STUDIO', 'DUAL', 'LEGACY', 'OOS', 'RETIRED'];
const STATUS_RE = /\*\*(STUDIO|DUAL|LEGACY|OOS|RETIRED)\*\*/;

/** Pull route patterns out of a Routes cell: backticked tokens and bare /paths. */
function extractRoutes(cell: string): string[] {
  const out = new Set<string>();
  for (const m of cell.matchAll(/`([^`]+)`/g)) {
    for (const piece of m[1]!.split(/[,\s]+/)) {
      const t = piece.trim().replace(/[.,;]+$/, '');
      if (t.startsWith('/')) out.add(t);
    }
  }
  for (const m of cell.matchAll(/(^|[\s,(])(\/[A-Za-z0-9:_\-*/{}]+)/g)) {
    out.add(m[2]!.replace(/[.,;]+$/, ''));
  }
  return [...out];
}

function splitRow(line: string): string[] {
  return line.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((c) => c.trim());
}

export function loadLedger(root: string): LedgerTruth {
  const path = truthPaths(root).ledger;
  let raw: string;
  try {
    raw = readFileSync(path, 'utf-8');
  } catch {
    return { ok: false, warning: `surface ledger not found at ${path} — surface routing unavailable`, rows: [], rowsWithoutRoutes: 0 };
  }

  const rows: SurfaceRow[] = [];
  let section = '';
  let withoutRoutes = 0;

  for (const line of raw.split('\n')) {
    if (line.startsWith('## ')) {
      section = line.slice(3).trim();
      continue;
    }
    if (!line.startsWith('|')) continue;

    const cells = splitRow(line);
    if (cells.length < 4) continue;
    if (/^[-: ]+$/.test(cells[0]!)) continue;                    // separator row
    if (/^(surface|status)$/i.test(cells[0]!)) continue;         // header row

    const statusCell = cells[2]!;
    const m = STATUS_RE.exec(statusCell);
    if (!m) continue;

    // The status-vocabulary table's first cell IS the status name — skip it.
    const surface = cells[0]!.replace(/\*\*/g, '').trim();
    if (STATUSES.includes(surface.toUpperCase() as SurfaceStatus)) continue;

    const routes = extractRoutes(cells[1]!);
    if (routes.length === 0) withoutRoutes += 1;

    rows.push({ section, surface, routes, status: m[1] as SurfaceStatus, notes: cells[3] ?? '' });
  }

  return { ok: true, rows, rowsWithoutRoutes: withoutRoutes };
}

/**
 * Find the row for a route or a surface name. Longest route match wins.
 * Returns null when nothing matches — the caller renders that as `no-row`
 * ("the ledger has a bug; add the row, don't guess"), never as a guess.
 */
export function surfaceFor(truth: LedgerTruth, query: string): SurfaceRow | null {
  const q = normalize(query);

  let best: SurfaceRow | null = null;
  let bestLen = -1;
  for (const row of truth.rows) {
    for (const route of row.routes) {
      const r = normalize(route);
      if (q === r || (r !== '/' && q.startsWith(r.endsWith('/') ? r : r + '/'))) {
        if (r.length > bestLen) { best = row; bestLen = r.length; }
      }
    }
  }
  if (best) return best;

  const lower = q.toLowerCase();
  return truth.rows.find((r) => r.surface.toLowerCase() === lower) ?? null;
}
