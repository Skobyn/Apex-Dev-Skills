# Maintenance & hygiene (periodic, not a CI gate)

Covers brief §6 (Dead Code & Hygiene), §7 (Sin Bin), and the "warnings as errors" thread from §0/§2/§4. The defining idea: some cleanup is **periodic and human-judged**, not a per-PR blocker. Dead-code tools have false positives, so gating CI on them is noise; instead run them on a cadence, triage by hand, and **track when it was last done** so it doesn't silently lapse.

Generate this layer when the maintenance toggle is on (default on). It produces: a tracked `.apex/maintenance.json`, a stack-appropriate sweep script under `scripts/`, a whitelist file, and a **Maintenance** section in `AGENTS.md` (authored by the steering-docs skill).

---

## 1. Dead-code sweep — periodic, triage-by-hand

Run on a cadence (default every ~3 days of active work, or weekly for quiet repos). **Never auto-delete.** Produce a ranked list, review it, delete what's truly dead (don't comment it out — git remembers), and whitelist false positives.

### Python — vulture
Add `vulture` to dev deps. The canonical sweep:
```bash
vulture src/ vulture_whitelist.py --min-confidence 80 --sort-by-size
```
- `--min-confidence 80` keeps the signal high (vulture is heuristic; lower confidence = more false positives).
- `--sort-by-size` ranks the biggest dead blocks first, so you delete the highest-value items first.
- Whitelist false positives in `vulture_whitelist.py` (referenced on the command line above) — e.g. attributes touched only by frameworks/serialization. Regenerate stubs with `vulture src/ --make-whitelist >> vulture_whitelist.py` then prune.
- Optional config in `pyproject.toml`:
  ```toml
  [tool.vulture]
  paths = ["src", "vulture_whitelist.py"]
  min_confidence = 80
  sort_by_size = true
  ```

### TypeScript — knip
`knip` supersedes `ts-prune`; it finds unused files, exports, dependencies, and more in one pass:
```bash
npx knip
```
Add a minimal `knip.json` (entry + project globs) and run periodically. (`ts-prune` is fine for exports-only but is in maintenance mode.)

### Go — deadcode / staticcheck
```bash
go run golang.org/x/tools/cmd/deadcode@latest ./...
```
staticcheck's `U1000` also flags unused unexported code; it's already in the golangci-lint set.

### Rust — compiler + udeps
`dead_code` is a compiler lint — with `-D warnings` (already set in `.cargo/config.toml`) dead code fails the build, so Rust needs little periodic sweeping for code. For unused **dependencies**:
```bash
cargo +nightly udeps   # cargo install cargo-udeps
```

---

## 2. Dependency hygiene — keep deps lean

Audit and remove unused packages periodically (same cadence):
- **Python:** `deptry .` (unused / missing / transitive deps) or `uv pip tree`. Run `uv lock --upgrade` deliberately, not blindly.
- **TypeScript:** `knip` also reports unused deps; or `depcheck`.
- **Rust:** `cargo +nightly udeps`.
- **Go:** `go mod tidy` (removes unused module requirements).

Every dependency is a tax (brief §0). Removing one is as valuable as adding a feature.

---

## 3. Tracking last-run + the >3-day reminder (the mechanism)

Scheduling these reliably is hard, so instead make staleness **visible and self-correcting**. Two committed artifacts plus an AGENTS.md instruction:

### `.apex/maintenance.json` (committed)
```json
{
  "tasks": {
    "dead-code-sweep": {
      "description": "Periodic dead-code sweep — triage the ranked list, delete dead code, whitelist false positives.",
      "command": "scripts/dead-code-sweep.sh",
      "cadence_days": 3,
      "last_run": null
    },
    "dependency-audit": {
      "description": "Remove unused dependencies.",
      "command": "scripts/dead-code-sweep.sh --deps",
      "cadence_days": 14,
      "last_run": null
    }
  }
}
```

### `scripts/dead-code-sweep.sh` (stack-adapted; Python shown)
The script runs the sweep and, only when passed `--done`, stamps the timestamp. It never deletes anything itself.
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

stamp() {
  python3 - "$1" <<'PY'
import json, datetime, pathlib, sys
task = sys.argv[1]
p = pathlib.Path(".apex/maintenance.json")
d = json.loads(p.read_text())
d["tasks"][task]["last_run"] = datetime.date.today().isoformat()
p.write_text(json.dumps(d, indent=2) + "\n")
print(f"stamped {task} = {d['tasks'][task]['last_run']}")
PY
}

case "${1:-sweep}" in
  --done)  stamp dead-code-sweep ;;
  --deps)  echo "== dependency audit =="; uv run deptry . || true ;;
  *)
    echo "== vulture dead-code sweep (min-confidence 80, ranked by size) =="
    uv run vulture src/ vulture_whitelist.py --min-confidence 80 --sort-by-size || true
    echo
    echo "Triage the list above: delete what's dead (don't comment it out),"
    echo "add false positives to vulture_whitelist.py, commit, then run:"
    echo "  scripts/dead-code-sweep.sh --done"
    ;;
esac
```
Adapt the sweep line per stack (knip / deadcode / cargo udeps). `chmod +x` it.

### AGENTS.md "Maintenance" section
The steering-docs skill writes a Maintenance section instructing agents to read `.apex/maintenance.json` at the start of a session and, if a task's `last_run` is null or older than `cadence_days`, **remind the user and offer to run it** — running the sweep, presenting the ranked list, proposing deletions for approval (never deleting without confirmation), updating the whitelist, and stamping the run. See the steering-docs reference for the exact wording.

### Optional: proactive SessionStart hook (generated project)
For determinism, the generated project can carry a `.claude/settings.json` SessionStart hook that prints a one-line staleness nudge so the reminder fires even if the agent doesn't think to check. Offer it; don't force it.
```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [{ "type": "command", "command": "bash scripts/maintenance-check.sh 2>/dev/null || true" }]
      }
    ]
  }
}
```
`scripts/maintenance-check.sh` reads `.apex/maintenance.json` and echoes e.g. `⚠ dead-code-sweep is 6 days stale — run scripts/dead-code-sweep.sh` when over cadence. Keep it silent when fresh.

---

## 4. Sin bin (brief §7) — optional quarantine

A scratch/quarantine dir for experimental or untrusted code that must not affect the main build or pollute quality metrics. Default name `sandbox/` (or `sin-bin/`). Exclude it from **every** gate:
- Ruff: `extend-exclude = ["sandbox"]`; Biome: add to `files.ignore`; ESLint flat: `ignores`.
- tsconfig: add to `exclude`; pytest: `--ignore=sandbox`; Vitest: `exclude`.
- Coverage: omit `sandbox/**`.
- CI: path-filter so changes under `sandbox/` don't trigger the quality jobs (or keep them but scope the jobs to `src/`).
- Dead-code sweep: don't scan it.
Add a `sandbox/README.md` stating it's excluded from CI and not for production code. Generate only when the sin-bin toggle is on.

---

## 5. Warnings as errors (brief §0/§2/§4) — consistent default

Make linters, type-checkers, compilers, and tests **fail** rather than warn, so warnings get fixed while context is fresh:
- **Python:** Ruff exits non-zero on any finding (default). Add `filterwarnings = ["error"]` under `[tool.pytest.ini_options]` so runtime warnings fail tests. pyright strict already errors.
- **TypeScript:** Biome `check` fails CI on any diagnostic; if using ESLint, run `eslint --max-warnings 0`. `tsc --noEmit` under `strict`.
- **Rust:** `-D warnings` in `.cargo/config.toml` (already set) + `cargo clippy -- -D warnings`.
- **Go:** golangci-lint fails on any enabled-linter finding.
- **CI:** ensure the lint/typecheck steps don't swallow non-zero exits (no `|| true`).

---

## Generated files (when maintenance toggle on)
- `.apex/maintenance.json`
- `scripts/dead-code-sweep.sh` (+ optional `scripts/maintenance-check.sh`)
- whitelist: `vulture_whitelist.py` (Python) / `knip.json` (TS) as applicable
- `[tool.vulture]` / `knip.json` config
- AGENTS.md **Maintenance** section (via steering-docs)
- optional `.claude/settings.json` SessionStart hook
- `sandbox/` + exclusions (only if sin-bin toggle on)
