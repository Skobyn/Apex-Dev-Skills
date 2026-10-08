#!/usr/bin/env bash
# gate.sh — Evaluate a single approval gate from a plan, outside the /loop flow.
#
# Usage:
#   ./gate.sh <plan-path> <gate-id>
#
# <gate-id> matches the task title, e.g. "gate-2-3" or "Gate 2→3".
# Pass either form; the script normalizes.
#
# Behavior by gate type:
#   [gate:auto]            Runs the Acceptance shell command. Exits 0 on pass, 1 on fail.
#   [gate:human]           Prints the required approval phrase; exits 2 (awaiting).
#                          Does NOT modify checkpoint — the orchestrator owns halting.
#   [gate:partner:{who}]   Notifies the partner and exits 2 (awaiting):
#                          $APEX_PARTNER_NOTIFY_CMD gets the gate JSON on stdin;
#                          else the Apex inbox API when .claude/agent-coord-config.json
#                          exists (apex profile); else it degrades to [gate:human].
#
# Exit codes:
#   0  — Gate passed
#   1  — Gate failed (auto-gate command returned non-zero)
#   2  — Gate awaiting (human or partner)
#   3  — Bad args / gate not found
#   4  — Partner notification failed (notify command or inbox API)

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <plan-path> <gate-id>" >&2
  echo "  <gate-id> example: gate-2-3" >&2
  exit 3
fi

PLAN="$1"
GATE_ID_RAW="$2"

[[ -f "$PLAN" ]] || { echo "Plan not found: $PLAN" >&2; exit 3; }

# Find the gate with planlib's id normalisation ("gate-2-3", "Gate 2→3",
# "Gate 2-3" are one id), the same rule Blocked-by references use.
PL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../apex-execute/scripts" && pwd)/planlib.py"
FOUND="$(python3 - "$PL" "$PLAN" "$GATE_ID_RAW" <<'PY' || true
import sys
sys.dont_write_bytecode = True
pl, plan, raw = sys.argv[1:]
sys.path.insert(0, pl.rsplit("/", 1)[0]); import planlib
want = planlib.norm_ref(raw)
for t in planlib.parse(plan):
    if t["ref"] and t["ref"] == want and want[0] == "gate":
        print(f"{t['line_no']}\t{t['line']}")
        break
PY
)"
GATE_LINE_NO="${FOUND%%$'\t'*}"
GATE_LINE="${FOUND#*$'\t'}"

if [[ -z "$FOUND" ]]; then
  echo "Gate not found in plan: $GATE_ID_RAW" >&2
  exit 3
fi

# Extract gate kind
KIND=""
PARTNER_EMAIL=""
if [[ "$GATE_LINE" =~ \[gate:auto\] ]]; then
  KIND="auto"
elif [[ "$GATE_LINE" =~ \[gate:human\] ]]; then
  KIND="human"
elif [[ "$GATE_LINE" =~ \[gate:partner:([^]]+)\] ]]; then
  KIND="partner"
  PARTNER_EMAIL="${BASH_REMATCH[1]}"
else
  echo "Gate line has no recognizable [gate:*] tag: $GATE_LINE" >&2
  exit 3
fi

# Read Acceptance line (look ahead up to 8 lines from gate line)
ACCEPTANCE=""
END=$((GATE_LINE_NO + 8))
NEXT=$((GATE_LINE_NO + 1))
while [[ $NEXT -le $END ]]; do
  L="$(sed -n "${NEXT}p" "$PLAN" 2>/dev/null || echo "")"
  [[ -z "$L" ]] && break
  case "$L" in
    *"Acceptance:"*) ACCEPTANCE="${L#*Acceptance:}"; ACCEPTANCE="${ACCEPTANCE# }"; break ;;
    "- ["*) break ;;
  esac
  NEXT=$((NEXT + 1))
done

if [[ -z "$ACCEPTANCE" ]]; then
  echo "Gate has no Acceptance line: $GATE_LINE" >&2
  exit 3
fi

echo "Gate: $GATE_LINE"
echo "Kind: $KIND"
echo "Acceptance: $ACCEPTANCE"
echo

case "$KIND" in
  auto)
    echo "Running acceptance check..."
    if bash -c "$ACCEPTANCE"; then
      echo
      echo "PASS — gate cleared."
      exit 0
    else
      echo
      echo "FAIL — acceptance check returned non-zero."
      exit 1
    fi
    ;;

  human)
    echo "AWAITING HUMAN — approval phrase required:"
    echo "    $ACCEPTANCE"
    echo
    echo "The /loop orchestrator should halt the loop and prompt the user."
    exit 2
    ;;

  partner)
    # Partner gates are generic (ADR-0003): $APEX_PARTNER_NOTIFY_CMD receives
    # the gate as JSON on stdin (gh issue create, a webhook, Slack); the Apex
    # inbox POST is the apex profile's default, used only when
    # .claude/agent-coord-config.json exists. With neither, the gate degrades
    # to a human gate instead of failing.
    GATE_TITLE="$(echo "$GATE_LINE" | grep -oE 'Gate [0-9A-Za-z→.-]+' | head -1 || true)"
    BODY="$(python3 - "$PARTNER_EMAIL" "$GATE_TITLE" "$ACCEPTANCE" "$PLAN" <<'PY'
import json, sys
forUser, title, acceptance, plan_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
print(json.dumps({
    "kind": "phase-gate-approval",
    "title": f"Approve {title}",
    "forUser": forUser,
    "docPath": plan_path,
    "actionPrompt": f"Review phase results and confirm: {acceptance}",
    "extra": {"gate": title, "plan": plan_path},
}))
PY
    )"
    if [[ -n "${APEX_PARTNER_NOTIFY_CMD:-}" ]]; then
      if printf '%s' "$BODY" | bash -c "$APEX_PARTNER_NOTIFY_CMD"; then
        echo "AWAITING PARTNER — notified $PARTNER_EMAIL via APEX_PARTNER_NOTIFY_CMD"
        exit 2
      fi
      echo "Partner notification failed (APEX_PARTNER_NOTIFY_CMD returned non-zero)" >&2
      exit 4
    fi
    CONFIG="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.claude/agent-coord-config.json"
    if [[ ! -f "$CONFIG" ]]; then
      echo "AWAITING HUMAN — no partner channel configured (set APEX_PARTNER_NOTIFY_CMD); treating as [gate:human]."
      echo "Ask $PARTNER_EMAIL (or the user) for the approval phrase:"
      echo "    $ACCEPTANCE"
      exit 2
    fi
    AUTH_KEY="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['authKey'])" "$CONFIG")"
    AUTH_USER="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['user'])" "$CONFIG")"
    API_BASE="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('apiBase','https://api.getapexinsights.com'))" "$CONFIG")"
    RESP="$(mktemp "${TMPDIR:-/tmp}/apex-gate-resp.XXXXXX")"
    trap 'rm -f "$RESP"' EXIT

    HTTP_CODE="$(curl -sS -o "$RESP" -w '%{http_code}' \
      -X POST "$API_BASE/api/agent-coordination/inbox" \
      -H "Content-Type: application/json" \
      -H "X-Agent-Auth: $AUTH_KEY" \
      -H "X-Agent-User: $AUTH_USER" \
      -d "$BODY")"

    if [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
      echo "AWAITING PARTNER — inbox item written for $PARTNER_EMAIL"
      cat "$RESP"
      echo
      exit 2
    else
      echo "Failed to write inbox item (HTTP $HTTP_CODE):" >&2
      cat "$RESP" >&2
      exit 4
    fi
    ;;
esac
