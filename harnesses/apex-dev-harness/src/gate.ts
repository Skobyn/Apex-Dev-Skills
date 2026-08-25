// SPDX-License-Identifier: MIT
// The done-gate. A phase closes when its obligations pass, not when someone
// says the work is finished.

import { execSync } from 'node:child_process';
import type { CommandResult, GateVerdict } from './types.js';
import { loadPolicy } from './truth/policy.js';
import { changedPaths, obligationsFor, parityWarningsFor } from './obligations.js';
import { scanWatchlist } from './watchlist.js';

export function runCommand(root: string, command: string): CommandResult {
  try {
    const output = execSync(command, {
      cwd: root,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 10 * 60 * 1000,
    });
    return { command, ok: true, output };
  } catch (err) {
    const e = err as { stdout?: string; stderr?: string; message?: string };
    return { command, ok: false, output: (e.stdout ?? '') + (e.stderr ?? '') || (e.message ?? 'failed') };
  }
}

export interface GateOptions {
  base?: string;
  message?: string;
  /** Override the diff (tests, and `--paths` on the CLI). */
  paths?: string[];
  runner?: (root: string, command: string) => CommandResult;
  /** Compute obligations, parity and watchlist WITHOUT running any command. */
  dryRun?: boolean;
}

export function gate(root: string, opts: GateOptions = {}): GateVerdict {
  const policy = loadPolicy(root);
  const runner = opts.runner ?? runCommand;
  const warnings: string[] = [];
  if (policy.warning) warnings.push(policy.warning);

  const paths = opts.paths ?? changedPaths(root, opts.base ?? 'HEAD');
  if (paths.length === 0) warnings.push('no changed files detected — the gate ran against an empty diff');

  const obligations = obligationsFor(policy, paths);
  const results: CommandResult[] = [];
  // A dry run answers "what would this owe?" without side effects — the
  // question a status check asks. Never execute here.
  if (!opts.dryRun) {
    for (const o of obligations) for (const c of o.commands) results.push(runner(root, c));
  }

  const parityWarnings = parityWarningsFor(policy, paths);
  const watchlistHits = opts.message ? scanWatchlist(policy, opts.message) : [];

  const ok = results.every((r) => r.ok) && watchlistHits.length === 0;
  return { obligations, results, parityWarnings, watchlistHits, warnings, ok, dryRun: opts.dryRun === true };
}

/** Say precisely what is unmet: failed checks and watchlist hits are different things. */
function summarizeUnmet(failed: number, hits: number): string {
  const parts: string[] = [];
  if (failed > 0) parts.push(`${failed} check${failed === 1 ? '' : 's'} failed`);
  if (hits > 0) parts.push(`${hits} watchlist hit${hits === 1 ? '' : 's'}`);
  return parts.join(', ');
}

export function formatGate(v: GateVerdict): string {
  const lines: string[] = [];

  // Walk results in the order gate() pushed them: obligation by obligation,
  // command by command. Grouping matters — a flat failure list leaves the
  // reader unable to tell which obligation each command belongs to.
  let i = 0;
  for (const o of v.obligations) {
    lines.push(`${o.reason} -> ${o.id}`);
    for (const _c of o.commands) {
      const r = v.results[i++];
      if (!r) continue;
      lines.push(`  ${r.ok ? 'PASS' : 'FAILED'}  ${r.command}`);
    }
  }
  // Any results beyond the obligations' commands (defensive; should not occur).
  for (; i < v.results.length; i++) {
    const r = v.results[i]!;
    lines.push(`  ${r.ok ? 'PASS' : 'FAILED'}  ${r.command}`);
  }

  for (const p of v.parityWarnings) lines.push(`parity      ${p} — verify, or state why it diverges.`);
  for (const h of v.watchlistHits) lines.push(`watchlist   "${h.term}" (line ${h.line}) — BOUND-006`);
  for (const w of v.warnings) lines.push(`warn        ${w}`);

  const failed = v.results.filter((r) => !r.ok).length;
  const hits = v.watchlistHits.length;
  if (v.dryRun) {
    const owed = v.obligations.length;
    lines.push(`VERDICT     DRY RUN — ${owed} obligation${owed === 1 ? '' : 's'} owed, nothing executed`);
    return lines.join('\n');
  }
  lines.push(v.ok ? 'VERDICT     DONE — every obligation met' : `VERDICT     NOT DONE — ${summarizeUnmet(failed, hits)}`);
  return lines.join('\n');
}
