#!/usr/bin/env python3
"""knobslib.py: the per-repository knobs file of apex-scope-loop (one implementation).

The knobs file is <state-base>/knobs/scope-loop.json (<state-base> is what
_lib.sh apex_state_base prints: the .dev-plan-state base, APEX_STATE_ROOT
honoured). It sets the review-loop strictness and the risk-tier definitions;
risk-tier.sh, checkpoint.sh and iterate.sh read it, and apex-console edits it
through the same validator. It lives in the state base on purpose:
apex-dispatch refuses agent writes there during a run.

Precedence: an environment variable that is set and non-empty (a whole
number) wins over the file, the file wins over the built-in default. A
missing file means the defaults. An invalid file is fatal (fail closed):
every script that reads it stops, naming the file and the problem.

CLI:
  knobslib.py validate FILE
      exit 0 and "OK", or exit 1 and one "ERROR: <path.key>: <problem>" per problem
  knobslib.py get --state-base DIR KEY [--env VAR] [--default V]
      the effective value of KEY (e.g. review.cap): env > file > default
  knobslib.py effective --state-base DIR [--file FILE]
      JSON: file, exists, sha, effective, sources, builtins, limits, env;
      --file reads a proposed knobs file instead (risk-tier.sh --knobs, simulation only)

Import: validate(obj) -> [errors]; load(state_base) -> (obj, sha) (raises
KnobsError on an invalid file); effective(state_base, environ) -> dict.
"""
import fnmatch
import hashlib
import json
import os
import re
import sys

SCHEMA = 1
REL_PATH = os.path.join("knobs", "scope-loop.json")

# The built-in Tier C definitions. risk-tier.sh takes them from here (the one
# copy). Both are matched case-insensitively (Python re): C_PATHS against the
# repo-relative path, C_TERMS against each added line of the task diff.
C_PATHS = (r"(auth|login|logout|session|oauth|password|passwd|credential|permission|billing|payment|stripe|paypal|"
           r"invoice|pricing|checkout|subscription|refund|ledger|wallet|consent|gdpr|ccpa|privacy|personal|migration|"
           r"migrate|schema|\.sql$|prisma|secret|crypto|encrypt|security|middleware|rate.?limit|webhook|alert|pagerduty|"
           r"oncall|incident|prod(uction)?[-_.]?(data|db|config)|jwt|rbac|saml|pii|csp|cors|role)")
C_TERMS = (r"(stripe|charge\(|amount_cents|price|currency|bcrypt|argon2|jwt\.|verify_?token|set-cookie|httponly|"
           r"samesite|csrf|consent|date_of_birth|ssn|social_security|DROP (TABLE|COLUMN)|ALTER TABLE|DELETE FROM|TRUNCATE)")
# Tier B shared-module directories: (^|/)(api|routes?|shared|common|core|lib)/
B_SHARED_DIRS = ["api", "route", "routes", "shared", "common", "core", "lib"]

REVIEW_KEYS = ["cap", "ask_human_after", "adversary_budget", "escalate_after", "error_budget", "attempt_cap"]
DEFAULTS = {
    "review": {"cap": 3, "ask_human_after": 2, "adversary_budget": 3, "escalate_after": 2, "error_budget": 3, "attempt_cap": 6},
    "tiers": {"c_paths_extra": [], "c_terms_extra": [], "exempt": [], "b_max_lines": 150, "b_max_files": 6,
              "b_shared_dirs": list(B_SHARED_DIRS)},
}
LIMITS = {
    "review.cap": [1, 10], "review.ask_human_after": [1, 10], "review.adversary_budget": [0, 20],
    "review.escalate_after": [1, 10], "review.error_budget": [1, 20], "review.attempt_cap": [1, 50],
    "tiers.b_max_lines": [10, 5000], "tiers.b_max_files": [1, 500],
}
LIST_LIMITS = {
    "tiers.c_paths_extra": {"max_entries": 50, "max_len": 200},
    "tiers.c_terms_extra": {"max_entries": 50, "max_len": 200},
    "tiers.b_shared_dirs": {"max_entries": 30, "max_len": 64},
    "tiers.exempt": {"max_entries": 50, "max_len": 200, "min_reason_chars": 8},
}
ENV = {
    "review.cap": "APEX_REVIEW_CAP", "review.ask_human_after": "APEX_ASK_HUMAN_AFTER",
    "review.adversary_budget": "APEX_ADVERSARY_BUDGET", "review.escalate_after": "APEX_ESCALATE_AFTER",
    "review.error_budget": "APEX_ERROR_BUDGET", "review.attempt_cap": "APEX_ATTEMPT_CAP",
}
TIER_KEYS = ["c_paths_extra", "c_terms_extra", "exempt", "b_max_lines", "b_max_files", "b_shared_dirs"]
DIR_RE = re.compile(r"[A-Za-z0-9._-]{1,64}")
CATCH_ALL = {"*", "**", "**/*", "*/**"}


class KnobsError(Exception):
    def __init__(self, path, errors):
        self.path, self.errors = path, errors
        super().__init__("knobs file %s is invalid: %s" % (path, "; ".join(errors)))


def knobs_path(state_base):
    return os.path.join(state_base, REL_PATH)


def _is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _check_regex(where, r, errs):
    if not isinstance(r, str):
        errs.append("%s: must be a string (a Python regex)" % where)
        return
    if not r or len(r) > 200:
        errs.append("%s: must be 1-200 characters" % where)
        return
    try:
        pat = re.compile(r, re.I)
        re.compile("(?:%s)" % r, re.I)
    except (re.error, RecursionError, OverflowError) as e:
        errs.append("%s: not a valid Python regex (%s)" % (where, e))
        return
    if pat.search(""):
        errs.append("%s: matches the empty string (it would match everything)" % where)


def _check_glob(where, g, errs):
    if not isinstance(g, str) or not g.strip():
        errs.append("%s: must be a non-empty string" % where)
        return
    if len(g) > 200:
        errs.append("%s: longer than 200 characters" % where)
        return
    if g.strip() in CATCH_ALL or (fnmatch.fnmatchcase("a", g) and fnmatch.fnmatchcase("x/y/z.py", g)):
        errs.append("%s: %r matches every path (a catch-all exemption is refused)" % (where, g))
    elif len(re.findall(r"[A-Za-z0-9]", re.sub(r"\[[^\]]*\]", "", g))) < 2:
        # "*/*" or "*.*" names no directory, file or extension: it exempts almost everything.
        errs.append("%s: %r names no directory, file name or extension (at least two letters or digits)" % (where, g))


def validate(obj):
    """Every problem in a parsed knobs object, as "<path.key>: <problem>" strings."""
    errs = []
    if not isinstance(obj, dict):
        return ["(root): must be a JSON object"]
    for k in obj:
        if k not in ("schema", "review", "tiers"):
            errs.append("%s: unknown key" % k)
    if "schema" in obj and (not _is_int(obj["schema"]) or obj["schema"] != SCHEMA):
        errs.append("schema: must be %d, got %s" % (SCHEMA, json.dumps(obj["schema"])))
    rv = obj.get("review", {})
    if not isinstance(rv, dict):
        errs.append("review: must be an object")
        rv = {}
    for k, v in rv.items():
        key = "review." + k
        if k not in REVIEW_KEYS:
            errs.append("%s: unknown key" % key)
        elif not _is_int(v):
            errs.append("%s: must be a whole number, got %s" % (key, json.dumps(v)))
        elif not LIMITS[key][0] <= v <= LIMITS[key][1]:
            errs.append("%s: %d is out of range %d-%d" % (key, v, LIMITS[key][0], LIMITS[key][1]))
    tv = obj.get("tiers", {})
    if not isinstance(tv, dict):
        errs.append("tiers: must be an object")
        tv = {}
    for k, v in tv.items():
        key = "tiers." + k
        if k not in TIER_KEYS:
            errs.append("%s: unknown key" % key)
        elif k in ("b_max_lines", "b_max_files"):
            if not _is_int(v):
                errs.append("%s: must be a whole number, got %s" % (key, json.dumps(v)))
            elif not LIMITS[key][0] <= v <= LIMITS[key][1]:
                errs.append("%s: %d is out of range %d-%d" % (key, v, LIMITS[key][0], LIMITS[key][1]))
        elif not isinstance(v, list):
            errs.append("%s: must be a list" % key)
        elif len(v) > LIST_LIMITS[key]["max_entries"]:
            errs.append("%s: %d entries, at most %d" % (key, len(v), LIST_LIMITS[key]["max_entries"]))
        elif k in ("c_paths_extra", "c_terms_extra"):
            for i, r in enumerate(v):
                _check_regex("%s[%d]" % (key, i), r, errs)
        elif k == "b_shared_dirs":
            for i, d in enumerate(v):
                if not isinstance(d, str) or not DIR_RE.fullmatch(d) or d in (".", ".."):
                    errs.append("%s[%d]: must match [A-Za-z0-9._-]{1,64} (a directory name), got %s" % (key, i, json.dumps(d)))
        else:  # exempt
            for i, e in enumerate(v):
                where = "%s[%d]" % (key, i)
                if not isinstance(e, dict):
                    errs.append("%s: must be an object {\"glob\": ..., \"reason\": ...}" % where)
                    continue
                for ek in e:
                    if ek not in ("glob", "reason"):
                        errs.append("%s.%s: unknown key" % (where, ek))
                if "glob" not in e:
                    errs.append("%s.glob: required" % where)
                else:
                    _check_glob(where + ".glob", e["glob"], errs)
                r = e.get("reason")
                if not isinstance(r, str) or len(re.sub(r"\s", "", r)) < 8:
                    errs.append("%s.reason: required, at least 8 non-space characters (why this path is not Tier C)" % where)
                elif len(r) > 500:
                    errs.append("%s.reason: longer than 500 characters" % where)
    return errs


def load(state_base, path=None):
    """(obj, sha): ({}, "default") when the file is absent; KnobsError when invalid.
    path: read this file instead of the state base's (a proposed file: simulation only)."""
    path = path or knobs_path(state_base)
    try:
        with open(path, "rb") as f:
            data = f.read()
    except FileNotFoundError:
        return {}, "default"
    except OSError as e:
        raise KnobsError(path, ["(file): cannot be read (%s)" % e.strerror])
    sha = hashlib.sha256(data).hexdigest()[:12]
    try:
        obj = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as e:
        raise KnobsError(path, ["(file): not valid JSON (%s)" % e])
    errs = validate(obj)
    if errs:
        raise KnobsError(path, errs)
    return obj, sha


def _env_int(environ, var):
    """(value, note): a set, non-empty whole number wins; anything else is ignored with a note."""
    raw = environ.get(var, "") if var else ""
    if raw == "":
        return None, None
    if re.fullmatch(r"[0-9]{1,6}", raw.strip()):
        return int(raw.strip()), None
    return None, "%s=%r is not a whole number: ignored (knobs file or default used)" % (var, raw)


def effective(state_base, environ=None, path=None):
    """path: a proposed knobs file read instead of the state base's one (risk-tier.sh
    --knobs, a simulation that records nothing); validated the same way."""
    environ = os.environ if environ is None else environ
    obj, sha = load(state_base, path)
    path = path or knobs_path(state_base)
    eff = {"review": {}, "tiers": {}}
    sources, warnings = {}, []
    for k in REVIEW_KEYS:
        key = "review." + k
        v, note = _env_int(environ, ENV[key])
        if note:
            warnings.append(note)
        if v is not None:
            eff["review"][k], sources[key] = v, "env"
        elif k in obj.get("review", {}):
            eff["review"][k], sources[key] = obj["review"][k], "file"
        else:
            eff["review"][k], sources[key] = DEFAULTS["review"][k], "default"
    for k in TIER_KEYS:
        key = "tiers." + k
        if k in obj.get("tiers", {}):
            eff["tiers"][k], sources[key] = obj["tiers"][k], "file"
        else:
            d = DEFAULTS["tiers"][k]
            eff["tiers"][k], sources[key] = (list(d) if isinstance(d, list) else d), "default"
    return {
        "file": path, "exists": sha != "default", "sha": sha,
        "effective": eff, "sources": sources,
        "builtins": {"c_paths": C_PATHS, "c_terms": C_TERMS, "b_shared_dirs": list(B_SHARED_DIRS)},
        "defaults": DEFAULTS, "limits": LIMITS, "list_limits": LIST_LIMITS, "env": ENV,
        "warnings": warnings,
    }


def _usage():
    print(__doc__.split("CLI:", 1)[1].split("Import:", 1)[0].rstrip(), file=sys.stderr)
    sys.exit(2)


def _fail(e):
    print("ERROR: knobs file %s is invalid:" % e.path, file=sys.stderr)
    for x in e.errors:
        print("ERROR: " + x, file=sys.stderr)
    sys.exit(1)


def main(argv):
    if not argv:
        _usage()
    cmd, rest = argv[0], argv[1:]
    if cmd == "validate":
        if len(rest) != 1:
            _usage()
        try:
            with open(rest[0], "rb") as f:
                obj = json.loads(f.read().decode("utf-8"))
        except OSError as e:
            print("ERROR: (file): cannot be read (%s)" % e.strerror)
            return 1
        except (UnicodeDecodeError, ValueError) as e:
            print("ERROR: (file): not valid JSON (%s)" % e)
            return 1
        errs = validate(obj)
        for x in errs:
            print("ERROR: " + x)
        if errs:
            return 1
        print("OK")
        return 0
    opts, pos, i = {}, [], 0
    while i < len(rest):
        a = rest[i]
        if a in ("--state-base", "--env", "--default", "--file"):
            if i + 1 >= len(rest):
                _usage()
            opts[a], i = rest[i + 1], i + 2
        else:
            pos.append(a)
            i += 1
    if "--state-base" not in opts:
        _usage()
    sb = opts["--state-base"]
    if cmd == "effective":
        if pos:
            _usage()
        try:
            out = effective(sb, path=opts.get("--file"))
        except KnobsError as e:
            _fail(e)
        print(json.dumps(out, indent=2, sort_keys=True))
        return 0
    if cmd == "get":
        if len(pos) != 1 or "." not in pos[0]:
            _usage()
        sec, k = pos[0].split(".", 1)
        if sec not in DEFAULTS or k not in DEFAULTS[sec]:
            print("ERROR: unknown knob %s" % pos[0], file=sys.stderr)
            return 2
        try:
            obj, _ = load(sb)
        except KnobsError as e:
            _fail(e)
        v = None
        if "--env" in opts:
            v, note = _env_int(os.environ, opts["--env"])
            if note:
                print("note: " + note, file=sys.stderr)
        if v is None and k in obj.get(sec, {}):
            v = obj[sec][k]
        if v is None:
            v = opts["--default"] if "--default" in opts else DEFAULTS[sec][k]
        print(json.dumps(v) if isinstance(v, (list, dict)) else v)
        return 0
    _usage()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
