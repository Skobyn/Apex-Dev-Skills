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
#   --classify  also ask the decision layer (${APEX_DECIDE_CMD}, else the sibling
#               apex-decision-layer; rubric risk-tier@1) and combine as
#               max(heuristic, decision): a decision can raise the tier, never
#               lower it (spec §6), and an uncalibrated one raises at most to B.
#               Absent, unscored, uncertain or malformed: the heuristic stands,
#               noted in REASON.
#   --since  diff base for this task. Default and latest allowed: the chain
#            floor (TASK_BASE in iterate.sh's brief: the head the last reviewed
#            complete verified, else the run's fork point). An earlier base
#            only widens the diff.
#   --no-record  print the classification of the diff without recording it
#               (checkpoint.sh complete recomputes the tier this way).
#   --tags   extra tags; the task's own tags are always read from the plan.
#            [security] or [tier:c] force Tier C. [tier:a] / [tier:b] are
#            authoritative over the Tier B signals and the content signals,
#            never over Tier C path signals or [security] / [tier:c] (ADR-0004).
#   --raise A|B|C --reason TEXT  record a higher tier a reviewer asked for (with
#            its reason; the tier only ratchets up). [tier:a]/[tier:b] take
#            effect only as [tier:a reason="..."] / [tier:b reason="..."];
#            the reason is recorded in the tier record.
#   Size and breadth alone never go above Tier B (one six-lens reviewer, no
#   fan-out, no G12); only Tier C brings the fan-out, adversarial pass and G12.
#   Content signals in added lines of test/fixture/smoke/example/docs files
#   are ignored (noted in a REASON line); their paths are still classified.
#
# Tier only ratchets upward: a line already recorded as C stays C.
#
# Emits: TIER: A|B|C, then one REASON: line per trigger.
set -euo pipefail

PLAN="${1:?usage: risk-tier.sh PLAN.md LINE_NO [--since SHA] [--tags t1,t2]}"
LINE_NO="${2:?line_no required}"
shift 2
SINCE=""; TAGS=""; CLASSIFY=0; NO_RECORD=0; RAISE=""; RAISE_REASON=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --raise) RAISE="${2:?}"; shift 2 ;;
    --reason) RAISE_REASON="${2-}"; shift 2 ;;
    --since) SINCE="${2:?}"; shift 2 ;;
    --tags)  TAGS="${2-}"; shift 2 ;;
    --classify) CLASSIFY=1; shift ;;
    --no-record) NO_RECORD=1; shift ;;
    *) echo "ERROR: unknown arg $1" >&2; exit 2 ;;
  esac
done
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"; PLAN="$(apex_locate_plan "$PLAN")"   # ADR-0004 H
[[ -f "$PLAN" ]] || { echo "ERROR: plan not found: $PLAN" >&2; exit 2; }
[[ "$LINE_NO" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "ERROR: LINE_NO must be a plan line number, got '$LINE_NO'" >&2; exit 2; }
if [[ -n "$RAISE" ]]; then
  [[ "$RAISE" =~ ^[ABC]$ ]] || { echo "ERROR: --raise takes A, B or C" >&2; exit 2; }
  [[ -n "${RAISE_REASON//[[:space:]]/}" ]] || { echo "ERROR: --raise needs --reason \"<why, e.g. the reviewer's finding>\"" >&2; exit 2; }
fi

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
TASK_JSON="$(python3 "$APEX_EXECUTE_SCRIPTS/planlib.py" task "$PLAN" "$LINE_NO")"
PLAN_TAGS="$(python3 -c 'import json,sys; print(",".join(json.loads(sys.argv[1])["tags"]))' "$TASK_JSON")"
# An explicit tier override: [tier:a reason="..."] / [tier:b reason="..."] (the reason is required).
OVERRIDE="$(python3 -c 'import json,sys; o=json.loads(sys.argv[1]).get("tier_override") or {}; print((o.get("tier") or "").upper() + "\t" + (o.get("reason") or "") if o.get("reason") else "")' "$TASK_JSON")"
TAGS="${TAGS:+$TAGS,}$PLAN_TAGS"
# The task's diff base is the chain floor (ADR-0003; apex_floor in _lib.sh).
# --since may only widen the diff (an ancestor of the floor), never narrow it.
FLOOR="$(apex_floor "$WT")" \
  || { echo "ERROR: no diff base (apex_floor reason above)" >&2; exit 2; }
[[ -n "$SINCE" ]] || SINCE="$FLOOR"
SINCE="$(apex_git "$WT" rev-parse -q --verify "${SINCE}^{commit}" 2>/dev/null)" \
  || { echo "ERROR: --since is not a commit in $WT" >&2; exit 2; }
HEAD_NOW="$(apex_git "$WT" rev-parse HEAD)"
if ! apex_git "$WT" merge-base --is-ancestor "$SINCE" "$FLOOR" 2>/dev/null; then
  echo "ERROR: --since ${SINCE:0:12} is later than this task's base ${FLOOR:0:12} — it would hide the task's own commits; use --since $FLOOR (TASK_BASE) or omit --since" >&2
  exit 2
fi

# Committed changes since SINCE plus anything still uncommitted. Renames are
# split into delete + add (an auth file moved to a bland name keeps its old
# path in the list); paths are not octal-quoted.
# Submodule bumps count even when .gitmodules says ignore = all. Only in a run
# without a worktree (the plan and the lessons/backlog ledgers are edited in place in
# the same checkout) are those exact files left out: the plan file when it
# is a regular .md file, the ledgers only at .claude/apex-scope-loop/{LESSONS,BACKLOG}.md.
GIT=(apex_git "$WT")
DIFF_OPTS=(--no-color --no-renames --ignore-submodules=none --no-ext-diff)
EXCL=()
if [[ -z "$(read_field worktree_branch)" ]]; then
  for p in "$PLAN_ABS" "${LESSONS_LEDGER:-}" "${BACKLOG_LEDGER:-}"; do
    [[ -n "$p" && -f "$p" && ! -L "$p" ]] || continue
    rel="$(python3 -c 'import os,sys; r=os.path.relpath(os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])); print("" if r.startswith("..") else r)' "$p" "$WT")"
    [[ -n "$rel" ]] || continue
    if [[ "$p" == "$PLAN_ABS" ]]; then [[ "$rel" == *.md ]] || continue
    else [[ "$rel" == ".claude/apex-scope-loop/LESSONS.md" || "$rel" == ".claude/apex-scope-loop/BACKLOG.md" ]] || continue; fi
    EXCL+=(":(exclude,top,literal)$rel")
  done
fi
PATHSPEC=(-- . ${EXCL[@]+"${EXCL[@]}"})   # bash 3.2 (macOS) + set -u: an empty array is "unbound"
# Paths are read NUL-separated (git C-quotes control characters even with
# quotepath off, and a quote escape can fuse with the next word); control
# characters become "_" (a word break) before classification.
FILES="$( { "${GIT[@]}" diff "${DIFF_OPTS[@]}" --name-only -z "$SINCE" "$HEAD_NOW" "${PATHSPEC[@]}"; "${GIT[@]}" diff "${DIFF_OPTS[@]}" --name-only -z HEAD "${PATHSPEC[@]}"; \
            "${GIT[@]}" ls-files -z --others --exclude-standard "${PATHSPEC[@]}"; } 2>/dev/null | python3 -c '
import re, sys
paths = {re.sub(r"[\x00-\x1f\x7f]", "_", p.decode("utf-8", "surrogateescape")) for p in sys.stdin.buffer.read().split(b"\0") if p}
sys.stdout.buffer.write("".join(sorted(p + "\n" for p in paths)).encode("utf-8", "surrogateescape"))')"
LINES="$( { "${GIT[@]}" diff "${DIFF_OPTS[@]}" --numstat "$SINCE" "$HEAD_NOW" "${PATHSPEC[@]}"; "${GIT[@]}" diff "${DIFF_OPTS[@]}" --numstat HEAD "${PATHSPEC[@]}"; } 2>/dev/null \
          | awk '$1 ~ /^[0-9]+$/ {s += $1 + $2} END {print s + 0}')"
NFILES="$(printf '%s\n' "$FILES" | sed '/^$/d' | wc -l | tr -d ' ')"

TIER="A"
REASONS=()
raise() { # raise <tier> <reason>
  case "$1$TIER" in C*|BA) TIER="$1" ;; esac
  REASONS+=("$2")
}
# An explicit [tier:a] / [tier:b] tag (ADR-0004) is authoritative over the
# Tier B size/breadth/shared signals and the content signals, never over a
# Tier C path signal or a [security] / [tier:c] tag (nor the decision layer).
# The override needs a reason (ADR-0004 addendum E); a bare [tier:a] / [tier:b]
# tag is noted and has no effect.
TAG_TIER=""; TAG_REASON=""
if [[ -n "$OVERRIDE" ]]; then TAG_TIER="${OVERRIDE%%$'\t'*}"; TAG_REASON="${OVERRIDE#*$'\t'}"; fi
case ",$TAGS," in *,tier:a,*|*,tier-a,*|*,tier:b,*|*,tier-b,*)
  [[ -n "$TAG_TIER" ]] || REASONS+=("a bare [tier:a]/[tier:b] tag has no effect: write [tier:a reason=\"...\"] or [tier:b reason=\"...\"]") ;;
esac

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
  if grep -aqiE "$C_PATHS" <<<"$f" || grep -aqxF -- "$f" <<<"$SHORT_HITS"; then
    raise C "tier-c path: $f"
  fi
done <<<"$FILES"

# Tier C: content signals in added lines (catches risk in innocuously named
# files). Calibrated (ADR-0004): added lines of test, fixture, smoke, example
# and docs files are not scanned (test data that names "stripe" is not money
# code); their paths still are. A file is exempt only when its diff header
# parses cleanly; anything unparsed is scanned (fail closed).
C_CONTENT='(stripe|charge\(|amount_cents|price|currency|bcrypt|argon2|jwt\.|verify_?token|set-cookie|httponly|samesite|csrf|consent|date_of_birth|ssn|social_security|DROP (TABLE|COLUMN)|ALTER TABLE|DELETE FROM|TRUNCATE)'
CONTENT_OUT="$( { "${GIT[@]}" diff "${DIFF_OPTS[@]}" --text --no-textconv -U0 "$SINCE" "$HEAD_NOW" "${PATHSPEC[@]}"; "${GIT[@]}" diff "${DIFF_OPTS[@]}" --text --no-textconv -U0 HEAD "${PATHSPEC[@]}"; } 2>/dev/null \
  | python3 -c '
import re, sys
pat = re.compile(sys.argv[1], re.I)
EXEMPT_DIR = re.compile(r"(^|/)(tests?|__tests__|spec|fixtures?|examples?|docs?)/", re.I)
def exempt(path):
    if path is None:
        return False
    base = path.rsplit("/", 1)[-1].lower()
    return bool(EXEMPT_DIR.search(path) or re.search(r"_test\.[^/]*$", base) or re.search(r"\.test\.[^/]*$", base)
                or re.search(r"(^|/)(scripts|tests?)/(.*/)?[^/]*smoke[^/]*$", path, re.I))
def unquote(h):
    """b/<path> from a +++ header; None when it cannot be read exactly."""
    h = h.rstrip("\n")
    if h.startswith("\""):
        if not h.endswith("\"") or len(h) < 2:
            return None
        try:
            h = h[1:-1].encode("latin-1", "backslashreplace").decode("unicode_escape").encode("latin-1").decode("utf-8")
        except Exception:
            return None
    if "\t" in h:
        h = h.split("\t", 1)[0]
    return h[2:] if h.startswith("b/") else None
cur, in_hdr, skipped = None, False, set()
hits, md_hits = {}, {}     # every distinct term -> first file (code; Markdown outside docs/)
for raw in sys.stdin.buffer:
    line = raw.decode("utf-8", "surrogateescape").replace("\0", "")
    if line.startswith("diff --git "):
        cur, in_hdr = None, True
        continue
    if in_hdr:
        if line.startswith("+++ "):
            cur = unquote(line[4:].encode("utf-8", "surrogateescape").decode("utf-8", "replace"))
        elif line.startswith("@@"):
            in_hdr = False
        continue
    if not line.startswith("+"):
        continue
    ms = list(pat.finditer(line[1:]))
    if not ms:
        continue
    if exempt(cur):
        skipped.add(cur)
        continue
    # Markdown is documentation unless it ships as product (the agents,
    # skills, commands or hooks of a plugin): there Tier C terms keep Tier C.
    is_md = cur is not None and cur.lower().endswith((".md", ".markdown")) \
        and not re.search(r"(^|/)(agents|skills|commands|hooks)/", cur)
    for m in ms:
        term = m.group(0).lower()
        (md_hits if is_md else hits).setdefault(term, (m.group(0), cur or "?"))
for term, (t, f) in hits.items():
    print("HIT\t%s\t%s" % (t, f))
for term, (t, f) in md_hits.items():
    if term not in hits:
        print("MDHIT\t%s\t%s" % (t, f))
for p in sorted(skipped)[:5]:
    print("SKIP\t" + p)
if len(skipped) > 5:
    print("SKIP\t... and %d more" % (len(skipped) - 5))
' "$C_CONTENT" 2>/dev/null || echo "HIT	(could not scan the diff)	?")"
CONTENT_HITS=(); MD_HITS=()
while IFS=$'\t' read -r kind a b; do
  case "$kind" in
    HIT) CONTENT_HITS+=("tier-c content signal in diff: '$a' ($b)") ;;
    MDHIT) MD_HITS+=("'$a' ($b)") ;;
    SKIP) REASONS+=("content signals ignored in test/fixture/smoke/example/docs file: $a (its path is still classified)") ;;
  esac
done <<<"$CONTENT_OUT"
# Every distinct Tier C content term is its own signal (ADR-0004 §8b): each
# is checked against an override's reason, printed and recorded.
OVERRIDDEN_C=()
for CONTENT_HIT in ${CONTENT_HITS[@]+"${CONTENT_HITS[@]}"}; do
  if [[ -n "$TAG_TIER" ]]; then
    REASONS+=("$CONTENT_HIT — overridden by the task's [tier:$(tr 'AB' 'ab' <<<"$TAG_TIER") reason=\"$TAG_REASON\"] (reviewers: say so if this is real Tier C)")
    # Bound to its reason: a signal the reason does not mention was not
    # anticipated by the plan and is printed prominently.
    if python3 -c 'import re,sys; t=re.sub(r"[^a-z0-9]+","",sys.argv[1].lower()); sys.exit(0 if t and t in re.sub(r"[^a-z0-9]+","",sys.argv[2].lower()) else 1)' "$(sed -n "s/^tier-c content signal in diff: '\(.*\)' (.*/\1/p" <<<"$CONTENT_HIT")" "$TAG_REASON"; then
      OVERRIDDEN_C+=("TIER_C_OVERRIDDEN: $CONTENT_HIT — anticipated by the override reason \"$TAG_REASON\"")
    else
      OVERRIDDEN_C+=("TIER_C_UNANTICIPATED: $CONTENT_HIT — the override reason \"$TAG_REASON\" does not mention it; reviewers must decide whether this is real Tier C (raise with risk-tier.sh --raise C --reason ...)")
    fi
  else
    raise C "$CONTENT_HIT"
  fi
done
# Tier C content terms found only in Markdown outside docs/ give Tier B.
if [[ ${#MD_HITS[@]} -gt 0 ]]; then
  if [[ -n "$TAG_TIER" ]]; then
    REASONS+=("tier-c content terms only in Markdown: ${MD_HITS[*]} — the task's [tier:$(tr 'AB' 'ab' <<<"$TAG_TIER") reason=\"$TAG_REASON\"] decides")
  else
    raise B "tier-c content terms only in Markdown (Tier B, not C): ${MD_HITS[*]}"
  fi
fi

# Tier C: explicit tags.
case ",$TAGS," in
  *,security,*|*,tier:c,*|*,tier-c,*) raise C "task tagged [${TAGS}]" ;;
esac

# Tier B: size and shared-surface signals (never above B; a [tier:a] /
# [tier:b] tag decides instead of them).
BSIG=()
[[ "$LINES" -gt 150 ]] && BSIG+=("diff size: $LINES changed lines (>150)")
[[ "$NFILES" -gt 6 ]] && BSIG+=("diff breadth: $NFILES files (>6)")
if grep -aqiE '(^|/)(api|routes?|shared|common|core|lib)/' <<<"$FILES"; then
  BSIG+=("touches a shared module or API route")
fi
if [[ -n "$TAG_TIER" ]]; then
  for b in ${BSIG[@]+"${BSIG[@]}"}; do REASONS+=("$b — the task's [tier:$(tr 'AB' 'ab' <<<"$TAG_TIER") reason=\"$TAG_REASON\"] decides"); done
  [[ "$TAG_TIER" == B ]] && raise B "task override [tier:b reason=\"$TAG_REASON\"]"
else
  for b in ${BSIG[@]+"${BSIG[@]}"}; do raise B "$b"; done
fi

# The lens each Tier C signal belongs to (ADR-0004: a Tier C lens narrowing
# must keep them), from every Tier C reason, an overridden content signal included.
SIGNAL_LENSES="$(printf '%s\n' ${REASONS[@]+"${REASONS[@]}"} | python3 -c '
import re, sys
sig = [l for l in sys.stdin.read().splitlines() if l.startswith(("tier-c ", "task tagged"))]
txt = "\n".join(sig).lower()
out = []
if re.search(r"stripe|paypal|billing|payment|invoice|pricing|price|checkout|subscription|refund|ledger|wallet|charge\(|amount_cents|currency|money", txt):
    out.append("money")
if re.search(r"auth|login|logout|session|oauth|password|passwd|credential|permission|secret|crypto|encrypt|security|middleware|jwt|rbac|saml|csp|cors|role|bcrypt|argon2|verify_?token|set-cookie|httponly|samesite|csrf|sso|acl", txt):
    out.append("security")
if re.search(r"consent|gdpr|ccpa|privacy|personal|pii|date_of_birth|ssn|social_security", txt):
    out.append("consent-pii")
print(",".join(out))' 2>/dev/null || true)"

# A reviewer-raised tier (recorded by the orchestrator with its reason).
[[ -n "$RAISE" ]] && raise "$RAISE" "raised to Tier $RAISE: $RAISE_REASON"

# Decision layer (optional): max(heuristic, decision). The state holds
# observed facts only (paths, sizes, tags), never another model's labels.
if [[ "$CLASSIFY" == "1" ]]; then
  # The CLI (decision-layer spec §11.3): APEX_DECIDE_CMD overrides; else the sibling
  # apex-decision-layer's bin/apex-decide (APEX_DECISION_LAYER_ROOT overrides the lookup).
  # Called as an argv list with the state on stdin, never through a shell.
  DROOT="${APEX_DECISION_LAYER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)/apex-decision-layer}"
  DEXE=""; [[ -z "${APEX_DECIDE_CMD:-}" && -x "$DROOT/bin/apex-decide" ]] && DEXE="$DROOT/bin/apex-decide"
  if [[ -n "${APEX_DECIDE_CMD:-}" || -n "$DEXE" ]]; then
    DSTATE="$(python3 - "$FILES" "$LINES" "$NFILES" "$TAGS" <<'PY'
import json, sys
files, lines, nfiles, tags = sys.argv[1:]
print(json.dumps({"changed_paths": [f for f in files.splitlines() if f][:200], "changed_lines": int(lines or 0),
                  "changed_files": int(nfiles or 0), "task_tags": [t for t in tags.split(",") if t]}))
PY
)"
    # Timeout in python: no dependency on coreutils `timeout` (absent on stock macOS).
    DOUT="$(python3 -c '
import shlex, subprocess, sys
cmd, exe, state, limit = sys.argv[1:]
argv = shlex.split(cmd) if cmd else [exe]
lim = float(limit)
try:
    p = subprocess.run(argv + ["--rubric", "risk-tier@1", "--state", "-", "--json", "--deadline-ms", str(max(100, int(lim * 1000) - 400))],
                       input=state.encode(), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=lim)
    sys.stdout.write(p.stdout.decode("utf-8", "replace"))
except Exception:
    pass' "${APEX_DECIDE_CMD:-}" "$DEXE" "$DSTATE" "${APEX_DECIDE_TIMEOUT:-10}" 2>/dev/null || true)"
    # TIER|CALIBRATED|WHY: a usable tier only when scored, a known tier and not uncertain.
    DANS="$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("||malformed or no answer"); sys.exit(0)
if not isinstance(d, dict):
    print("||malformed answer"); sys.exit(0)
v = str(d.get("verdict", "")).strip().upper()
if d.get("scored") is False:
    print("||%s" % (d.get("reason") or "unscored")); sys.exit(0)
if d.get("uncertain"):
    print("||uncertain"); sys.exit(0)
if v not in ("A", "B", "C"):
    print("||no tier in the answer"); sys.exit(0)
print("%s|%s|" % (v, "calibrated" if d.get("calibrated") is True else "uncalibrated"))' "$DOUT" 2>/dev/null || echo '||malformed')"
    IFS='|' read -r DTIER DCAL DWHY <<<"$DANS"
    if [[ "$DTIER" == "C" && "$DCAL" != "calibrated" ]]; then
      # Decision Q3: an uncalibrated answer may raise to B, never to C (Tier C costs G12 and seven reviewers).
      raise B "decision layer risk-tier@1 said C, uncalibrated: not raised past B (reviewers: raise to C with --raise if real)"
    elif [[ -n "$DTIER" ]]; then
      raise "$DTIER" "decision layer risk-tier@1: $DTIER ($DCAL)"
    else
      REASONS+=("decision layer: no usable answer ($DWHY); heuristic stands")
    fi
  else
    REASONS+=("decision layer: not installed and APEX_DECIDE_CMD not set; heuristic only")
  fi
fi

# Persist (tier only ratchets upward — diffs may drift into C, never out).
# Under checkpoint.sh's state lock, written atomically. --no-record (used by
# checkpoint.sh complete) prints the heuristic for the diff without recording.
[[ "$NO_RECORD" == "1" ]] || TIER="$(python3 - "$CHECKPOINT" "$LINE_NO" "$TIER" "$SINCE" "$STATE_DIR/.checkpoint.lock" "$HEAD_NOW" "$TAG_TIER" "$TAG_REASON" "$RAISE" "$RAISE_REASON" "$(printf '%s\037' ${REASONS[@]+"${REASONS[@]}"})" "$SIGNAL_LENSES" "$(printf '%s\037' ${OVERRIDDEN_C[@]+"${OVERRIDDEN_C[@]}"})" <<'PY'
import fcntl, json, os, sys
path, line_no, tier, since, lock, head, ov_tier, ov_reason, raise_tier, raise_reason, reasons, sig, overridden = sys.argv[1:]
fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)
s = json.load(open(path))
tiers = s.setdefault("tiers", {})
prev = (tiers.get(line_no) or {}).get("tier", "A")
order = {"A": 0, "B": 1, "C": 2}
final = tier if order[tier] >= order.get(prev, 0) else prev
# `head` binds the tier to the code it classified: complete refuses a tier
# recorded for an older head.
epoch = s.get("epoch", 0)               # the tier still ratchets across a refork
prev_rec = tiers.get(line_no) or {}
rec = {"tier": final, "since": since, "head": head, "epoch": epoch}
if ov_tier:
    rec["override"] = {"tier": ov_tier, "reason": ov_reason}      # the plan's explicit override and why
raised = list(prev_rec.get("raised") or [])
if raise_tier:
    raised.append({"tier": raise_tier, "reason": raise_reason})  # a reviewer raised it (never lowers)
if raised:
    rec["raised"] = raised
# What reviewers must see (iterate.sh prints them as TIER_REASONS): every
# reason, the lenses of the Tier C signals, an overridden Tier C signal.
rec["reasons"] = [x for x in dict.fromkeys(reasons.split("\x1f")) if x][:30]
rec["signal_lenses"] = [x for x in sig.split(",") if x]
ov = [x for x in overridden.split("\x1f") if x]
if ov:
    rec["overridden_c"] = ov
tiers[line_no] = rec
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
[[ ${#OVERRIDDEN_C[@]} -gt 0 ]] && printf '%s\n' "${OVERRIDDEN_C[@]}"
echo "SIGNAL_LENSES: $SIGNAL_LENSES"
if [[ ${#REASONS[@]} -eq 0 ]]; then
  echo "REASON: no elevated-risk signals"
else
  printf 'REASON: %s\n' "${REASONS[@]}" | awk '!seen[$0]++ && n++ < 20'   # awk reads everything: no SIGPIPE
fi
case "$TIER" in
  C) echo "REQUIRES: fan-out review (six lenses) + adversarial refutation + human approval G12 before check-off" ;;
  B) echo "REQUIRES: full six-lens independent review" ;;
  A) echo "REQUIRES: solo independent review" ;;
esac
