---
description: Read-only orientation — what the harness can see, and what the current diff owes.
---

!`node ${CLAUDE_PLUGIN_ROOT}/engine/bin/apex.js doctor`

Then summarize what the working diff would owe. `--dry-run` computes the obligations without executing any of them, so this command never triggers a test run:

!`node ${CLAUDE_PLUGIN_ROOT}/engine/bin/apex.js gate --dry-run --json`

Report: the lane and surface of the files in flight, outstanding obligations, and anything the doctor flagged as missing.
