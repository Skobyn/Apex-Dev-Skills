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
#   [gate:partner:<email>] Writes an inbox item via the agent-coordination API; exits 2.
#                          Requires .claude/agent-coord-config.json with authKey.
#
# Exit codes:
#   0  — Gate passed
#   1  — Gate failed (auto-gate command returned non-zero)
#   2  — Gate awaiting (human or partner)
#   3  — Bad args / gate not found
#   4  — Inbox API call failed (partner-gate only)

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <plan-path> <gate-id>" >&2
  echo "  <gate-id> example: gate-2-3" >&2
  exit 3
fi

PLAN="$1"
GATE_ID_RAW="$2"

[[ -f "$PLAN" ]] || { echo "Plan not found: $PLAN" >&2; exit 3; }

# Normalize gate-id: "gate-2-3" or "Gate 2→3" or "Gate 2-3" → "2-3" / "2→3"
# Look for both "Gate 2→3" and "gate-2-3" forms in the plan.
NORM="${GATE_ID_RAW#gate-}"
NORM="${NORM#Gate }"
# Try to find the gate line; match either "Gate 2→3" or "gate-2-3" anywhere
GATE_LINE=""
GATE_LINE_NO=""
while IFS= read -r match; do
  LN="${match%%:*}"
  CONTENT="${match#*:}"
  if echo "$CONTENT" | grep -qE "Gate ${NORM//-/[→-]}|gate-${NORM//→/-}"; then
    GATE_LINE="$CONTENT"
    GATE_LINE_NO="$LN"
    break
  fi
done < <(grep -nE '^- \[[ x]\] \*\*Gate' "$PLAN")

if [[ -z "$GATE_LINE" ]]; then
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
    CONFIG="$(git rev-parse --show-toplevel)/.claude/agent-coord-config.json"
    if [[ ! -f "$CONFIG" ]]; then
      echo "Partner-gate requires $CONFIG (copy from .claude/agent-coord-config.example.json)" >&2
      exit 4
    fi
    AUTH_KEY="$(python3 -c "import json,sys; print(json.load(open('$CONFIG'))['authKey'])")"
    AUTH_USER="$(python3 -c "import json,sys; print(json.load(open('$CONFIG'))['user'])")"
    API_BASE="$(python3 -c "import json,sys; d=json.load(open('$CONFIG')); print(d.get('apiBase','https://api.getapexinsights.com'))")"

    GATE_TITLE="$(echo "$GATE_LINE" | grep -oE 'Gate [0-9→-]+' | head -1)"
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

    HTTP_CODE="$(curl -sS -o /tmp/decide-plan-gate-resp.json -w '%{http_code}' \
      -X POST "$API_BASE/api/agent-coordination/inbox" \
      -H "Content-Type: application/json" \
      -H "X-Agent-Auth: $AUTH_KEY" \
      -H "X-Agent-User: $AUTH_USER" \
      -d "$BODY")"

    if [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
      echo "AWAITING PARTNER — inbox item written for $PARTNER_EMAIL"
      cat /tmp/decide-plan-gate-resp.json
      echo
      exit 2
    else
      echo "Failed to write inbox item (HTTP $HTTP_CODE):" >&2
      cat /tmp/decide-plan-gate-resp.json >&2
      exit 4
    fi
    ;;
esac
