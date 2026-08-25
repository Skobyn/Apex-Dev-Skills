// SPDX-License-Identifier: MIT
// Compose lanes + ledger + policy into the answer to "what applies here?".

import type { RouteVerdict, SurfaceStatus } from './types.js';
import { loadLanes, laneFor } from './truth/lanes.js';
import { loadLedger, surfaceFor } from './truth/ledger.js';
import { loadPolicy } from './truth/policy.js';
import { matchesGlob } from './glob.js';
import { normalize } from './repo.js';

/** The ledger's own routing sentences, keyed by status. */
const ROUTING: Record<SurfaceStatus, string> = {
  STUDIO: 'Build in Studio. Touching the legacy twin is a smell.',
  DUAL: 'New features go to the Studio side (unless a named parity gap blocks). Fixes go wherever the bug lives. Behavior changes must keep both sides consistent (surface-parity rule).',
  LEGACY: 'Build in the legacy surface, guilt-free. If the ask is big, raise "is this the moment to port the domain?" first.',
  OOS: 'Different audience, not a deferred port. Never a Studio TODO.',
  RETIRED: "Route redirects or the surface is dead. Don't touch.",
};

export function route(root: string, query: string): RouteVerdict {
  const lanes = loadLanes(root);
  const ledger = loadLedger(root);
  const policy = loadPolicy(root);

  const warnings: string[] = [];
  for (const t of [lanes, ledger, policy]) if (t.warning) warnings.push(t.warning);

  const q = normalize(query);
  const { lane, entry } = laneFor(lanes, q);
  let surface = surfaceFor(ledger, q);
  if (!surface) {
    // The ledger keys on ROUTE paths and contains no source-file paths, so a
    // file query cannot match one directly. surfaceHints is a curated
    // file-glob -> surface-NAME map; an unmatched file still reports no-row,
    // and a hint naming a surface the ledger lacks also still reports no-row.
    // Curated data, never a guess.
    let bestHint: string | null = null;
    let bestLen = -1;
    for (const hint of policy.surfaceHints) {
      if (matchesGlob(hint.match, q) && hint.match.length > bestLen) {
        bestHint = hint.surface;
        bestLen = hint.match.length;
      }
    }
    if (bestHint) surface = surfaceFor(ledger, bestHint);
  }

  const mwg = policy.mwgTargets.find((m) => matchesGlob(m.match, q))?.target ?? null;

  const skills: string[] = [];
  for (const rule of policy.skillRules) {
    if (matchesGlob(rule.match, q)) for (const s of rule.skills) if (!skills.includes(s)) skills.push(s);
  }

  const parity: string[] = [];
  for (const rule of policy.parityRules) {
    if (matchesGlob(rule.match, q)) for (const s of rule.surfaces) if (!parity.includes(s)) parity.push(s);
  }

  // Which guarded namespaces does this file already have permission to import?
  // Only the grandfathered note is emitted: route() has no file content, so it
  // cannot know whether an import exists, and a blanket "this is guarded" note
  // on every path would be pure noise. The content-aware LANE-IMPORT check
  // refuses new imports.
  const importNotes: string[] = [];
  for (const guard of lanes.importGuards) {
    const hit = guard.allow.find((a) => normalize(a.file) === q);
    if (hit) {
      importNotes.push(
        `${guard.namespace} is LEGACY — this file is a grandfathered importer (${hit.reason}) Do not add new imports.`,
      );
    }
  }

  return {
    query,
    lane,
    laneEntry: entry,
    surface,
    surfaceVerdict: surface ? 'row' : 'no-row',
    routing: surface ? ROUTING[surface.status] : null,
    mwg,
    skills,
    parity,
    importNotes,
    warnings,
  };
}

function pad(label: string): string {
  return (label + '           ').slice(0, 11);
}

export function formatRoute(v: RouteVerdict): string {
  const lines: string[] = [];
  const laneNote = v.laneEntry?.notes ? ` — ${v.laneEntry.notes}` : '';
  lines.push(`${pad('lane')}${v.lane.toUpperCase()}${laneNote}`);
  if (v.laneEntry?.replacement) lines.push(`${pad('replacement')}${v.laneEntry.replacement}`);

  if (v.surface) {
    lines.push(`${pad('surface')}${v.surface.surface}  ·  ${v.surface.status}   [${v.surface.section}]`);
    lines.push(`${pad('routing')}${v.routing}`);
  } else {
    lines.push(`${pad('surface')}no row — the ledger has a bug; add the row, don't guess`);
  }

  if (v.mwg) lines.push(`${pad('mwg')}${v.mwg}`);
  if (v.skills.length) lines.push(`${pad('skills')}${v.skills.join(', ')}`);
  if (v.parity.length) lines.push(`${pad('parity')}${v.parity.join(' · ')}`);
  for (const n of v.importNotes) lines.push(`${pad('imports')}${n}`);
  for (const w of v.warnings) lines.push(`${pad('warn')}${w}`);
  return lines.join('\n');
}
