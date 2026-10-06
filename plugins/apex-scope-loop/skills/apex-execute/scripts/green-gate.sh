#!/usr/bin/env bash
# green-gate.sh — Baseline-relative green gate for the plan's worktree.
# Adapted from The Gibson's Law 4 ("the green gate is absolute": zero NEW
# failures vs. the branch point) — see docs/GIBSON_HARNESS.md.
#
# Usage:
#   ./green-gate.sh PLAN.md baseline   # snapshot step exit codes at the fork point (init.sh calls this)
#   ./green-gate.sh PLAN.md check      # re-run; fail on any step that was green at baseline and is red now
#
# Gate steps, in order: generate → typecheck → lint → test → build.
# Command resolution (first match wins per step):
#   1. env APEX_GATE_GENERATE / _TYPECHECK / _LINT / _TEST / _BUILD
#   2. <worktree>/.agents/gate.json   (The Gibson's machine-readable gate twin;
#                                     a top-level "gate" object is also read)
#   3. package.json "scripts" entries of the same name → `npm run -s <step>`
#   4. toolchain autodetect: a Makefile target named after the step; Python
#      (pyproject/setup.*: pytest when tests/ or pytest config exist, ruff and
#      mypy when configured; via `uv run` when uv.lock is present and uv is
#      installed, else `python3 -m`); Cargo (test, clippy, build); Go (test,
#      vet, build)
# Empty / unresolved steps are skipped and reported as such.
#
# Env:
#   APEX_GATE_TIMEOUT  per-step timeout in seconds (default 1800; needs `timeout`)
#
# Emits (machine-readable):
#   GATE_STEP: <step> <PASS|FAIL|NEW_FAILURE|PREEXISTING|SKIPPED> [exit=N]
#   HEAD_SHA: <sha the check ran against>
#   GATE: PASS | FAIL | SKIPPED
# Exit codes: 0 PASS/SKIPPED/baseline written · 1 FAIL · 2 bad args / not initialized
set -euo pipefail

PLAN="${1:?usage: green-gate.sh PLAN.md baseline|check}"
MODE="${2:?mode: baseline|check}"
[[ -f "$PLAN" ]] || { echo "ERROR: plan not found: $PLAN" >&2; exit 2; }

APEX_RESOLVE_MODE=act  # this script acts: a repository mismatch is fatal (never inherited from the env)
# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
apex_resolve "$PLAN"
[[ -f "$CHECKPOINT" ]] || { echo "ERROR: not initialized — run init.sh first" >&2; exit 2; }

WT="$(read_field worktree_path)"; WT="${WT:-$REPO_ROOT}"
[[ -d "$WT" ]] || { echo "ERROR: worktree missing at $WT — re-run init.sh" >&2; exit 2; }

GATE_DIR="$STATE_DIR/gate"
BASELINE="$GATE_DIR/baseline.json"
mkdir -p "$GATE_DIR"
TIMEOUT_S="${APEX_GATE_TIMEOUT:-1800}"
STEPS=(generate typecheck lint test build)

resolve_cmd() {
  local step="$1" var
  var="APEX_GATE_$(printf '%s' "$step" | tr '[:lower:]' '[:upper:]')"
  if [[ -n "${!var:-}" ]]; then printf '%s' "${!var}"; return; fi
  python3 - "$WT" "$step" <<'PY'
import json, os, sys
wt, step = sys.argv[1:]
gj = os.path.join(wt, ".agents", "gate.json")
if os.path.isfile(gj):
    try:
        d = json.load(open(gj))
        if isinstance(d.get("gate"), dict):
            d = d["gate"]
        if step in d:  # present in the twin → authoritative, even if empty
            print(d[step] or "", end="")
            sys.exit(0)
    except Exception:
        pass
pj = os.path.join(wt, "package.json")
if os.path.isfile(pj):
    try:
        if step in (json.load(open(pj)).get("scripts") or {}):
            print(f"npm run -s {step}", end="")
            sys.exit(0)
    except Exception:
        pass
# 4. Toolchain autodetect (ADR-0003): a real stop signal in non-npm repos.
import re, shutil
def has(*names):
    return any(os.path.exists(os.path.join(wt, n)) for n in names)
mk = os.path.join(wt, "Makefile")
if os.path.isfile(mk):
    try:
        if re.search(rf"^{re.escape(step)}\s*:(?!=)", open(mk, errors="replace").read(), re.M):
            print(f"make {step}", end="")
            sys.exit(0)
    except Exception:
        pass
cmds = {}
if has("pyproject.toml", "setup.py", "setup.cfg"):
    py = "uv run" if (has("uv.lock") and shutil.which("uv")) else "python3 -m"
    cfg = ""
    for n in ("pyproject.toml", "setup.cfg", "ruff.toml", ".ruff.toml", "mypy.ini", "pytest.ini", "tox.ini"):
        p = os.path.join(wt, n)
        if os.path.isfile(p):
            cfg += open(p, errors="replace").read()
    if has("tests", "test") or "[tool.pytest" in cfg or has("pytest.ini"):
        cmds["test"] = f"{py} pytest -q"
    if "[tool.ruff" in cfg or has("ruff.toml", ".ruff.toml"):
        cmds["lint"] = f"{py} ruff check ."
    if "[tool.mypy" in cfg or has("mypy.ini"):
        cmds["typecheck"] = f"{py} mypy ."
elif has("Cargo.toml"):
    cmds = {"test": "cargo test --quiet", "lint": "cargo clippy --quiet", "build": "cargo build --quiet"}
elif has("go.mod"):
    cmds = {"test": "go test ./...", "lint": "go vet ./...", "build": "go build ./..."}
print(cmds.get(step, ""), end="")
PY
}

run_step() {
  local cmd="$1" log="$2"
  if command -v timeout >/dev/null 2>&1; then
    (cd "$WT" && timeout "$TIMEOUT_S" bash -c "$cmd") >"$log" 2>&1
  else
    (cd "$WT" && bash -c "$cmd") >"$log" 2>&1
  fi
}

HEAD_SHA="$(apex_git "$WT" rev-parse HEAD 2>/dev/null || echo unknown)"

if [[ "$MODE" == "check" ]] && [[ -n "$(apex_git "$WT" status --porcelain 2>/dev/null)" ]]; then
  echo "HEAD_SHA: $HEAD_SHA"
  echo "GATE: FAIL uncommitted changes in $WT — commit first; the gate and the reviewer bind to an exact head SHA"
  exit 1
fi

RESULTS="$GATE_DIR/$MODE-results.tsv"
: >"$RESULTS"
ran=0
for step in "${STEPS[@]}"; do
  cmd="$(resolve_cmd "$step")"
  if [[ -z "$cmd" ]]; then
    printf '%s\t\t-\n' "$step" >>"$RESULTS"
    continue
  fi
  ran=$((ran + 1))
  code=0
  run_step "$cmd" "$GATE_DIR/$MODE-$step.log" || code=$?
  printf '%s\t%s\t%s\n' "$step" "$cmd" "$code" >>"$RESULTS"
  # A step the baseline never ran with this command (a 0.2.x baseline, or a
  # newly detected toolchain) is baselined now at the fork SHA, so the check
  # compares like with like instead of blaming the plan for pre-existing red.
  if [[ "$MODE" == "check" && "$code" != "0" && -f "$BASELINE" ]]; then
    BCMD="$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("steps",{}).get(sys.argv[2]) or {}).get("cmd") or "")' "$BASELINE" "$step")"
    if [[ "$BCMD" != "$cmd" ]]; then
      BSHA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("head_sha",""))' "$BASELINE")"
      BWT="$(mktemp -d "${TMPDIR:-/tmp}/apex-gate-baseline.XXXXXX")"
      bcode=""
      if [[ -n "$BSHA" ]] && git -C "$WT" worktree add -q --detach "$BWT/wt" "$BSHA" 2>/dev/null; then
        # Only when the fork itself resolves the same command: a step the plan
        # introduced (say it added the Makefile) stays strict — any red is new.
        FORK_CMD="$(WT="$BWT/wt" resolve_cmd "$step")"
        if [[ "$FORK_CMD" == "$cmd" ]]; then
          bcode=0
          (cd "$BWT/wt" && if command -v timeout >/dev/null 2>&1; then timeout "$TIMEOUT_S" bash -c "$cmd"; else bash -c "$cmd"; fi) \
            >"$GATE_DIR/baseline-$step.log" 2>&1 || bcode=$?
        fi
        git -C "$WT" worktree remove --force "$BWT/wt" >/dev/null 2>&1 || true
      fi
      rm -rf "$BWT"
      python3 - "$BASELINE" "$step" "$cmd" "${bcode:-}" <<'PY'
import datetime, json, sys
path, step, cmd, code = sys.argv[1:]
b = json.load(open(path))
b.setdefault("steps", {})[step] = {"cmd": cmd, "exit": int(code) if code != "" else None,
    "rebaselined_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
json.dump(b, open(path, "w"), indent=2)
PY
    fi
  fi
done

python3 - "$MODE" "$RESULTS" "$BASELINE" "$GATE_DIR" "$HEAD_SHA" "$ran" <<'PY'
import json, os, sys, datetime
mode, results, baseline_path, gate_dir, head, ran = sys.argv[1:]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
steps = {}
for line in open(results):
    step, cmd, code = line.rstrip("\n").split("\t")
    steps[step] = {"cmd": cmd, "exit": None if code == "-" else int(code)}

if mode == "baseline":
    json.dump({"head_sha": head, "at": now, "steps": steps}, open(baseline_path, "w"), indent=2)
    for s, v in steps.items():
        state = "SKIPPED" if v["exit"] is None else ("PASS" if v["exit"] == 0 else "PREEXISTING")
        print(f"GATE_STEP: {s} {state}" + ("" if v["exit"] is None else f" exit={v['exit']}"))
    print(f"HEAD_SHA: {head}")
    print(f"GATE: BASELINE recorded ({ran} step(s) ran) -> {baseline_path}")
    sys.exit(0)

base = {}
if os.path.isfile(baseline_path):
    base = json.load(open(baseline_path)).get("steps", {})
failed = False
for s, v in steps.items():
    if v["exit"] is None:
        print(f"GATE_STEP: {s} SKIPPED")
        continue
    if v["exit"] == 0:
        print(f"GATE_STEP: {s} PASS")
        continue
    b = base.get(s, {}).get("exit")
    if b not in (None, 0):
        # Red at the fork point too — not this plan's failure, but never hidden.
        print(f"GATE_STEP: {s} PREEXISTING exit={v['exit']} (baseline exit={b}; log {gate_dir}/check-{s}.log)")
    else:
        failed = True
        print(f"GATE_STEP: {s} NEW_FAILURE exit={v['exit']} (log {gate_dir}/check-{s}.log)")

result = "SKIPPED" if int(ran) == 0 else ("FAIL" if failed else "PASS")
json.dump({"result": result, "head_sha": head, "at": now, "steps": steps},
          open(os.path.join(gate_dir, "last.json"), "w"), indent=2)
print(f"HEAD_SHA: {head}")
if result == "SKIPPED":
    print("GATE: SKIPPED no gate commands resolved — configure .agents/gate.json or APEX_GATE_* (acceptance check still applies)")
else:
    print(f"GATE: {result}")
sys.exit(1 if failed else 0)
PY
