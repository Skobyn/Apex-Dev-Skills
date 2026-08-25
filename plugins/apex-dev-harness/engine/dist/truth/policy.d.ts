import type { Policy, PolicyRule } from '../types.js';
/** The built-in policy, used when the project ships none. */
export declare const DEFAULT_POLICY: Policy;
export declare function loadPolicy(root: string): Policy;
/**
 * The enforceable rules that apply to a path. `historical` rules are recorded
 * in the policy for provenance and are never returned here.
 */
export declare function rulesInScope(policy: Policy, relPath: string): PolicyRule[];
