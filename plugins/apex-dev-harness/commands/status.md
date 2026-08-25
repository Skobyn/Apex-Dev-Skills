---
description: Read-only orientation — what the harness can see, and what the current diff owes.
---

!`apex doctor`

Then summarize what the working diff would owe. `--dry-run` computes the obligations without executing any of them, so this command never triggers a test run:

!`apex gate --dry-run --json`

Report: the lane and surface of the files in flight, outstanding obligations, and anything the doctor flagged as missing.
