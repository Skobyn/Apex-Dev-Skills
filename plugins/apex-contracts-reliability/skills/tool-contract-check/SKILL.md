---
name: tool-contract-check
description: Use when a tool or MCP call starts behaving differently than before — new or missing fields, changed types — or when reviewing the captured tool-call ledger for CONTRACT DRIFT. Explains how to read the drift report produced from the PostToolUse ledger and how to act on a flagged divergence.
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
---

# Tool Contract Check (F1)

This skill helps you review **tool-contract drift**: the situation where a tool
or MCP server's call shape silently changes underneath an agent. A field is
added, a field disappears, or a value flips type (string → object). Nothing
errors — the agent just starts getting data it wasn't built to read, or sending
input the tool no longer accepts. These failures are quiet and expensive.

## How the contract is captured

The plugin's `capture-tool-io.sh` hook is bound to **PreToolUse and PostToolUse
for every tool** (`"*"`). On each call it appends a record to a JSONL ledger at:

```
${CLAUDE_PROJECT_DIR:-$PWD}/.claude/contracts-reliability/ledger.jsonl
```

Each record stores the *shape* of the tool input (and, on PostToolUse, the
output) — a field-name → JSON-type map, one level deep. Shapes, not raw values,
so the ledger never hoards secrets or large payloads.

## How a schema is inferred

There is no schema file to maintain. For each tool, the **first** observed input
shape becomes the *established schema*. Every later call is compared against it.
A call is flagged as **CONTRACT DRIFT** when, relative to that baseline, it has:

- `+` a **new field** the schema never had,
- `-` a **missing field** the schema requires, or
- `~` a **field whose type changed** (e.g. `string` → `object`).

This is deliberately lightweight — it catches the shape regressions that cause
real agent breakage without demanding hand-written JSON Schema per tool.

## Reviewing the drift report

Run the analyzer in drift mode:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analyze-ledger.sh" drift
# machine-readable:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analyze-ledger.sh" drift --json
```

Read it like this:

1. **Scan for `[DRIFT]` rows.** `[ok]` tools matched their schema on every call.
2. **For each drift event**, the report names the call index, timestamp, and the
   exact divergence (`+ new field 'X'`, `- missing field 'Y'`, `~ field 'Z'
   type a -> b`).
3. **Decide whether the drift is benign or a break:**
   - *New optional field?* Usually benign — the upstream tool grew a capability.
     Note it; no action needed unless your prompt/parsing assumed a fixed shape.
   - *Missing required field?* A break. The tool/MCP server changed its contract;
     downstream parsing will fail or read `None`. Pin the tool version or update
     the consumer.
   - *Type change?* Almost always a break. Trace which call introduced it
     (the call index points you at the offending invocation) and fix the caller
     or the server.

## When to use this skill

- An MCP server was upgraded and an agent that worked yesterday misbehaves today.
- You're hardening a workflow before shipping and want to confirm no tool's
  contract has quietly shifted across a session.
- A teammate reports "the tool returns weird data now" — the drift report tells
  you *which field* and *which call* changed, instead of guessing.

## What this skill is NOT

It is not a unit-test or lint runner, and it does not validate your source code.
It validates **tool-call contracts at runtime** from observed traffic. If you
want to detect intermittent / non-deterministic *failures* (retries, flaky
tools) rather than *shape* changes, use the companion **flake-guard** skill.

## Resetting the baseline

The first call defines the schema, so if you intentionally changed a tool's
contract and want the new shape to become the baseline, clear the ledger:

```bash
rm -f "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/contracts-reliability/ledger.jsonl"
```

The next call re-establishes the schema. Consider adding that path to
`.gitignore` so per-developer ledgers don't get committed.
