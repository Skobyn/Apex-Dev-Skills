# apex-console

**One desk for the suite.** A local admin page for apex-scope-loop, apex-dispatch and apex-decision-layer. On it you can put in your API keys, see where every plan stands, measure how well the factory runs, and turn the knobs each plugin already honours. It is an admin layer: it never starts or drives work. Every change is logged, and most can be undone.

> **Status: 0.3.0.** Built: the server, the page, keys, progress (with plan scope and filter, intent, the Operate panel and per-task cost), the Watched tab, metrics, all four knob panels, the tier simulator, the kill switch, and the audit log with undo. Demo data (`?demo=1`) covers every view. The operate and cost panels are read-only.

## Start it

```bash
/apex-console:console                      # from Claude Code, in a repository
# or directly:
plugins/apex-console/bin/apex-console serve --repo ~/src/my-app --repo ~/src/other
```

It prints `CONSOLE_URL: http://127.0.0.1:4747/?t=<token>`. Open that address once; the token becomes a cookie. Add more repositories from the page. `?demo=1` shows the page with sample data and no server.

## What is on it

- **Overview.** Uber's software-factory cost equation for your repos, plus a scorecard of every metric against your own targets.
  - The equation is active repos × tasks per repo × turns per task × runs per turn × tokens per run × price per token, and the six terms multiply to the spend.
  - The scorecard shows each metric with its trend, its status and how it is computed.
- **Metrics.** Weekly charts: agent runs, spend, cost per 1,000 runs, cost per task, tasks completed, cache hit rate, active repos, and the A/B/C tier mix.
- **Progress.** Per repository: the running task and its stage, each plan's done/total, cost, open findings, and every task's tier, rounds and attempts. **Stop all work** writes the HALT kill switch that apex-scope-loop obeys; **Resume** removes it.
  - *Scope:* each plan carries a scope badge (`bugfix`, `poc` or `feature`, from the plan header; a plan without one reads `feature`). The **Scope** filter shows all plans or one scope.
  - *Intent:* a collapsible summary of the plan's intent file (problem, who, why now, non-goals). A plan with no intent file reads "Intent: n/a (no intent file for this plan)"; an intent file that exists but cannot be read reads "Intent: n/a" with the error and the file.
  - *Operate:* a panel on each landed plan (see below).
  - *Cost:* a per-task table and plan totals (see below).
- **Watched.** Every plan whose watch window is open, with its day N of M and the date the window ends, and each repository's own checks from `.claude/apex-scope-loop/monitor.json`.
- **Knobs.**
  - *Review strictness:* the Lenient, Standard, Strict and Paranoid presets, or the six numbers directly (review cap, ask-human-after, adversary budget, escalate-after, error budget, attempt cap).
  - *Tier definitions:* extra Tier C path and content triggers, reasoned exemptions, and the Tier B size thresholds and shared dirs. **Simulate on past tasks** replays your completed tasks under the proposal before you apply it: which tasks would get a lower or higher tier, and the reasons that change.
  - *Reviewers and providers:* enable or disable a provider, let it review or not, raise its acceptance floor, lower max review rounds.
  - *Decision layer:* egress, state fields, the primary backend per rubric, shadow.
- **Keys.** Set, replace or remove the keys the plugins read. The tab shows which ones your enabled providers need, and whether your shell profile sources the keys file.
- **Audit.** Every change, with Undo.

## Operate and cost panels

These panels only read. The Operate and Watched panels read files the plugins wrote. The Cost panel also reads Claude Code session transcripts (see **Cost** below). The console never runs `operate.sh deploy`, `monitor` or `ingest`, never runs a plan, and never writes plugin state. Deploys, monitor runs and ingest happen in the CLI; the page shows what they recorded.

**Operate** (on each landed plan) shows the operate state of that plan, read from its checkpoint and its `## Monitor` section:
- *Deploy history:* every recorded deploy, with its time, commit and exit code. A deploy that exited non-zero opens no window; each deploy that exits 0 closes the window still open (closed by `redeploy`) and opens a new one.
- *Watch window:* "not opened (no deploy recorded)", open as "day N of M", or closed with its outcome (`operated-clean` or `closed-with-breaches`) and its checks open and unmeasured at close. An open or closed window shows its measured runs and breaches (breaches read **unmeasured** when no run produced a reading). A window whose end has passed but that no monitor run has closed yet reads "ended, not yet closed by a monitor run". The end date is on the Watched tab.
- *Checks:* each declared check with its threshold, severity, latest value and status, breach count, and where its first breach was filed. A check that has never produced a reading shows **unmeasured** for both its latest value and its breaches. A check whose last probe failed shows **unmeasured** as its latest value, with the reason and the last good reading on hover, and keeps its breach count. A check that was in breach, or never measured, when the window closed is flagged **open-at-close**.
- *Ingested:* the lessons and backlog items that `operate.sh ingest` filed for the plan, with a count of the open backlog items.
- *Last closed window:* how many windows have closed, and for the last one its outcome, what closed it (`monitor` or `redeploy`), and its checks open and unmeasured at close.
- *State missing:* a landed plan whose checkpoint has no operate block reads **state missing**, with nothing deployed or measured. That is a fact to act on, not a zero.

A value the console cannot compute is shown as **n/a** (or **unmeasured** for a check), never as 0.

**Watched** lists the plans whose window is open, then each repository's repo-level checks (its `monitor.json` with the state from the repo-level operate run). Repo-level backlog items from ingest appear under the checks.

**Cost** is on each plan's task table, from apex-dispatch's per-task report, read-only:
- *Delegated:* the USD and tokens the delegated agents used for the task.
- *Orchestrator:* the main session's cost attributed to the task. It is a lower bound: compaction and utility calls write no assistant line to the transcript, so they are never counted.
- *Orchestrator unattributed:* main-session turns that fall in no single task's window (outside every window, or in more than one). It appears on the plan's total row, not on a task.
- *Delegated, outside any task:* delegated ledger spend that belongs to no task of the plan (`usd_unrouted`, for example a helper run on no routed task). It is a row of its own, shown when it is not zero or is **n/a** (null: not computable), and is not in the plan total.

Each cell shows **n/a**, not 0, when it cannot be measured. A background agent with no recorded usage has no delegated figure, so its delegated cell is n/a. A task whose orchestrator figure is missing shows the reason on hover (for example "no routed task" or "session(s) with no transcript read: <session id>"). When no orchestrator figure in the plan can be measured, the reason is the plan's cost status, for example "n/a (transcripts held no main-session turns)". Where tokens are measured but the price is not, the cell shows the tokens with an n/a price. The totals row notes how many tasks are n/a, as "(N tasks n/a)". Plan totals use the measured tasks only, so they may differ from the older per-plan USD shown on the plan header.

The orchestrator figures come from Claude Code's session transcripts. apex-dispatch's `report.per_task` finds them under `<config>/projects/*/<session_id>.jsonl`, where `<config>` is `$CLAUDE_CONFIG_DIR` or `~/.claude`, and opens only files named after a session id recorded in the plan's ledger. It opens them read-only and parses only the fields usage needs: `type`, `isSidechain`, `sessionId`, `timestamp`, `message.id`, `message.model` and the token counts in `message.usage` (with each of its `iterations`' type, model and counts). It does not parse message content. Nothing from a transcript is shown or stored except the token and USD figures and the session ids.

## Tier simulator

Before you apply a tier change, replay it. **Simulate on past tasks** takes the proposal on the Tier definitions panel and classifies up to 60 of your most recently completed tasks twice: once under the definitions in force, once under the proposal. It uses apex-scope-loop's own `risk-tier.sh` (`--no-record --since <the task's base> --head <its completed head> [--knobs <proposal>]`), so what it shows is what the classifier would do. Nothing is recorded or written.

You get the moves ("C→A ×4"), the tier mix before and after, and per task the reasons the proposal adds or removes. A lower tier is looser and a higher one stricter. The replay covers the heuristic only: reviewer raises and the decision layer are not replayed, so a recorded tier can sit above both. This is how to fix Tier C over-triggering on, say, plugin agent prompts that name auth terms as prose: try an exemption such as `plugins/*/agents/*.md`, see exactly which past tasks it would have moved, then apply it.

## Metrics

Each metric is computed from the plugins' own records. Spend comes from apex-dispatch's pricing, and ledgers are checked with its chain verification. Each metric shows how many tasks or runs it rests on, and reads "—" rather than 0 when there is nothing to measure. Definitions are in [ADR-0001](docs/adrs/0001-apex-console-contract.md).

| Group | Metrics |
|---|---|
| Uber software factory | the six-term cost equation; cost per completed task (paired with revert rate); cost per review (paired with findings addressed); time to recover from a failure; cost per 1,000 runs; runs per week; prompt cache hit rate; autonomy rate |
| Factory flow | first-pass yield, review rounds per task, lead time p50/p90, throughput, escalation rate, human touches per task |
| Integrity | unreadable verdicts, policy violations, ledgers intact |

## Keys

Keys are written to `~/.config/apex/keys.env` (mode 600) as `export NAME='value'`. They are never shown again: the page shows only set or not set, and the last four characters. Claude Code reads keys from its environment, so add this line to your shell profile; the Keys tab shows whether it is there:

```bash
[ -f ~/.config/apex/keys.env ] && . ~/.config/apex/keys.env
```

Never put keys in a repository or a `.env` file.

## Compatibility

| Component | Version |
|---|---|
| apex-scope-loop | ≥ 0.5.0 for the knobs file, ≥ 0.6.0 for the tier simulator, ≥ 0.7.0 for scope, intent and the Operate and Watched panels; older: progress and metrics only |
| apex-dispatch | ≥ 0.6.0; ≥ 0.7.0 for the per-task cost table (`report.per_task` and `locate_transcripts`, the numbers of `report.sh --per-task --json`); older: the cost cells read n/a |
| apex-decision-layer | ≥ 0.6.0 |
| python3 | ≥ 3.8 (stdlib only) |
| git | any recent; used to find repositories and reverts |
| Browser | any current one; the page uses no external scripts |

## Namespace coordination

apex-console owns `~/.config/apex/console.json`, `console-audit.jsonl`, `keys.env` and `keys.meta.json` (override the directory with `APEX_CONFIG_DIR`). It writes into other plugins' space only through these files, each checked by its owner's validator before the write:
- `<state-base>/knobs/scope-loop.json` (apex-scope-loop `knobslib.py`);
- `.claude/apex-dispatch/policy.json` (apex-dispatch `compile.py`);
- `.claude/apex-decision-layer/config.json` (apex-decision-layer `load_config`);
- `<state-base>/HALT`.

It writes no memory or AgentDB keys.

It reads, and never writes, Claude Code session transcripts (`<$CLAUDE_CONFIG_DIR or ~/.claude>/projects/*/<session_id>.jsonl`, matched by the ledger's session ids) for the Cost panel, through apex-dispatch's `report.per_task`.

## Verification

```bash
bash plugins/apex-console/scripts/smoke.sh
```

It builds a fixture repository with a real apex-dispatch ledger. It then checks:
- the metrics, including that the cost equation multiplies to the spend;
- the server's token, Host and header checks;
- that no route returns a key value;
- refusals by each plugin's validator;
- audit and undo, and the kill switch;
- check 11, the tier simulator: a proposed exemption moves the fixture's agent-prompt task from C to A, nothing is written, and a bad proposal is refused;
- check 12, console-plans-payload: the plans API carries scope, intent, operate state and per-task cost, read-only;
- check 13, console-ui-borrowings: the page's own `app.js` renders scope, intent, the Operate panel, Watched plans and per-task cost. It runs under node; without node it falls back to a static scan of `app.js` and prints a warning.

## Architecture Decisions

- [ADR-0001: apex-console contract](docs/adrs/0001-apex-console-contract.md): admin layer only, the files it reads and writes, the metric definitions, the security model.
- [docs/api.md](docs/api.md): the HTTP API between the server and the page.
