// SPDX-License-Identifier: MIT
// The BOUND-006 vocabulary watchlist. A hit is not a violation — it is a
// prompt to verify the work underneath is sound.
function escape(term) {
    return term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
export function scanWatchlist(policy, text) {
    const hits = [];
    const lines = text.split('\n');
    for (const term of policy.watchlist) {
        const re = new RegExp(`\\b${escape(term)}\\b`, 'i');
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i];
            if (!re.test(line))
                continue;
            hits.push({ term, line: i + 1, excerpt: line.trim().slice(0, 120) });
            break; // one report per term keeps the output readable
        }
    }
    return hits;
}
