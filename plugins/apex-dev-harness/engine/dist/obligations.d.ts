import type { Obligation, Policy } from './types.js';
/** The changed files in the working tree, unstaged and staged, relative to `base`. */
export declare function changedPaths(root: string, base?: string): string[];
export declare function obligationsFor(policy: Policy, paths: string[]): Obligation[];
export declare function parityWarningsFor(policy: Policy, paths: string[]): string[];
