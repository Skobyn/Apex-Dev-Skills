---
name: characterization-test
description: Generate characterization (pinning) tests that lock in the CURRENT behavior of legacy or AI-generated code that has no tests, so a refactor is provably behavior-preserving. Use this skill before refactoring, renaming, extracting, or porting an untested module — or before touching "vibe-coded" code you don't fully understand and didn't write. This is NOT greenfield TDD and NOT a quality pass: you assert what the code does today (even if it looks wrong), creating a safety net that turns red the instant a refactor changes observable output. Trigger on phrasing like "I need to refactor this but there are no tests", "pin the current behavior", "characterization tests", "this AI-generated code has no coverage and I'm scared to change it", or "make a safety net before I touch this".
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
---

# Characterization Test Generator

Generate **characterization tests** (a.k.a. **pinning tests**) for a module that has
**no tests** so you can refactor it safely.

> Michael Feathers, *Working Effectively with Legacy Code*: **"Legacy code is simply
> code without tests."** A characterization test is "a test that characterizes the
> actual behavior of a piece of code" — it documents what the system *does*, not what
> it *should* do.

The modern corollary: **AI-generated / "vibe-coded" code is born as legacy.** It was
written without tests, it ships fast, and nobody — sometimes not even its author —
holds the full mental model. The same technique that tamed 20-year-old COBOL tames
the function an LLM emitted last Tuesday.

## What this skill is — and what it is NOT

| This skill DOES | This skill does NOT |
|---|---|
| Capture the code's **current** observable behavior | Assert what the code *should* do (that's TDD) |
| Assert outputs **even when they look wrong** | "Fix" bugs while writing the test |
| Build a regression net **before** a refactor | Improve, clean, or restructure the code under test |
| Treat surprising output as a finding to record | Silently correct surprising output |
| Cover real I/O: return values, exceptions, side effects | Aim for "nice" coverage of imagined cases |

If you find yourself wanting to write the *correct* answer in an assertion, stop. The
correct answer for a characterization test is **whatever the code produces right now**.
A bug pinned by a passing test is a bug you can refactor *around* safely and fix
*deliberately* later — with a separate, clearly-labeled change.

## The workflow

### 1. Establish the boundary

Identify the **unit you will pin** and its **observable surface**:

- **Inputs** — function arguments, constructor args, env vars, files read, network/db reads, clock/random.
- **Outputs** — return values, raised exceptions/error codes, mutations to arguments, writes to files/db/stdout, calls made to collaborators.

Use `Grep`/`Glob` to find the module's call sites — they reveal the inputs that
*actually occur in production*. Pin those first; they matter most.

> Rule: a characterization test only asserts what is **observable at the boundary**.
> Don't reach into private state. If behavior isn't observable, either it doesn't
> matter for the refactor, or you need to widen the boundary (e.g., a thin seam).

### 2. Find the seams

Untested code usually has hard-wired dependencies (real clock, real DB, `now()`,
global singletons). A **seam** is a place you can substitute behavior without editing
the code in place. Options, least-invasive first:

1. **Pass-through inputs** — call the function with controlled args; assert the return.
2. **Environment control** — set env vars, freeze the clock, seed RNG, point at a temp dir/sqlite.
3. **Subprocess / golden capture** — run the program end-to-end and capture stdout/exit code (great for CLIs and AI-generated scripts).
4. **Characterize-then-extract** — if it's truly untestable, pin the *largest callable boundary* you can (e.g., the whole handler) before extracting a seam.

Avoid editing production code to make it testable *before* you have a single pinning
test — that edit is itself an unverified change. Pin first at the coarsest honest
boundary, then refine.

### 3. Probe and record actual output

This is the core move. Write a test that calls the code and asserts a **placeholder**,
run it, and let the *failure message tell you the real value*. Then paste the real
value into the assertion.

```python
# Step A — assert a deliberately-wrong placeholder
assert normalize_phone("(415) 555-2671") == "PLACEHOLDER"
```
Run it. The failure prints the actual return, e.g. `'+14155552671'`. Now pin it:
```python
# Step B — pin the ACTUAL current behavior
assert normalize_phone("(415) 555-2671") == "+14155552671"
```

Do this for a spread of inputs: typical, empty, boundary, malformed, and the inputs
you saw at real call sites in step 1. **Pin exceptions too** — if bad input throws
`ValueError: ...`, assert that it throws exactly that. If it *silently returns
`None`*, pin the `None`. Surprises get a `# CHARACTERIZED: looks wrong — see notes`
comment, not a fix.

### 4. Run, confirm green, lock it in

All characterization tests must **pass against the unchanged code**. A red
characterization test means you mis-recorded the behavior, not that the code is wrong —
re-probe. Green across the suite = your safety net is live.

### 5. Refactor under the net

Now refactor. The net stays green ⇒ behavior preserved. The net turns red ⇒ you
changed observable behavior; revert or decide deliberately. **Fix discovered bugs in a
separate, labeled commit**, updating the pinned assertion in the same commit so the
test now documents the new intended behavior.

## Language-agnostic recipe

| Concern | Approach |
|---|---|
| Pure function | Call with table of inputs; pin return / thrown error. |
| Function with hidden time/RNG | Freeze clock, seed RNG (or inject), then pin. |
| Reads files/DB | Point at a temp fixture (tmpdir, in-memory sqlite); pin output. |
| CLI / script (common for AI-gen) | Run as subprocess; capture stdout/stderr/exit code as a **golden file**. |
| Class with state | Drive a sequence of method calls; pin the observable state after each. |
| Calls collaborators | Record the calls (spy/mock) and pin the call sequence + args. |
| Non-deterministic output | Pin the *invariant* (length, schema, sorted set), not the volatile bytes. |

Pick the test framework the repo already uses (pytest, Jest/Vitest, JUnit, Go
`testing`, RSpec). Detect it with `Glob`/`Grep` before writing — match the project's
conventions; do not introduce a new framework.

## Worked example

A vibe-coded helper lands in the repo with no tests. You need to extract a sub-function
but you don't trust it.

```python
# legacy/discount.py  — no tests, origin unknown
def apply_discount(price, code):
    if code == "VIP":
        return price * 0.8
    if code.startswith("BULK"):
        n = int(code[4:] or 0)
        return price * (1 - min(n, 50) / 100)
    return price
```

**Step 1 — boundary:** inputs `(price, code)`, output is a number or an exception.
`Grep` for `apply_discount(` shows call sites pass `"VIP"`, `"BULK10"`, `""`, and a
user-supplied string.

**Step 3 — probe and pin (record actual, including the surprises):**

```python
# test_discount_characterization.py — pins CURRENT behavior, not desired behavior
from legacy.discount import apply_discount
import pytest

def test_vip():
    assert apply_discount(100, "VIP") == 80.0

def test_bulk_ten():
    assert apply_discount(100, "BULK10") == 90.0

def test_bulk_caps_at_fifty():
    # CHARACTERIZED: cap is 50% even for BULK99
    assert apply_discount(100, "BULK99") == 50.0

def test_unknown_code_passes_through():
    assert apply_discount(100, "GARBAGE") == 100

def test_empty_code_raises():
    # CHARACTERIZED: looks wrong — "" hits .startswith path? No: "" != "VIP",
    # "".startswith("BULK") is False, so it returns price unchanged.
    assert apply_discount(100, "") == 100

def test_bulk_no_number_is_zero_discount():
    # CHARACTERIZED: "BULK" with no digits -> int("" or 0) -> 0 -> no discount
    assert apply_discount(100, "BULK") == 100.0

def test_none_code_raises_attributeerror():
    # CHARACTERIZED: passing None throws — pin the actual exception type
    with pytest.raises(AttributeError):
        apply_discount(100, None)
```

**Step 4:** run — all green against the untouched function.
**Step 5:** now extract `parse_bulk(code)`, rename, simplify the branches — the suite
stays green, proving you didn't change behavior. The `None` -> `AttributeError` case is
ugly; you fix it later in a commit titled *"discount: handle None code (was
AttributeError)"* and update `test_none_code_raises_attributeerror` in the same commit.

## Hard rules

1. **Pin reality, not intent.** Assert what runs today. Looks-wrong output gets a comment, not a fix.
2. **Green before refactor.** Every characterization test must pass against the unchanged code first.
3. **Don't edit the code to test it — until you have one pinning test.** Coarsest honest boundary first; carve seams under the net.
4. **One purpose per change.** Pinning, refactoring, and bug-fixing are three different commits.
5. **Match the repo's test framework.** Detect it; never introduce a new one for this.
6. **Observable boundary only.** No assertions on private internals.
