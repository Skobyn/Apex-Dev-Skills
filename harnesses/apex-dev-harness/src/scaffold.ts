// SPDX-License-Identifier: MIT
// `apex init` — install the hook shim and the policy into apex-app.

import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const TEMPLATES = join(HERE, '..', 'templates');
const PACKAGE_JSON = join(HERE, '..', 'package.json');

// The hook is a COPY in the consuming repo, so `npm i` cannot update it.
// Stamp the engine version as we write so `doctor` can detect a stale copy —
// injected here rather than hardcoded in the template, which would drift from
// package.json on every release.
export const HOOK_VERSION_MARKER = 'apex-dev-harness-hook-version:';

function engineVersion(): string {
  return JSON.parse(readFileSync(PACKAGE_JSON, 'utf-8')).version;
}

// Read the hook template and inject the version marker as the second line,
// immediately after the shebang, producing:
//   #!/usr/bin/env node
//   // apex-dev-harness-hook-version: 0.3.1
function stampedHook(): string {
  const template = readFileSync(join(TEMPLATES, 'apex-hook.js'), 'utf-8');
  const lines = template.split('\n');
  if (lines[0] !== '#!/usr/bin/env node') {
    throw new Error('templates/apex-hook.js does not start with the expected shebang');
  }
  const stamp = `// ${HOOK_VERSION_MARKER} ${engineVersion()}`;
  return [lines[0], stamp, ...lines.slice(1)].join('\n');
}

const FILES: Array<[string, string]> = [
  ['apex-hook.js', join('.claude', 'hooks', 'apex-hook.js')],
  // `init` writes a minimal DELTA overlay, not a full copy of the built-in
  // policy: loadPolicy() merges the two at read time, so any rule or hint
  // added to the engine later reaches this repo automatically. A repo that
  // still has the old full-copy snapshot should run `apex policy prune`.
  ['policy-overlay.json', join('.harness', 'policy.json')],
  // Node resolves a file's module type from the nearest package.json. Scoping
  // "type": "module" to .claude/hooks/ silences MODULE_TYPELESS_PACKAGE_JSON
  // on every hook run without touching the consuming repo's root
  // package.json, which may drive CommonJS code elsewhere (e.g. backend/express).
  ['hooks-package.json', join('.claude', 'hooks', 'package.json')],
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

export function scaffold(root: string, opts: { force?: boolean } = {}) {
  const written: string[] = [];
  const skipped: string[] = [];
  const lines: string[] = [`installing apex-dev-harness into ${root}`, ''];

  for (const [src, rel] of FILES) {
    const dest = join(root, rel);
    if (existsSync(dest) && !opts.force) {
      skipped.push(rel);
      lines.push(`  skip   ${rel} (exists — pass --force to overwrite)`);
      continue;
    }
    mkdirSync(dirname(dest), { recursive: true });
    if (src === 'apex-hook.js') {
      // The hook is written, not copied: we stamp the engine version into
      // it as we go (see HOOK_VERSION_MARKER above), so `copyFileSync`
      // won't do here.
      writeFileSync(dest, stampedHook());
    } else {
      copyFileSync(join(TEMPLATES, src), dest);
    }
    written.push(rel);
    lines.push(`  write  ${rel}`);
  }

  lines.push('', `${written.length} written, ${skipped.length} skipped`, SETTINGS_SNIPPET);
  return { lines, written, skipped };
}
