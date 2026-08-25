// SPDX-License-Identifier: MIT
// Block-tier evaluation of a single pending edit. Every refusal names its
// rule and the document that rule came from.

import { basename } from 'node:path';
import type { CheckDecision, PolicyRule } from './types.js';
import { loadLanes, laneFor, importAllowed } from './truth/lanes.js';
import { loadPolicy, rulesInScope } from './truth/policy.js';
import { normalize } from './repo.js';

// Assembled from parts so this source never contains a credential-shaped
// literal of its own (apex-app's guardrail hook rejects files that do).
const SECRET_NAME = '(?:API_?KEY|SECRET|TOKEN|PASSWORD|CREDENTIAL|PRIVATE_?KEY)';
const OPAQUE_VALUE = String.raw`['"][^'"\s]{16,}['"]`;
const CREDENTIAL_RE = new RegExp(
  String.raw`\b[A-Za-z_]*${SECRET_NAME}[A-Za-z_]*\s*[:=]\s*${OPAQUE_VALUE}`,
  'i',
);

const PROVIDER_IMPORT_RE =
  /^\s*(?:from\s+(?:anthropic|openai|google\.generativeai|vertexai)\b|import\s+(?:anthropic|openai|vertexai)\b)/m;

/** The LLM abstraction layer is the one place provider SDKs may be imported. */
const LLM_LAYER = 'backend/agentic/core/llm/';

function deny(rule: PolicyRule, reason: string): CheckDecision {
  return { allow: false, ruleId: rule.id, reason, source: rule.source };
}

export function check(root: string, relPath: string, content: string | null): CheckDecision {
  const p = normalize(relPath);
  const lanes = loadLanes(root);
  const policy = loadPolicy(root);
  const active = rulesInScope(policy, p);
  const rule = (id: string) => active.find((r) => r.id === id && r.tier === 'block');

  // BOUND-005 — no dotenv files, anywhere.
  const dotenv = rule('BOUND-005');
  if (dotenv && /^\.env(\..+)?$/.test(basename(p))) {
    return deny(dotenv, `${p} is a dotenv file. Credentials belong in Google Secret Manager.`);
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
    // BOUND-002 — no credential literals.
    const creds = rule('BOUND-002');
    if (creds && CREDENTIAL_RE.test(content)) {
      return deny(creds, 'Credential-shaped literal. Retrieve it from Google Secret Manager instead.');
    }

    // CONV-PROJECTDATA — the dead legacy field.
    const pdj = rule('CONV-PROJECTDATA');
    if (pdj && content.includes('projectDataJson')) {
      return deny(pdj, 'projectDataJson is a dead legacy field — never read it, never write it.');
    }

    // BOUND-004 — provider SDKs only inside the abstraction layer.
    const provider = rule('BOUND-004');
    if (provider && !p.startsWith(LLM_LAYER) && PROVIDER_IMPORT_RE.test(content)) {
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
        if (!leaf) continue;
        const importRe = new RegExp(
          String.raw`(?:^\s*import\s|^\s*from\s|\bfrom\s+['"][^'"]*)\b${leaf}\b`,
          'm',
        );
        if (!importRe.test(content)) continue;
        if (!importAllowed(lanes, p, guard.namespace).allowed) {
          return deny(
            importRule,
            `New import of ${guard.namespace}, a guarded legacy namespace. The allowlist only shrinks — new importers fail CI.`,
          );
        }
      }
    }
  }

  return { allow: true };
}
