---
name: doctor
description: Check this repository's decision-layer setup — config, egress, the backend per rubric, whether each hosted backend's API key is present (never its value), the rubrics, and with `--probe` whether jev and frontier are reachable. Pass `--probe` as $ARGUMENTS to send one empty, free request to each hosted backend.
argument-hint: "[--probe]"
---

You are checking the decision layer's setup in this repository.

1. Run `${CLAUDE_PLUGIN_ROOT}/bin/apex-decide doctor --json $ARGUMENTS` (only `--probe` is accepted as an argument; drop anything else).
2. Summarise each check in one line, failures and warnings first:
   - `config` and `egress`: absent config means everything is off, and every call answers `backend_none`.
   - `jev_key` / `frontier_key`: whether the environment variable is set. Never print, echo or ask for a key value. If a key is missing, name the variable the user should set in their own environment.
   - `jev_reach` / `frontier_reach`: without `--probe`, only the pinned endpoint. With it, `key rejected` means the provider refused the key, and a failure means the host could not be reached (network policy, proxy, DNS).
   - `rubric …`: a rubric that fails lint answers `rubric_unknown`.
3. Do not change `.claude/apex-decision-layer/` to fix a check. Tell the user what to change.
