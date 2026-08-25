export type Lane = 'production' | 'legacy' | 'experimental' | 'retired' | 'ungoverned';
export interface LaneEntry {
    path: string;
    lane: Exclude<Lane, 'ungoverned'>;
    owner?: string;
    replacement?: string;
    canonicalDoc?: string;
    since?: string;
    notes?: string;
}
export interface ImportGuardAllow {
    file: string;
    reason: string;
}
export interface ImportGuard {
    id: string;
    namespace: string;
    language: string;
    internalExempt: string[];
    allow: ImportGuardAllow[];
}
export interface LanesTruth {
    ok: boolean;
    /** Present when the file was missing or unparseable. Never throws. */
    warning?: string;
    governedRoots: string[];
    modules: LaneEntry[];
    importGuards: ImportGuard[];
}
export type SurfaceStatus = 'STUDIO' | 'DUAL' | 'LEGACY' | 'OOS' | 'RETIRED';
export interface SurfaceRow {
    section: string;
    surface: string;
    routes: string[];
    status: SurfaceStatus;
    notes: string;
}
export interface LedgerTruth {
    ok: boolean;
    warning?: string;
    rows: SurfaceRow[];
    /** Rows naming a surface with no parseable route pattern. */
    rowsWithoutRoutes: number;
}
export type RuleTier = 'block' | 'warn' | 'historical';
export interface PolicyRule {
    id: string;
    tier: RuleTier;
    /** 'repo' or a path prefix such as 'backend/agentic/'. */
    scope: string;
    /** Named check implemented in check.ts. Absent for historical rules. */
    check?: string;
    source?: string;
    note?: string;
}
export interface ObligationDef {
    id: string;
    when: {
        anyPathMatches: string[];
    };
    run: string[];
    reason: string;
}
export interface MwgTarget {
    match: string;
    target: string;
}
export interface SkillRule {
    match: string;
    skills: string[];
}
export interface ParityRule {
    match: string;
    surfaces: string[];
}
export interface SurfaceHint {
    /** File glob, e.g. 'ui/src/marketing/**'. */
    match: string;
    /** EXACT surface name as it appears in the ledger's Surface column. */
    surface: string;
}
export interface Policy {
    ok: boolean;
    warning?: string;
    version: number;
    rules: PolicyRule[];
    obligations: ObligationDef[];
    watchlist: string[];
    mwgTargets: MwgTarget[];
    skillRules: SkillRule[];
    parityRules: ParityRule[];
    surfaceHints: SurfaceHint[];
}
export interface RouteVerdict {
    query: string;
    lane: Lane;
    laneEntry: LaneEntry | null;
    surface: SurfaceRow | null;
    /** 'row' when the ledger has an entry; 'no-row' when it does not. */
    surfaceVerdict: 'row' | 'no-row';
    routing: string | null;
    mwg: string | null;
    skills: string[];
    parity: string[];
    importNotes: string[];
    /** Truth-file problems. Non-empty means a reduced verdict. */
    warnings: string[];
    /** True when the path is under a governedRoots entry but matched no module — a gap in lanes.json. */
    laneGap: boolean;
}
export type CheckDecision = {
    allow: true;
} | {
    allow: false;
    ruleId: string;
    reason: string;
    source?: string;
};
export interface WatchlistHit {
    term: string;
    line: number;
    excerpt: string;
}
export interface Obligation {
    id: string;
    reason: string;
    commands: string[];
}
export interface CommandResult {
    command: string;
    ok: boolean;
    output: string;
}
export interface GateVerdict {
    obligations: Obligation[];
    results: CommandResult[];
    parityWarnings: string[];
    watchlistHits: WatchlistHit[];
    warnings: string[];
    ok: boolean;
    /** True when obligations were computed but deliberately not executed. */
    dryRun: boolean;
}
