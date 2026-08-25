// SPDX-License-Identifier: MIT
// Minimal glob matching. Deliberately not a dependency: the patterns we need
// are `**`, `*`, and literals, and a tiny implementation we can test beats a
// package whose semantics we would have to look up.
import { normalize } from './repo.js';
/** Escape everything regex-special except the wildcards we implement. */
function toRegex(pattern) {
    let out = '';
    for (let i = 0; i < pattern.length; i++) {
        const c = pattern[i];
        if (c === '*') {
            if (pattern[i + 1] === '*') {
                // `**/` should also match zero directories, so a/**/b.js matches a/b.js
                if (pattern[i + 2] === '/') {
                    out += '(?:.*/)?';
                    i += 2;
                }
                else {
                    out += '.*';
                    i += 1;
                }
            }
            else {
                out += '[^/]*';
            }
            continue;
        }
        out += c.replace(/[.+?^${}()|[\]\\]/g, '\\$&');
    }
    return new RegExp(`^${out}$`);
}
export function matchesGlob(pattern, path) {
    return toRegex(normalize(pattern)).test(normalize(path));
}
