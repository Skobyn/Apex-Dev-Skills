---
name: decide
description: Ask the decision layer one rubric question and explain the envelope — verdict, probabilities, uncertain, calibrated and why, or the unscored reason. Pass a rubric id and a JSON state as $ARGUMENTS, e.g. `risk-tier@1 {"changed_paths":["src/auth/session.py"],"changed_lines":40,"changed_files":1,"task_tags":[]}`.
argument-hint: "<rubric>@<v> <state-json>"
---

You are asking the decision layer one question for `$ARGUMENTS`.

1. Split `$ARGUMENTS` into the rubric id (first word) and the state (the rest, a JSON object). If either is missing, run `${CLAUDE_PLUGIN_ROOT}/bin/apex-decide lint` to list the shipped rubrics and ask which one and what state.
2. Run `${CLAUDE_PLUGIN_ROOT}/bin/apex-decide --rubric <id> --state - --json` with the state on stdin (never interpolate the state into the command line).
3. Print the envelope verbatim, then explain it in a few plain sentences:
   - Exit 0 (`scored: true`): the verdict and its probability; `uncertain` (a consumer tightens or does nothing on an uncertain answer, never loosens); `calibrated` and the `calibration.reason` (an uncalibrated answer may only make a route safer or more expensive).
   - Exit 3 (`scored: false`): the `reason`. `backend_none` means this repository has not opted in (`.claude/apex-decision-layer/config.json`); `egress_disabled` means a hosted backend was chosen with `egress: none`; `hard_rule` means code answered without a backend; `rubric_unknown` means the id has no rubric file yet. None of these is an error: consumers fall back to their deterministic path.
   - Exit 2: a usage error. Quote stderr.
4. Never edit `.claude/apex-decision-layer/` (config, labels, calibration records) to change an answer. Calibration comes only from the measurement job.
