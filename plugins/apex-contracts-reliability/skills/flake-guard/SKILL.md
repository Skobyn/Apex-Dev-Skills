---
name: flake-guard
description: Use when an agent run is unreliable — tool calls that fail then succeed on retry, partial tool failures, or the same call passing one moment and failing the next. Reads the captured tool-call ledger to surface a reliability report (flaky tool, failure rate, retry runs, success-then-failure flip-flops) so non-deterministic failures stop being invisible.
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
---

# FlakeGuard (F2)

Non-deterministic failures are the worst kind: a run fails, you re-run it, it
passes, and you conclude "must have been a fluke." It wasn't. A tool is flaky —
it times out under load, an MCP server drops a connection, a rate limit trips
intermittently — and that flakiness compounds across an autonomous loop into
wasted iterations and untrustworthy results.

FlakeGuard makes that behavior **visible and measurable** from the same JSONL
ledger that `capture-tool-io.sh` writes (see the **tool-contract-check** skill
for ledger location and capture mechanics).

## What FlakeGuard detects

For each tool, the analyzer computes from the recorded PreToolUse / PostToolUse
records:

| Signal | Meaning | How it's derived |
|---|---|---|
| **failure rate** | fraction of calls that returned an error | PostToolUse records with `ok:false` ÷ total |
| **retry runs** | the agent re-issued the *same* call shape back-to-back | ≥2 consecutive PreToolUse calls with identical input shape |
| **flip-flops** | the *same* call shape both succeeded and failed | a shape seen with both `ok:true` and `ok:false` |

A tool is flagged **FLAKY** when its failure rate is strictly between 0 and 1
(it neither always works nor always fails), **or** it shows any retry runs, **or**
any flip-flops. A tool that fails 100% of the time is *broken*, not flaky — that
shows as `stable` with a 1.0 rate so you don't confuse the two.

## Reading the reliability report

Render it via the command or directly:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analyze-ledger.sh" reliability
# machine-readable:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analyze-ledger.sh" reliability --json
```

The table has one row per tool:

```
tool                              calls  fails   rate  retry  flip  status
--------------------------------------------------------------------------
mcp__example__fetch                  12      3  0.250      2     1  FLAKY
Bash                                 40      0  0.000      0     0  stable
```

Triage the `FLAKY` rows:

1. **High failure rate + flip-flops** → the tool's success is environment- or
   timing-dependent. Add a bounded retry-with-backoff around it, or treat its
   output as best-effort rather than authoritative.
2. **Retry runs but low failure rate** → the agent is re-issuing identical calls
   (often waiting on eventual consistency). Consider an explicit wait/poll step
   instead of blind retries, which burn tokens and time.
3. **Failure rate 1.0 (shown `stable`)** → not flaky, just down. Fix or remove
   the tool; FlakeGuard is not the right lens here.

## When to use this skill

- An autonomous `/loop` makes uneven progress across iterations and you suspect
  a tool, not the plan, is the culprit.
- A test or acceptance step "sometimes" passes and you want evidence of which
  tool is non-deterministic before you spend hours bisecting.
- Before promoting a workflow to run unattended — confirm its tool surface is
  stable enough to trust without a human watching.

## What this skill is NOT

It does not detect *shape* changes in tool contracts — that's the
**tool-contract-check** skill (F1). FlakeGuard is purely about
**non-deterministic success/failure** of tool calls. It also does not retry
calls for you; it diagnoses, you decide the remediation.

## Tip: gate a loop on reliability

`analyze-ledger.sh` exits `3` when flakiness (or drift) is detected and `0` when
clean, so you can fail an acceptance check or pause a loop when a tool goes
non-deterministic:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analyze-ledger.sh" reliability || echo "tools went flaky — halting"
```
