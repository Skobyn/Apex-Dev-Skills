import type { CommandResult, GateVerdict } from './types.js';
export declare function runCommand(root: string, command: string): CommandResult;
export interface GateOptions {
    base?: string;
    message?: string;
    /** Override the diff (tests, and `--paths` on the CLI). */
    paths?: string[];
    runner?: (root: string, command: string) => CommandResult;
    /** Compute obligations, parity and watchlist WITHOUT running any command. */
    dryRun?: boolean;
}
export declare function gate(root: string, opts?: GateOptions): GateVerdict;
export declare function formatGate(v: GateVerdict): string;
