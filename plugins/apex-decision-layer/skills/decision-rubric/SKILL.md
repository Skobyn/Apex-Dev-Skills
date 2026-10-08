---
name: decision-rubric
description: Write, review or version a decision-layer rubric (rubrics/<id>@<v>.json) — the questions apex-decide asks a backend, their labels, the state allowlist, uncertainty thresholds, hard rules and the data-handling clause. Use when adding a rubric for a new consumer, when `apex-decide lint` fails, or when a rubric's wording or labels need to change.
allowed-tools: Bash Read Grep Glob Edit Write
---

# decision-rubric — write a rubric the validator and the measurement job can trust

A rubric is data, not code. Its path is its id (`rubrics/dispatch/task-class@1.json` is `dispatch/task-class@1`), and anything that reaches the wire is fixed per version: changing it means a new version with its own calibration. `apex-decide lint` enforces the rules below and prints the rubric's `question_hash`.

## The authoring rules

1. **Name the condition, not the conclusion.** "Changes code that handles authentication", not "is risky".
2. **No counting words** ("more than", "several", "many", "a few", "at least"). Numbers are computed in code and passed as state fields (`changed_lines`).
3. **Score levels are concrete situations**, 2–10 of them, never degrees ("adds a column with a default and no backfill", not "moderate").
4. **Every choice question has a `none` label** for "the record does not say".
5. **State fields are observed records** with their original names. Never another model's label; a code-computed field such as `risk_tier` is fine.
6. **Untrusted text is declared**: every free-text field is typed `untrusted-text` and listed in `state.egress_raw`. It reaches a backend only when the repository sets `state_fields: raw`, and always wrapped.
7. **`data_handling` is required** and is appended to every question.

## Shape

`rubric_id`, `version`, `primary` (the question the envelope's top level reports), `backend_models` (per backend; `jev` is a per-transport map because TypeSafe and OpenRouter accept disjoint ids), `model_pin` (`record` or `strict`), `state` (`allow` with types `str|bool|int|list[str]|untrusted-text`, `max_bytes`, `egress_raw`), `hard_rules` (answered by code before any backend call, reported as unscored `hard_rule`), `questions` (`type` noul|choice|score, `instructions` {question, focus, ignore, caution}, `criteria`, `uncertain` thresholds), `combine: primary`, `gate_for`, `data_handling`.

Thresholds and model ids are not part of `question_hash`; a locked calibration record overrides the rubric's thresholds for its backend.

## Checklist before committing a rubric

- `apex-decide lint` passes and the hash is new (or unchanged on purpose).
- A consumer actually calls it; reserved ids without a consumer stay without a file.
- `bash plugins/apex-decision-layer/scripts/smoke.sh` passes.
