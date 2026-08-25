import type { Lane, LaneEntry, LanesTruth } from '../types.js';
export declare function loadLanes(root: string): LanesTruth;
/**
 * Longest-prefix match. A path under a governed root but matching no module
 * is still 'ungoverned' — the registry has a gap, and guessing 'production'
 * would hide it.
 */
export declare function laneFor(truth: LanesTruth, relPath: string): {
    lane: Lane;
    entry: LaneEntry | null;
    gap?: boolean;
};
/**
 * May `importerPath` import `importedNamespace`? Files inside the guarded
 * namespace are exempt; everyone else must be on the grandfathered allowlist,
 * which only ever shrinks.
 */
export declare function importAllowed(truth: LanesTruth, importerPath: string, importedNamespace: string): {
    allowed: boolean;
    reason?: string;
};
