# MemoryDoctor findings — <project>

- **Date:** <YYYY-MM-DD>
- **Scanned root:** `<path>`
- **Corpus:** `<path or n/a>`
- **Live store checked:** <yes via MCP / no — repo-only>

## Summary

| Severity | Count |
|---|---|
| Blocker | <n> |
| High | <n> |
| Medium | <n> |
| Low | <n> |

One-paragraph verdict: is retrieval *meaningless* (drift), *degraded* (chunking/staleness), or *unmeasured* (no recall gate)?

## Findings (prioritized)

For each finding:

### [SEVERITY] <short title> — class: <drift | chunking | staleness | recall | missing-control>

- **Evidence:** `<file:line>` or `<artifact>` (or "needs live store to confirm")
- **Why it matters:** <lifecycle impact — what fails downstream>
- **Remediation:** <concrete, ordered steps>

## Recommended next action

- [ ] If drift: pin one embedder + dimension, reindex, re-run audit.
- [ ] If recall unmeasured: build-golden.sh -> commit -> measure-recall.sh to set a baseline.
- [ ] If staleness: add a reindex trigger; re-run with corpus dir to confirm.
- [ ] If live findings pending: configure the optional MCP server and re-run.
