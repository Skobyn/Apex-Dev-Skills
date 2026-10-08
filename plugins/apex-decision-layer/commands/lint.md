---
name: lint
description: Lint decision-layer rubric files against the authoring rules (condition not conclusion, no counting words, a none label, untrusted fields declared, data-handling clause) and print each rubric's question_hash. Pass rubric file paths as $ARGUMENTS, or nothing to lint every shipped rubric.
argument-hint: "[rubric.json ...]"
---

Run `${CLAUDE_PLUGIN_ROOT}/bin/apex-decide lint $ARGUMENTS` and print its output verbatim.

- `LINT OK <id> <question_hash>`: the rubric passes. The hash changes whenever anything that reaches the wire changes, which invalidates every calibration record for that rubric version: say so if the user is editing a rubric that has calibration records.
- `LINT FAIL <id>: <problem>`: explain the rule it breaks using the `decision-rubric` skill, and propose a fix. A change to wording, labels, criteria, the state allowlist or the data-handling clause needs a new rubric version, not an edit in place.

Exit 0 when every rubric passes, 1 otherwise.
