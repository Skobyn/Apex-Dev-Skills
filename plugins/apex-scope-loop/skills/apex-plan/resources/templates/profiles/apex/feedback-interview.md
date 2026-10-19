# SCOPE interview — feedback prompt library

Use `AskUserQuestion` for each round. Send Round 0 (intent) and rounds 1–6 as separate questions (one per round) so the user can answer iteratively. The one exception is bugfix, which asks Rounds 1 and 3 as one combined question. Don't batch everything into one giant question — that loses signal.

## Rounds per scope

The plan's scope (`bugfix`, `poc` or `feature`, set with `start.sh --scope`) decides which rounds run. Each round heading below says which scopes run it. Round 0 (Intent) runs first and is not one of the numbered SCOPE rounds, so the counts below do not include it.

| Scope | Round 0 (Intent, not counted) | Rounds asked |
|---|---|---|
| `bugfix` | only if the user asks | 2 rounds: Round 1 (scope) and Round 3 (done means), asked as one combined question, then Round 6 (gate) |
| `poc` | yes | 4 rounds: Rounds 1, 2, 3 and 6 |
| `feature` (default) | yes | 6 rounds: Rounds 1 to 6 |

Skip the rounds a scope doesn't run. Don't ask them to fill the gap.

## Round 0: Intent

**Runs for**: poc, feature. Bugfix only if the user asks for it.

**Counts toward the 2/4/6 rounds?** No. Intent is a round-0 step before Round 1; the round counts above are the SCOPE rounds only.

**Question**: "In your own words: what is the problem, who is it for, why now, and what is this explicitly not trying to solve?"

**Header**: `Intent`

**Options** (free text; use "Other" for every answer, or one `AskUserQuestion` per heading below if the user prefers):
1. **Problem** — "What hurts today? One or two short paragraphs, no solution yet."
2. **Who it's for** — "Who feels it, and what do they do instead?"
3. **Why now** — "What changed, or what breaks if this waits?"
4. **Non-goals** — "What is out of bounds?"

**After the answer**: write the answers to `.claude/tasks/<slug>-intent.md`, following [intent-template.md](intent-template.md) (headings `## Problem`, `## Who it's for`, `## Why now`, `## Non-goals`). Do this *before* running `start.sh`. `start.sh` copies the `## Problem` text into the ADR's "Why this matters" section and never overwrites an existing intent file.

## Round 1: Scope

**Runs for**: bugfix, poc, feature

**Question**: "What's the smallest version of this that's still useful? What's explicitly out-of-scope for v1?"

**Header**: `Scope`

**Options** (single-select, with "Other" available):
1. **Minimal MVP** — "Just the core flow. No edge cases, no polish."
2. **Standard v1** — "Core flow + obvious extensions. Good defaults but not exhaustive."
3. **Comprehensive v1** — "Everything I can think of. We'll prune later if needed."
4. **Other** — user types their own framing

## Round 2: Constraints

**Runs for**: poc, feature (not bugfix)

**Question**: "What can't change? Things that are non-negotiable — existing data, partner contracts, auth boundaries, surface parity, perf budgets."

**Header**: `Constraints`

**Format**: Multi-select so the user can pick all that apply.

**Options**:
1. **No data migration** — existing Firestore/BigQuery shapes stay as-is
2. **No save/load flow changes** — `WebsiteBuilderPage.jsx` save/load is off-limits
3. **Surface parity** — every change must hit admin desktop, admin mobile, portal desktop, portal mobile
4. **Perf budget** — p99 latency cannot regress
5. **Auth boundary unchanged** — `authExcludedEndpoints` not modified
6. **Per-venue isolation** — no cross-venue data leakage
7. **Other** — user types

## Round 3: Success criteria

**Runs for**: bugfix (combined with Round 1), poc, feature

**Question**: "How will we know this shipped correctly? Try to make each criterion runnable — a test, a metric, a curl command."

**Header**: `Done means`

**Open-text via "Other"**. Provide examples as the option labels:
1. **Test suite green** — "pytest tests/{slug}/ passes"
2. **Metric threshold** — "p99 < X ms; conversion > Y%"
3. **User flow works** — "manager can do X end-to-end without console errors"
4. **All of the above** — combine the structured criteria

## Round 4: Ownership

**Runs for**: feature only

**Question**: "Who needs to sign off, and who's implementing? Affects how we wire approval gates."

**Header**: `Ownership`

**Options** (single-select):
1. **Solo** — you decide and implement; gates are auto-only
2. **You + reviewer** — partner reviews ADR before plan starts; gates include human checkpoints
3. **Cross-team** — multiple partners need to sign off at phase boundaries; gates include partner-email inbox notifications
4. **Other** — user types

Follow-up if option 2 or 3: ask for reviewer email address(es).

## Round 5: Execution preference

**Runs for**: feature only

**Question**: "When the plan runs, how should each phase dispatch work?"

**Header**: `Swarm mode`

**Options** (single-select):
1. **Hierarchical-mesh default** — 6-agent swarm per phase, queen-led (heaviest, best for complex work)
2. **Multi-agent default** — 2–3 parallel agents per phase, no queen (lighter, fast)
3. **Single agent default** — one specialist per phase (lightest, you stay close to the work)
4. **Per-phase override** — defaults to hierarchical, but I'll specify per-phase in the plan

The default flows to the plan's `Execution Strategy` section as the "no-override" behavior; individual phases can still override via the `Swarm:` line.

## Round 6: Gate preference

**Runs for**: bugfix, poc, feature

**Question**: "Between phases, should the system advance automatically or wait for me?"

**Header**: `Gate mode`

**Options** (single-select):
1. **Auto-only** — every gate is a runnable check; loop never waits for me
2. **Major gates human, minor auto** — phase transitions (1→2, 4→5) wait for me; intra-phase advances run
3. **Every gate human** — I explicitly approve each phase boundary
4. **Partner-gated where it matters** — phases that cross ownership boundaries notify a partner via inbox; others are auto

---

## Capturing answers

Record each answer in working memory. They go directly into:

- ADR sections **Context > Requirements**, **Context > Constraints**, **Context > Success criteria**
- Plan sections **Execution Strategy** (round 5), **Gate tags per phase** (round 6)
- ADR frontmatter **Reviewer** / **Implementor** (round 4)

If the user gives "Other" answers in their own words, paste their exact phrasing into the ADR. The point of co-authoring is they see their words on the page.

---

## Anti-patterns

- **Don't batch all 6 rounds into one question.** The user can't think clearly about scope and gates at the same time. One round per `AskUserQuestion` invocation. The bugfix exception is the combined Rounds 1 and 3 question.
- **Don't draft anything before round 6 completes.** Drafting too early signals "I've already decided" and disengages the user from the decision.
- **Don't accept vague success criteria.** If they say "the feature works," push back with "what command would you run to prove that?" until you get a check.
- **Don't skip round 4** even when the user is clearly solo. The act of saying "solo" out loud commits them to also being the reviewer, which informs gate-tag defaults.
