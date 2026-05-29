#!/usr/bin/env bash
# apex-contracts-reliability — analyze-ledger
#
# Reads the JSONL ledger written by hooks/capture-tool-io.sh and produces one of
# two reports:
#
#   drift        F1 ToolContractCheck — for each tool, treat the FIRST observed
#                input shape as the established schema, then list later calls
#                whose shape diverges (added field, missing field, type change).
#   reliability  F2 FlakeGuard — for each tool, compute call count, failure
#                count + rate, retry runs (consecutive identical-input calls),
#                and flip-flops (a call shape that both succeeded and failed).
#
# Usage:
#   analyze-ledger.sh [drift|reliability] [--ledger PATH] [--json]
#
# Dependency-free: bash + python3 stdlib. Exits 0 on a clean report, 3 when
# drift/flakiness is detected (so it can gate CI), and 2 on bad usage.
set -euo pipefail

MODE="reliability"
LEDGER=""
AS_JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    drift|reliability) MODE="$1"; shift ;;
    --ledger) LEDGER="${2:-}"; shift 2 ;;
    --json) AS_JSON=1; shift ;;
    -h|--help)
      grep -E '^#' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) echo "analyze-ledger: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$LEDGER" ]; then
  LEDGER="${APEX_CR_LEDGER_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}/.claude/contracts-reliability}/ledger.jsonl"
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "analyze-ledger: python3 is required for analysis" >&2
  exit 2
fi
if [ ! -f "$LEDGER" ]; then
  echo "analyze-ledger: no ledger at $LEDGER (no tool calls captured yet)" >&2
  exit 0
fi

APEX_CR_MODE="$MODE" APEX_CR_LEDGER="$LEDGER" APEX_CR_JSON="$AS_JSON" python3 - <<'PY'
import json, os, sys
from collections import defaultdict, OrderedDict

mode    = os.environ["APEX_CR_MODE"]
path    = os.environ["APEX_CR_LEDGER"]
as_json = os.environ.get("APEX_CR_JSON") == "1"

records = []
with open(path, encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        if isinstance(r, dict) and "tool" in r:
            records.append(r)

def norm_shape(s):
    """Hashable, order-independent representation of an input shape."""
    if isinstance(s, dict):
        return tuple(sorted((k, norm_shape(v)) for k, v in s.items()))
    return s

def diff_shape(base, cur):
    """Compare two object shapes; return human-readable divergences."""
    issues = []
    if not isinstance(base, dict) or not isinstance(cur, dict):
        if base != cur:
            issues.append(f"shape changed: {base!r} -> {cur!r}")
        return issues
    bk, ck = set(base), set(cur)
    for k in sorted(ck - bk):
        issues.append(f"+ new field '{k}' ({cur[k]})")
    for k in sorted(bk - ck):
        issues.append(f"- missing field '{k}' (was {base[k]})")
    for k in sorted(bk & ck):
        if norm_shape(base[k]) != norm_shape(cur[k]):
            issues.append(f"~ field '{k}' type {base[k]} -> {cur[k]}")
    return issues

exit_code = 0

# Index calls per tool, preserving order.
per_tool = OrderedDict()
for r in records:
    per_tool.setdefault(r["tool"], []).append(r)

if mode == "drift":
    out = OrderedDict()
    drift_found = False
    for tool, calls in per_tool.items():
        # Establish schema from first call that carries an input shape.
        base = None
        divergences = []
        for i, c in enumerate(calls):
            shp = c.get("input_shape")
            if shp is None:
                continue
            if base is None:
                base = shp
                continue
            issues = diff_shape(base, shp)
            if issues:
                divergences.append({"call_index": i, "ts": c.get("ts"), "issues": issues})
        out[tool] = {
            "calls": len(calls),
            "schema": base,
            "drift_events": divergences,
        }
        if divergences:
            drift_found = True
    if drift_found:
        exit_code = 3

    if as_json:
        print(json.dumps(out, indent=2))
    else:
        print("=== Tool Contract Drift Report ===")
        print(f"ledger: {path}")
        print(f"tools observed: {len(out)}\n")
        for tool, info in out.items():
            flag = "DRIFT" if info["drift_events"] else "ok"
            print(f"[{flag}] {tool}  ({info['calls']} call(s))")
            print(f"      established schema: {info['schema']}")
            for ev in info["drift_events"]:
                print(f"      ! call #{ev['call_index']} (ts {ev['ts']}):")
                for iss in ev["issues"]:
                    print(f"          {iss}")
            print()
        if drift_found:
            print("CONTRACT DRIFT detected — a tool's call shape diverged from its established schema.")
        else:
            print("No contract drift: every tool's call shape matched its established schema.")

else:  # reliability / FlakeGuard
    out = OrderedDict()
    flaky = False
    for tool, calls in per_tool.items():
        posts = [c for c in calls if c.get("phase") == "PostToolUse"]
        total = len(posts)
        fails = sum(1 for c in posts if c.get("ok") is False)
        rate = (fails / total) if total else 0.0

        # Retry runs: consecutive PreToolUse calls with identical input shape.
        pres = [c for c in calls if c.get("phase") == "PreToolUse"]
        retry_runs = 0
        run_len = 1
        for a, b in zip(pres, pres[1:]):
            if norm_shape(a.get("input_shape")) == norm_shape(b.get("input_shape")):
                run_len += 1
            else:
                if run_len >= 2:
                    retry_runs += 1
                run_len = 1
        if run_len >= 2:
            retry_runs += 1

        # Flip-flops: same input shape observed both succeeding and failing.
        by_shape = defaultdict(set)
        for c in posts:
            if c.get("ok") is not None:
                by_shape[norm_shape(c.get("input_shape"))].add(bool(c["ok"]))
        flip_flops = sum(1 for v in by_shape.values() if len(v) > 1)

        is_flaky = (0.0 < rate < 1.0) or retry_runs > 0 or flip_flops > 0
        out[tool] = {
            "calls": total,
            "failures": fails,
            "failure_rate": round(rate, 3),
            "retry_runs": retry_runs,
            "flip_flops": flip_flops,
            "flaky": is_flaky,
        }
        if is_flaky:
            flaky = True
    if flaky:
        exit_code = 3

    if as_json:
        print(json.dumps(out, indent=2))
    else:
        print("=== FlakeGuard Reliability Report ===")
        print(f"ledger: {path}")
        print(f"tools observed: {len(out)}\n")
        hdr = f"{'tool':<32} {'calls':>6} {'fails':>6} {'rate':>6} {'retry':>6} {'flip':>5}  status"
        print(hdr)
        print("-" * len(hdr))
        for tool, m in out.items():
            status = "FLAKY" if m["flaky"] else "stable"
            print(f"{tool:<32} {m['calls']:>6} {m['failures']:>6} "
                  f"{m['failure_rate']:>6} {m['retry_runs']:>6} {m['flip_flops']:>5}  {status}")
        print()
        if flaky:
            print("NON-DETERMINISTIC behavior detected — see FLAKY rows above "
                  "(intermittent failures, repeated retries, or success-then-failure on the same call).")
        else:
            print("No flakiness detected: tools either consistently succeeded or consistently failed.")

sys.exit(exit_code)
PY
