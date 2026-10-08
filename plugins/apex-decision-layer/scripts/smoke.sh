#!/usr/bin/env bash
# apex-decision-layer smoke test
# Verifies the plugin contract from ADR-0001 against the scripted `fake` backend
# only (no network). Exits non-zero on the first failure with a named reason.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKET_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
D="$PLUGIN_ROOT/bin/apex-decide"
fail() { echo "smoke FAIL: $1" >&2; exit 1; }
ok()   { echo "smoke OK:   $1"; }
N=0; pass() { N=$((N + 1)); ok "$1"; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/apex-decision-layer-smoke.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# Decision-layer variables from the caller's environment must not leak into the checks.
unset APEX_DECIDE_CMD APEX_DECIDE_FAKE APEX_DECIDE_FAKE_RECORD APEX_DECISION_LAYER_ROOT APEX_STATE_ROOT || true

# --------------------------------------------------------------- structure ----

# 1. plugin.json exists and has required fields
PJ="$PLUGIN_ROOT/.claude-plugin/plugin.json"
[ -f "$PJ" ] || fail "missing $PJ"
for k in name version description author license keywords; do
  grep -q "\"$k\"" "$PJ" || fail "plugin.json missing key: $k"
done
grep -q '"name": "apex-decision-layer"' "$PJ" || fail "plugin.json name is not apex-decision-layer"
pass "plugin.json has name/version/description/author/license/keywords"

# 2. plugin.json does NOT enumerate skills/commands/agents arrays
for forbidden in '"skills"' '"commands"' '"agents"'; do
  if grep -qE "$forbidden[[:space:]]*:[[:space:]]*\[" "$PJ"; then
    fail "plugin.json enumerates $forbidden array (must be auto-discovered)"
  fi
done
pass "plugin.json does not enumerate skills/commands/agents"

# 3. registered in the marketplace with the same description, and a root README row
python3 - "$MARKET_ROOT/.claude-plugin/marketplace.json" "$PJ" <<'PY' || fail "apex-decision-layer not registered in marketplace.json with the plugin's description"
import json, sys
m = json.load(open(sys.argv[1])); p = json.load(open(sys.argv[2]))
e = [x for x in m["plugins"] if x.get("source") == "./plugins/apex-decision-layer"]
assert len(e) == 1 and e[0]["name"] == "apex-decision-layer" and e[0]["description"] == p["description"]
PY
grep -q '(plugins/apex-decision-layer)' "$MARKET_ROOT/README.md" || fail "root README has no apex-decision-layer row"
pass "registered in marketplace.json (same description) and in the root README"

# 4. README has the required sections and the same description
R="$PLUGIN_ROOT/README.md"
for h in "## Compatibility" "## Namespace coordination" "## Verification" "## Architecture Decisions"; do
  grep -q "^$h" "$R" || fail "README missing section: $h"
done
python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["description"]; assert d in open(sys.argv[2]).read()' "$PJ" "$R" \
  || fail "README does not carry plugin.json's description"
pass "README has Compatibility / Namespace coordination / Verification / Architecture Decisions and the description"

# 5. ADR-0001 exists with a status, and the namespace is claimed in README and ADR
ADR="$PLUGIN_ROOT/docs/adrs/0001-apex-decision-layer-contract.md"
[ -f "$ADR" ] || fail "missing $ADR"
grep -qE "^- \*\*Status:\*\* (Proposed|Accepted)" "$ADR" || fail "ADR-0001 has no Proposed/Accepted status"
for f in "$R" "$ADR"; do grep -q 'apex-decision-layer:rubrics/' "$f" || fail "$f does not claim the apex-decision-layer:* namespace"; done
pass "ADR-0001 exists with a status; namespace apex-decision-layer:* claimed"

# 6. commands: name matches the filename, description present
for c in "$PLUGIN_ROOT"/commands/*.md; do
  n="$(basename "$c" .md)"
  grep -q "^name: $n$" "$c" || fail "command $n: frontmatter name does not match the filename"
  grep -q '^description: ' "$c" || fail "command $n: no description"
done
pass "commands: name matches filename, description present"

# 7. skills: unquoted kebab-case name matching the directory, explicit allowed-tools without wildcards
for s in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
  n="$(basename "$(dirname "$s")")"
  grep -qE "^name: $n$" "$s" || fail "skill $n: name is not the unquoted directory name"
  printf '%s' "$n" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$' || fail "skill $n is not kebab-case"
  t="$(sed -n 's/^allowed-tools: //p' "$s")"
  [ -n "$t" ] || fail "skill $n has no allowed-tools"
  case "$t" in *'*'*) fail "skill $n uses a wildcard in allowed-tools";; esac
done
pass "skills: kebab-case name = directory, explicit allowed-tools, no wildcards"

# 8. scripts are executable and parse; no hooks are registered (an observational plugin emits no allow/deny)
for s in "$D" "$PLUGIN_ROOT/scripts/smoke.sh" "$PLUGIN_ROOT/scripts/lib/decide.py"; do
  [ -x "$s" ] || fail "not executable: $s"
done
bash -n "$D" || fail "bin/apex-decide does not parse"
python3 -m py_compile "$PLUGIN_ROOT/scripts/lib/decide.py" "$PLUGIN_ROOT/scripts/lib/backends/__init__.py" || fail "python sources do not compile"
find "$PLUGIN_ROOT" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
[ ! -e "$PLUGIN_ROOT/hooks" ] || fail "apex-decision-layer must not register hooks"
pass "scripts executable and parse; no hooks"

# 9. no platform coupling in engine sources
HITS="$(grep -rIl 'apex-app\|getapexinsights\|claude-flow' "$PLUGIN_ROOT/bin" "$PLUGIN_ROOT/scripts/lib" 2>/dev/null || true)"
[ -z "$HITS" ] || fail "engine sources reference apex-app/getapexinsights/claude-flow: $HITS"
pass "no apex-app/getapexinsights/claude-flow coupling in engine sources"

# 10. version is semver and the CLI reports it
python3 -c "import json,re,sys; v=json.load(open(sys.argv[1]))['version']; assert re.fullmatch(r'\d+\.\d+\.\d+', v)" "$PJ" || fail "version is not semver"
[ "$("$D" --version)" = "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PJ")" ] || fail "apex-decide --version != plugin.json version"
pass "version is semver; apex-decide --version matches"

# ---------------------------------------------------------------- behaviour ----

# A throwaway repository with run state (so the decision log is written).
R0="$WORK/repo"; mkdir -p "$R0/.dev-plan-state"; git init -q -b main "$R0"
CFG="$R0/.claude/apex-decision-layer"; LOG="$R0/.dev-plan-state/decisions/decisions.jsonl"
FAKE="$WORK/fake.json"; REC="$WORK/received.jsonl"
TC='dispatch/task-class@1'
TC_LABELS='["docs","tests","mechanical","feature","bugfix","migration","security","none"]'
TC_STATE='{"tags":["x"],"paths":["src/**"],"risk_tier":"A","acceptance_present":true,"acceptance_command":true,"toolchains":["npm"],"task_title":"Add a --dry-run flag","acceptance_text":"npm test","source":"plan","review_rounds":0}'
RT_STATE='{"changed_paths":["src/a.py"],"changed_lines":12,"changed_files":1,"task_tags":[]}'
# ask RUBRIC STATE [ARGS...] -> stdout envelope; exit code in $RC
ask() { local r="$1" s="$2"; shift 2; set +e; OUT="$(cd "$R0" && printf '%s' "$s" | "$D" --rubric "$r" --state - --json "$@" 2>"$WORK/err")"; RC=$?; set -e; }
fld() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); v=d
for k in sys.argv[2].split("."): v=v.get(k) if isinstance(v, dict) else None
print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$OUT" "$1"; }
# fake RUBRIC RESPONSE_JSON [extra entry keys as JSON] -> writes $FAKE with one scripted entry
fake() { python3 - "$FAKE" "$1" "$2" "${3:-}" <<'PY'
import json, sys
path, rubric, resp, extra = sys.argv[1:]
try:
    r = json.loads(resp)
except ValueError:
    r = resp                       # an unparsable body, sent as a string
e = dict(json.loads(extra or "{}"), response=r)
json.dump({rubric: e}, open(path, "w"))
PY
}
choice() { python3 -c 'import json,sys
labels=json.loads(sys.argv[1]); probs=json.loads(sys.argv[2]); full={l: probs.get(l, 0.0) for l in labels}
a={"choice": sys.argv[3], "probabilities": full}
if sys.argv[4] != "null": a["confidence"]=float(sys.argv[4])
print(json.dumps({"model": "fake-1", "id": "x", "provider": "fake", "answers": {sys.argv[5]: a}, "usage": {"input_tokens": 500, "output_tokens": 0, "cost": 0.00002}}))' "$@"; }
GOOD_TC="$(choice "$TC_LABELS" '{"feature":0.84,"bugfix":0.06,"docs":0.04,"tests":0.03,"none":0.03}' feature 0.8 class)"

# 11. lint: shipped rubrics pass with a stable hash; a wire change moves the hash; each authoring rule fails by name
"$D" lint >"$WORK/lint.out" || fail "shipped rubrics fail lint: $(cat "$WORK/lint.out")"
grep -q "^LINT OK $TC sha256:" "$WORK/lint.out" && grep -q '^LINT OK risk-tier@1 sha256:' "$WORK/lint.out" || fail "lint did not report both v1 rubrics: $(cat "$WORK/lint.out")"
[ "$("$D" lint)" = "$(cat "$WORK/lint.out")" ] || fail "question_hash is not stable across runs"
python3 - "$PLUGIN_ROOT" "$WORK" <<'PY' || fail "lint/question_hash rules"
import copy, json, os, sys
root, work = sys.argv[1:]
sys.path.insert(0, os.path.join(root, "scripts", "lib"))
import decide
r = json.load(open(os.path.join(root, "rubrics", "dispatch", "task-class@1.json")))
h = decide.question_hash(r)
t = copy.deepcopy(r); t["questions"]["class"]["uncertain"]["min_confidence"] = 0.9; t["backend_models"]["fake"] = "x"
assert decide.question_hash(t) == h, "thresholds or model ids moved the hash"
for mut in (lambda x: x["questions"]["class"]["instructions"].__setitem__("question", "Other?"),
            lambda x: x["questions"]["class"]["criteria"]["docs"].__setitem__("what", "Only prose."),
            lambda x: x.__setitem__("data_handling", "Different."),
            lambda x: x["state"]["allow"].__setitem__("extra", "str")):
    t = copy.deepcopy(r); mut(t); assert decide.question_hash(t) != h, "a wire change did not move the hash"
def problems(mut):
    t = copy.deepcopy(r); mut(t); return " | ".join(decide.lint(t, "dispatch/task-class@1"))
assert "counting word" in problems(lambda x: x["questions"]["class"]["criteria"]["docs"].__setitem__("what", "Changes more than three files."))
assert "no-match label" in problems(lambda x: x["questions"]["class"]["criteria"].pop("none"))
assert "egress_raw" in problems(lambda x: x["state"].__setitem__("egress_raw", []))
assert "data_handling" in problems(lambda x: x.__setitem__("data_handling", ""))
assert "does not match its file path" in problems(lambda x: x.__setitem__("version", 2))
assert "min_confidence" in problems(lambda x: x["questions"]["class"].pop("uncertain"))
assert "hard_rules[0]" in problems(lambda x: x["hard_rules"][0]["answer"].__setitem__("class", "nonsense"))
PY
ask dispatch/size@1 '{}'; [ "$RC" = 3 ] && [ "$(fld reason)" = rubric_unknown ] || fail "a reserved rubric id did not answer rubric_unknown: $OUT"
ask '../../etc/passwd@1' '{}'; [ "$RC" = 3 ] && [ "$(fld reason)" = rubric_unknown ] || fail "a path-shaped rubric id was not refused: $OUT"
pass "lint: v1 rubrics pass with a stable question_hash; thresholds/model ids excluded; wire changes move it; authoring rules fail by name; reserved ids answer rubric_unknown"

# 12. exit codes and usage: unconfigured = backend_none (exit 3, logged); usage errors exit 2 with empty stdout
ask "$TC" "$TC_STATE"
[ "$RC" = 3 ] && [ "$(fld scored)" = false ] && [ "$(fld reason)" = backend_none ] && [ "$(fld envelope)" = apex-decide/1 ] || fail "unconfigured ask: $OUT"
tail -1 "$LOG" | grep -q '"reason": "backend_none"' || fail "the unconfigured call was not logged"
set +e; O="$(cd "$R0" && "$D" --rubric "$TC" --state 'not json' 2>/dev/null)"; c=$?; set -e
[ "$c" = 2 ] && [ -z "$O" ] || fail "malformed --state: exit $c, stdout '$O'"
set +e; O="$(cd "$R0" && "$D" --rubric "$TC" --state '{}' --bogus 2>/dev/null)"; c=$?; set -e
[ "$c" = 2 ] && [ -z "$O" ] || fail "an unknown flag: exit $c, stdout '$O'"
set +e; "$D" measure >/dev/null 2>&1; c=$?; set -e; [ "$c" = 2 ] || fail "measure (Phase 3) did not exit 2"
E="$WORK/empty"; mkdir -p "$E"; git init -q "$E"; (cd "$E" && "$D" --rubric "$TC" --state '{}' >/dev/null) || true
[ ! -e "$E/.dev-plan-state" ] || fail "a call in a repo without run state or config created .dev-plan-state"
pass "exit codes: unconfigured = 3 backend_none (logged); usage = 2 with empty stdout; Phase 3 subcommands exit 2; no log created in a bare repo"

# 13. a scored answer: envelope shape, extra response fields ignored, unknown state fields dropped, untrusted text withheld
fake "$TC" "$GOOD_TC"
APEX_DECIDE_FAKE="$FAKE" APEX_DECIDE_FAKE_RECORD="$REC" ask "$TC" "$TC_STATE"
[ "$RC" = 0 ] && [ "$(fld scored)" = true ] && [ "$(fld verdict)" = feature ] && [ "$(fld uncertain)" = false ] \
  && [ "$(fld calibrated)" = false ] && [ "$(fld add_gate)" = null ] && [ "$(fld backend)" = fake ] && [ "$(fld model_resolved)" = fake-1 ] \
  && [ "$(fld usage.cost)" = 2e-05 ] || fail "scored envelope: $OUT"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert set(d["probabilities"])==set(json.loads(sys.argv[2])) and d["question_hash"].startswith("sha256:") and d["decision_id"].startswith("d-")' "$OUT" "$TC_LABELS" \
  || fail "the envelope's probabilities are not exactly the rubric's labels"
python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).read().splitlines()[-1]); s=r["state"]
assert "task_title" not in s and "acceptance_text" not in s and "source" not in s and s["tags"]==["x"], s' "$REC" \
  || fail "the backend received untrusted text (state_fields structured) or an unknown field"
tail -1 "$LOG" | python3 -c 'import json,sys; r=json.loads(sys.stdin.read()); assert r["scored"] and set(r["dropped_fields"])=={"task_title","acceptance_text","source","review_rounds"} and "state" not in r, r' \
  || fail "the decision log row does not list the dropped fields (or stored the state by default)"
pass "scored: envelope shape, labels exact, unknown response fields ignored, unknown/untrusted state fields dropped and logged"

# 14. the validator: every rejection is invalid_answer (exit 3), never repaired
bad() { fake "$TC" "$1"; APEX_DECIDE_FAKE="$FAKE" ask "$TC" "$TC_STATE"; [ "$RC" = 3 ] && [ "$(fld reason)" = invalid_answer ] || fail "validator accepted $2: $OUT"; }
bad "$(choice "$TC_LABELS" '{"feature":0.6,"docs":0.6}' feature 0.8 class)" "a sum of 1.2 (frontier's Phase 0 failure)"
bad "$(choice "$TC_LABELS" '{"feature":0.6,"docs":0.37}' feature 0.8 class)" "a sum of 0.97"
bad "$(choice "$TC_LABELS" '{}' feature 0.8 class)" "an all-zero map"
bad "$(choice "$TC_LABELS" '{"feature":0.5,"docs":0.5}' feature 0.8 class)" "a tie at the top"
bad "$(choice "$TC_LABELS" '{"feature":0.84,"docs":0.16}' docs 0.8 class)" "choice != argmax"
bad "$(choice "$TC_LABELS" '{"feature":0.84,"docs":0.16}' feature 1.5 class)" "a confidence above 1"
bad "$(choice "$TC_LABELS" '{"feature":0.84,"docs":0.16}' feature 0.8 wrongq)" "a wrong question id"
bad '{"model":"fake-1","answers":{"class":{"choice":"feature","probabilities":{"feature":0.9,"docs":0.1}}}}' "missing labels"
bad '{"model":"fake-1","answers":{"class":{"choice":"feature","probabilities":{"feature":0.9,"docs":0.1,"tests":0,"mechanical":0,"bugfix":0,"migration":0,"security":0,"none":0,"extra":0}}}}' "an extra label"
bad '{"model":"fake-1","answers":{"class":{"choice":"feature","probabilities":{"feature":true,"docs":0,"tests":0,"mechanical":0,"bugfix":0,"migration":0,"security":0,"none":0}}}}' "a boolean probability"
bad '{"model":"fake-1","answers":{"class":{"choice":"feature","probabilities":{"feature":"NaN","docs":0,"tests":0,"mechanical":0,"bugfix":0,"migration":0,"security":0,"none":0}}}}' "a string probability"
bad '{"model":"fake-1","answers":{}}' "a 200 with no answers"
bad '{"model":"fake-1"}' "no answers object"
bad '{"model": "fake-1", "answers": {"class": ' "an unparsable body"
python3 - "$PLUGIN_ROOT" <<'PY' || fail "score and noul validation"
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "scripts", "lib"))
import decide
qs = {"s": {"type": "score", "criteria": ["a", "b", "c"]}, "n": {"type": "noul", "criteria": {"true": {}, "false": {}}}}
ok = decide.validate({"answers": {"s": {"score": 1.2, "probabilities": {"0": 0.1, "1": 0.6, "2": 0.3}, "confidence": 0.5},
                                  "n": {"noul": 0.7}}}, qs)
assert ok["s"]["score"] == 1.2 and abs(ok["n"]["probabilities"]["false"] - 0.3) < 1e-9
for bad in ({"s": {"score": 2.0, "probabilities": {"0": 0.1, "1": 0.6, "2": 0.3}}, "n": {"noul": 0.7}},
            {"s": {"score": 1.2, "probabilities": {"0": 0.1, "1": 0.6, "2": 0.3}}, "n": {"noul": 1.7}},
            {"s": {"score": 1.2, "probabilities": {"0": 0.1, "1": 0.6, "3": 0.3}}, "n": {"noul": 0.7}}):
    try:
        decide.validate({"answers": bad}, qs)
    except decide.Unscored as e:
        assert e.reason == "invalid_answer"
    else:
        raise AssertionError("accepted %r" % bad)
PY
pass "validator: sums off by 0.03 or 0.2, all-zero, ties, choice != argmax, bad confidence, wrong ids, missing/extra labels, booleans, strings, empty answers, unparsable bodies, score mean and noul range all rejected"

# 15. tri-state: confidence below the threshold, or null, is uncertain (still exit 0); noul margin and dead band
for c in 0.49 null; do
  fake "$TC" "$(choice "$TC_LABELS" '{"feature":0.84,"bugfix":0.16}' feature "$c" class)"
  APEX_DECIDE_FAKE="$FAKE" ask "$TC" "$TC_STATE"
  [ "$RC" = 0 ] && [ "$(fld uncertain)" = true ] && [ "$(fld verdict)" = feature ] || fail "confidence $c was not uncertain: $OUT"
done
fake "$TC" "$(choice "$TC_LABELS" '{"feature":0.84,"bugfix":0.16}' feature 0.5 class)"
APEX_DECIDE_FAKE="$FAKE" ask "$TC" "$TC_STATE"; [ "$(fld uncertain)" = false ] || fail "confidence at the threshold was uncertain: $OUT"
python3 - "$PLUGIN_ROOT" <<'PY' || fail "noul tri-state"
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "scripts", "lib"))
import decide
q = {"uncertain": {"threshold": 0.5, "margin": 0.1}}
assert decide.tri_state(q, {"type": "noul", "noul": 0.55}, None) == (True, "__uncertain__")
assert decide.tri_state(q, {"type": "noul", "noul": 0.75}, None) == (False, "true")
assert decide.tri_state(q, {"type": "noul", "noul": 0.2}, None) == (False, "false")
q = {"uncertain": {"dead_band": [0.3, 0.7]}}
assert decide.tri_state(q, {"type": "noul", "noul": 0.65}, None)[0] is True
assert decide.tri_state(q, {"type": "noul", "noul": 0.71}, None) == (False, "true")
PY
pass "tri-state: below threshold or null confidence is uncertain (exit 0, verdict kept); noul margin and dead band"

# 16. calibration: only a locked, passing record that matches rubric, hash, backend and resolved model
QH="$(sed -n "s/^LINT OK $(printf '%s' "$TC" | sed 's/[/.@]/\\&/g') //p" "$WORK/lint.out")"
mkdir -p "$CFG/calibration/$TC"; CR="$CFG/calibration/$TC/fake.json"
rec() { printf '%s' "$1" >"$CR"; }
lock() { printf '{"calibration_lock": ["sha256:%s"]}' "$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$CR")" >"$CFG/config.json"; }
fake "$TC" "$GOOD_TC"
calq() { APEX_DECIDE_FAKE="$FAKE" ask "$TC" "$TC_STATE"; CAL="$(fld calibrated)"; }
REC_OK="{\"rubric_version\":\"$TC\",\"question_hash\":\"$QH\",\"backend\":\"fake\",\"model_resolved\":\"fake-1\",\"passed\":true,\"thresholds\":{\"class\":{\"min_confidence\":0.9}}}"
rec "$REC_OK"; rm -f "$CFG/config.json"
calq; [ "$CAL" = false ] && fld calibration.reason | grep -q 'not in config.calibration_lock' || fail "an unlocked record calibrated: $OUT"
lock; calq; [ "$CAL" = true ] && [ "$(fld uncertain)" = true ] || fail "a locked passing record did not calibrate (and apply its 0.9 threshold): $OUT"
for mut in 's/"passed":true/"passed":false/' "s/$QH/sha256:0000/" 's/"backend":"fake"/"backend":"jev"/' 's/"model_resolved":"fake-1"/"model_resolved":"fake-2"/'; do
  rec "$(printf '%s' "$REC_OK" | sed "$mut")"; lock
  calq; [ "$CAL" = false ] || fail "a record with $mut calibrated: $OUT"
done
rec "$REC_OK"; lock; printf ' ' >>"$CR"; calq; [ "$CAL" = false ] || fail "an edited record (hash not locked) calibrated"
rm -rf "$CFG"
pass "calibration: unlocked, failed, wrong hash/backend/resolved model and edited records stay uncalibrated; a locked match calibrates and applies its thresholds"

# 17. deadline: a slow backend is discarded within the deadline; nothing late is printed
fake "$TC" "$GOOD_TC" '{"sleep_ms": 3000}'
T="$(python3 -c 'import time; print(time.monotonic())')"
APEX_DECIDE_FAKE="$FAKE" ask "$TC" "$TC_STATE" --deadline-ms 400
EL="$(python3 -c 'import sys,time; print(int((time.monotonic()-float(sys.argv[1]))*1000))' "$T")"
[ "$RC" = 3 ] && [ "$(fld reason)" = deadline ] || fail "a slow backend was not a deadline: $OUT"
[ "$EL" -lt 1500 ] || fail "the deadline call took ${EL} ms (deadline 400 ms)"
pass "deadline: a backend past --deadline-ms is unscored 'deadline' (${EL} ms wall clock for a 400 ms deadline)"

# 18. egress: hosted backends refuse without egress hosted; raw state_fields sends untrusted text; config validation
ask "$TC" "$TC_STATE" --backend jev; [ "$RC" = 3 ] && [ "$(fld reason)" = egress_disabled ] || fail "jev ran with egress none: $OUT"
ask risk-tier@1 "$RT_STATE" --backend frontier; [ "$(fld reason)" = egress_disabled ] || fail "frontier ran with egress none: $OUT"
mkdir -p "$CFG"; printf '{"egress":"hosted","primary":{"%s":"jev"}}' "$TC" >"$CFG/config.json"
ask "$TC" "$TC_STATE"; [ "$(fld backend)" = jev ] && [ "$(fld reason)" = provider_error ] || fail "a configured jev primary in 0.1.0: $OUT"
printf '{"state_fields":"raw"}' >"$CFG/config.json"; : >"$REC"
fake "$TC" "$GOOD_TC"; APEX_DECIDE_FAKE="$FAKE" APEX_DECIDE_FAKE_RECORD="$REC" ask "$TC" "$TC_STATE"
python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).read().splitlines()[-1]); assert r["state"]["task_title"]=="Add a --dry-run flag" and r["untrusted"]==["acceptance_text","task_title"], r' "$REC" \
  || fail "state_fields raw did not send the untrusted text, declared as untrusted"
for c in '{"primary":{"default":"fake"}}' '{"egress":"everywhere"}' '{"surprise":1}' '{"calibration_lock":["md5:x"]}' 'not json'; do
  printf '%s' "$c" >"$CFG/config.json"; ask "$TC" "$TC_STATE"
  [ "$RC" = 3 ] && [ "$(fld reason)" = config_invalid ] || fail "config $c was not config_invalid: $OUT"
done
rm -rf "$CFG"
pass "egress: jev/frontier refused with egress none; raw state_fields sends declared untrusted text; fake is never configurable; invalid configs are config_invalid"

# 19. state limits and hard rules: wrong types and oversize states are state_rejected; a hard rule answers without a call
fake "$TC" "$GOOD_TC"; : >"$REC"
APEX_DECIDE_FAKE="$FAKE" ask "$TC" '{"tags":"security-ish"}'; [ "$(fld reason)" = state_rejected ] || fail "a string for list[str] was accepted: $OUT"
BIG="$(python3 -c 'import json; print(json.dumps({"paths": ["p/%05d/**" % i for i in range(2000)]}))')"
APEX_DECIDE_FAKE="$FAKE" ask "$TC" "$BIG"; [ "$(fld reason)" = state_rejected ] || fail "an oversize state was accepted (or truncated): $OUT"
APEX_DECIDE_FAKE="$FAKE" APEX_DECIDE_FAKE_RECORD="$REC" ask "$TC" '{"tags":["auth"],"paths":["src/**"]}'
[ "$RC" = 3 ] && [ "$(fld reason)" = hard_rule ] && fld detail | grep -q security || fail "a security tag was not answered by the hard rule: $OUT"
[ ! -s "$REC" ] || fail "a hard rule still called the backend"
pass "state: wrong types and oversize states rejected, never truncated; hard rules answer by code without a backend call"

# 20. model pin and shadow: strict pin refuses a different resolved model; shadow runs detached and logs shadow_of
python3 - "$PLUGIN_ROOT" "$WORK" <<'PY' || fail "strict model pin"
import json, os, sys
root, work = sys.argv[1:]
sys.path.insert(0, os.path.join(root, "scripts", "lib"))
import decide
r = decide.load_rubric("risk-tier@1"); r["model_pin"] = "strict"
f = os.path.join(work, "pin.json")
json.dump({"risk-tier@1": {"response": {"model": "fake-2", "answers": {"tier": {"choice": "A", "confidence": 0.9,
          "probabilities": {"A": 0.9, "B": 0.05, "C": 0.04, "none": 0.01}}}}}}, open(f, "w"))
os.environ["APEX_DECIDE_FAKE"] = f
cfg = decide.load_config(work)
req = {"rubric_version": "risk-tier@1", "rubric": r, "state": {}, "untrusted": [], "model": "fake-1",
       "deadline": decide.time.monotonic() + 5, "config": cfg}
try:
    decide.answer(r, "risk-tier@1", decide.question_hash(r), "fake", req, cfg, work)
except decide.Unscored as e:
    assert e.reason == "model_mismatch", e.reason
else:
    raise AssertionError("strict pin accepted a different resolved model")
PY
mkdir -p "$CFG"; printf '{"shadow":{"backend":"fake","sample":1.0,"deadline_ms":5000}}' >"$CFG/config.json"
python3 - "$FAKE" "$GOOD_TC" "$(choice "$TC_LABELS" '{"bugfix":0.9,"feature":0.1}' bugfix 0.9 class)" <<'PY'
import json, sys
json.dump({"dispatch/task-class@1": {"response": json.loads(sys.argv[2])},
           "shadow:dispatch/task-class@1": {"sleep_ms": 1500, "response": json.loads(sys.argv[3])}}, open(sys.argv[1], "w"))
PY
T="$(python3 -c 'import time; print(time.monotonic())')"
APEX_DECIDE_FAKE="$FAKE" ask "$TC" "$TC_STATE"
EL="$(python3 -c 'import sys,time; print(int((time.monotonic()-float(sys.argv[1]))*1000))' "$T")"
PID="$(fld decision_id)"
[ "$RC" = 0 ] && [ "$(fld verdict)" = feature ] && [ "$(fld shadow.backend)" = fake ] || fail "primary with a shadow: $OUT"
[ "$EL" -lt 1200 ] || fail "the primary waited for the shadow (${EL} ms)"
for _ in $(seq 1 40); do grep -q "\"shadow_of\": \"$PID\"" "$LOG" 2>/dev/null && break; sleep 0.1; done
grep "\"shadow_of\": \"$PID\"" "$LOG" | python3 -c 'import json,sys; r=json.loads(sys.stdin.readline()); assert r["verdict"]=="bugfix" and r["scored"] and r["backend"]=="fake", r' \
  || fail "the shadow answer was not logged with shadow_of"
APEX_DECIDE_FAKE="$FAKE" ask "$TC" "$TC_STATE" --no-shadow; [ "$(fld shadow)" = null ] || fail "--no-shadow still started a shadow"
rm -rf "$CFG"
pass "model pin strict refuses a different resolved model; shadow is detached (${EL} ms primary), logged with shadow_of, and --no-shadow skips it"

# 21. doctor: a JSON report with a status per check and both rubrics ok
(cd "$R0" && "$D" doctor --json >"$WORK/doctor.json") || fail "doctor failed: $(cat "$WORK/doctor.json")"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); n={c["name"]:c["status"] for c in d["checks"]}
assert n["config"]=="ok" and n["egress"]=="ok" and n["rubric dispatch/task-class@1"]=="ok" and n["rubric risk-tier@1"]=="ok", n' "$WORK/doctor.json" \
  || fail "doctor JSON is missing checks"
grep -qE 'sk-[A-Za-z0-9_-]{20,}|Bearer [A-Za-z0-9]' "$WORK/doctor.json" && fail "doctor printed a credential-looking value"
pass "doctor: JSON with a status per check; rubrics ok; no credential values"

echo
echo "smoke passed: $N/$N checks"
