// SPDX-License-Identifier: MIT
// Parse .claude/tasks/apex-studio-surface-ledger.md — the per-surface answer
// to "where does new work go?".

import { readFileSync } from 'node:fs';
import type { LedgerTruth, SurfaceRow, SurfaceStatus } from '../types.js';
import { normalize, truthPaths } from '../repo.js';

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
  // Honor escaped pipes: a surface name may legitimately contain "\|".
  // Use a control character as the placeholder — never plain space — so we
  // don't clobber legitimate spaces when restoring the escaped pipe.
  const PLACEHOLDER = '';
  return line.trim().replace(/\\\|/g, PLACEHOLDER)
    .replace(/^\|/, '').replace(/\|$/, '')
    .split('|')
    .map((c) => c.split(PLACEHOLDER).join('|').trim());
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
  let unparsed = 0;

  for (const line of raw.split('\n')) {
    if (line.startsWith('## ')) {
      section = line.slice(3).trim();
      continue;
    }
    if (!line.startsWith('|')) continue;

    const cells = splitRow(line);
    if (cells.length > 0 && /^[-: ]+$/.test(cells[0]!)) continue;   // separator row
    if (cells.length > 0 && /^(surface|status)$/i.test(cells[0]!)) continue; // header row

    // The status-vocabulary table defines the vocabulary; it is not a surface.
    // Skip it by SECTION, not by name — a real surface may legitimately be
    // called "Studio", and dropping it silently would be a third outcome
    // alongside no-row and unparseable.
    if (/vocabulary/i.test(section)) continue;

    if (cells.length < 3) {
      if (STATUS_RE.test(line)) unparsed += 1;
      continue;
    }

    const statusCell = cells[2]!;
    const m = STATUS_RE.exec(statusCell);
    if (!m) {
      // A row that carries a status token somewhere but failed our column
      // assumptions is a PARSER gap, not a missing ledger row. Count it so
      // it can be surfaced as a warning instead of silently reporting as
      // no-row later ("the ledger has a bug" would be the wrong message —
      // this is our bug).
      if (STATUS_RE.test(line)) unparsed += 1;
      continue;
    }

    const surface = cells[0]!.replace(/\*\*/g, '').trim();

    const routes = extractRoutes(cells[1]!);
    if (routes.length === 0) withoutRoutes += 1;

    rows.push({ section, surface, routes, status: m[1] as SurfaceStatus, notes: cells[3] ?? '' });
  }

  const warning = unparsed > 0
    ? `${unparsed} ledger row(s) carry a status but could not be parsed — those surfaces will report no-row incorrectly. The parser needs updating, not the ledger.`
    : undefined;

  return { ok: true, warning, rows, rowsWithoutRoutes: withoutRoutes };
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
