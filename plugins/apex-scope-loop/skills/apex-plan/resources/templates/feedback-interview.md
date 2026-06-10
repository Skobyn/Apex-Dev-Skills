# SCOPE interview — feedback prompt library

Use `AskUserQuestion` for each round. Send rounds 1–7 as separate questions (one per round) so the user can answer iteratively. Don't batch everything into one giant question — that loses signal.

## Round 1: Scope

**Question**: "What's the smallest version of this that's still useful? What's explicitly out-of-scope for v1?"

**Header**: `Scope`

**Options** (single-select, with "Other" available):
1. **Minimal MVP** — "Just the core flow. No edge cases, no polish."
2. **Standard v1** — "Core flow + obvious extensions. Good defaults but not exhaustive."
3. **Comprehensive v1** — "Everything I can think of. We'll prune later if needed."
4. **Other** — user types their own framing

## Round 2: Constraints

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

**Question**: "How will we know this shipped correctly? Try to make each criterion runnable — a test, a metric, a curl command."

**Header**: `Done means`

**Open-text via "Other"**. Provide examples as the option labels:
1. **Test suite green** — "pytest tests/{slug}/ passes"
2. **Metric threshold** — "p99 < X ms; conversion > Y%"
3. **User flow works** — "manager can do X end-to-end without console errors"
4. **All of the above** — combine the structured criteria

## Round 4: Ownership

**Question**: "Who needs to sign off, and who's implementing? Affects how we wire approval gates."

**Header**: `Ownership`

**Options** (single-select):
1. **Solo** — you decide and implement; gates are auto-only
2. **You + reviewer** — partner reviews ADR before plan starts; gates include human checkpoints
3. **Cross-team** — multiple partners need to sign off at phase boundaries; gates include partner-email inbox notifications
4. **Other** — user types

Follow-up if option 2 or 3: ask for reviewer email address(es).

## Round 5: Execution preference

**Question**: "When the plan runs, how should each phase dispatch work?"

**Header**: `Swarm mode`

**Options** (single-select):
1. **Hierarchical-mesh default** — 6-agent swarm per phase, queen-led (heaviest, best for complex work)
2. **Multi-agent default** — 2–3 parallel agents per phase, no queen (lighter, fast)
3. **Single agent default** — one specialist per phase (lightest, you stay close to the work)
4. **Per-phase override** — defaults to hierarchical, but I'll specify per-phase in the plan

The default flows to the plan's `Execution Strategy` section as the "no-override" behavior; individual phases can still override via the `Swarm:` line.

## Round 6: Gate preference

**Question**: "Between phases, should the system advance automatically or wait for me?"

**Header**: `Gate mode`

**Options** (single-select):
1. **Auto-only** — every gate is a runnable check; loop never waits for me
2. **Major gates human, minor auto** — phase transitions (1→2, 4→5) wait for me; intra-phase advances run
3. **Every gate human** — I explicitly approve each phase boundary
4. **Partner-gated where it matters** — phases that cross ownership boundaries notify a partner via inbox; others are auto

## Round 7: Default tier

**Question**: "What's the default compute tier for this project's phases? Each phase routes to a named phase-worker subagent that owns the model binding — cost varies roughly 30x between tiers."

**Header**: `Default tier`

**Options** (single-select):
1. **Standard (recommended)** — `phase-worker-standard`: feature work within one module; the safe default
2. **Light** — `phase-worker-light`: mostly bounded, mechanical tasks (≤2 files, no judgment); heavier phases override per-phase
3. **Heavy** — `phase-worker-heavy`: cross-module work, migrations, long autonomous runs; every heavy phase still needs a rationale line in the ADR tier table
4. **Per-phase only** — no project default; I'll assign every phase's tier explicitly during OPTIMIZE

The answer seeds the ADR's "Decision: Compute Tiers per Phase" section. Individual phases override via their row in the phase-assignment table, which compiles into per-task `Tier:` lines in the plan.

---

## Capturing answers

Record each answer in working memory. They go directly into:

- ADR sections **Context > Requirements**, **Context > Constraints**, **Context > Success criteria**
- Plan sections **Execution Strategy** (round 5), **Gate tags per phase** (round 6)
- ADR frontmatter **Reviewer** / **Implementor** (round 4)
- ADR section **Decision: Compute Tiers per Phase** > default tier (round 7)

If the user gives "Other" answers in their own words, paste their exact phrasing into the ADR. The point of co-authoring is they see their words on the page.

---

## Anti-patterns

- **Don't batch all 7 rounds into one question.** The user can't think clearly about scope and gates at the same time. One round per `AskUserQuestion` invocation.
- **Don't draft anything before round 7 completes.** Drafting too early signals "I've already decided" and disengages the user from the decision.
- **Don't accept vague success criteria.** If they say "the feature works," push back with "what command would you run to prove that?" until you get a check.
- **Don't skip round 4** even when the user is clearly solo. The act of saying "solo" out loud commits them to also being the reviewer, which informs gate-tag defaults.
