# ADR-0004: Review-loop calibration

- **Status:** Accepted
- **Date:** 2026-10-07
- **Author:** solutions@getapexinsights.com
- **Plugin:** apex-scope-loop v0.4.0 (with apex-dispatch v0.3.1 reviewer contracts)
- **Amends:** [ADR-0002](0002-gibson-harness.md), [ADR-0003](0003-portability-and-dispatch-consumer.md)

## Context

The apex-dispatch Phase 1.4 run (`checkpoint.sh` provenance, `risk-tier`, `land.sh` and the clean-worktree check) spent one Tier C task on 10 attempts, 3 halts and about 58 review rounds. Each finding was real, but approval depended on the adversary running out of ideas rather than on a fixed bar:

1. the adversarial reviewer had no stopping rule;
2. scope was settled one finding at a time, because no threat model existed before round 1;
3. the trust model was never stated, so findings that assumed the implementing agent sabotages its own worktree were blocking;
4. every round re-attacked the whole surface instead of the fix;
5. "3 consecutive failures → HALT" could not tell stuck from converging;
6. test fixtures that name sensitive tokens (`stripe`) raised the task to Tier C.

(Source: `.claude/apex-scope-loop/REVIEW-LOOP-FEEDBACK.md` and LESSONS.md L-004/L-005 in the development repo.)

## Decision

### 1. Threat model before review

Plans get an optional `## Threat model` section (both plan templates carry it with the default text) and tasks an optional one-line `- Threat:` directive in the 8-line look-ahead (`planlib.py`; `planlib.py threat PLAN LINE`). `iterate.sh` prints a `THREAT_MODEL: source task|plan|default` line followed by the text as `  > ` lines; precedence is task directive, then plan section, then the default:

> Trusted, non-malicious agents and operators. Guard against accidents and realistic misuse. Not a sandbox: deliberate tampering with state, config or the harness by the trusted agent, and obfuscated inputs, are out of scope.

Blockquoted lines inside the section are author notes and are not passed on; the section is cut at 40 lines (the brief says so). `iterate.md`, `gibson-reviewer` and apex-dispatch's `dispatch-route` skill pass it to every reviewer verbatim.

### 2. Severity bar

`gibson-reviewer` and apex-dispatch's `reviewer` / `adversarial-reviewer` contracts: `[blocking]` only when a realistic actor under the stated threat model can cause the failure in an ordinary flow, or Acceptance is unmet, or a test was deleted, skipped or weakened. Anything that needs deliberate tampering or obfuscation, or lies outside the threat model, is `[non-blocking]` and goes to the backlog (§7).

### 3. Diff-scoped re-reviews

The brief prints `LAST_REVIEWED: <sha>|none` (the last reviewed SHA in the current attempt and epoch), `REVIEW_ROUND: n` (the head's own round while its reviews are still arriving and none requested changes, else the next round) and `REVIEW_MODE: full|verify`. Round 1 is the full review and carries the attempt's one full adversarial pass. Round 2 and later are verify-only: SINCE=`LAST_REVIEWED`, `PRIOR_FINDINGS` passed verbatim, review the fixes and their blast radius. The reviewer prompt documents `MODE: full|verify`. Each review record stores the tier it was done at; `REVIEW_MODE` is `full` again (and `REVIEW_SINCE` is `TASK_BASE`) whenever the recorded tier is above every tier reviewed in the attempt, or a Tier C attempt has no adversarial review yet, so a mid-attempt tier rise always gets a full review. Because the brief predates the build, the orchestrator re-reads the mode after `risk-tier.sh` with the read-only `checkpoint.sh PLAN review-mode LINE` (same rule, no re-route). The mode is also enforced: each review record stores `mode` (`review --mode full|verify`, else the frozen round's mode, else `full`); `freeze --mode verify` is refused when the tier rose above every full round of the attempt or a Tier C attempt has no full-mode adversarial review at Tier C; and `complete` refuses unless some round of the attempt was full at the effective tier and, for Tier C, included a full-mode adversarial review at Tier C.

### 4. Adversary budget

Reviewers cap `[blocking]` findings at `BUDGET` per pass (`APEX_ADVERSARY_BUDGET`, default 3, surfaced as `ADVERSARY_BUDGET:` in the brief), ranked by severity; the rest are non-blocking.

### 5. Earlier human escalation and a written waiver

`checkpoint.sh review` prints `ASK_HUMAN:` when a REQUEST_CHANGES is recorded and the line has REQUEST_CHANGES in at least `APEX_ASK_HUMAN_AFTER` (default 2) distinct review rounds of the current attempt. The orchestrator halts and asks with the Ask Contract: accept the residual risk, or keep fixing.

`checkpoint.sh PLAN waive LINE SHA "<the human's literal reply>" "<residual risk accepted>"` appends `{kind: review_waiver, line, sha, epoch, attempt, reply, residual_risk, waived_verdicts, at}` to `operator_overrides[]` — the writer ADR-0003 §5 said was missing. It is refused unless the reply contains `waive <LINE>`, the risk is named, and a REQUEST_CHANGES exists at that SHA in the current attempt and epoch. With apex-dispatch state it is ledgered first, as a non-provenance `human_gate` row (`gate: review-waiver`, `decision: approved`, via `ledger.sh append --source cli`); if it cannot be ledgered it is not recorded. A waiver clears an `awaiting human review waiver …` halt.

`waive` is refused while a freeze on the line still has verdicts outstanding, and unless the reply, after trimming whitespace and surrounding quotes or backticks, starts with `waive <LINE>` followed by the end or a separator (space, `.`, `,`, `:`, `;`, a dash); a remark may follow. Nothing else is parsed: any other reply ("Yes waive 1", "I don't think we should waive 1") is refused, and the orchestrator asks the human to reply plainly `waive <LINE>`. The override stores the REQUEST_CHANGES records it covers (`covered`: their indices, sources, roles and times; their count is `waived_verdicts`). It clears only a halt that names its own line. After a waiver, a new REQUEST_CHANGES at the same SHA prints `ASK_HUMAN: new REQUEST_CHANGES … after the waiver — not covered`. While a frozen round still has verdicts outstanding, `review` prints `ASK_HUMAN: pending — record the rest of this round's verdicts first` instead of asking for a halt; when the round's last verdict comes in, the final `ASK_HUMAN:` is printed if any verdict of the round requested changes and the threshold is met, even if that last verdict approved.

**What a waiver unlocks (exactly):** in `complete`, for the waiver's line, at exactly its SHA, in its epoch and attempt, the REQUEST_CHANGES records it listed when it was written (and only those: the listed indices must still hold REQUEST_CHANGES records at that SHA with the same source, and their number must equal `waived_verdicts`) stop refusing the completion, and a reviewer who requested changes at that SHA counts toward the review shape (Tier C adversarial; in provenance mode the six lenses, the adversarial pass and family diversity). In provenance mode it also lifts the "non-APPROVE at HEAD is final" block for the hook/shim records and ledger rows whose `record_id` is one of the covered records.

**What it never unlocks:** the green gate; the risk-tier record and the re-classification at `complete`; G12 for Tier C; `--skip-review` rules; audit-refused, stale or UNPARSED records; a role that never reviewed the head (no APPROVE is fabricated); Acceptance (the orchestrator's step 10); any other SHA, epoch or a later attempt; another line; a verdict recorded after the waiver (a late fan-out reviewer, or a lens or adversarial reviewer dispatched afterwards). The completion is recorded as `review: waived` with the waiver's index in `completes[]` and `last_verdict`, never as an approval.

### 6. Progress-aware halts

`checkpoint.sh fail LINE REASON [--progress "what this attempt closed"]`. `ESCALATE` still fires at `APEX_ESCALATE_AFTER` consecutive failures. A failure is a **stall** unless `--progress` is given and the worktree head moved since the previous failure on that line (else since the task's diff base). The plan halts at `APEX_ERROR_BUDGET` (default 3) stalls in the failure streak, or at `APEX_ATTEMPT_CAP` (default 6) consecutive failures of any kind; the HALTED line names the counter. `complete` and `resume` reset both counters (`consecutive_stalls`, `fail_heads` in the checkpoint).

### 7. Hardening backlog

`backlog.sh PLAN add LINE "<finding>" [--from reviewer] | list [--all] | done ID | count`. One tracked markdown file per plan repository, beside the lessons ledger: `<main checkout>/.claude/apex-scope-loop/BACKLOG.md` (`APEX_BACKLOG_FILE` overrides), one `## Plan: <path>` section per plan, items `B-NNN`, one line each. It is treated exactly like the lessons ledger: `land.sh` exempts it in the base checkout, records it with the plan, and always lands the base's copy; a run without a worktree leaves it out of the task diff and the dirty check, only at its fixed path. The brief prints `BACKLOG: <n> open for this plan`; `iterate.md` records non-blocking findings there and has the next `[docs]` or hygiene task consume open items.

### 8. Classifier calibration (`risk-tier.sh`)

a. Tier C **content** signals are ignored in added lines of files under `(^|/)(tests?|__tests__|spec|fixtures?|examples?|docs?)/`, or whose name matches `*_test.*` or `*.test.*`, or that have `smoke` in the basename under a `scripts/` or `tests/` directory; a REASON line names each such file. A Markdown file elsewhere is scanned, but Tier C content terms found only in Markdown give Tier B (a REASON names them), not C — except Markdown under a shipped surface (`(^|/)(agents|skills|commands|hooks)/`), which is product and keeps Tier C. Path signals still apply to every file. A file counts as exempt only when its diff header parses exactly; anything else is scanned (fail closed).

b. An explicit override `[tier:a reason="…"]` or `[tier:b reason="…"]` (the reason is required; a bare `[tier:a]` has no effect; inside a backtick code span it is not an override) is authoritative over the Tier B size, breadth and shared-module signals and over content signals. It never overrides a Tier C path signal, a `[security]` / `[tier:c]` tag, the decision layer or a reviewer's `--raise`. Every overridden signal reaches the reviewers: `risk-tier.sh` prints it as a REASON and, for every distinct overridden Tier C content term (each with its file), its own `TIER_C_OVERRIDDEN:` line, or `TIER_C_UNANTICIPATED:` when the override's reason does not mention that term; `SIGNAL_LENSES` is derived from all of them; all of these are recorded with the tier (`reasons`, `overridden_c`, `signal_lenses`) and `iterate.sh` prints them as `TIER_REASONS:`, which the orchestrator passes to every reviewer verbatim. A reviewer who finds an overridden signal real asks for the tier to be raised (`risk-tier.sh --raise B|C --reason …`). The tier still only ratchets up within a line's records, and `complete` still takes the higher of the recorded and recomputed tier.

## What this loosens and why it is safe

| Change | Loosens | Keeps | Why it is safe under the stated trust model |
|---|---|---|---|
| Threat model + severity bar | Findings that need deliberate tampering, obfuscation or an out-of-scope actor no longer block | Acceptance, weakened tests and realistic ordinary-flow failures block; every finding is still written down (backlog) | The harness trusts its own agent and operator; it is not a sandbox. Accidents and realistic misuse are still blocking. A plan or task that needs a stronger model says so in its section or `Threat:` line |
| Verify-only rounds | Later rounds stop re-attacking unchanged code | Round 1 is a full review with a full adversarial pass; fix commits and their blast radius are always reviewed; `complete` still needs approvals at the exact head | Code unchanged since a full review was already reviewed; new defects outside the fix are recorded as non-blocking, not lost |
| Adversary budget | More than `BUDGET` blocking findings per pass | The top `BUDGET` by severity still block; the rest are recorded | The next round still sees the fixes; the most severe issues always block |
| ASK_HUMAN + waiver | A human can accept residual review findings at one SHA | Gate, tier, G12, Acceptance, refused/unparsed records, real reviews at the head; binding to SHA + epoch + attempt; the human's literal reply and the named risk are recorded (and ledgered) | A human decides with the findings in front of them; the waiver cannot move to other code, and no approval is fabricated |
| Progress-aware halts | A failure streak that closes findings no longer halts at 3 | Stalls still halt at 3; any streak halts at 6; ESCALATE unchanged | Progress needs a claim **and** a moved head; the attempt cap bounds a slow streak |
| Backlog | Non-blocking findings leave the review loop | They are durable, per plan, and consumed by a later task | Nothing is dropped; it is scheduled |
| Classifier (a) | Test/fixture/docs-directory content no longer raises Tier C (not Markdown elsewhere; smoke files only under scripts/ or tests/) | Path signals for those files; content of every other file | Test data naming a token is not code handling it; a fixture under an auth path is still Tier C |
| Classifier (b) | An explicit `[tier:a\|b reason="…"]` decides over B and content signals | Tier C paths, `[security]`/`[tier:c]`, the decision layer, reviewer raises, the upward ratchet; every overridden signal (an unanticipated one flagged) is recorded and passed to every reviewer as `TIER_REASONS` | The override is a reviewed plan decision with a stated reason; reviewers see exactly what it overrode and can raise the tier |
| `Review:` directive | A task may set its cap, choose lenses and drop the adversarial pass (Tier A/B) | Tier C and sensitive-tagged tasks: at least 3 distinct lenses including each signal's lens, the adversarial pass, G12, and `cap=` may only lower the cap; with apex-dispatch, never below the active route's review shape | The directive is in the reviewed plan, the floors for risky work stay, and what it changed is recorded |
| Cap counts blocking rounds | Approving rounds no longer use the review cap | Rounds that requested changes still count; ASK_HUMAN after 2 | An approving round is progress, not a loop |

Applying LESSONS L-004 ("state the invariant in terms of capability"): a waiver's capability is "REQUEST_CHANGES verdicts at this SHA, line, epoch and attempt stop blocking `complete`", and the smoke test covers its adversarial neighbours (another SHA, another epoch, a later attempt, no literal reply, a missing gate, a missing G12). The classifier's exemption capability is "content of exempt-path files", and the smoke test covers its neighbours (the same content in a source file, an auth path under `tests/`, a name that only contains "test").

## Consequences

- Review rounds end on a fixed bar and a budget, not on the adversary running out of ideas.
- The plan author must think about the threat model before round 1; the default is stated and conservative about accidents.
- Two new checkpoint fields (`operator_overrides[]`, `consecutive_stalls` / `fail_heads`) and one new tracked file (`BACKLOG.md`).
- A misjudged `[tier:a reason="…"]` override can land a content-only Tier C change with a solo review. The guard is that the overridden signal is recorded and handed to every reviewer as `TIER_REASONS` (flagged `TIER_C_UNANTICIPATED` when the reason does not mention it), and a reviewer who finds it real raises the tier, which forces a full review (§3).

### Smoke contract additions

See the full, ordered list (checks 44–61) at the end of this ADR.

## Addendum: a downstream fork's halt-repair-loop run

Source: feedback from a downstream fork's halt-repair-loop run (a fork of this plugin at 0.2.0, used on another repository). Each item extends the mechanism above rather than adding a parallel one.

- **A. Carried findings per task.** `findings.sh PLAN add LINE --severity blocking|non-blocking --class C --at FILE:LINE --sha SHA "<mechanism>" [--from R] | list LINE [--open] | close LINE ID [--reason] | path | summary | classes`, stored at `<state>/findings/L<line>.json` (id, sha, severity, class, file:line, mechanism, status, rounds). A defect is counted once: the same class and file:line is the same entry (its rounds grow, a new mechanism is added to its `mechanisms` list, a blocking re-report re-opens a closed one, and a non-blocking re-report never re-opens anything). Non-blocking entries are residuals: they are copied to the backlog (§7) and never count as open. The brief prints `FINDINGS: <path> (<open> open, <residual> residual, <closed> closed)`; verify rounds get the open items as `PRIOR_FINDINGS`, re-verify each by experiment, then hunt only in the fix delta.
- **B. The cap counts blocking rounds.** `APEX_REVIEW_CAP` (default 3) now counts only rounds of the attempt with a REQUEST_CHANGES; an approving round does not use it. A task's `- Review: cap=<n> lenses=<list|all> adversarial=yes|no` directive (validated by planlib) sets the cap, and at `complete`: Tier A/B may drop the adversarial pass and choose lenses; Tier C — and, without dispatch state, a task tagged security/auth/money/billing/payment/pii/consent/migration — may narrow the provenance lens fan-out to no fewer than 3 distinct lenses (fewer is ignored: all six), which must include the lens of each Tier C signal (money → `money`, auth/security → `security`, consent/PII → `consent-pii`; `risk-tier.sh` prints `SIGNAL_LENSES:`); `adversarial=no` is ignored (the adversarial pass and G12 stay), and `cap=` may only lower the cap. With dispatch state, the directive never goes below the active route's review shape (`fanout6+adversarial` keeps six lenses and the adversarial pass). planlib refuses unknown or repeated lens names. What the directive applied and ignored is printed and recorded in `completes[].review_directive`. `Route: review=` may still only tighten.
- **C. Freeze the head during review.** `checkpoint.sh freeze LINE SHA [--reviewers N]` (the worktree head only) refuses `review` of any other SHA for the line until N verdicts are recorded (then it lifts, printing `FREEZE: lifted`) or `checkpoint.sh unfreeze LINE`; `fail` (a new attempt) and `rewind` clear it too, and `waive` is refused while it has verdicts outstanding. Fixes wait and land as one batch after the round. With apex-dispatch, freeze moves the `ACTIVE` lock GATE → REVIEW, the stage in which its hooks already refuse commits. The brief prints `FROZEN:`.
- **Backlog closes are pending.** `backlog.sh PLAN done ID --line LINE --sha SHA` marks an item pending; `complete` of that line confirms it when SHA is in the completed head's history; `fail` and `rewind` reopen it; `done ID --now` is the immediate human form.
- **D. One shared review snapshot per commit.** `snapshot.sh PLAN [SHA]` writes `<state>/snapshots/<sha>/` with `read-tree` into a private index and `checkout-index -a` (not `git archive`: export-ignore cannot drop files), runs `APEX_SNAPSHOT_SETUP` once inside it (a failure leaves nothing), makes it read-only and prints `REVIEW_SNAPSHOT:`. It is reused per SHA and pruned by `complete` and `land.sh` (`snapshot.sh PLAN prune`). Submodules are not populated. A run without a worktree keeps its snapshots under `<git-common-dir>/apex-scope-loop-snapshots/<plan>/`, outside the work tree.
- **E. Tier override with a reason.** Item 8b now takes effect only as `[tier:a reason="…"]` / `[tier:b reason="…"]` (a bare `[tier:a]` is noted and ignored); the override and its reason are recorded in the tier record. A reviewer raises the tier through the orchestrator: `risk-tier.sh PLAN LINE --raise B|C --reason "<finding>"` (reason required, recorded in `raised[]`, ratchets). Size and breadth alone give Tier B (one six-lens reviewer); only Tier C brings the fan-out, the adversarial pass and G12.
- **F. Builder handback and threat list.** Tasks may carry `- Threats:` (inline `1) …; 2) …` and/or sub-items); the brief prints `THREATS:`. `skills/apex-execute/resources/templates/builder-handback.md` asks for threat → failing-first test (real files, real gate, real seal) → the mutant that turns it red, the tests that use real files, and one line per threat. `iterate.md` hands builders both and states the working agreement: if a hook or filter rejects text, stop and report the exact message; never obfuscate around it. The plan templates ask a task that hand-parses a language to name a fallback (drop the feature) in its Acceptance.
- **G. Known defect classes.** The brief prints `KNOWN_DEFECT_CLASSES:` (lessons matching the task's tags, as `L-NNN:slug`, plus the classes of closed findings in this plan). A class closed in two tasks with no lesson yet prints `LESSON_SUGGESTED:` with the exact `lessons.sh … add` command (root cause and fix left to fill in).
- **H. Script confusions.** (a) The brief also prints `SINCE:` (= `TASK_BASE`, the `--since` value); `HEAD_SHA` is documented as the head at brief time, never a diff base. (b) Every acting script locates the plan first (`apex_locate_plan`): a plan path given from inside the plan worktree means the base checkout's copy (so `complete` ticks the plan `iterate` reads), and a relative path missing in a linked worktree is looked up in the main checkout. The "not initialized" / "plan not found" reports did not reproduce for base-relative or absolute paths; the worktree-copy case was the real confusion. (c) `complete` names each missing prerequisite with the exact command, e.g. "run risk-tier.sh for line N first: risk-tier.sh PLAN N --since <TASK_BASE>". (d) The npm autodetect already used only scripts present in `package.json`; the invented `npm run typecheck` was in the generic plan template, which now says `{typecheck command}`.
- **I. Gate signal annotations.** Not implemented: this version of `green-gate.sh` has no anti-Goodhart warnings (no `timeout-inflated` or similar), so there is nothing to annotate.
- **J. Measurement.** `status.sh PLAN --review-metrics` prints, per task, review rounds, blocking rounds, attempts, minutes per round (mean gap between consecutive rounds' first verdicts) and whether the completion was waived. The calibration is judged by before/after measurement of these numbers on comparable plans, not by the absence of complaints.
- **K. Out of scope (harness or environment, not plugin work).** Output-filter false positives on quoted text; automated "commit security review" notices that lack detail; partial-findings checkpoints for agents. `iterate.md` documents resuming a reviewer by its agent id so partial findings are kept.

### Smoke contract additions (checks 44–61, in order)

44. Threat model block (task > plan > default), `Threat:` directive and template sections.
45. `LAST_REVIEWED` / `REVIEW_ROUND` / `REVIEW_MODE` / `ADVERSARY_BUDGET`.
46. `ASK_HUMAN` after `APEX_ASK_HUMAN_AFTER` rounds.
47. `waive` and its neighbours (another SHA, another epoch, a later attempt, no literal reply; gate and G12 still required; recorded as `waived`; provenance mode and ledger row).
48. Progress-aware halts (stall budget, attempt cap, counter named).
49. Backlog add / list / done and its treatment by `land.sh`.
50. Classifier: fixture content, exempt-path neighbours, tier overrides vs path signals and `[tier:c]`.
51. Findings (dedupe, residuals to the backlog, close/reopen, brief).
52. Cap counts blocking rounds; `Review:` directive validated, applied and recorded; Tier C floors.
53. Freeze / unfreeze.
54. Snapshot (export-ignore kept, read-only, setup once, reuse, failed setup, prune).
55. Tier override reason, `--raise`, size-only Tier B without G12.
56. Threats in the brief, handback template, working agreement, parser fallback.
57. Known defect classes and `LESSON_SUGGESTED`.
58. `SINCE`, worktree cwd and plan paths, exact prerequisites, npm scripts.
59. Review metrics.
60. Round-1 review fixes: waiver scope (late and post-waiver verdicts not covered, freeze outstanding, refused replies, own-line halt), `TIER_REASONS` and unanticipated overrides, distinct-lens floor and signal lenses, full review after a tier rise, directive floors and Tier C cap, freeze cleared by fail/rewind, findings key, backlog pending close, narrower content exemption, no-worktree snapshots.
61. Round-2 review fixes (and round 3: strict `waive <LINE>` reply form, shipped-surface Markdown keeps Tier C, final ASK_HUMAN when a frozen round completes): review mode enforced (a brief taken before `risk-tier` says verify; `freeze --mode verify` refused after the rise; a verify-only Tier C fan-out cannot complete; a full Tier C round can), every Tier C content term checked against the override reason (one line each; signal lenses from all), plain-reply waivers accepted and refusals named, `ASK_HUMAN: pending` during an outstanding freeze, findings keyed by class and file:line with a mechanism list, Markdown-only content terms give Tier B, backlog `done --line --sha` without run state refused.

## Status changes

- 2026-10-07 — Accepted (apex-scope-loop v0.4.0)
- 2026-10-07 — Addendum A–K from a downstream fork's feedback, same release (v0.4.0, unreleased when added)
