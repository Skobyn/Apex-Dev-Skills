// SPDX-License-Identifier: MIT
// `apex init` — install the hook shim and the policy into apex-app.
import { copyFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const HERE = dirname(fileURLToPath(import.meta.url));
const TEMPLATES = join(HERE, '..', 'templates');
const FILES = [
    ['apex-hook.js', join('.claude', 'hooks', 'apex-hook.js')],
    ['policy.json', join('.harness', 'policy.json')],
];
const SETTINGS_SNIPPET = `
Apply these entries to .claude/settings.json (they replace the .ps1/.cmd pairs):

  "PreToolUse":  [{ "matcher": "Edit|Write|MultiEdit",
                    "hooks": [{ "type": "command", "command": "node .claude/hooks/apex-hook.js pre-tool-use" }] }],
  "PostToolUse": [{ "matcher": "Edit|Write|MultiEdit",
                    "hooks": [{ "type": "command", "command": "node .claude/hooks/apex-hook.js post-tool-use" }] }],
  "SessionStart":[{ "matcher": "",
                    "hooks": [{ "type": "command", "command": "node .claude/hooks/apex-hook.js session-start" }] }]
`;
export function scaffold(root, opts = {}) {
    const written = [];
    const skipped = [];
    const lines = [`installing apex-dev-harness into ${root}`, ''];
    for (const [src, rel] of FILES) {
        const dest = join(root, rel);
        if (existsSync(dest) && !opts.force) {
            skipped.push(rel);
            lines.push(`  skip   ${rel} (exists — pass --force to overwrite)`);
            continue;
        }
        mkdirSync(dirname(dest), { recursive: true });
        copyFileSync(join(TEMPLATES, src), dest);
        written.push(rel);
        lines.push(`  write  ${rel}`);
    }
    lines.push('', `${written.length} written, ${skipped.length} skipped`, SETTINGS_SNIPPET);
    return { lines, written, skipped };
}
