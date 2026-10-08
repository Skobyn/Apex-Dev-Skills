#!/usr/bin/env python3
"""apex-decide — the decision-layer CLI (spec 2026-10-08-apex-decision-layer-design.md §4).

  apex-decide [ask] --rubric <id>@<v> (--state <json> | --state -) --json
              [--deadline-ms N] [--backend B] [--shadow | --no-shadow] [--repo DIR]
  apex-decide lint [RUBRIC_FILE...]
  apex-decide doctor [--json] [--probe] [--repo DIR]

Prints exactly one JSON envelope on stdout. Exit 0 scored (uncertain included),
3 unscored (the envelope says why), 2 usage, 1 internal error (stdout empty).
python3 stdlib only.
"""
import fcntl
import hashlib
import json
import math
import os
import random
import re
import secrets
import subprocess
import sys
import time

T0 = time.monotonic()
HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
from backends import HOSTED, NAMES, BackendUnavailable, get_backend, state_hash  # noqa: E402

ENVELOPE = "apex-decide/1"
EXIT_OK, EXIT_INTERNAL, EXIT_USAGE, EXIT_UNSCORED = 0, 1, 2, 3
DEFAULT_DEADLINE_MS = 1500
WRAP_VERSION = "untrusted-wrap/1"
RUBRIC_ID = re.compile(r"^[a-z0-9][a-z0-9-]*(/[a-z0-9][a-z0-9-]*)*@[1-9][0-9]*$")
LABEL = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]{0,63}$")
STATE_TYPES = {"str", "bool", "int", "list[str]", "untrusted-text"}
COUNTING = re.compile(r"\b(more than|fewer than|less than|several|many|a few|at least|at most|majority|most of)\b", re.I)
CONFIG_REL = os.path.join(".claude", "apex-decision-layer")
SUM_TOL, ARGMAX_TOL, SCORE_TOL = 0.02, 1e-6, 0.02


class Usage(Exception):
    pass


class Unscored(Exception):
    def __init__(self, reason, detail=""):
        super().__init__(detail or reason)
        self.reason, self.detail = reason, detail


def plugin_version():
    try:
        with open(os.path.join(PLUGIN_ROOT, ".claude-plugin", "plugin.json"), encoding="utf-8") as f:
            return json.load(f).get("version", "0.0.0")
    except (OSError, ValueError):
        return "0.0.0"


def canon(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def sha(obj_or_bytes):
    b = obj_or_bytes if isinstance(obj_or_bytes, bytes) else canon(obj_or_bytes).encode()
    return "sha256:" + hashlib.sha256(b).hexdigest()


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


# ------------------------------------------------------------------ rubrics ----

def rubric_path(rid):
    return os.path.join(PLUGIN_ROOT, "rubrics", rid + ".json")


def load_rubric(rid):
    if not RUBRIC_ID.match(rid or ""):
        raise Unscored("rubric_unknown", "not a rubric id: %r" % rid)
    try:
        with open(rubric_path(rid), encoding="utf-8") as f:
            r = json.load(f)
    except OSError:
        raise Unscored("rubric_unknown", "no rubric file for %s (reserved ids answer rubric_unknown until a consumer "
                       "calls them)" % rid)
    except ValueError as e:
        raise Unscored("rubric_unknown", "rubric %s is not valid JSON: %s" % (rid, e))
    problems = lint(r, rid)
    if problems:
        raise Unscored("rubric_unknown", "rubric %s fails lint: %s" % (rid, "; ".join(problems)))
    return r


def _texts(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values():
            yield from _texts(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _texts(v)


def lint(r, rid=None):
    """The authoring rules (spec §5.2). Returns a list of problems."""
    p = []
    if not isinstance(r, dict):
        return ["the rubric is not a JSON object"]
    full = "%s@%s" % (r.get("rubric_id"), r.get("version"))
    if rid is not None and full != rid:
        p.append("rubric_id@version %s does not match its file path %s" % (full, rid))
    if not RUBRIC_ID.match(full):
        p.append("rubric_id/version do not form a valid id: %s" % full)
    qs = r.get("questions")
    if not isinstance(qs, dict) or not qs:
        return p + ["questions must be a non-empty object"]
    if r.get("primary") not in qs:
        p.append("primary must name a question")
    for qid, q in qs.items():
        where = "question %s" % qid
        if not LABEL.match(qid):
            p.append("%s: id is not an identifier" % where)
        if not isinstance(q, dict):
            p.append("%s: not an object" % where)
            continue
        t = q.get("type")
        ins = q.get("instructions")
        if not isinstance(ins, dict) or not isinstance(ins.get("question"), str) or not ins["question"].strip():
            p.append("%s: instructions.question is required" % where)
        crit = q.get("criteria")
        unc = q.get("uncertain") or {}
        if t == "choice":
            if not isinstance(crit, dict) or not crit:
                p.append("%s: choice criteria must be a label -> description object" % where)
            else:
                if len(crit) > 255:
                    p.append("%s: more than 255 labels" % where)
                if "none" not in crit:
                    p.append("%s: a choice question needs a no-match label `none` (rule 4)" % where)
                for lab, c in crit.items():
                    if not LABEL.match(lab):
                        p.append("%s: label %r is not an identifier" % (where, lab))
                    if not isinstance(c, dict) or not isinstance(c.get("what"), str) or not c["what"].strip():
                        p.append("%s: label %s needs a `what`" % (where, lab))
            if not is_num(unc.get("min_confidence")) or not 0 <= unc["min_confidence"] <= 1:
                p.append("%s: uncertain.min_confidence in [0,1] is required" % where)
        elif t == "score":
            if not isinstance(crit, list) or not 2 <= len(crit) <= 10 or not all(isinstance(c, str) and c.strip() for c in crit):
                p.append("%s: score criteria must be 2-10 level descriptions (concrete situations)" % where)
            if not is_num(unc.get("min_confidence")) or not 0 <= unc["min_confidence"] <= 1:
                p.append("%s: uncertain.min_confidence in [0,1] is required" % where)
        elif t == "noul":
            if not isinstance(crit, dict) or set(crit) != {"true", "false"}:
                p.append("%s: noul criteria must have exactly `true` and `false`" % where)
            db = unc.get("dead_band")
            if db is not None:
                if not (isinstance(db, list) and len(db) == 2 and all(is_num(x) for x in db) and 0 <= db[0] <= db[1] <= 1):
                    p.append("%s: uncertain.dead_band must be [lo, hi] in [0,1]" % where)
            elif not (is_num(unc.get("threshold")) and is_num(unc.get("margin"))):
                p.append("%s: uncertain needs threshold + margin, or dead_band" % where)
        else:
            p.append("%s: type must be noul, choice or score" % where)
        for text in _texts({"i": ins, "c": crit}):
            m = COUNTING.search(text)
            if m:
                p.append("%s: counting word %r (rule 2: numbers are computed in code and passed as state)" % (where, m.group(0)))
                break
    st = r.get("state")
    if not isinstance(st, dict) or not isinstance(st.get("allow"), dict) or not st["allow"]:
        p.append("state.allow must list the allowed fields")
    else:
        for k, t in st["allow"].items():
            if t not in STATE_TYPES:
                p.append("state field %s: type %r is not one of %s" % (k, t, sorted(STATE_TYPES)))
        untrusted = {k for k, t in st["allow"].items() if t == "untrusted-text"}
        raw = set(st.get("egress_raw") or [])
        if raw != untrusted:
            p.append("state.egress_raw must list exactly the untrusted-text fields (rule 6): %s" % sorted(untrusted))
        if not isinstance(st.get("max_bytes"), int) or isinstance(st.get("max_bytes"), bool) or st["max_bytes"] <= 0:
            p.append("state.max_bytes must be a positive integer")
    if not isinstance(r.get("data_handling"), str) or not r["data_handling"].strip():
        p.append("data_handling is required (rule 7)")
    if r.get("model_pin", "record") not in ("strict", "record"):
        p.append("model_pin must be strict or record")
    if r.get("combine", "primary") != "primary":
        p.append("combine must be `primary` in this version")
    bm = r.get("backend_models")
    if not isinstance(bm, dict):
        p.append("backend_models must be an object")
    else:
        for b, m in bm.items():
            if b not in NAMES:
                p.append("backend_models: unknown backend %s" % b)
            elif not (isinstance(m, str) and m) and not (isinstance(m, dict) and m and all(isinstance(v, str) and v for v in m.values())):
                p.append("backend_models.%s must be a model id or a transport -> model id map" % b)
    for i, h in enumerate(r.get("hard_rules") or []):
        if not isinstance(h, dict) or not isinstance(h.get("when"), dict) or not isinstance(h.get("answer"), dict):
            p.append("hard_rules[%d] needs `when` and `answer`" % i)
            continue
        for qid, lab in h["answer"].items():
            crit = (qs.get(qid) or {}).get("criteria")
            if not isinstance(crit, dict) or lab not in crit:
                p.append("hard_rules[%d]: answer %s=%r is not a label of that question" % (i, qid, lab))
    m = r.get("measure")
    if m is not None:
        prim = (qs.get(r.get("primary")) or {}).get("criteria")
        labs = set(prim) if isinstance(prim, dict) else set()
        if not isinstance(m, dict) or set(m) - {"acted_on", "order", "false_tighten_budget", "false_loosen_budget"}:
            p.append("measure has only acted_on, order, false_tighten_budget, false_loosen_budget")
        else:
            for k in ("acted_on", "order"):
                if k in m and not (isinstance(m[k], list) and m[k] and set(m[k]) <= labs):
                    p.append("measure.%s must list labels of the primary question" % k)
            for k in ("false_tighten_budget", "false_loosen_budget"):
                if k in m and not (is_num(m[k]) and m[k] >= 0):
                    p.append("measure.%s must be a number >= 0 (per 100 tasks)" % k)
    for i, g in enumerate(r.get("gate_for") or []):
        if not isinstance(g, dict) or g.get("question") not in qs or not isinstance(g.get("gate"), str):
            p.append("gate_for[%d] needs question and gate" % i)
    return p


def question_hash(r):
    """sha256 over everything that reaches the wire, thresholds and model ids excluded (§5.1)."""
    qs = {qid: {"type": q["type"], "instructions": q["instructions"], "criteria": q["criteria"]}
          for qid, q in r["questions"].items()}
    return sha({"questions": qs, "data_handling": r["data_handling"], "state_allow": r["state"]["allow"],
                "wrap": WRAP_VERSION})


def labels_of(q):
    if q["type"] == "choice":
        return list(q["criteria"])
    if q["type"] == "score":
        return [str(i) for i in range(len(q["criteria"]))]
    return ["true", "false"]


# ------------------------------------------------------------------- config ----

def repo_root(arg):
    if arg:
        return os.path.abspath(arg)
    try:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=5)
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return os.getcwd()


def load_config(repo):
    """The per-repo config (§10.1). Absent: everything off."""
    path = os.path.join(repo, CONFIG_REL, "config.json")
    cfg = {"egress": "none", "state_fields": "structured", "primary": {"default": "none"}, "shadow": {},
           "jev": {"transport": "openrouter"},
           "frontier": {"provider": "anthropic", "api_key_env": "ANTHROPIC_API_KEY"},
           "decision_log": {"store_state": "hash"}, "calibration_lock": [], "_path": None}
    if not os.path.exists(path):
        return cfg
    try:
        with open(path, encoding="utf-8") as f:
            user = json.load(f)
    except (OSError, ValueError) as e:
        raise Unscored("config_invalid", "%s: %s" % (path, e))
    problems = []
    if not isinstance(user, dict):
        raise Unscored("config_invalid", "%s is not a JSON object" % path)
    known = {"egress", "state_fields", "primary", "shadow", "jev", "frontier", "decision_log", "calibration_lock"}
    for k in set(user) - known:
        problems.append("unknown key %s" % k)
    test_mode = bool(os.environ.get("APEX_DECIDE_FAKE"))
    allowed_backends = {"none", "jev", "frontier"} | ({"fake"} if test_mode else set())
    if user.get("egress", "none") not in ("none", "hosted"):
        problems.append("egress must be none or hosted")
    if user.get("state_fields", "structured") not in ("structured", "raw"):
        problems.append("state_fields must be structured or raw")
    prim = user.get("primary", {})
    if not isinstance(prim, dict) or not all(isinstance(v, str) and v in allowed_backends for v in prim.values()):
        problems.append("primary maps rubric ids (or `default`) to one of %s (fake is never configurable)"
                        % sorted(allowed_backends - {"fake"}))
    sh = user.get("shadow", {})
    if not isinstance(sh, dict) or (sh and (sh.get("backend") not in allowed_backends
                                            or not (is_num(sh.get("sample", 0)) and 0 <= sh.get("sample", 0) <= 1)
                                            or not isinstance(sh.get("deadline_ms", 20000), int))):
        problems.append("shadow needs backend, sample in [0,1], deadline_ms")
    lock = user.get("calibration_lock", [])
    if not isinstance(lock, list) or not all(isinstance(x, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", x) for x in lock):
        problems.append("calibration_lock is a list of sha256:<hex> digests")
    dl = user.get("decision_log", {})
    if not isinstance(dl, dict) or dl.get("store_state", "hash") not in ("hash", "full"):
        problems.append("decision_log.store_state must be hash or full")
    for sec in ("jev", "frontier"):
        if not isinstance(user.get(sec, {}), dict):
            problems.append("%s must be an object" % sec)
            continue
        ke = user.get(sec, {}).get("api_key_env")
        if ke is not None and not (isinstance(ke, str) and re.fullmatch(r"[A-Z_][A-Z0-9_]{0,127}", ke)):
            problems.append("%s.api_key_env must name an environment variable (the key itself never goes in config)" % sec)
    if isinstance(user.get("jev", {}), dict) and user.get("jev", {}).get("transport", "openrouter") not in ("typesafe", "openrouter"):
        problems.append("jev.transport must be typesafe or openrouter")
    if isinstance(user.get("frontier", {}), dict) and user.get("frontier", {}).get("provider", "anthropic") != "anthropic":
        problems.append("frontier.provider must be anthropic")
    if problems:
        raise Unscored("config_invalid", "%s: %s" % (path, "; ".join(problems)))
    for k, v in user.items():
        if isinstance(v, dict) and isinstance(cfg.get(k), dict):
            cfg[k] = dict(cfg[k], **v)
        else:
            cfg[k] = v
    cfg["_path"] = path
    return cfg


def state_base(repo):
    """apex-scope-loop's apex_state_base (_lib.sh), so the log sits beside the run state (ADR-0003)."""
    try:
        out = subprocess.run(["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                             capture_output=True, text=True, timeout=5)
        common = os.path.realpath(out.stdout.strip()) if out.returncode == 0 and out.stdout.strip() else ""
    except (OSError, subprocess.SubprocessError):
        common = ""
    root = os.environ.get("APEX_STATE_ROOT")
    if root:
        os.makedirs(root, exist_ok=True)
        return os.path.join(os.path.realpath(root), ".dev-plan-state",
                            hashlib.sha256((common or repo).encode()).hexdigest()[:12])
    if not common:
        return os.path.join(repo, ".dev-plan-state")
    if os.path.basename(common) == ".git":
        return os.path.join(os.path.dirname(common), ".dev-plan-state")
    return os.path.join(common, "apex-scope-loop-state")


def decisions_dir(repo):
    """<state-base>/decisions, or None in a repository that has neither run state nor a
    decision-layer config (nothing is created there). The transport's circuit breaker and
    latency samples live here too (§6.4), beside the log."""
    try:
        base = state_base(repo)
    except OSError:
        return None
    if not os.path.isdir(base) and not os.path.isdir(os.path.join(repo, CONFIG_REL)):
        return None
    return os.path.join(base, "decisions")


KEY_ENVS = ("TYPESAFE_API_KEY", "JEV_API_KEY", "OPENROUTER_API_KEY", "ANTHROPIC_API_KEY")


def scrub(text, cfg=None):
    """Belt for §6.4 'the key never appears': no API key value survives into stdout or the log."""
    names = set(KEY_ENVS)
    for sec in ("jev", "frontier"):
        n = ((cfg or {}).get(sec) or {}).get("api_key_env")
        if isinstance(n, str):
            names.add(n)
    for n in names:
        v = os.environ.get(n, "")
        if len(v) >= 4:
            text = text.replace(v, "[redacted]").replace(json.dumps(v)[1:-1], "[redacted]")
    return text


def log_row(repo, row, cfg=None):
    """Append one decision-log row (§11.1). A log failure never fails the call."""
    try:
        d = decisions_dir(repo)
        if d is None:
            return
        os.makedirs(d, exist_ok=True)
        line = (scrub(json.dumps(row, sort_keys=True, ensure_ascii=True), cfg) + "\n").encode()
        fd = os.open(os.path.join(d, "decisions.jsonl"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            os.write(fd, line)
        finally:
            os.close(fd)
    except OSError as e:
        print("apex-decide: decision log not written: %s" % e, file=sys.stderr)


# -------------------------------------------------------------------- state ----

def build_state(rubric, raw, cfg):
    """Allowlisted fields only. Unknown fields are dropped (and logged); a field of the
    wrong type, or a state over max_bytes, is state_rejected. Untrusted text is kept
    only when the repo set state_fields: raw (§10.1)."""
    allow = rubric["state"]["allow"]
    state, dropped, untrusted = {}, [], []
    for k, v in raw.items():
        t = allow.get(k)
        if t is None:
            dropped.append(k)
            continue
        ok = {"str": isinstance(v, str), "untrusted-text": isinstance(v, str),
              "bool": isinstance(v, bool), "int": isinstance(v, int) and not isinstance(v, bool),
              "list[str]": isinstance(v, list) and all(isinstance(x, str) for x in v)}[t]
        if not ok:
            raise Unscored("state_rejected", "state field %s is not %s" % (k, t))
        if t == "untrusted-text":
            if cfg["state_fields"] != "raw":
                dropped.append(k)
                continue
            untrusted.append(k)
        state[k] = v
    size = len(canon(state).encode())
    if size > rubric["state"]["max_bytes"]:
        raise Unscored("state_rejected", "state is %d bytes, over the rubric's max_bytes %d (never truncated)"
                       % (size, rubric["state"]["max_bytes"]))
    return state, sorted(dropped), untrusted


def hard_rule(rubric, state):
    tags = set(state.get("tags") or []) | set(state.get("task_tags") or [])
    for h in rubric.get("hard_rules") or []:
        checks = []
        for k, v in h["when"].items():
            if k == "tags_any":
                checks.append(bool(tags & set(v)))
            elif k == "risk_tier":
                checks.append(state.get("risk_tier") in (v if isinstance(v, list) else [v]))
            else:
                checks.append(False)
        if checks and all(checks):
            return h["answer"]
    return None


# ---------------------------------------------------------------- validator ----

def _probs(where, probs, labels):
    if not isinstance(probs, dict) or set(probs) != set(labels):
        raise Unscored("invalid_answer", "%s: probabilities must have exactly the labels %s" % (where, labels))
    for k, v in probs.items():
        if not is_num(v) or not 0 <= v <= 1:
            raise Unscored("invalid_answer", "%s: probability for %s is not a finite number in [0,1]" % (where, k))
    total = sum(probs.values())
    if all(v == 0 for v in probs.values()):
        raise Unscored("invalid_answer", "%s: all-zero probability map (a missing answer)" % where)
    if abs(total - 1.0) > SUM_TOL:
        raise Unscored("invalid_answer", "%s: probabilities sum to %.4f, not 1 +/- %.2f (never rescaled)" % (where, total, SUM_TOL))
    return {k: float(v) for k, v in probs.items()}


def _confidence(where, a):
    c = a.get("confidence")
    if c is None:
        return None
    if not is_num(c) or not 0 <= c <= 1:
        raise Unscored("invalid_answer", "%s: confidence is not a finite number in [0,1]" % where)
    return float(c)


def validate(raw, questions):
    """One fail-closed validator for every backend (§6.2). Unknown fields are ignored."""
    if not isinstance(raw, dict) or not isinstance(raw.get("answers"), dict):
        raise Unscored("invalid_answer", "the response has no answers object")
    answers = raw["answers"]
    if set(answers) != set(questions):
        raise Unscored("invalid_answer", "answered questions %s != asked %s" % (sorted(answers), sorted(questions)))
    out = {}
    for qid, q in questions.items():
        a, where = answers[qid], "answer %s" % qid
        if not isinstance(a, dict):
            raise Unscored("invalid_answer", "%s is not an object" % where)
        labels = labels_of(q)
        if q["type"] == "noul":
            v = a.get("noul")
            if not is_num(v) or not 0 <= v <= 1:
                raise Unscored("invalid_answer", "%s: noul is not a finite number in [0,1]" % where)
            out[qid] = {"type": "noul", "noul": float(v), "probabilities": {"true": float(v), "false": 1.0 - float(v)},
                        "confidence": None}
            continue
        probs = _probs(where, a.get("probabilities"), labels)
        ranked = sorted(probs.values(), reverse=True)
        if len(ranked) > 1 and ranked[0] - ranked[1] <= ARGMAX_TOL:
            raise Unscored("invalid_answer", "%s: a tie at the top (a missing answer, never a first-label pick)" % where)
        top = max(probs, key=probs.get)
        conf = _confidence(where, a)
        if q["type"] == "choice":
            if a.get("choice") != top:
                raise Unscored("invalid_answer", "%s: choice %r is not the argmax %r" % (where, a.get("choice"), top))
            out[qid] = {"type": "choice", "choice": top, "probabilities": probs, "confidence": conf}
        else:
            s = a.get("score")
            mean = sum(int(k) * v for k, v in probs.items())
            if not is_num(s) or not 0 <= s <= len(labels) - 1 or abs(s - mean) > SCORE_TOL:
                raise Unscored("invalid_answer", "%s: score %r is not the distribution mean %.3f" % (where, s, mean))
            out[qid] = {"type": "score", "score": float(s), "probabilities": probs, "confidence": conf}
    return out


def tri_state(q, a, thresholds):
    """`uncertain` and the verdict, computed here, never by a backend (§7)."""
    unc = dict(q.get("uncertain") or {}, **(thresholds or {}))
    if a["type"] == "noul":
        p = a["noul"]
        if unc.get("dead_band") is not None:
            lo, hi = unc["dead_band"]
            u = lo <= p <= hi
            t = (lo + hi) / 2.0
        else:
            t = unc["threshold"]
            u = abs(p - t) < unc["margin"]
        return u, ("__uncertain__" if u else ("true" if p >= t else "false"))
    c = a["confidence"]
    u = c is None or c < unc["min_confidence"]
    verdict = a["choice"] if a["type"] == "choice" else max(a["probabilities"], key=a["probabilities"].get)
    return u, verdict


# -------------------------------------------------------------- calibration ----

def calibration(repo, cfg, rv, qhash, backend, model_resolved):
    """`calibrated` is never configured: a locked, passing record must match (§8.4)."""
    rid, _, ver = rv.rpartition("@")
    path = os.path.join(repo, CONFIG_REL, "calibration", "%s@%s" % (rid, ver), backend + ".json")
    key = "(%s, %s, %s, %s)" % (rv, qhash, backend, model_resolved)
    try:
        with open(path, "rb") as f:
            body = f.read()
    except OSError:
        return False, None, {"record": None, "reason": "no calibration record for " + key}
    digest = sha(body)
    rel = os.path.relpath(path, repo)
    if digest not in cfg.get("calibration_lock", []):
        return False, None, {"record": rel, "reason": "record %s is not in config.calibration_lock" % digest}
    try:
        rec = json.loads(body)
    except ValueError:
        return False, None, {"record": rel, "reason": "record is not JSON"}
    for field, want in (("rubric_version", rv), ("question_hash", qhash), ("backend", backend),
                        ("model_resolved", model_resolved)):
        if rec.get(field) != want:
            return False, None, {"record": rel, "reason": "record %s %r != %r" % (field, rec.get(field), want)}
    if rec.get("passed") is not True:
        return False, None, {"record": rel, "reason": "record did not pass the kill criterion"}
    if rec.get("invalidated"):
        return False, None, {"record": rel, "reason": "record invalidated: %s" % rec.get("invalidated")}
    return True, rec.get("thresholds") or {}, {"record": rel, "reason": "locked record matches"}


# ---------------------------------------------------------------------- ask ----

def parse_ask(argv):
    a = {"rubric": None, "state": None, "deadline_ms": DEFAULT_DEADLINE_MS, "backend": None, "shadow": None, "repo": None}
    i = 0
    while i < len(argv):
        x = argv[i]
        if x in ("--rubric", "--state", "--deadline-ms", "--backend", "--repo"):
            if i + 1 >= len(argv):
                raise Usage("%s needs a value" % x)
            v = argv[i + 1]
            i += 2
            if x == "--deadline-ms":
                if not re.fullmatch(r"[0-9]{1,7}", v) or int(v) < 1:
                    raise Usage("--deadline-ms must be a positive integer")
                a["deadline_ms"] = int(v)
            elif x == "--backend":
                if v not in NAMES:
                    raise Usage("--backend must be one of %s" % ", ".join(NAMES))
                a["backend"] = v
            else:
                a[x[2:]] = v
        elif x == "--json":
            i += 1
        elif x in ("--shadow", "--no-shadow"):
            a["shadow"] = x == "--shadow"
            i += 1
        else:
            raise Usage("unknown argument %r" % x)
    if not a["rubric"] or a["state"] is None:
        raise Usage("ask needs --rubric <id>@<v> and --state <json>|-")
    text = sys.stdin.read() if a["state"] == "-" else a["state"]
    try:
        a["state"] = json.loads(text)
    except ValueError:
        raise Usage("--state is not valid JSON")
    if not isinstance(a["state"], dict):
        raise Usage("--state must be a JSON object")
    return a


def model_for(rubric, backend, cfg):
    m = (rubric.get("backend_models") or {}).get(backend)
    if isinstance(m, dict):
        return m.get(cfg.get("jev", {}).get("transport", "")) if backend == "jev" else next(iter(m.values()))
    return m or ("fake-1" if backend == "fake" else None)


def choose_backend(a, rv, cfg):
    if a["backend"]:
        return a["backend"]
    if os.environ.get("APEX_DECIDE_FAKE"):
        return "fake"
    prim = cfg.get("primary") or {}
    return prim.get(rv, prim.get("default", "none"))


def run_backend(name, req, cfg):
    if name in HOSTED and cfg.get("egress") != "hosted":
        raise Unscored("egress_disabled", "%s is a hosted backend and this repository's egress is %s"
                       % (name, cfg.get("egress")))
    try:
        raw = get_backend(name).ask(req)
    except BackendUnavailable as e:
        raise Unscored(e.reason, e.detail)
    if time.monotonic() > req["deadline"]:
        raise Unscored("deadline", "the backend answered after the deadline; the answer is discarded")
    return raw


def answer(rubric, rv, qhash, name, req, cfg, repo):
    """Backend call → validate → pin check → calibration → tri-state. Returns the scored fields."""
    raw = run_backend(name, req, cfg)
    questions = rubric["questions"]
    answers = validate(raw, questions)
    resolved = raw.get("model") if isinstance(raw.get("model"), str) else None
    if rubric.get("model_pin", "record") == "strict" and resolved != req["model"]:
        raise Unscored("model_mismatch", "requested %s, the backend resolved %s" % (req["model"], resolved))
    calibrated, thresholds, cal = calibration(repo, cfg, rv, qhash, name, resolved or req["model"])
    for qid, q in questions.items():
        u, v = tri_state(q, answers[qid], (thresholds or {}).get(qid) if calibrated else None)
        answers[qid]["uncertain"], answers[qid]["verdict"] = u, v
    usage = {k: v for k, v in (raw.get("usage") or {}).items() if is_num(v)} if isinstance(raw.get("usage"), dict) else {}
    return {"answers": answers, "model_resolved": resolved, "calibrated": calibrated, "calibration": cal,
            "usage": usage, "raw": raw}


def gate_for(rubric, answers):
    for g in rubric.get("gate_for") or []:
        a = answers.get(g["question"]) or {}
        w = g.get("when") or {}
        if ("verdict_in" in w and a.get("verdict") in w["verdict_in"]) or (w.get("uncertain") and a.get("uncertain")):
            return g["gate"]
    return None


def shadow_plan(a, cfg, primary):
    sh = cfg.get("shadow") or {}
    b = sh.get("backend")
    if not b or b == "none" or a["shadow"] is False:
        return None
    if b == primary and b != "fake":
        return None
    if a["shadow"] is True or random.random() < float(sh.get("sample", 0)):
        return b
    return None


def spawn_shadow(b, rubric, rv, qhash, req, cfg, repo, decision_id):
    """Detached: the primary envelope is already printed; the consumer never waits (§9)."""
    sys.stdout.flush()
    sys.stderr.flush()
    try:
        pid = os.fork()
    except OSError:
        return
    if pid:
        return
    try:
        os.setsid()
        dn = os.open(os.devnull, os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(dn, fd)
        sreq = dict(req, shadow=True, model=model_for(rubric, b, cfg), meta={},
                    deadline=time.monotonic() + int((cfg.get("shadow") or {}).get("deadline_ms", 20000)) / 1000.0)
        row = {"decision_id": "d-" + secrets.token_hex(6), "shadow_of": decision_id, "ts": now_iso(),
               "rubric_version": rv, "question_hash": qhash, "backend": b, "model_requested": sreq["model"],
               "state_hash": state_hash(req["state"])}
        t = time.monotonic()
        try:
            res = answer(rubric, rv, qhash, b, sreq, cfg, repo)
            p = res["answers"][rubric["primary"]]
            row.update(scored=True, model_resolved=res["model_resolved"], answers=res["answers"], raw_response=res["raw"],
                       verdict=p["verdict"], uncertain=p["uncertain"], calibrated=res["calibrated"], usage=res["usage"])
        except Unscored as e:
            row.update(scored=False, reason=e.reason, detail=e.detail)
        row["latency_ms"] = int((time.monotonic() - t) * 1000)
        if sreq.get("meta"):
            row["transport"] = sreq["meta"]
        log_row(repo, row, cfg)
    finally:
        os._exit(0)


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def ask(argv):
    a = parse_ask(argv)
    deadline = T0 + a["deadline_ms"] / 1000.0
    rv = a["rubric"]
    decision_id = "d-" + secrets.token_hex(6)
    env = {"envelope": ENVELOPE, "rubric_version": rv, "decision_id": decision_id}
    repo = repo_root(a["repo"])
    row = {"decision_id": decision_id, "ts": now_iso(), "rubric_version": rv, "cli_version": plugin_version()}
    shadow = cfg = req = None
    try:
        cfg = load_config(repo)
        rubric = load_rubric(rv)
        qhash = question_hash(rubric)
        env["question_hash"] = row["question_hash"] = qhash
        name = choose_backend(a, rv, cfg)
        env["backend"] = row["backend"] = name
        state, dropped, untrusted = build_state(rubric, a["state"], cfg)
        row.update(state_hash=state_hash(state), dropped_fields=dropped, untrusted_sent=sorted(untrusted))
        if cfg["decision_log"].get("store_state") == "full":
            row["state"] = state
        hr = hard_rule(rubric, state)
        if hr is not None:
            raise Unscored("hard_rule", json.dumps(hr, sort_keys=True))
        req = {"rubric_version": rv, "rubric": rubric, "state": state, "untrusted": untrusted,
               "model": model_for(rubric, name, cfg), "deadline": deadline, "config": cfg,
               "state_dir": decisions_dir(repo)}
        env["model_requested"] = row["model_requested"] = req["model"]
        shadow = shadow_plan(a, cfg, name)
        res = answer(rubric, rv, qhash, name, req, cfg, repo)
        p = res["answers"][rubric["primary"]]
        env.update(scored=True, model_resolved=res["model_resolved"], verdict=p["verdict"], uncertain=p["uncertain"],
                   probabilities=p["probabilities"], confidence=p["confidence"], calibrated=res["calibrated"],
                   calibration=res["calibration"], add_gate=gate_for(rubric, res["answers"]),
                   answers={k: {kk: vv for kk, vv in v.items() if kk != "type"} for k, v in res["answers"].items()},
                   usage=res["usage"])
        row.update(scored=True, model_resolved=res["model_resolved"], answers=res["answers"], verdict=p["verdict"],
                   uncertain=p["uncertain"], calibrated=res["calibrated"], add_gate=env["add_gate"], usage=res["usage"],
                   raw_response=res["raw"] if name in HOSTED else None)
        code = EXIT_OK
    except Unscored as e:
        env.update(scored=False, reason=e.reason, detail=e.detail)
        env.setdefault("backend", None)
        row.update(scored=False, reason=e.reason, detail=e.detail)
        code = EXIT_UNSCORED
    latency = int((time.monotonic() - T0) * 1000)
    env["latency_ms"] = row["latency_ms"] = latency
    if shadow:
        env["shadow"] = {"backend": shadow, "pending": True}
    env = {"envelope": env.pop("envelope"), "scored": env.pop("scored"), **env}
    if isinstance(req, dict) and req.get("meta"):
        row["transport"] = req["meta"]
    sys.stdout.write(scrub(json.dumps(env, ensure_ascii=True), cfg) + "\n")
    sys.stdout.flush()
    log_row(repo, row, cfg)
    if shadow:
        spawn_shadow(shadow, rubric, rv, qhash, req, cfg, repo, decision_id)
    return code


# --------------------------------------------------------------- lint/doctor ----

def cmd_lint(argv):
    files = argv or sorted(os.path.join(dp, f) for dp, _, fs in os.walk(os.path.join(PLUGIN_ROOT, "rubrics"))
                           for f in fs if f.endswith(".json"))
    bad = 0
    for path in files:
        rel = os.path.relpath(os.path.abspath(path), os.path.join(PLUGIN_ROOT, "rubrics"))
        rid = rel[:-5] if rel.endswith(".json") and not rel.startswith("..") else None
        try:
            with open(path, encoding="utf-8") as f:
                r = json.load(f)
        except (OSError, ValueError) as e:
            print("LINT FAIL %s: %s" % (path, e))
            bad += 1
            continue
        problems = lint(r, rid)
        name = rid or path
        if problems:
            bad += 1
            for pr in problems:
                print("LINT FAIL %s: %s" % (name, pr))
        else:
            print("LINT OK %s %s" % (name, question_hash(r)))
    return 1 if bad else 0


def calibration_checks(repo, cfg, hashes):
    """One (name, status, detail) per record under .claude/apex-decision-layer/calibration/:
    ok only when it is locked, passed, not invalidated and keyed on the rubric's current hash."""
    base = os.path.join(repo, CONFIG_REL, "calibration")
    out = []
    for dp, _, fs in os.walk(base):
        for f in sorted(fs):
            if not f.endswith(".json"):
                continue
            path = os.path.join(dp, f)
            rv, backend = os.path.relpath(dp, base), f[:-5]
            name = "%s/%s" % (rv, backend)
            try:
                with open(path, "rb") as fh:
                    body = fh.read()
                rec = json.loads(body)
            except (OSError, ValueError) as e:
                out.append((name, "warn", "unreadable record: %s" % e))
                continue
            problems = []
            if sha(body) not in cfg.get("calibration_lock", []):
                problems.append("not in calibration_lock")
            if rec.get("passed") is not True:
                problems.append("did not pass the kill criterion")
            if rec.get("invalidated"):
                problems.append("invalidated (drift): %s" % rec.get("invalidated"))
            if hashes.get(rv) and rec.get("question_hash") != hashes[rv]:
                problems.append("question_hash is not the rubric's current hash")
            out.append((name, "warn" if problems else "ok", "; ".join(problems) if problems else
                        "locked; model %s; n %s; auroc %s" % (rec.get("model_resolved"), rec.get("n"), rec.get("auroc"))))
    return out


def doctor_backends(cfg):
    """(backend, key env names, endpoint or None, header builder or the error) for jev and frontier."""
    from backends import frontier, jev
    out = []
    try:
        url = jev.endpoint(cfg)
        out.append(("jev", jev.key_envs(cfg), url, lambda k: {"Authorization": "Bearer " + k}))
    except BackendUnavailable as e:
        out.append(("jev", ("TYPESAFE_API_KEY", "OPENROUTER_API_KEY"), None, e.detail))
    try:
        url = frontier.endpoint()
        out.append(("frontier", (frontier.key_env(cfg),), url,
                    lambda k: {"x-api-key": k, "anthropic-version": frontier.API_VERSION}))
    except BackendUnavailable as e:
        out.append(("frontier", (frontier.key_env(cfg),), None, e.detail))
    return out


def cmd_doctor(argv):
    probe_on = "--probe" in argv
    repo = None
    if "--repo" in argv:
        i = argv.index("--repo")
        repo = argv[i + 1] if i + 1 < len(argv) else None
    repo = repo_root(repo)
    out = {"version": plugin_version(), "repo": repo, "checks": []}

    def add(name, status, detail):
        out["checks"].append({"name": name, "status": status, "detail": detail})
    try:
        cfg = load_config(repo)
        add("config", "ok", cfg["_path"] or "absent: egress none, every rubric answers backend_none")
    except Unscored as e:
        cfg = None
        add("config", "fail", e.detail)
    if cfg:
        add("egress", "ok", cfg["egress"])
        add("primary", "ok", cfg["primary"])
        used = set(cfg["primary"].values()) | {(cfg.get("shadow") or {}).get("backend")}
        for sec, keys, url, hdr in doctor_backends(cfg):
            present = [k for k in keys if os.environ.get(k)]
            # The key's presence only, never its value (§10.1).
            add("%s_key" % sec, "ok" if present or sec not in used else "warn",
                "%s present" % present[0] if present else "%s absent" % " / ".join(keys))
            if sec in used and cfg["egress"] != "hosted":
                add("%s_egress" % sec, "warn", "configured as a backend but egress is %s: every call is egress_disabled"
                    % cfg["egress"])
            if url is None:
                add("%s_reach" % sec, "fail", hdr)
            elif probe_on:
                from backends import transport
                secret = os.environ.get(present[0]) if present else ""
                r = transport.probe(url, hdr(secret) if secret else {}, 5.0, secrets=(secret,))
                st = "ok" if r["reachable"] and (r["status"] not in (401, 403) or not secret) else (
                    "warn" if r["reachable"] else "fail")
                add("%s_reach" % sec, st, "%s: %s (%s ms%s)" % (url, r["detail"], r["latency_ms"],
                                                                ", HTTP %s" % r["status"] if r["status"] else ""))
            else:
                add("%s_reach" % sec, "ok", "%s (not probed; doctor --probe sends one empty request)" % url)
    hashes = {}
    for dp, _, fs in os.walk(os.path.join(PLUGIN_ROOT, "rubrics")):
        for f in sorted(fs):
            rid = os.path.relpath(os.path.join(dp, f), os.path.join(PLUGIN_ROOT, "rubrics"))[:-5]
            try:
                r = load_rubric(rid)
                hashes[rid] = question_hash(r)
                add("rubric " + rid, "ok", hashes[rid])
            except Unscored as e:
                add("rubric " + rid, "fail", e.detail)
    if cfg:
        for name, st, detail in calibration_checks(repo, cfg, hashes):
            add("calibration " + name, st, detail)
    if "--json" in argv:
        print(json.dumps(out, indent=1, sort_keys=True))
    else:
        for c in out["checks"]:
            print("DOCTOR %-5s %s: %s" % (c["status"].upper(), c["name"], c["detail"]))
    return 1 if any(c["status"] == "fail" for c in out["checks"]) else 0


PHASE3 = {"label", "corpus", "measure", "replay"}


def main(argv):
    try:
        if argv and argv[0] == "lint":
            return cmd_lint(argv[1:])
        if argv and argv[0] == "doctor":
            return cmd_doctor(argv[1:])
        if argv and argv[0] in ("--version", "version"):
            print(plugin_version())
            return 0
        if argv and argv[0] in PHASE3:
            import measure
            return measure.run(sys.modules[__name__], argv[0], argv[1:])
        if argv and argv[0] == "ask":
            argv = argv[1:]
        return ask(argv)
    except Usage as e:
        print("apex-decide: %s" % e, file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except BaseException as e:  # noqa: BLE001 — internal error: stdout stays empty (§4.3)
        print("apex-decide: internal error: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        sys.exit(EXIT_INTERNAL)
