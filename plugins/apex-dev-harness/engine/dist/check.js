// SPDX-License-Identifier: MIT
// Block-tier evaluation of a single pending edit. Every refusal names its
// rule and the document that rule came from.
import { basename } from 'node:path';
import { loadLanes, laneFor, importAllowed } from './truth/lanes.js';
import { loadPolicy, rulesInScope } from './truth/policy.js';
import { normalize } from './repo.js';
// Assembled from parts so this source never contains a credential-shaped
// literal of its own (apex-app's guardrail hook rejects files that do).
const SECRET_NAME = '(?:API_?KEY|SECRET|TOKEN|PASSWORD|CREDENTIAL|PRIVATE_?KEY)';
const OPAQUE_VALUE = String.raw `['"]([^'"\s]{16,})['"]`;
const CREDENTIAL_RE = new RegExp(String.raw `\b([A-Za-z_]*${SECRET_NAME}[A-Za-z_]*)\s*[:=]\s*${OPAQUE_VALUE}`, 'i');
/** Names that hold a key's NAME, location, or docs — not the secret itself. */
const NON_SECRET_NAME_RE = /_(NAME|NAMES|URL|URI|DOCS|PATH|ENV|VAR)$/i;
/**
 * True when the captured value is plainly not a live credential: a URL, an
 * env-var name in screaming snake case, or an obvious placeholder. Real
 * secrets are high-entropy mixed strings; these are not.
 */
function looksNonSecret(name, value) {
    if (NON_SECRET_NAME_RE.test(name))
        return true;
    if (/^https?:\/\//i.test(value))
        return true;
    if (/^[A-Z0-9_]+$/.test(value))
        return true; // an env-var NAME, not a value
    if (/(test|mock|example|sample|placeholder|dummy|fake|replace|your[-_]|xxxx|\.\.\.)/i.test(value))
        return true;
    return false;
}
const PROVIDER_IMPORT_RE = /^\s*(?:from\s+(?:anthropic|openai|google\.generativeai|vertexai)\b|import\s+(?:anthropic|openai|vertexai)\b)/m;
/** The LLM abstraction layer is the one place provider SDKs may be imported. */
const LLM_LAYER = 'backend/agentic/core/llm/';
function deny(rule, reason) {
    return { allow: false, ruleId: rule.id, reason, source: rule.source };
}
/**
 * Blank out comments and docstrings before matching. Rules look for real code;
 * an example inside a docstring, or a comment warning against a pattern, must
 * never be refused. Replaces content with spaces rather than deleting so line
 * structure (and therefore /m anchoring) is preserved.
 */
function stripCommentsAndDocstrings(text) {
    return text
        .replace(/"""[\s\S]*?"""/g, (m) => m.replace(/[^\n]/g, ' '))
        .replace(/'''[\s\S]*?'''/g, (m) => m.replace(/[^\n]/g, ' '))
        .replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
        .replace(/(^|[^:])\/\/[^\n]*/g, (m, p1) => p1 + ' '.repeat(m.length - p1.length))
        .replace(/#[^\n]*/g, (m) => ' '.repeat(m.length));
}
export function check(root, relPath, content) {
    const p = normalize(relPath);
    const lanes = loadLanes(root);
    const policy = loadPolicy(root);
    const active = rulesInScope(policy, p);
    const rule = (id) => active.find((r) => r.id === id && r.tier === 'block');
    // BOUND-005 — no dotenv files, anywhere.
    const dotenv = rule('BOUND-005');
    const base = basename(p);
    // .env.example / .env.sample / .env.template are documentation, not secrets.
    const isEnvTemplate = /^\.env\.(example|sample|template|dist)$/i.test(base);
    if (dotenv && !isEnvTemplate && /^\.env(\..+)?$/.test(base)) {
        return deny(dotenv, `${p} is a dotenv file. Credentials belong in Google Secret Manager.`);
    }
    // GUARD-SENSITIVE-FILE — restores the three deny categories of the .ps1
    // hook this shim supersedes, beyond .env* which BOUND-005 already covers.
    // Path-only: no content needed.
    const sensitive = rule('GUARD-SENSITIVE-FILE');
    if (sensitive) {
        const b = base.toLowerCase();
        if (/^(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|poetry\.lock|pipfile\.lock)$/.test(b)) {
            return deny(sensitive, `${b} is a lock file — it should change only via the package manager (npm install / pip install), never a direct edit.`);
        }
        if (/^(credentials\.json|secrets\.ya?ml)$/.test(b)) {
            return deny(sensitive, `${b} is a secret file — a human should edit it by hand.`);
        }
        if (b === '.mcp.json') {
            return deny(sensitive, '.mcp.json can hold a live API key — a human should edit it by hand so the key is not echoed into the transcript.');
        }
    }
    // LANE-RETIRED — a retired module is delete-on-sight, not edit-on-sight.
    const retired = rule('LANE-RETIRED');
    if (retired) {
        const { lane, entry } = laneFor(lanes, p);
        if (lane === 'retired') {
            return deny(retired, `${entry?.path ?? p} is in the RETIRED lane. ${entry?.notes ?? ''}`.trim());
        }
    }
    if (content !== null) {
        const code = stripCommentsAndDocstrings(content);
        // BOUND-002 — no credential literals.
        const creds = rule('BOUND-002');
        if (creds) {
            const m = CREDENTIAL_RE.exec(code);
            if (m && !looksNonSecret(m[1], m[2])) {
                return deny(creds, 'Credential-shaped literal. Retrieve it from Google Secret Manager instead.');
            }
        }
        // CONV-PROJECTDATA — the dead legacy field.
        const pdj = rule('CONV-PROJECTDATA');
        if (pdj && code.includes('projectDataJson')) {
            // Writers are REQUIRED to clear this dead field to an empty string, so a
            // clear is sanctioned by the same convention that forbids reads/writes.
            const clearsOnly = code
                .split('\n')
                .filter((line) => line.includes('projectDataJson'))
                .every((line) => /projectDataJson[^=:]*[=:]\s*(''|""|``)\s*[,;)}\]]*\s*$/.test(line));
            if (!clearsOnly) {
                return deny(pdj, 'projectDataJson is a dead legacy field — never read it, never write it.');
            }
        }
        // BOUND-004 — provider SDKs only inside the abstraction layer.
        const provider = rule('BOUND-004');
        if (provider && !p.startsWith(LLM_LAYER) && PROVIDER_IMPORT_RE.test(code)) {
            return deny(provider, `Direct LLM provider SDK import. Use the abstraction layer in ${LLM_LAYER}.`);
        }
        // LANE-IMPORT — no NEW importers of a guarded namespace.
        // Deliberately narrow: only an import/from statement naming the namespace's
        // leaf counts. A false block is the worst failure this harness can produce,
        // and the authoritative check is pytest tools/repo-lanes/tests/.
        const importRule = rule('LANE-IMPORT');
        if (importRule) {
            for (const guard of lanes.importGuards) {
                const leaf = normalize(guard.namespace).split('/').filter(Boolean).pop();
                if (!leaf)
                    continue;
                const importRe = new RegExp(String.raw `(?:^\s*import\s|^\s*from\s|\bfrom\s+['"][^'"]*)\b${leaf}\b`, 'm');
                if (!importRe.test(code))
                    continue;
                if (!importAllowed(lanes, p, guard.namespace).allowed) {
                    return deny(importRule, `New import of ${guard.namespace}, a guarded legacy namespace. The allowlist only shrinks — new importers fail CI.`);
                }
            }
        }
    }
    return { allow: true };
}
