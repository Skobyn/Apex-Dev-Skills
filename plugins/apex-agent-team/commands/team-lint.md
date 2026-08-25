---
name: team-lint
description: Statically lint a project's subagent / agent-team configuration before a run — flags dead agents, overlapping responsibilities, missing tool grants, and unbounded fan-out. Pass a path to scan as $ARGUMENTS (default: repo root).
argument-hint: "[path-to-scan]"
---

You are running **TeamLint** over the agent-team configuration at `$ARGUMENTS`
(if `$ARGUMENTS` is empty, scan the current repo root).

1. Invoke the `team-lint` skill.

2. Run the static analyzer:

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/team-lint.sh $ARGUMENTS
   ```

   The script scans `agents/**/*.md` and `.claude/agents/**/*.md`, parses each agent's
   frontmatter and prompt body, and reports four finding classes:
   dead agents, overlapping responsibilities, missing tool grants, and unbounded fan-out.

3. Summarize the report for the user, grouped by severity. For each **high**-severity finding
   (missing tool grant, unbounded fan-out) propose a concrete one-line fix.

4. Honor the exit code: if the script exits non-zero, treat the agent-team config as **not yet
   safe to launch** and tell the user which high-severity findings to resolve first. Do not
   silence a finding by widening `allowed-tools` to a wildcard — grant the specific tool.

Keep the output focused on agent-team *configuration*. Do not drift into reviewing application
source, security, or test coverage — that is out of scope for this command.
