---
name: measure
description: Measure one rubric and backend against this repository's labels — AUROC with its CI beside Brier and ECE, ablation arms, the threshold sweep, and a status (insufficient n, degenerate, fails or passes the kill criterion). Pass "<rubric>@<v> <backend> [--outcomes FILE]" as $ARGUMENTS. Never locks a record.
argument-hint: "<rubric>@<v> <backend> [--outcomes FILE]"
---

You are running the decision layer's measurement job for `$ARGUMENTS` (`docs/shadow-pilot.md`).

1. Split `$ARGUMENTS` into the rubric id, the backend and any `--outcomes FILE`.
2. Run `${CLAUDE_PLUGIN_ROOT}/bin/apex-decide measure --rubric <id> --backend <name> [--outcomes FILE]`, and print the output.
3. Explain the status in plain words:
   - `insufficient n`: how many more labels are needed.
   - `degenerate`: near-one-hot answers that AUROC cannot rank.
   - `fails kill criterion`: name the reasons it printed.
   - `passes kill criterion`: what locking would do.
4. Never pass `--lock`. Locking a calibration record is a human decision. Tell the user the command, and remind them that the printed digest must be added to `calibration_lock` by hand.
