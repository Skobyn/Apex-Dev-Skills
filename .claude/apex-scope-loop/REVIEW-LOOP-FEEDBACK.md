# Review-loop feedback (input for the follow-up PR that loosens reviews)

Source: the apex-dispatch run, Phase 1.4 (`checkpoint.sh` provenance, `risk-tier`,
`land.sh`, and the clean-worktree check behind the green gate). That one Tier C task
took 10 attempts, 3 halts and about 58 recorded review rounds. Most rounds were
adversarial findings against `apex_dirty`/`inventory.py`. Each finding was real, but
each fix opened the next edge case.

## What made it slow

1. **The adversarial reviewer has no stopping rule.** Its brief is "try to break the
   claims". The attack surface (git's blind spots, filesystem semantics, attributes,
   Unicode, permissions) has no end, so a fresh adversary almost always finds one more
   input. Approval depended on the reviewer running out of ideas, not on a fixed bar.
2. **The scope was settled one finding at a time.** Questions like "is ignored content
   in scope?", "are committed-ignored files in scope?" and "what does 'unmodified'
   mean?" were each decided only after a reviewer hit them, and each answer cost a
   round. A threat model written before the first review would have removed about
   half the rounds.
3. **The trust model was never stated.** Almost every blocking finding assumed the
   implementing agent plants files in its own worktree to fake a green gate. If the
   harness trusts its own agent to be non-malicious and guards only against accidents
   (stale files, caches, leftover directories), most of these findings are
   non-blocking. That is the biggest lever.
4. **Every round re-attacked the whole surface.** After each fix, the adversary started
   from scratch rather than checking the fix and its blast radius. New findings in old
   code kept appearing in late rounds.
5. **The failure budget does not count progress.** "3 consecutive failures → HALT" fired
   three times, although every failed attempt fixed real bugs. The counter cannot tell
   "stuck" from "converging slowly".
6. **Tier C was over-applied.** The classifier raised the task on a content signal
   (`stripe` appearing in smoke fixtures and token lists). Test data that names
   sensitive tokens inflates the tier, and Tier C is what brings in the adversarial
   pass and G12.

## Suggested changes

- **Write the threat model before review.** Each Tier C task (or its ADR) states the
  trust model, in-scope actors and out-of-scope classes before round 1. Reviewers get
  it verbatim, and findings outside it are automatically non-blocking.
- **Use a severity bar for "blocking".** Blocking means a realistic actor under the
  stated trust model can do it. Contrived inputs that need deliberate tampering by the
  trusted agent go to a hardening backlog unless the human promotes them.
- **Diff-scope re-reviews.** Round N > 1 verifies the previous findings' fixes and the
  changed code's blast radius. A full fresh adversarial pass happens once per attempt,
  not once per round.
- **Give the adversary a budget.** For example, at most K blocking findings per pass,
  ranked by severity. Or one adversarial pass per task, after which residual findings
  go to the human as accept-or-fix.
- **Escalate to the human earlier.** After about 2 blocking findings in the same
  component, ask the human whether to accept the residual risk, rather than looping.
- **Make halts progress-aware.** Reset or soften the consecutive-failure count when the
  failing attempt closed findings from the previous one, or count stalls (the same
  finding class twice) instead of failures.
- **Keep a hardening backlog.** Non-blocking findings are written to a per-plan backlog
  file that the next phase's docs task consumes, not carried in the orchestrator's
  memory.
- **Calibrate the classifier.** Ignore content signals that appear only in test
  fixtures, smoke files or string lists, or weight them down. Let the plan's
  `[tier:x]` tag be authoritative unless the diff touches the named surfaces.

## Design lessons worth keeping (see LESSONS.md L-004, L-005)

- When a check has to prove "nothing hidden", make it a positive inventory: walk the
  real tree and require each entry to be accounted for. Do not enumerate the ways git
  can hide something. Each enumerated exception became a review round.
- Make it positive on every axis, both presence and content. Byte-compare tracked files
  rather than trusting `git status` plus an allowlist of attributes.
