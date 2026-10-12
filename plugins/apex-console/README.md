# apex-console

**One desk for the suite.** A local admin page for apex-scope-loop, apex-dispatch and apex-decision-layer. On it you can put in your API keys, see where every plan stands, measure how well the factory runs, and turn the knobs each plugin already honours. It is an admin layer: it never starts or drives work. Every change is logged, and most can be undone.

> **Status: 0.2.0.** Built: the server, the page, keys, progress, metrics, all four knob panels, the tier simulator, the kill switch, and the audit log with undo.

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
- **Knobs.**
  - *Review strictness:* the Lenient, Standard, Strict and Paranoid presets, or the six numbers directly (review cap, ask-human-after, adversary budget, escalate-after, error budget, attempt cap).
  - *Tier definitions:* extra Tier C path and content triggers, reasoned exemptions, and the Tier B size thresholds and shared dirs. **Simulate on past tasks** replays your completed tasks under the proposal before you apply it: which tasks would get a lower or higher tier, and the reasons that change.
  - *Reviewers and providers:* enable or disable a provider, let it review or not, raise its acceptance floor, lower max review rounds.
  - *Decision layer:* egress, state fields, the primary backend per rubric, shadow.
- **Keys.** Set, replace or remove the keys the plugins read. The tab shows which ones your enabled providers need, and whether your shell profile sources the keys file.
- **Audit.** Every change, with Undo.

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
| apex-scope-loop | ≥ 0.5.0 for the knobs file, ≥ 0.6.0 for the tier simulator; older: progress and metrics only |
| apex-dispatch | ≥ 0.6.0 |
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
- the tier simulator: a proposed exemption moves the fixture's agent-prompt task from C to A, nothing is written, and a bad proposal is refused.

## Architecture Decisions

- [ADR-0001: apex-console contract](docs/adrs/0001-apex-console-contract.md): admin layer only, the files it reads and writes, the metric definitions, the security model.
- [docs/api.md](docs/api.md): the HTTP API between the server and the page.
