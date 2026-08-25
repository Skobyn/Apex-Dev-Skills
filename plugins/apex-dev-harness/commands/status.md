---
description: Read-only orientation — what the harness can see, and what the current diff owes.
---

!`apex doctor`

Then summarize what the working diff would owe, without running the wrapped commands:

!`apex gate --paths "$(git diff --name-only HEAD | tr '\n' ',')" --json`

Report: the lane and surface of the files in flight, outstanding obligations, and anything the doctor flagged as missing.
