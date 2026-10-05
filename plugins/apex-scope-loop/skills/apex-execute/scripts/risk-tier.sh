#!/usr/bin/env bash
# risk-tier.sh — Classify a task's diff into The Gibson's risk tiers (A/B/C)
# and record the result in the checkpoint. Adapted from The Gibson's Law 7
# ("Tier C is sacred") — see docs/GIBSON_HARNESS.md.
#
#   A  routine: docs, tests, isolated components
#   B  elevated: shared modules / API routes, >150 changed lines or >6 files
#   C  money, auth, consent/PII, security boundaries, schema, incident
#      alerting, production data → fan-out + adversarial review AND a human
#      approval (G12) before the task can be checked off
#
# Usage: ./risk-tier.sh PLAN.md LINE_NO [--since SHA] [--tags t1,t2] [--classify]
#   --classify  also ask the decision layer (${APEX_DECIDE_CMD}, rubric
#               risk-tier@1) and combine as max(heuristic, decision): a
#               decision can raise the tier, never lower it (spec §6). Absent,
#               failing or malformed: the heuristic stands, noted in REASON.
#   --since  diff base for this task. Default and latest allowed: the chain
#            floor (TASK_BASE in iterate.sh's brief: the head the last reviewed
#            complete verified, else the run's fork point). An earlier base
#            only widens the diff.
#   --no-record  print the classification of the diff without recording it
#               (checkpoint.sh complete recomputes the tier this way).
#   --tags   extra tags; the task's own tags are always read from the plan.
#            [security] or [tier:c] force Tier C.
#
# Tier only ratchets upward: a line already recorded as C stays C.
#
# Emits: TIER: A|B|C, then one REASON: line per trigger.
set -euo pipefail

PLAN="${1:?usage: risk-tier.sh PLAN.md LINE_NO [--since SHA] [--tags t1,t2]}"
LINE_NO="${2:?line_no required}"
shift 2
SINCE=""; TAGS=""; CLASSIFY=0; NO_RECORD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="${2:?}"; shift 2 ;;
    --tags)  TAGS="${2-}"; shift 2 ;;
    --classify) CLASSIFY=1; shift ;;
    --no-record) NO_RECORD=1; shift ;;
    *) echo "ERROR: unknown arg $1" >&2; exit 2 ;;
  esac
done
[[ -f "$PLAN" ]] || { echo "ERROR: plan not found: $PLAN" >&2; exit 2; }
[[ "$LINE_NO" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "ERROR: LINE_NO must be a plan line number, got '$LINE_NO'" >&2; exit 2; }

APEX_RESOLVE_MODE=act  # this script acts: a repository mismatch is fatal (never inherited from the env)
# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
apex_resolve "$PLAN"
[[ -f "$CHECKPOINT" ]] || { echo "ERROR: not initialized — run init.sh first" >&2; exit 2; }
python3 "$APEX_EXECUTE_SCRIPTS/planlib.py" validate "$PLAN" >/dev/null 2>&1 \
  || { echo "ERROR: the plan is invalid — run: planlib.py validate $PLAN" >&2; exit 2; }
python3 "$APEX_EXECUTE_SCRIPTS/planlib.py" task "$PLAN" "$LINE_NO" >/dev/null 2>&1 \
  || { echo "ERROR: line $LINE_NO is not a task in $PLAN" >&2; exit 2; }

WT="$(read_field worktree_path)"; WT="${WT:-$REPO_ROOT}"
BASE_BRANCH="$(read_field base_branch)"

# The task's own tags always count (a caller cannot drop [tier:c]).
PLAN_TAGS="$(python3 -c 'import json,sys; print(",".join(json.loads(sys.argv[1])["tags"]))' "$(python3 "$APEX_EXECUTE_SCRIPTS/planlib.py" task "$PLAN" "$LINE_NO")")"
TAGS="${TAGS:+$TAGS,}$PLAN_TAGS"
# The task's diff base is the chain floor (ADR-0003; apex_floor in _lib.sh).
# --since may only widen the diff (an ancestor of the floor), never narrow it.
FLOOR="$(apex_floor "$WT")" \
  || { echo "ERROR: no diff base: this run has no fork point recorded (iterate.sh records it for a worktree run; a run without a worktree that predates the chain needs a new run)" >&2; exit 2; }
[[ -n "$SINCE" ]] || SINCE="$FLOOR"
SINCE="$(git -C "$WT" rev-parse -q --verify "${SINCE}^{commit}" 2>/dev/null)" \
  || { echo "ERROR: --since is not a commit in $WT" >&2; exit 2; }
HEAD_NOW="$(git -C "$WT" rev-parse HEAD)"
if ! git -C "$WT" merge-base --is-ancestor "$SINCE" "$FLOOR" 2>/dev/null; then
  echo "ERROR: --since ${SINCE:0:12} is later than this task's base ${FLOOR:0:12} — it would hide the task's own commits; use --since $FLOOR (TASK_BASE) or omit --since" >&2
  exit 2
fi

# Committed changes since SINCE plus anything still uncommitted. Renames are
# split into delete + add (an auth file moved to a bland name keeps its old
# path in the list); paths are not octal-quoted.
# Submodule bumps count even when .gitmodules says ignore = all. Only in a run
# without a worktree (the plan and the lessons ledger are edited in place in
# the same checkout) are those two exact files left out: the plan file when it
# is a regular .md file, the ledger only at .claude/apex-scope-loop/LESSONS.md.
GIT=(git -c core.quotepath=false -C "$WT")
DIFF_OPTS=(--no-renames --ignore-submodules=none --no-ext-diff)
EXCL=()
if [[ -z "$(read_field worktree_branch)" ]]; then
  for p in "$PLAN_ABS" "${LESSONS_LEDGER:-}"; do
    [[ -n "$p" && -f "$p" && ! -L "$p" ]] || continue
    rel="$(python3 -c 'import os,sys; r=os.path.relpath(os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])); print("" if r.startswith("..") else r)' "$p" "$WT")"
    [[ -n "$rel" ]] || continue
    if [[ "$p" == "$PLAN_ABS" ]]; then [[ "$rel" == *.md ]] || continue
    else [[ "$rel" == ".claude/apex-scope-loop/LESSONS.md" ]] || continue; fi
    EXCL+=(":(exclude,top,literal)$rel")
  done
fi
PATHSPEC=(-- . "${EXCL[@]}")
FILES="$( { "${GIT[@]}" diff "${DIFF_OPTS[@]}" --name-only "$SINCE" "$HEAD_NOW" "${PATHSPEC[@]}"; "${GIT[@]}" diff "${DIFF_OPTS[@]}" --name-only HEAD "${PATHSPEC[@]}"; \
            "${GIT[@]}" ls-files --others --exclude-standard "${PATHSPEC[@]}"; } 2>/dev/null | sort -u | sed '/^$/d')"
LINES="$( { "${GIT[@]}" diff "${DIFF_OPTS[@]}" --numstat "$SINCE" "$HEAD_NOW" "${PATHSPEC[@]}"; "${GIT[@]}" diff "${DIFF_OPTS[@]}" --numstat HEAD "${PATHSPEC[@]}"; } 2>/dev/null \
          | awk '$1 ~ /^[0-9]+$/ {s += $1 + $2} END {print s + 0}')"
NFILES="$(printf '%s\n' "$FILES" | sed '/^$/d' | wc -l | tr -d ' ')"

TIER="A"
REASONS=()
raise() { # raise <tier> <reason>
  case "$1$TIER" in C*|BA) TIER="$1" ;; esac
  REASONS+=("$2")
}

# Tier C: path signals (case-insensitive). Fail closed: a false positive only
# costs review; a miss lands an auth change unreviewed. Every token matches
# anywhere in the path ("jwtverify", "clusterrolebinding", "AzureADSSO",
# "aclv2"). "sso" and "acl" also occur inside ordinary words: an occurrence is
# ignored only when it lies wholly inside one path word (split at
# punctuation, digits and camelCase humps) that is exactly an allowlisted
# word ("lessons", "processor", "oracle", …). "associateSSOIdentity",
# "lessonsso" and "ProcessorSSO" stay Tier C.
C_PATHS='(auth|login|logout|session|oauth|password|passwd|credential|permission|billing|payment|stripe|paypal|invoice|pricing|checkout|subscription|refund|ledger|wallet|consent|gdpr|ccpa|privacy|personal|migration|migrate|schema|\.sql$|prisma|secret|crypto|encrypt|security|middleware|rate.?limit|webhook|alert|pagerduty|oncall|incident|prod(uction)?[-_.]?(data|db|config)|jwt|rbac|saml|pii|csp|cors|role)'
SHORT_HITS="$(printf '%s\n' "$FILES" | python3 -c '
import re, sys
BENIGN = set("""lesson lessons processor processors accessor accessors successor successors predecessor
predecessors compressor compressors associate associates associated association associations associative
dossier dossiers crossover crossovers lasso lassos oracle oracles miracle miracles spectacle spectacles
tentacle tentacles obstacle obstacles pinnacle pinnacles debacle debacles receptacle receptacles barnacle
barnacles manacle manacles coracle coracles""".split())
WORD = re.compile(r"[A-Z]{2,}s(?![a-z])|[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+")
for path in sys.stdin.read().splitlines():
    spans = [(m.start(), m.end(), m.group().lower()) for m in WORD.finditer(path)]
    for m in re.finditer(r"(?i)(?=(sso|acl))", path):   # offsets in the original string
        a = m.start()
        if not any(s <= a and a + 3 <= e and w in BENIGN for s, e, w in spans):
            print(path)
            break')"
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if printf '%s' "$f" | grep -qiE "$C_PATHS" || grep -qxF -- "$f" <<<"$SHORT_HITS"; then
    raise C "tier-c path: $f"
  fi
done <<<"$FILES"

# Tier C: content signals in added lines (catches risk in innocuously named files).
C_CONTENT='(stripe|charge\(|amount_cents|price|currency|bcrypt|argon2|jwt\.|verify_?token|set-cookie|httponly|samesite|csrf|consent|date_of_birth|ssn|social_security|DROP (TABLE|COLUMN)|ALTER TABLE|DELETE FROM|TRUNCATE)'
ADDED="$( { "${GIT[@]}" diff "${DIFF_OPTS[@]}" --text --no-textconv -U0 "$SINCE" "$HEAD_NOW" "${PATHSPEC[@]}"; "${GIT[@]}" diff "${DIFF_OPTS[@]}" --text --no-textconv -U0 HEAD "${PATHSPEC[@]}"; } 2>/dev/null | tr -d '\000' | grep -aE '^\+[^+]' || true)"
if [[ -n "$ADDED" ]] && printf '%s' "$ADDED" | grep -aqiE "$C_CONTENT"; then
  hit="$(printf '%s' "$ADDED" | grep -aoiE "$C_CONTENT" | head -1)"
  raise C "tier-c content signal in diff: '$hit'"
fi

# Tier C: explicit tags.
case ",$TAGS," in
  *,security,*|*,tier:c,*|*,tier-c,*) raise C "task tagged [${TAGS}]" ;;
esac

# Tier B: size and shared-surface signals.
[[ "$LINES" -gt 150 ]] && raise B "diff size: $LINES changed lines (>150)"
[[ "$NFILES" -gt 6 ]] && raise B "diff breadth: $NFILES files (>6)"
if printf '%s\n' "$FILES" | grep -qiE '(^|/)(api|routes?|shared|common|core|lib)/'; then
  raise B "touches a shared module or API route"
fi

# Decision layer (optional): max(heuristic, decision). The state holds
# observed facts only (paths, sizes, tags), never another model's labels.
if [[ "$CLASSIFY" == "1" ]]; then
  if [[ -n "${APEX_DECIDE_CMD:-}" ]]; then
    DSTATE="$(python3 - "$FILES" "$LINES" "$NFILES" "$TAGS" <<'PY'
import json, sys
files, lines, nfiles, tags = sys.argv[1:]
print(json.dumps({"changed_paths": [f for f in files.splitlines() if f][:200], "changed_lines": int(lines or 0),
                  "changed_files": int(nfiles or 0), "task_tags": [t for t in tags.split(",") if t]}))
PY
)"
    # Timeout in python: no dependency on coreutils `timeout` (absent on stock macOS).
    DOUT="$(python3 -c '
import subprocess, sys
cmd, state, limit = sys.argv[1:]
try:
    p = subprocess.run(["bash", "-c", cmd + " --rubric risk-tier@1 --state \"$1\" --json", "_", state],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=float(limit))
    sys.stdout.write(p.stdout.decode("utf-8", "replace"))
except Exception:
    pass' "$APEX_DECIDE_CMD" "$DSTATE" "${APEX_DECIDE_TIMEOUT:-10}" 2>/dev/null || true)"
    DTIER="$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
v = str(d.get("verdict", "")).strip().upper()
print(v if v in ("A", "B", "C") and not d.get("uncertain") else "")' "$DOUT" 2>/dev/null || true)"
    if [[ -n "$DTIER" ]]; then
      raise "$DTIER" "decision layer risk-tier@1: $DTIER"
    else
      REASONS+=("decision layer: no usable answer (absent, uncertain or malformed); heuristic stands")
    fi
  else
    REASONS+=("decision layer: APEX_DECIDE_CMD not set; heuristic only")
  fi
fi

# Persist (tier only ratchets upward — diffs may drift into C, never out).
# Under checkpoint.sh's state lock, written atomically. --no-record (used by
# checkpoint.sh complete) prints the heuristic for the diff without recording.
[[ "$NO_RECORD" == "1" ]] || TIER="$(python3 - "$CHECKPOINT" "$LINE_NO" "$TIER" "$SINCE" "$STATE_DIR/.checkpoint.lock" "$HEAD_NOW" <<'PY'
import fcntl, json, os, sys
path, line_no, tier, since, lock, head = sys.argv[1:]
fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)
s = json.load(open(path))
tiers = s.setdefault("tiers", {})
prev = (tiers.get(line_no) or {}).get("tier", "A")
order = {"A": 0, "B": 1, "C": 2}
final = tier if order[tier] >= order.get(prev, 0) else prev
# `head` binds the tier to the code it classified: complete refuses a tier
# recorded for an older head.
tiers[line_no] = {"tier": final, "since": since, "head": head}
tmp = path + ".tmp"
try:
    os.unlink(tmp)
except FileNotFoundError:
    pass
with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o644), "w") as f:
    json.dump(s, f, indent=2)
os.replace(tmp, path)
print(final)
PY
)"

echo "TIER: $TIER"
echo "HEAD: $HEAD_NOW"
echo "DIFF: $NFILES file(s), $LINES line(s) since ${SINCE:0:12}"
if [[ ${#REASONS[@]} -eq 0 ]]; then
  echo "REASON: no elevated-risk signals"
else
  printf 'REASON: %s\n' "${REASONS[@]}" | awk '!seen[$0]++' | head -20
fi
case "$TIER" in
  C) echo "REQUIRES: fan-out review (six lenses) + adversarial refutation + human approval G12 before check-off" ;;
  B) echo "REQUIRES: full six-lens independent review" ;;
  A) echo "REQUIRES: solo independent review" ;;
esac
