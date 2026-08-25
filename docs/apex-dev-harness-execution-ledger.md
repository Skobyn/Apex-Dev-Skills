# SDD ledger — plan: docs/superpowers/plans/2026-08-24-apex-dev-harness.md

Spec: docs/superpowers/specs/2026-08-24-apex-dev-harness-design.md (read; binding authority)
Branch: feat/apex-dev-harness (base de77c6f)

## Ruling: branch, not worktree
The plan's Global Constraints pin ABSOLUTE paths
(/mnt/c/Dev/Apex-Dev-Skills/harnesses/apex-dev-harness) and every task's
verification command targets the live repo at /mnt/c/Dev/Apex-APP-SW/apex-app.
A worktree relocates the package root, so every absolute path in the plan
would point at the wrong tree.
Ruling: execute on branch feat/apex-dev-harness in the main checkout.
Cost if wrong: work is on a branch rather than an isolated worktree; main is
untouched and the branch can be deleted. Low.

## Pre-flight scan — cross-task interface pairs

| Pair | Produces -> consumes | Finding |
|---|---|---|
| T1 -> T2,3,4,5,6,7,9,10,11,12,13 | types.ts (all types), repo.ts (findRepoRoot, truthPaths, normalize) | clean — one definition site, imported unchanged |
| T2 -> T6,7,11 | loadLanes/laneFor/importAllowed | clean |
| T3 -> T6,11 | loadLedger/surfaceFor | clean |
| T4 -> T6,7,8,9,10,11 | loadPolicy/DEFAULT_POLICY/rulesInScope + templates/policy.json | clean |
| T5 -> T6,9 | matchesGlob | clean |
| T6 -> T12,13 | route/formatRoute | FINDING 1 (below) |
| T7 -> T12,13 | check | clean |
| T8 -> T10,11 | scanWatchlist | clean |
| T9 -> T10 | changedPaths/obligationsFor/parityWarningsFor | clean |
| T10 -> T11,13 | gate/formatGate/runCommand | clean |
| T11 -> T12 | templates/apex-hook.js stub, rewritten by T12 | intentional; T12 declares Rewrite |
| T11 -> T13 | bin/apex.js `mcp` case imports dist/mcp/server.js | deferred import; T11 tests never invoke it. Acceptable. |
| T13 -> T11 | @modelcontextprotocol/sdk added in T13 | T11 has no SDK dependency. clean |
| T14 -> repo root | test path ../../.. resolves to Apex-Dev-Skills | verified correct |

## Pre-flight scan — per-task self-consistency

T1 clean · T2 clean (fixture supplies legacy+experimental+production) ·
T3 clean (fixture excerpt covers the vocabulary table + all five statuses) ·
T4 clean · T5 clean · T6 FINDING 1 · T7 clean · T8 clean ·
T9 clean (policy patterns match every asserted path) · T10 clean ·
T11 FINDING 2 · T12 clean · T13 clean · T14 clean · T15 clean

## FINDING 1 (Task 6) — route() emits a guard note for every file
route() pushes "<ns> is guarded" whenever importAllowed() is false, which is
true for EVERY file that is not a grandfathered importer. Every routed path
would carry noise about namespaces it never imports. route() has no file
content, so it cannot know whether an import exists.
Ruling: emit ONLY the grandfathered-importer note. Drop the generic
"is guarded" branch. The block-tier LANE-IMPORT check in T7 sees content and
is the right place to refuse a new import.
Cost if wrong: route output omits a general warning that a namespace is
guarded; the authoritative guard (pytest tools/repo-lanes/tests/) still runs
in the gate. Low.

## FINDING 2 (Task 11) — doctor() fails on a missing truth file
doctor() calls fail() for a missing ledger or lanes.json, setting ok=false,
so the CLI exits 1. The Task 11 fixture has no ledger, so the test
"doctor reports the repo it found" would exit 1 and throw. This also
contradicts the spec's binding rule: a missing or unparseable truth file
warns, never hard-fails.
Ruling: doctor() warns on a missing/unparseable truth file and keeps ok=true.
fail() is reserved for "no apex-app checkout found". Spec is the authority.
Cost if wrong: `apex doctor` exits 0 in a repo missing a truth file; the
warning still names the file, and route/gate degrade visibly. Low.

## Execution
Task 1: implementer DONE (commits de77c6f..b379cf4, 5/5 tests). Task review dispatched.
Task 1: review clean (spec OK, quality approved). Controller resolved all 3 "cannot verify" items: skeleton dirs present, typescript installed, 5/5 tests pass on independent run.
Task 1: minor (deferred): test/repo.test.js:9-24 assumes no ancestor of the OS temp dir contains tools/repo-lanes/lanes.json (brief-authored).
Task 1: minor (deferred): test/repo.test.js:26-34 unconditionally deletes APEX_REPO_ROOT in finally, clobbering a pre-existing value if CI sets one (brief-authored).
Task 1: complete (commits de77c6f..b379cf4, review clean)
Task 2: implementer DONE (commits b379cf4..24d442b, 14/14 tests; live repo: 54 modules, 3 guards, funnel_builder=legacy). Task review dispatched.
Task 2: Ruling: reviewer's Important finding (laneFor prefix match lacks a directory-boundary check) is PLAN-MANDATED — the plan's Step 4 code is exactly `p === prefix || p.startsWith(prefix)`. Verified latent today: all 54 live module paths end in '/' and no risky prefix pairs exist. Fixing anyway because laneFor feeds the block-tier LANE-RETIRED rule, so a wrong lane becomes a FALSE BLOCK, which the plan itself names the worst failure this harness can produce. Spec mandates longest-prefix matching, not the specific buggy form, so the spec (binding authority) is satisfied by the fix.
  Cost if wrong: a few lines diverge from the plan text and one extra test exists. Negligible.
Task 2: fix round 1/5 dispatched (1 Important: prefix boundary).
Task 2: fix round 1/5 (1 addressed, 0 open — laneFor directory boundary; commits 24d442b..cfa3817)
Task 2: complete (commits b379cf4..cfa3817, review clean, 15/15 tests)
Task 3: implementer DONE_WITH_CONCERNS (commits cfa3817..67b6e90, 23/23; live ledger 106 rows {STUDIO:52 DUAL:23 LEGACY:16 RETIRED:12 OOS:3} — matches plan exactly).
Task 3: Ruling: implementer diverged from the brief's surfaceFor by adding an `r !== '/'` guard. ACCEPTED. Verified 2 live rows carry a bare '/' route (Home dashboard, Apex Studio itself); without the guard EVERY route query prefix-matches one of them, which violates the spec's binding "null means no-row, never a guess" rule. The fix is minimal: exact `q === r` still resolves '/'; only prefix-matching on '/' is disabled.
  Cost if wrong: a query for the literal route '/' still resolves; only prefix descent from '/' is lost. Low.
Task 3: Ruling: route-less count is 34, not the plan's stated ~9. Investigated: the parser is CORRECT. Sampled rows (Operator Inbox, Instagram channel, Business profile "no legacy twin", Corporate-event targeting) are Studio-born surfaces with no URL route at all. The plan's ~9 came from the controller's crude pre-flight grep that counted any backtick/slash as a route. Expectation corrected, code unchanged.
  Cost if wrong: none to code; the doctor output will report 34 route-less rows as name-matchable only, which is accurate.
Task 3: Ruling: reviewer's Important finding (a surface literally named "Studio" is silently dropped by the STATUSES name-collision guard, creating an undocumented third outcome) is PLAN-MANDATED — the controller's plan wrote that guard. Fixing. Verified the live doc has a real `## Status vocabulary` heading whose table is 3 cells wide, so a SECTION-based skip is precise and makes the name-collision guard unnecessary. This removes the silent-drop path rather than documenting it, which is what the "no-row vs unparseable must never collapse" constraint demands.
  Cost if wrong: if a future ledger renames that heading, vocabulary rows could parse as surfaces — but they are 3 cells wide and the cells.length<4 filter still excludes them. Low.
Task 3: fix round 1/5 dispatched (1 Important: silent row drop; 1 Minor: misleading comment, fixed with it).
Task 3: fix round 1/5 (2 addressed, 0 open — section-based vocab skip + comment; commits 67b6e90..607624c)
Task 3: complete (commits cfa3817..607624c, review clean, 24/24 tests, live parse 106 rows unchanged)
Task 4: implementer DONE (commits 607624c..044dbb6, 33/33).
Task 4: Ruling: PLAN DEFECT found by the implementer, not by my pre-flight scan (which wrongly marked T4 self-consistent). The brief's BOUND-001 note text contained the literal string "ui/src/agentic/" while the brief's own test asserts that string appears nowhere in the policy — the plan contradicted itself. ACCEPTED the implementer's minimal rewording ("The UI agentic directory it protected no longer exists"), which preserves the meaning and the 2026-07-05 date the other assertion needs. Verified: literal string absent, tier historical, scope backend/agentic/.
  Cost if wrong: the note is one sentence less literal about which directory is gone. Negligible.
Task 4: Ruling: reviewer's Important finding (spread `{ok:true, ...JSON.parse(raw)}` lets a valid-but-incomplete policy.json yield undefined fields, so the first consumer of rulesInScope throws TypeError) is PLAN-MANDATED and REPRODUCED by the reviewer. Reviewer suggested deferring it to a later task's brief; I am OVERRIDING that and fixing it in Task 4. Reasons: (a) it directly violates the spec's binding "fail open, always" rule — a partial policy must degrade, never crash; (b) Task 4 owns loadPolicy and seven later tasks consume it, so deferring means seven tasks building on a known crash path. Fix is a field-wise fallback to DEFAULT_POLICY instead of a bare spread.
  Cost if wrong: a partial project policy silently inherits default rules/obligations rather than failing loudly. That is the documented fallback behavior already, so the risk is low.
Task 4: fix round 1/5 dispatched (1 Important: partial-policy undefined fields).
Task 4: fix round 1/5 (1 addressed, 0 open — field-wise policy fallback with ??; commits 044dbb6..b12dbf6)
Task 4: complete (commits 607624c..b12dbf6, review clean, 35/35 tests)
Task 5: review clean (spec OK, quality approved, no Critical/Important). Controller resolved the one "cannot verify" item: normalize() behavior was verified under Task 1 review (forward slashes + strips leading ./).
Task 5: minor (deferred): test/glob.test.js exercises Windows separators only in the path, never in the pattern; pattern-side normalization is implemented but untested.
Task 5: minor (deferred): no test documents that a trailing `**` pattern does not match the bare directory string (correct behavior, undocumented).
Task 5: complete (commits b12dbf6..cc5259f, review clean, 41/41 tests)
Task 6: implementer DONE (commits cc5259f..2414c2c, 48/48; controller ruling applied — generic "guarded" note dropped; live checks held).
Task 6: Ruling: SPEC DEFECT, load-bearing. The implementer observed that a FILE-PATH query returns surface `no-row` because the ledger keys on ROUTE paths. I verified this is structural: the ledger's Routes column contains ZERO source file paths (grep count 0), so file -> surface can never resolve by route match. This breaks (a) the spec's own flagship example, which shows `apex route ui/src/marketing/CampaignCockpit.jsx` resolving to "Marketing zone - Campaigns - DUAL", and (b) Task 12's post-tool-use hook, whose STUDIO warning routes an edited FILE and would be permanently dead code.
  Ruling: add `surfaceHints` (file glob -> exact ledger surface NAME) to policy.json; route() consults it ONLY when the direct route/name lookup misses, and resolves the hint through the existing name-match path. This is curated data, not a guess: an unmatched file still returns no-row, and a hint naming a surface the ledger does not contain still returns no-row. Precedent: skillRules and parityRules are already file-glob -> value maps in policy.json. Seeded with 6 name-verified entries; the list is designed to grow.
  Cost if wrong: policy.json carries a mapping table that must be maintained as surfaces move. If a hint goes stale it degrades to no-row (the safe outcome), never to a wrong status. Moderate-low.
Task 6: fix round 1/5 dispatched (1 load-bearing spec gap: file -> surface hints).
Task 6: fix round 1/5 (1 addressed, 0 open — surfaceHints file->surface resolution; commits 2414c2c..39252ab). Controller independently re-verified: tsc clean, 51/51 (re-reviewer had only run the route suite).
Task 6: complete (commits cc5259f..39252ab, review clean, 51/51 tests)
Task 7: implementer DONE (commits 39252ab..1d07e70, 62/62). Controller probed LANE-IMPORT against realistic content: comments, prose strings, and similarly-named variables all ALLOW; a genuine ES import BLOCKs. No false positive reproduced. One false NEGATIVE found: CommonJS require("../quizBuilder/api") is not caught — errs in the SAFE direction (authoritative check is pytest tools/repo-lanes/tests/, which the gate runs).
Task 7: Ruling: reviewer reported 2 Critical + 2 Important false-block risks. Controller REPRODUCED ALL FOUR empirically — 6 of 7 realistic non-violating edits were blocked. All are PLAN-MANDATED (the controller's own Step 3 code). Fixing all four; this is the only module that can stop a developer working, and the plan's binding rule is that a false block is the worst failure this harness can produce.
  Evidence from source documents:
   - CONV-PROJECTDATA: CLAUDE.md reads "never read it, never write it (writers clear it to ...)" — so a CLEAR is explicitly sanctioned by the very document the rule cites. Blocking it contradicts the rule's own source.
   - BOUND-005: apex-app commits no .env.example and .gitignore covers .env.*; allowing the example/sample/template variants removes a false block at negligible risk, since such files contain no secrets by definition.
   - BOUND-002: a key NAME constant and a docs URL assigned to a token-named variable both blocked.
   - BOUND-004: an `import anthropic` line inside a Python docstring blocked, because the regex is line-anchored with /m.
  Ruling: strip comments/docstrings before content matching; add value-shape exclusions to the credential detector; allow dotenv example variants; narrow the projectDataJson rule to genuine reads/writes, permitting a clear.
  Cost if wrong: the block tier becomes more permissive, so a real violation may slip to CI instead of being refused at the edit. That is the safe direction and CI remains authoritative.
Task 7: fix round 1/5 dispatched (2 Critical + 2 Important false-block risks).
Task 7: fix round 1/5 (4 findings addressed, 1 new open: original check test #2 now fails; commits 1d07e70..fd75214).
Task 7: Ruling: the failing original test is a BAD FIXTURE, not a code regression. Its credentialSample() was 24 literal 'x' characters, which contains "xxxx" and is genuinely placeholder-shaped — exactly what looksNonSecret() is designed to permit, since committing a placeholder is not a credential leak. The heuristic is correct; the fixture was unrealistic. Ruling: replace the fixture with a realistic high-entropy sample (still assembled by concatenation, never a literal). Implementer correctly reported rather than editing it.
  Cost if wrong: a real secret that happens to contain "xxxx" would not be blocked at edit time. CI and apex-app's own hook remain authoritative. Low.
Task 7: fix round 2/5 (1 addressed — realistic fixture; commits fd75214..baaa6dc). Re-review: all 5 prior findings ADDRESSED, block tier NOT hollowed out (real credential, real provider import, real projectDataJson write all still refused). 3 NEW findings, all reproduced by controller:
  (C) object-literal clear `{ projectDataJson: "" }` still FALSE-BLOCKED — clearsOnly regex requires `=`, missing the `:` form. False block = top priority.
  (B) NON_SECRET_NAME_RE exempts _ID/_HEADER/_PREFIX/_FIELD, so a real secret in AUTH_HEADER or CLIENT_SECRET_ID is allowed by NAME alone regardless of entropy. CONTROLLER'S OWN ERROR — I wrote that suffix list in the round-1 fix instruction, going beyond the _NAME/_URL I had ruled.
  (A) a protocol-relative URL string ("//cdn...") makes the // comment rule blank the rest of the line, masking a same-line violation. A miss, not a false block — safe direction, but cheap to fix.
Task 7: Ruling: fix all three in round 3. C restores correctness in the false-block direction; B reverses my own over-broad instruction; A tightens the comment guard so it cannot eat real code.
  Cost if wrong: minimal — each change is narrow and the "STILL blocked" tests pin the real violations.
Task 7: fix round 3/5 dispatched.
Task 7: fix round 3/5 (3 addressed, 1 new open; commits baaa6dc..c76ee70, 75/76).
Task 7: Ruling: the failing test 22 is MY BAD TEST, not a code gap. I asserted AUTH_HEADER = "Bearer sk-live-..." must block, but "AUTH_HEADER" contains no SECRET_NAME keyword, so CREDENTIAL_RE never matches and NON_SECRET_NAME_RE (which only gates already-matched names) cannot reach it. The rule is name-anchored by design. Fix the TEST to use a name that does contain a keyword (AUTH_TOKEN_HEADER), which genuinely exercises the _HEADER narrowing.
  Residual design gap accepted and deferred: a secret in a variable whose name contains no secret-ish keyword is not detected at edit time. That is inherent to a name-anchored rule; apex-app's own block-sensitive-files hook and CI remain authoritative.
Task 7: Ruling: round 4 resumes the SAME implementer rather than escalating to a fresh, more capable one as the loop's default prescribes. The escalation rule exists for an implementer that cannot see its own problem; this one precisely root-caused my faulty test and declined to patch around it. A fresh agent would lose that context for a one-line test change.
  Cost if wrong: one more round on the same model. Negligible.
Task 7: fix round 4/5 dispatched (1 bad test fixture).
Task 7: fix round 4/5 (1 addressed, 1 open; commits c76ee70..6aca65e, 76/77). Implementer's verification was rigorous: restored _HEADER to the pattern, saw test 22 fail identically either way, proving the id-named test is what exercises the narrowing.
Task 7: Ruling: test 22 fails for a SECOND flaw in my own test, again not a code regression: OPAQUE_VALUE requires 16+ NON-WHITESPACE chars, and my sample value "Bearer sk-live-..." contains a space, so CREDENTIAL_RE never matches whatever the name is.
  Considered widening OPAQUE_VALUE to admit internal whitespace so that a real `TOKEN = "Bearer <secret>"` would be caught. REJECTED: that would make any long prose string assigned to a secret-named variable (e.g. SECRET_MESSAGE = "a long sentence ...") look like a credential, reintroducing exactly the Critical false-block class rounds 1-3 removed. False block remains the worst failure.
  Ruling: correct the test to a whitespace-free value, and PIN the "Bearer <token>" miss as a documented limitation with its own test, so any future widening is a deliberate decision that breaks a test rather than a silent change.
  Cost if wrong: a credential written as "Bearer <token>" is not refused at edit time. apex-app's own block-sensitive-files hook and CI remain authoritative. Accepted.
Task 7: fix round 5/5 dispatched (final round before the breaker).
Task 7: fix round 5/5 (2 addressed, re-review raised 2 NEW). BREAKER TRIPPED — adjudicating each open finding.

Task 7: Ruling (BREAKER, load-bearing): re-reviewer reported a Critical false block via BOUND-004 for a comment abutting a closing quote. Controller tested: that exact claim does NOT reproduce — PROVIDER_IMPORT_RE is line-anchored, so a mid-line `import` never matched. But the underlying stripping failure IS real, and it false-blocks the two rules that are NOT line-anchored: `const X = "u"// never touch projectDataJson` -> BLOCK [CONV-PROJECTDATA], and the same shape with a credential -> BLOCK [BOUND-002]. So the finding is valid with a corrected mechanism.
  Load-bearing: Task 12's PreToolUse hook calls check() directly, so a false block here wedges a developer's editor.
  Ruling: REVERT round 3's `//` guard tightening, from (^|[^:"'`]) back to (^|[^:]). The two options trade one risk for the other: the tightened guard avoids a masking MISS on a protocol-relative URL but introduces a FALSE BLOCK on a quote-abutting comment; the original does the reverse. A false block is the worst failure this harness can produce, so the miss is the correct side to land on. One character-class change, strictly moving residual risk to the safe direction.
  Cost if wrong: a string containing "//" can mask a same-line violation, which CI and apex-app's own hook still catch. Accepted.

Task 7: parked — widened clearsOnly permits a genuine READ when an unrelated key on the same line holds "" (e.g. {"a": row["projectDataJson"], "b": ""}). Ruling: real, but a MISS not a false block, and narrower than the pre-fix behavior that blocked clears outright. Not load-bearing. Deferred to the final review.
Task 7: parked — the name-anchored limitation test is a WEAK PIN: its value also contains a space, so it is exempt for two reasons and would not flip if only the name side were widened. Ruling: real but cosmetic; the whitespace pin next to it is strong. Deferred to the final review.
Task 7: breaker ruling applied (commits 2d0ba98..20fbc11, 79/79). Confirmed: quote-abutting comment now ALLOWs (false block fixed); the accepted masking miss behaves as predicted; the multi-line protocol-relative + import case still BLOCKs.
Task 7: complete (commits 39252ab..20fbc11, 79/79 tests, 5 fix rounds + breaker, 2 parked)
Task 8+9: Ruling: BATCHED into one dispatch. Both are small, fully-specified, independent pure modules (watchlist scan; obligations/parity computation) whose briefs carry complete code, and neither depends on the other — only Task 10 consumes both. One dispatch and one combined review instead of two full cycles.
  Cost if wrong: a finding in one module is reviewed alongside the other's diff, slightly reducing focus. Low; both modules are small.
Task 8: complete (commit bfa3d99, review clean, 84/84)
Task 9: complete (commit 3b4f345, review clean, 92/92). Controller independently confirmed tsc clean (reviewer had not re-run it). Reviewer verified: watchlist `break` exits the line loop only; hyphenated "band-aid" matches correctly (- is not a metacharacter); changedPaths try/catch is inside the git() helper so a first-command failure does not discard staged changes.
Task 9: minor (deferred): the brief's "term inside a longer word" test uses "the informant reported", which does not actually stress the guard since no default term is a substring of "informant".
Task 10: implementer DONE (commit b957623, 100/100). Review: spec OK, quality approved with 1 Important + 3 Minor.
Task 10: Ruling: fixing the Important (formatGate lists all obligation headers, then a flat command list, so a reader cannot tell which command belongs to which obligation) and the Minor mis-wording ("5 obligation(s) unmet" when there were 2 obligations, 3 failed commands, 2 watchlist hits). Both are PLAN-MANDATED — my own brief code. Fixing because this output IS the deliverable a developer reads when the gate refuses to close a phase; an unattributable failure list makes the gate harder to act on than the raw commands.
  Cost if wrong: presentation-only change; verdict logic untouched. Negligible.
Task 10: Controller resolved the reviewer's "cannot verify" item: the default policy does match backend/app/routes/studio_chat.py and ui/src/** — proven by Task 9's obligations tests and the rendered gate sample naming the studio-capability-manifest and lane-import-guards obligations.
Task 10: fix round 1/5 (2 addressed, 0 open — grouped gate output + precise unmet wording; commits b957623..4585302)
Task 10: complete (commits 3b4f345..4585302, review clean, 103/103 tests)
Task 11: complete (commits 4585302..a748b7e, review clean, 111/111). Controller ruling (doctor warns instead of failing on a missing truth file) verified applied to both branches. Controller ran doctor against live apex-app: result ok, exit 0, 54 modules, 106 rows, all 4 wrapped commands found. Exit-code contract verified by reviewer: check 1 on block, gate 1 when not ok, doctor 1 only when no repo, unknown verb 2, only mcp returns null to stay alive.
Task 11: minor (deferred): --paths splits on commas, so a path containing a literal comma would be mis-split.
Task 11: minor (deferred): the watchlist verb calls loadPolicy('.') when no repo is found, so an unrelated ./.harness/policy.json in cwd would be read as truth.
Task 11: minor (deferred): two brief-authored CLI tests do not wrap rmSync in finally, leaking a temp dir if an assertion fails.
PHASE A COMPLETE — engine + CLI working end to end against the live repo.
Task 12: implementer DONE (commit 979ea8a, 120/120). Controller drove the real hook against the LIVE apex-app repo across every path: ordinary edit -> {}, dotenv write -> deny naming BOUND-005 and its source doc, garbage stdin -> {}, missing file_path -> {}, ENGINE MISSING -> {} (fails open, the incident-critical case), post-tool-use -> {} (never blocks). Protocol held on all seven: exactly one JSON object, always.
Task 12: NOTE (not a defect): a retired-lane edit returned {} in that probe. Investigated — the code is correct and my expectation was wrong: ui/src/menuDesigner/ is lane LEGACY in the live registry, not retired ("flip to retired when pages/MenuDesignerPage.jsx goes too"). Legacy means do not build new features there, not do not touch.
Task 12: FINDING for the final review / integration PR: the live lanes.json has ZERO retired modules today (48 production, 4 legacy, 2 experimental), so the LANE-RETIRED block rule cannot fire against apex-app as it stands. The rule is correct and tested against fixtures; it simply has no live target yet. Worth stating plainly in the integration PR so nobody assumes it is exercised in production.
Task 12: Ruling: reviewer found 3 real issues; fixing all. The lead one is LOAD-BEARING and could not have been caught by any evidence I gathered:
  (1) WINDOWS STDOUT RACE — emit() does process.stdout.write() then process.exit(0). Node's stdout is synchronous on POSIX but ASYNCHRONOUS on Windows, so exit can fire before the write flushes, yielding empty stdout — precisely the 2026-07-04 Cursor incident, reintroduced on the one platform this task exists to fix. Every test and every controller probe ran on WSL (synchronous), so all my evidence is silent on this. Fix: stop calling process.exit; set process.exitCode and let Node flush and exit naturally.
  (2) toRelative prefix strip is case-sensitive, so a drive-letter case mismatch (c:\ vs C:\) leaves an absolute path that matches no lane. Fix: compare case-insensitively.
  (3) STUDIO advisory uses includes('apexStudio'), a substring match that would also suppress on ui/src/apexStudioUtils/**. Fix: segment match. Minor — stderr advisory only.
  Reviewer also CLEARED my file:// concern by executing it: new URL('file://C:/...') normalizes to file:///C:/... per the WHATWG drive-letter rule, so the Linux result is valid evidence for Windows there.
  Cost if wrong: (1) is strictly safer than the status quo. (2) and (3) only widen correct matching. Low.
Task 12: fix round 1/5 dispatched (1 load-bearing Windows race + 2 platform-correctness issues).
Task 12: fix round 1/5 (3 addressed, 0 open — Windows flush race, case-insensitive root strip, segment-match STUDIO advisory; commits 979ea8a..8db6c46). Implementer independently caught that my case-sensitivity test was a no-op (BOUND-005 matches basename only) and rewrote it against LANE-RETIRED with fail-before/pass-after verified. Re-reviewer traced every branch: exactly one stdout write per invocation, no double-write, no new hang risk, exitCode 0 on all paths.
Task 12: complete (commits a748b7e..8db6c46, review clean, 123/123 tests)
Task 13: implementer DONE (commit 9b86dd7, 127/128; live MCP tools/call for CampaignCockpit returned DUAL, byte-for-byte matching the CLI). Reported 1 environment-dependent failure.
Task 13: Ruling: controller reproduced and found it WORSE than reported — the suite fails 1 test with APEX_REPO_ROOT unset and 3 with it set (repo.test.js's own root-discovery tests break when the env override is inherited). Root cause: tests mutate process.env.APEX_REPO_ROOT and DELETE it unconditionally in finally instead of saving and restoring, and some tests assume the ambient value is absent. Four test files touch it.
  This is a real defect, not an environment quirk: a suite whose result depends on the developer's shell is unreliable, and it will bite in CI where the variable may or may not be set. It also matches the Task 1 minor I deferred earlier (same unconditional-delete pattern), so it is now a recurring problem worth fixing at the root rather than deferring again.
  Ruling: fix with a save/restore helper across all four test files, and make repo.test.js's discovery tests explicitly clear the override for their duration rather than assuming it is unset.
  Cost if wrong: test-only change; no production code touched. Negligible.
Task 13: fix round 1/5 dispatched (environment-dependent test suite).
Task 13: fix round 1/5 (1 addressed, 0 open — withRepoRoot save/restore; commits 9b86dd7..1234b91). Controller verified 128/128 with AND without an ambient APEX_REPO_ROOT. Reviewer independently confirmed the implementer's scoping argument (cli/hook tests only build per-child env objects and never mutate parent env), so the narrower fix is complete.
Task 13: review clean. Reviewer traced into the MCP SDK to confirm a thrown handler error becomes a JSON-RPC error response rather than crashing the server, and confirmed runCommand pipes child stdio so apex_gate cannot pollute the protocol stream.
Task 13: minor (deferred): CallToolRequestSchema wraps all tool failures as protocol-level McpErrors rather than {isError:true} tool results, which obscures failure detail from the calling model. Brief-authored.
Task 13: complete (commits 8db6c46..1234b91, review clean, 128/128 tests)
Task 14: implementer DONE (commit 98050dc, 132/132; marketplace preserved, all 5 load-bearing lines verbatim, status.md --paths edge cases traced to a graceful warning).
Task 14: Ruling: reviewer found a CRITICAL contradiction, and it is MY brief's defect. /apex:status is documented "read-only ... without running the wrapped commands", but it calls `apex gate --paths ...`, and gate() has NO dry-run path (src/gate.ts:45 unconditionally executes every obligation command). Controller confirmed in source. So an advertised read-only status check silently runs pytest whenever the working diff is non-empty.
  Ruling: add a real `--dry-run` to gate (compute obligations, parity and watchlist WITHOUT executing commands) and have status.md use it. Rejected the alternative of just rewording status.md: the honest capability is genuinely useful — "what would this owe?" is the question a status command should answer — and a doc-only fix would leave the engine unable to answer it.
  Cost if wrong: one new flag and a plumbed option; the default path is untouched, so nothing that passes today changes behavior.
Task 14: Ruling: reviewer also found build.md's triviality paraphrase drops a disjunct. Confirmed against plugins/apex-plan-loop/.../SKILL.md:21, which reads "≥ 3 phases, ≥ a day of effort, or touches more than one bounded context". My paraphrase omitted "≥ a day of effort", so an agent could skip planning for a single-phase task that genuinely warrants it. Fixing the wording to match the source skill.
  Cost if wrong: none — it restores the criteria the referenced skill actually states.
Task 14: fix round 1/5 dispatched (1 Critical read-only contradiction + 1 Important paraphrase drift).
Task 14: fix round 1/5 (2 addressed — real gate --dry-run + build.md criteria; commits 98050dc..bf8e2aa, 135/135). Controller timed the live dry-run at 3.0s real / 2.9s sys — the implementer's >120s observation was cold-cache filesystem cost on WSL/NTFS, not dry-run logic. Verified output lists 2 obligations with no PASS/FAILED lines, i.e. nothing executed.
Task 14: parked — `apex gate --dry-run` exits 0, so a script doing `apex gate --dry-run && echo PASSED` could misread it as a passing gate. Ruling: NOT fixing. (a) Machine consumers already get an unambiguous signal — controller confirmed --json emits dryRun:true with results:[]. (b) The misuse requires someone to deliberately pass --dry-run and then treat it as a boolean gate, ignoring both the flag they typed and the JSON field. (c) Changing the exit code has a concrete downside: status.md invokes it via a slash-command shell call, where a non-zero exit would render as a failed command on every normal use. The verdict text says DRY RUN and USAGE says "lists what is owed without running it".
  Cost if wrong: a hand-rolled script could misread the exit code. Deferred to the final review.
Task 14: complete (commits 1234b91..bf8e2aa, review clean, 135/135, 1 parked)
Task 15: complete (commit 23d55e1, 135/135, scratch install verified, real gate run honestly reported a PRE-EXISTING apex-app failure).
FINAL WHOLE-BRANCH REVIEW: 3 Critical, 5 Important. Controller verified the three Criticals independently:
  C1 CONFIRMED — apex-dev-harness is absent from apex-app/node_modules, so the hook's import('apex-dev-harness/dist/...') throws and fails OPEN, while the PR deletes six working .ps1/.cmd files. Merging as written would turn all guardrails off everywhere, silently.
  C2 CONFIRMED — post-tool-use runs neither the style check nor the manifest check that the .ps1 pair it supersedes performs. The spec's hook table mandates both.
  C3 CONFIRMED and QUANTIFIED — 110 status-bearing rows exist outside the vocabulary table; the parser returns 106 and emits ZERO warnings. 4 live rows are silently dropped: a genuine 3-column staff-portal table (cells.length<4) and a row with escaped pipes (line 343). Each renders as "no row — add the row, don't guess", pinning a wrong diagnosis on the repo. This is the no-row/unparseable collapse the spec forbids.
  Ruling: ONE fix wave covering C1-C3 plus the three cheap high-value Importants (MultiEdit content, untracked files, governedRoots). Reviewer's re-opened Task 3 ruling is accepted: my "parser is CORRECT" conclusion was right about what it parsed and never asked what it dropped.
FINAL FIX WAVE: all 6 findings ADDRESSED (commit 28ea8c4, 146/146; ledger 110/110 parsed, 0 dropped; doctor emits the engine-not-installed warning). Re-review: SOUND, no Critical. 3 Important + 4 Minor residual.
Ruling (residuals): 3 of them are LOAD-BEARING and each is a one-line change, so I am ruling on the smallest change rather than surfacing them unfixed:
  (1) hook timeout 120000ms EXCEEDS Claude Code's 60s default per-hook timeout, so the platform would kill the hook first -> EMPTY STDOUT -> the exact 2026-07-04 Cursor false-block this file's own header exists to prevent. Verified the value at templates/apex-hook.js:106. Measured cost: style check ~30ms, manifest check 3.0s, so 10s is ample. Shipping a knowing reintroduction of that incident is not acceptable when the fix is one integer.
  (2) a nonzero exit from the manifest check is reported as "STALE" while the output is discarded — but nonzero also means COULD NOT RUN (python vs python3, missing deps). That is the no-row/unparseable collapse in miniature on the advisory path.
  (3) the integration doc's step 1 is `npm i -D apex-dev-harness`, but I confirmed the package is UNPUBLISHED (npm view -> E404). A reviewer following the doc exactly fails at step 1 and never reaches the doctor gate, making the deliverable unusable as documented.
  (4, minor, fixed with them) doc states 106 rows and 135/135; reality is 110 and 146 — numbers a reviewer will compare against their own doctor output.
  Cost if wrong: all four are surgical; no new logic, no behavior beyond the stated corrections.
