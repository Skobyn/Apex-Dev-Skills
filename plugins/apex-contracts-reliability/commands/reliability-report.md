---
name: reliability-report
description: Render the FlakeGuard reliability report (and optionally the contract-drift report) from the captured tool-call ledger. Pass "drift" to see contract drift instead, or "all" for both. Defaults to the reliability report.
allowed-tools:
  - Bash
  - Read
---

# /apex-contracts-reliability:reliability-report

Render a report from the tool-call ledger that `capture-tool-io.sh` has been
accumulating this session.

`$ARGUMENTS` selects the mode:

- *(empty)* or `reliability` → FlakeGuard reliability report (flaky tools,
  failure rate, retry runs, flip-flops).
- `drift` → ToolContractCheck drift report (per-tool inferred schema + any shape
  divergences).
- `all` → both reports, drift first.

## Steps

1. Resolve the analyzer path: `${CLAUDE_PLUGIN_ROOT}/scripts/analyze-ledger.sh`.
2. Based on `$ARGUMENTS`, run the analyzer:

   ```bash
   # reliability (default)
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/analyze-ledger.sh" reliability

   # drift
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/analyze-ledger.sh" drift

   # all
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/analyze-ledger.sh" drift
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/analyze-ledger.sh" reliability
   ```

   The analyzer exits `0` when the report is clean, `3` when drift or flakiness
   is detected, and `2` on a usage error or missing python3.

3. Present the table verbatim, then summarize for the user:
   - Name any tool marked **FLAKY** or **[DRIFT]** and the headline metric
     (failure rate, retry runs, or the specific field that changed).
   - If everything is clean, say so plainly and note how many tools were observed.
   - If the ledger doesn't exist yet, explain that no tool calls have been
     captured — the capture hook records calls as the session runs, so invoke a
     few tools first, then re-run this command.

4. For deeper interpretation and remediation guidance, point the user at the
   `flake-guard` skill (reliability) or the `tool-contract-check` skill (drift).

## Notes

- This command is read-only: it never blocks or retries tool calls; it only
  reports on what the hook already recorded.
- To reset the inferred schemas / clear history, delete the ledger at
  `${CLAUDE_PROJECT_DIR:-$PWD}/.claude/contracts-reliability/ledger.jsonl`.
