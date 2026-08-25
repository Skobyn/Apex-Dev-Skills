/**
 * Walk up from `start` looking for the lanes registry. Returns null rather
 * than throwing — callers degrade to a reduced verdict.
 * `APEX_REPO_ROOT` overrides discovery entirely (tests, CI, monorepo hosts).
 */
export declare function findRepoRoot(start?: string): string | null;
export interface TruthPaths {
    lanes: string;
    ledger: string;
    policy: string;
}
export declare function truthPaths(root: string): TruthPaths;
/** Normalize a path for matching: forward slashes, no leading './'. */
export declare function normalize(p: string): string;
