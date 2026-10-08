#!/usr/bin/env bash
# Phase 3 shadow pilot (spec §14): a small live run of apex-decide in a throwaway repository,
# then the first `measure` report per rubric. Usage:
#   pilot.sh OUT_DIR [typesafe|openrouter]
# Needs the jev key for the transport in the environment, or a session proxy that injects it
# (then any placeholder works: the script sets one only when the variable is unset).
# Writes OUT_DIR/decisions.jsonl, OUT_DIR/outcomes-*.jsonl and OUT_DIR/measure-<rubric>-jev.json.
set -euo pipefail
OUT="${1:?usage: pilot.sh OUT_DIR [typesafe|openrouter]}"; T="${2:-typesafe}"
D="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../plugins/apex-decision-layer" && pwd)/bin/apex-decide"
mkdir -p "$OUT"; R="$(mktemp -d "${TMPDIR:-/tmp}/apex-pilot.XXXXXX")"; trap 'rm -rf "$R"' EXIT
git init -q "$R"; mkdir -p "$R/.dev-plan-state" "$R/.claude/apex-decision-layer"
printf '{"egress":"hosted","state_fields":"raw","primary":{"default":"jev"},"jev":{"transport":"%s"},"decision_log":{"store_state":"full"}}' "$T" \
  >"$R/.claude/apex-decision-layer/config.json"
[ -n "${TYPESAFE_API_KEY:-}${JEV_API_KEY:-}" ] || export TYPESAFE_API_KEY=proxy-injected-key
[ -n "${OPENROUTER_API_KEY:-}" ] || export OPENROUTER_API_KEY=proxy-injected-key
# Fixture tasks with the label the fixture intends (an outcome-proxy, never a human label).
python3 - "$R" "$D" "$OUT" <<'PY'
import json, subprocess, sys
repo, D, out = sys.argv[1:]
TC = [("docs", {"task_title": "Fix typos in the installation guide", "tags": ["docs"], "paths": ["docs/install.md"], "risk_tier": "A"}),
      ("tests", {"task_title": "Add unit tests for the date parser", "tags": ["test"], "paths": ["tests/test_dates.py"], "risk_tier": "A"}),
      ("mechanical", {"task_title": "Rename getUser to fetchUser across the client", "tags": ["refactor"], "paths": ["src/client/api.ts", "src/client/hooks.ts"], "risk_tier": "A"}),
      ("feature", {"task_title": "Add CSV export button to the reports page", "tags": ["ui"], "paths": ["src/pages/reports.tsx"], "risk_tier": "B"}),
      ("bugfix", {"task_title": "Fix crash when the cart is empty at checkout", "tags": ["bug"], "paths": ["src/checkout/cart.ts"], "risk_tier": "B"}),
      ("feature", {"task_title": "Let users pin favourite dashboards", "tags": ["ux"], "paths": ["src/dashboards/pin.tsx"], "risk_tier": "B"}),
      ("bugfix", {"task_title": "Timezone off by one hour in the weekly digest", "tags": ["bug"], "paths": ["src/digest/schedule.py"], "risk_tier": "B"}),
      ("none", {"task_title": "Update stuff", "tags": [], "paths": [], "risk_tier": "A"})]
RT = [("A", {"changed_paths": ["src/cli/format.py"], "changed_lines": 12, "changed_files": 1, "task_tags": []}),
      ("A", {"changed_paths": ["docs/usage.md", "README.md"], "changed_lines": 40, "changed_files": 2, "task_tags": ["docs"]}),
      ("B", {"changed_paths": ["lib/http/client.ts", "lib/http/retry.ts"], "changed_lines": 220, "changed_files": 2, "task_tags": []}),
      ("B", {"changed_paths": [".github/workflows/ci.yml"], "changed_lines": 30, "changed_files": 1, "task_tags": ["ci"]}),
      ("C", {"changed_paths": ["src/auth/session.py"], "changed_lines": 40, "changed_files": 1, "task_tags": []}),
      ("C", {"changed_paths": ["migrations/0042_add_ssn.sql"], "changed_lines": 15, "changed_files": 1, "task_tags": []}),
      ("C", {"changed_paths": ["billing/charge.go"], "changed_lines": 60, "changed_files": 1, "task_tags": []}),
      ("none", {"changed_paths": ["a.txt"], "changed_lines": 1, "changed_files": 1, "task_tags": []})]
for rv, tasks, dl in (("dispatch/task-class@1", TC, "1500"), ("risk-tier@1", RT, "10000")):
    rows = []
    for intended, st in tasks:
        r = subprocess.run([D, "--repo", repo, "--rubric", rv, "--deadline-ms", dl, "--state", "-", "--json"],
                           input=json.dumps(st), capture_output=True, text=True)
        env = json.loads(r.stdout) if r.stdout.strip() else {"scored": False, "reason": "no output", "detail": r.stderr[-200:]}
        print("PILOT %s intended=%s exit=%d scored=%s verdict=%s conf=%s model=%s latency=%sms%s" % (
            rv, intended, r.returncode, env.get("scored"), env.get("verdict"), env.get("confidence"), env.get("model_resolved"),
            env.get("latency_ms"), "" if env.get("scored") else " reason=%s %s" % (env.get("reason"), env.get("detail", "")[:120])))
        if env.get("decision_id"):
            rows.append({"decision_id": env["decision_id"], "label": intended, "source": "outcome-proxy", "note": "fixture-intended"})
    with open("%s/outcomes-%s.jsonl" % (out, rv.replace("/", "_")), "w") as f:
        f.write("".join(json.dumps(x) + "\n" for x in rows))
PY
for rv in dispatch/task-class@1 risk-tier@1; do
  "$D" measure --repo "$R" --rubric "$rv" --backend jev --outcomes "$OUT/outcomes-${rv//\//_}.jsonl" --out "$OUT/measure-${rv//\//_}-jev.json"
done
cp "$R/.dev-plan-state/decisions/decisions.jsonl" "$OUT/decisions.jsonl"
