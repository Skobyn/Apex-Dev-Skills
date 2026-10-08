---
name: label
description: Record a human label for one past decision — the class or tier you would have chosen with hindsight — in .claude/apex-decision-layer/labels/. Pass "<rubric>@<v> <decision_id> <label> [note]" as $ARGUMENTS. Refused while an apex-scope-loop run is active.
argument-hint: "<rubric>@<v> <decision_id> <label> [note]"
---

You are recording one human label for the decision layer's measurement job (`docs/shadow-pilot.md`).

1. Split `$ARGUMENTS` into the rubric id, the decision id, the label and an optional note. If any is missing, ask.
2. Run `${CLAUDE_PLUGIN_ROOT}/bin/apex-decide label --rubric <id> --decision <decision_id> --label <label> [--note "<note>"]`.
3. Report the result. Exit 2 means a bad label or an unknown decision: quote stderr. Exit 5 means an ACTIVE run lock is held. Labels are written by a person between runs, never by an agent during one, so do not retry.
4. Never invent a label, and never label a decision the user did not name.
