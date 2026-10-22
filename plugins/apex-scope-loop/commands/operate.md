---
name: operate
description: Operate a landed plan — show its deploy and watch status, measure its declared Monitor checks, or file their breaches. Deploy is never run by the agent (a human types the ack at their own terminal).
argument-hint: "<PLAN> status|monitor|ingest | --all status|monitor [--ingest]"
---

Run the operate helper for `$ARGUMENTS`, the post-land operation for a plan that has landed:

`${CLAUDE_PLUGIN_ROOT}/skills/apex-execute/scripts/operate.sh $ARGUMENTS`

Accepted forms: `PLAN status|monitor|ingest` for one plan, and `--all status` or `--all monitor [--ingest]` for every landed plan with an open watch window plus the repo-level checks. Pass only the words the user typed; if the arguments are a sentence, pick the plan file and the step and say what you chose.

**Deploy is never run by the agent.** `operate.sh PLAN deploy` is refused to agent tool calls by apex-dispatch's pre-bash hook. A human runs it in their own terminal, reads the Ask Contract, and types the exact `<slug>@<landed sha>` ack there. If the user asks for a deploy, say so and give them the command to run themselves; do not try another route to it.

Report the script's output verbatim, including any `ERROR`, `REFUSED` or `WARNING` line and its exit code. For the subcommands, the Monitor section shape, probe rules, ingest and window-close outcomes, the metric and tagging conventions and the daily schedule, see `${CLAUDE_PLUGIN_ROOT}/skills/apex-execute/SKILL.md`, section "Operate".
