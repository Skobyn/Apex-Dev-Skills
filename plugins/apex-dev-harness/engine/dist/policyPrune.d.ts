export interface PruneResult {
    ok: boolean;
    lines: string[];
    changed: boolean;
}
export declare function prunePolicy(root: string): PruneResult;
