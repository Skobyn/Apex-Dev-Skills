export declare const HOOK_VERSION_MARKER = "apex-dev-harness-hook-version:";
export declare function scaffold(root: string, opts?: {
    force?: boolean;
}): {
    lines: string[];
    written: string[];
    skipped: string[];
};
