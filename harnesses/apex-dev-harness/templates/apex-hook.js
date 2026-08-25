#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// apex-dev-harness hook dispatcher. ONE file, invoked as:
//   node .claude/hooks/apex-hook.js <pre-tool-use|post-tool-use|session-start>
//
// OUTPUT PROTOCOL — do not change without reading this comment:
// ALWAYS print exactly one JSON object on stdout. `{}` allows; a deny object
// blocks. Claude Code accepts the bare exit-code protocol, but Cursor runs
// these same hooks and REQUIRES valid JSON — on 2026-07-04 an empty stdout
// made Cursor treat the hook as broken and block EVERY Edit/Write in the
// workspace. Fail open on every internal error: a harness bug must never
// wedge editing.

function emit(obj) {
  // Do NOT call process.exit() here. Node's stdout is asynchronous on Windows,
  // so exiting immediately after write() can truncate the output — and empty
  // stdout is precisely what bricked every edit in Cursor on 2026-07-04.
  // Setting exitCode lets Node flush and exit on its own.
  process.exitCode = 0;
  process.stdout.write(JSON.stringify(obj ?? {}) + '\n');
}

function deny(reason) {
  emit({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason,
    },
  });
}

async function readStdin() {
  const chunks = [];
  for await (const c of process.stdin) chunks.push(c);
  return Buffer.concat(chunks).toString('utf-8');
}

/**
 * Resolve the engine. Normally it is a dependency of the repo or installed
 * globally; APEX_ENGINE_DIST overrides for tests and local development.
 */
async function loadEngine(name) {
  const dist = process.env.APEX_ENGINE_DIST;
  if (dist) return import(new URL(`file://${dist.replace(/\\/g, '/')}/${name}`).href);
  return import(`apex-dev-harness/dist/${name}`);
}

/** Make an absolute or windows-style path repo-relative. */
function toRelative(root, filePath) {
  const p = String(filePath).replace(/\\/g, '/');
  const r = root.replace(/\\/g, '/').replace(/\/$/, '');
  // Case-insensitive compare: Windows may hand us a different drive-letter case
  // than findRepoRoot() returned, and a failed strip silently disables every rule.
  if (p.toLowerCase().startsWith(r.toLowerCase() + '/')) return p.slice(r.length + 1);
  return p;
}

async function main() {
  const phase = process.argv[2];

  let payload;
  try {
    payload = JSON.parse(await readStdin());
  } catch {
    return emit(); // unparseable stdin — not our business
  }

  const rawPath = payload?.tool_input?.file_path;
  if (!rawPath) return emit();

  const { findRepoRoot } = await loadEngine('repo.js');
  const root = findRepoRoot();
  if (!root) return emit();
  const rel = toRelative(root, rawPath);

  if (phase === 'pre-tool-use') {
    const { check } = await loadEngine('check.js');
    const content = payload.tool_input.content ?? payload.tool_input.new_string ?? null;
    const decision = check(root, rel, content);
    if (decision.allow) return emit();
    const src = decision.source ? ` (${decision.source})` : '';
    return deny(`[${decision.ruleId}]${src} ${decision.reason}`);
  }

  if (phase === 'post-tool-use') {
    // Advisory only — this phase must never block. Warnings go to stderr so
    // stdout stays a single clean JSON object, and stay quiet on the happy
    // path: a hook that prints on every edit trains people to ignore it.
    try {
      const { route } = await loadEngine('route.js');
      const v = route(root, rel);
      const inStudio = rel.split('/').includes('apexStudio');
      if (v.surface?.status === 'STUDIO' && !inStudio) {
        process.stderr.write(`[apex] ${v.surface.surface} is STUDIO-canonical — touching the legacy twin is a smell.\n`);
      }
    } catch { /* advisory only */ }
    return emit();
  }

  return emit(); // session-start and anything unknown
}

main().catch(() => {
  process.exitCode = 0;
  process.stdout.write('{}\n');
});
