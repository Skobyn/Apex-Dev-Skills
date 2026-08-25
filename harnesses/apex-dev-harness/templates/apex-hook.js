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
//
// post-tool-use is the one phase allowed to set a non-zero exit code (2,
// for genuine capability-manifest staleness — see below) so the failure
// text re-enters the agent loop. Even then stdout MUST still be exactly
// `{}`: never call process.exit() (Node's stdout is asynchronous on
// Windows and an immediate exit can truncate it — empty stdout is exactly
// what bricked every edit in Cursor on 2026-07-04), and never let emit()
// clobber an exit code a caller already set.

import { execSync } from 'node:child_process';

function emit(obj, exitCode = 0) {
  // Setting exitCode (never calling process.exit()) lets Node flush stdout
  // and exit on its own once the event loop drains.
  process.exitCode = exitCode;
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
  // Bundled layout: <root>/engine/{templates/apex-hook.js,dist/*}. Resolving
  // from import.meta.url works on every platform and needs no env var, so a
  // plugin-installed copy is self-sufficient.
  try {
    return await import(new URL(`../dist/${name}`, import.meta.url).href);
  } catch (err) {
    // Only fall back when the sibling engine genuinely isn't there (the manual,
    // non-bundled layout). If it EXISTS but threw while evaluating, that is a
    // real bug: let it propagate to main().catch() and fail open with {}, rather
    // than silently resolving a different — possibly older — installed engine
    // whose confident answers would be wrong.
    if (err?.code !== 'ERR_MODULE_NOT_FOUND') throw err;
    return import(`apex-dev-harness/dist/${name}`);
  }
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

/**
 * Run `cmd` quietly, returning combined stdout+stderr text on failure or
 * null on success. Exported so it can be unit-tested directly: execSync's
 * thrown error carries stdout/stderr as Buffers, and an EMPTY Buffer is
 * truthy — `e.stdout || e.stderr` therefore always picks empty stdout over
 * a real stderr-only failure and silently discards it. The
 * capability-manifest checker writes ONLY to stderr, so that form made its
 * diagnostics (and the staleness signal this hook blocks on) unreachable.
 * Concatenate, never choose.
 */
export function runQuiet(cmd, cwd) {
  try {
    execSync(cmd, { cwd, stdio: ['ignore', 'pipe', 'pipe'], timeout: 10000 });
    return null;
  } catch (e) {
    const both = (String(e?.stdout ?? '') + String(e?.stderr ?? '')).trim();
    return both || String(e?.message || 'failed').trim();
  }
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
    const ti = payload.tool_input;
    const content = ti.content
      ?? ti.new_string
      ?? (Array.isArray(ti.edits) ? ti.edits.map((e) => e?.new_string ?? '').join('\n') : null);
    const decision = check(root, rel, content);
    if (decision.allow) return emit();
    const src = decision.source ? ` (${decision.source})` : '';
    return deny(`[${decision.ruleId}]${src} ${decision.reason}`);
  }

  if (phase === 'post-tool-use') {
    // Mostly advisory (stderr only, exit 0) — EXCEPT genuine
    // capability-manifest staleness, which blocks (exit 2) so the reason
    // re-enters the agent loop, restoring what the superseded
    // studio-manifest-check.ps1 did. Everything else here must never block.
    let exitCode = 0;
    try {
      const [{ route }, { loadPolicy }, { matchesGlob }] = await Promise.all([
        loadEngine('route.js'), loadEngine('truth/policy.js'), loadEngine('glob.js'),
      ]);
      const v = route(root, rel);
      const inStudio = rel.split('/').includes('apexStudio');

      // A hint can mark itself `canonical: true` — this file IS the
      // canonical implementation of that surface, so the legacy-twin
      // advisory must not fire for it regardless of path. The path check
      // (apexStudio) stays the default for files with no matching hint.
      let canonicalHint = false;
      try {
        const policy = loadPolicy(root);
        let bestLen = -1;
        for (const hint of policy.surfaceHints ?? []) {
          if (matchesGlob(hint.match, rel) && hint.match.length > bestLen) {
            canonicalHint = !!hint.canonical;
            bestLen = hint.match.length;
          }
        }
      } catch { /* a policy load failure must not suppress or crash this */ }

      if (v.surface?.status === 'STUDIO' && !inStudio && !canonicalHint) {
        process.stderr.write(`[apex] ${v.surface.surface} is STUDIO-canonical — touching the legacy twin is a smell.\n`);
      }

      // Mirror the .ps1 hooks this shim supersedes: they ran the UI style
      // generator check and the capability-manifest freshness check after an
      // edit. Keep well under the host's per-hook timeout (60s in Claude
      // Code) — these checks cost ~30ms and ~3s.
      const run = (cmd) => runQuiet(cmd, root);
      // Env overrides let tests substitute a fixture command without
      // needing a real python/backend checkout — the real commands are the
      // default in production.
      const styleCmd = process.env.APEX_STYLE_CHECK_CMD || 'node ui/scripts/check-style-generators.js';
      const manifestCmd = process.env.APEX_MANIFEST_CHECK_CMD || 'cd backend && python -m scripts.gen_studio_capability_manifest --check';
      if (/^ui\/src\/.*\.(js|jsx|css)$/.test(rel)) {
        const out = run(styleCmd);
        if (out) process.stderr.write(`[apex] style-generator check failed:\n${out.slice(0, 2000)}\n`);
      }
      const CAPABILITY_SURFACES = [
        'backend/app/routes/studio_chat.py',
        'backend/agentic/core/mutations/registry.py',
        'backend/app/routes/studio_rest_write_exceptions.py',
        'ui/src/apexStudio/views/registry.js',
        'ui/src/apexStudio/rail/navDirective.js',
      ];
      if (CAPABILITY_SURFACES.includes(rel) || rel.startsWith('backend/app/routes/studio_adapters/')) {
        const out = run(manifestCmd);
        if (out) {
          const couldNotRun = /not found|No module named|command not found|ENOENT/i.test(out);
          if (couldNotRun) {
            // Could-not-run is NOT evidence of staleness — stays advisory.
            process.stderr.write(`[apex] could not run the capability-manifest check (not a staleness result):\n${out.slice(0, 500)}\n`);
          } else {
            process.stderr.write(`[apex] capability manifest is STALE — regenerate it before you call this done.\n${out.slice(0, 2000)}\n`);
            exitCode = 2;
          }
        }
      }
    } catch { /* on internal error, fail open (exit 0) — never block on our own bug */ }
    return emit(undefined, exitCode);
  }

  return emit(); // session-start and anything unknown
}

// Only run main() when this file is the process entry point — importing it
// (e.g. from a test, to reach `runQuiet`) must not block on stdin.
const isMain = (() => {
  if (!process.argv[1]) return false;
  try { return new URL(import.meta.url).pathname === process.argv[1].replace(/\\/g, '/'); }
  catch { return false; }
})();

if (isMain) {
  main().catch(() => {
    process.exitCode = 0;
    process.stdout.write('{}\n');
  });
}
