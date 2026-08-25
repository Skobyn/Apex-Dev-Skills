// SPDX-License-Identifier: MIT
// Derive which JSX components in ui/src/App.js are mounted EXCLUSIVELY under
// the `/portal` parent Route, versus mounted elsewhere (or in both places).
// Used only by the invariant test suite against the live consuming repo —
// not shipped as part of the published engine.
//
// Approach: parse <Route ...> tags with a brace-depth-aware scanner (JSX
// attribute expressions like `element={cond ? <A/> : <B/>}` can contain
// arbitrary nested braces and `>` characters, so a naive regex over lines
// is not reliable). Each Route tag is classified as self-closing (`/>`,
// leaf) or open (`>`, has nested <Route> children — used by the /portal
// parent and by the contest-admin nested routes). A stack tracks whether we
// are currently inside the /portal parent's children while walking the tree.
// For every Route tag, JSX component identifiers referenced inside its
// `element={...}` attribute are recorded as "mounted at this location".

import { readFileSync } from 'node:fs';

/**
 * Parse `content` (the text of App.js) and return
 * { portalOnly: Set<string>, portalMounted: Set<string>, elsewhereMounted: Set<string> }
 * of JSX component identifiers.
 */
export function derivePortalMounts(content) {
  const portalMounted = new Set();
  const elsewhereMounted = new Set();

  // Stack of booleans: true if the enclosing open Route tag is the /portal parent
  // (or nested inside it). Starts empty (top-level, "elsewhere").
  const stack = [];
  const inPortal = () => stack.length > 0 && stack[stack.length - 1];

  let i = 0;
  const n = content.length;
  while (i < n) {
    const tagStart = content.indexOf('<Route', i);
    const closeStart = content.indexOf('</Route>', i);

    if (tagStart === -1 && closeStart === -1) break;

    if (closeStart !== -1 && (tagStart === -1 || closeStart < tagStart)) {
      // Closing tag: pop the stack.
      stack.pop();
      i = closeStart + '</Route>'.length;
      continue;
    }

    // Parse the <Route ...> tag starting at tagStart.
    let j = tagStart + '<Route'.length;
    let braceDepth = 0;
    let elementAttr = '';
    let capturingElement = false;
    let selfClosing = false;
    let pathAttr = '';
    let capturingPath = false;

    while (j < n) {
      const ch = content[j];

      // Detect the start of the path="..." attribute (for diagnostics only).
      if (!capturingElement && braceDepth === 0 && content.startsWith('path=', j)) {
        capturingPath = true;
      }
      if (capturingPath && braceDepth === 0) {
        pathAttr += ch;
      }

      if (braceDepth === 0 && content.startsWith('element=', j)) {
        capturingElement = true;
      }

      if (ch === '{') {
        if (capturingElement && braceDepth === 0) {
          // start of the element={ ... } expression body
        }
        braceDepth++;
        if (capturingElement) elementAttr += ch;
        j++;
        continue;
      }
      if (ch === '}') {
        braceDepth--;
        if (capturingElement) {
          elementAttr += ch;
          if (braceDepth === 0) capturingElement = false;
        }
        j++;
        continue;
      }
      if (capturingElement) { elementAttr += ch; j++; continue; }

      if (braceDepth === 0) {
        if (content.startsWith('/>', j)) { selfClosing = true; j += 2; break; }
        if (ch === '>') { j += 1; break; }
      }
      j++;
    }

    // Extract component identifiers referenced in the element attribute.
    const comps = [...elementAttr.matchAll(/<([A-Z][A-Za-z0-9]*)/g)].map((m) => m[1]);
    const target = inPortal() ? portalMounted : elsewhereMounted;
    for (const c of comps) target.add(c);

    if (!selfClosing) {
      // This Route has children (a parent block). Determine if IT is the
      // portal parent (path === "/portal"), or already-inside-portal (any
      // nested parent Route beneath it), or an unrelated parent (e.g. the
      // contests admin nested routes) — those children are "elsewhere".
      const isPortalRoot = /path=["']\/portal["']/.test(pathAttr);
      stack.push(isPortalRoot || inPortal());
    }

    i = j;
  }

  const portalOnly = new Set([...portalMounted].filter((c) => !elsewhereMounted.has(c)));
  return { portalOnly, portalMounted, elsewhereMounted };
}

export function derivePortalMountsFromFile(appJsPath) {
  return derivePortalMounts(readFileSync(appJsPath, 'utf-8'));
}
