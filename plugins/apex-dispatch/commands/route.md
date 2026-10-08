---
name: route
description: Route one plan task or an ad-hoc ask through apex-dispatch's route.sh and print the ROUTE block (class, tier, model, effort, provider, roster, fan-out, review shape, budgets). Pass `plan <PLAN> --line N` or `adhoc --tags <csv> [--paths <globs>] [--acceptance <cmd>]` as $ARGUMENTS; add --dry-run to preview without writing state.
argument-hint: "plan <plan.md> --line N [--lanes L1,L2] [--dry-run] | adhoc --tags <csv> [--paths <globs>] [--acceptance <cmd>] [--dry-run]"
---

You are routing with apex-dispatch for `$ARGUMENTS`.

1. Run `${CLAUDE_PLUGIN_ROOT}/scripts/route.sh $ARGUMENTS` from the repository root.
   - If `$ARGUMENTS` starts with neither `plan` nor `adhoc`: when it is a path to a plan file, run `iterate.sh` through `/apex-scope-loop:iterate` instead (it routes the next unblocked task itself); when it is a request in words, do **not** pass the words to route.sh. Ad-hoc asks take caller-supplied tag tokens only (`--tags docs`, `--tags tests,backend`), never free text. Ask the user for the tags, the owned paths and a runnable Acceptance command, then run `route.sh adhoc --tags … --paths … --acceptance …`.
   - `--adhoc` (spec spelling) means the `adhoc` subcommand.
2. Print the ROUTE block verbatim, then read it with the `dispatch-route` skill:
   - `READY` (not `--dry-run`): the route is recorded in `active-route.json` and the ledger, and the `ACTIVE` lock is held for this plan or ad-hoc id. Say whether `ROUTE_ENFORCED` is `yes` or `no` (shadow mode). Offer `/apex-dispatch:run` to drive it.
   - `NEEDS_SPEC`: report `ROUTE_MISSING` and what the plan owner must add. Nothing is dispatched.
   - `HUMAN_GATE`, `HALTED`, `BUSY`: report the status and `ROUTE_REASON` verbatim and stop.
   - `ROUTE: none`: `APEX_DISPATCH_MODE=off`; routing is the orchestrator's 0.2.0 choice.
3. Do not spawn anything from this command. Routing and dispatch are separate steps.

Exit codes: every status exits 0; 1 is an error (bad policy, unreadable plan, apex-scope-loop not found beside apex-dispatch — set `APEX_SCOPE_LOOP_ROOT`); 2 is a usage error. Quote any error verbatim.
