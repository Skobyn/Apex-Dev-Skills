import type { LedgerTruth, SurfaceRow } from '../types.js';
export declare function loadLedger(root: string): LedgerTruth;
/**
 * Find the row for a route or a surface name. Longest route match wins.
 * Returns null when nothing matches — the caller renders that as `no-row`
 * ("the ledger has a bug; add the row, don't guess"), never as a guess.
 */
export declare function surfaceFor(truth: LedgerTruth, query: string): SurfaceRow | null;
