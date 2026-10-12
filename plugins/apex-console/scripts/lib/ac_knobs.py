"""Knobs: settings the plugins already honour, edited only through each plugin's own
validator. The console writes three files and nothing else:

- apex-scope-loop  <state-base>/knobs/scope-loop.json        validated by knobslib.py validate
- apex-dispatch    <repo>/.claude/apex-dispatch/policy.json  validated by compile.py --print-merged --overlay
- apex-decision    <repo>/.claude/apex-decision-layer/config.json  validated by decide.load_config

A write that the plugin's validator refuses is not made. Every write is recorded in
the audit log with the file's previous bytes, so it can be undone.
"""
import copy
import json
import os
import tempfile

import ac_collect
import ac_common as C

SL_REVIEW = ("cap", "ask_human_after", "adversary_budget", "escalate_after", "error_budget", "attempt_cap")


class KnobError(Exception):
    def __init__(self, errors):
        super().__init__("; ".join(errors))
        self.errors = errors


def _read_text(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def _flat(d, prefix=""):
    out = {}
    for k, v in (d or {}).items():
        key = prefix + str(k)
        if isinstance(v, dict) and v:
            out.update(_flat(v, key + "."))
        else:
            out[key] = v
    return out


def _changes(before, after):
    a, b = _flat(before), _flat(after)
    return [{"key": k, "from": a.get(k), "to": b.get(k)} for k in sorted(set(a) | set(b)) if a.get(k) != b.get(k)]


def _deep_merge(base, patch):
    out = copy.deepcopy(base)
    for k, v in patch.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _deep_merge(out[k], v)
        else:
            out[k] = v
    return out


# --- apex-scope-loop ------------------------------------------------------------------

def _knobslib():
    sl = C.sibling("apex-scope-loop")
    p = os.path.join(sl, "skills", "apex-execute", "scripts", "knobslib.py") if sl else None
    return p if p and os.path.isfile(p) else None


def sl_path(base):
    return os.path.join(base, "knobs", "scope-loop.json")


def sl_get(base):
    kl = _knobslib()
    if not kl:
        return {"available": False, "reason": "apex-scope-loop 0.5.0+ (knobslib.py) is not installed"}
    rc, out, err = C.run(["python3", kl, "effective", "--state-base", base], timeout=20)
    if rc != 0:
        return {"available": True, "error": (err or out).strip()[:500], "file": sl_path(base)}
    d = json.loads(out)
    d["available"] = True
    return d


def sl_plan(base, patch):
    if not isinstance(patch, dict) or set(patch) - {"review", "tiers"}:
        raise KnobError(["scope-loop changes are under review and tiers only"])
    kl = _knobslib()
    if not kl:
        raise KnobError(["apex-scope-loop 0.5.0+ (knobslib.py) is not installed"])
    path = sl_path(base)
    raw = _read_text(path)
    current = json.loads(raw) if raw else {"schema": 1}
    new = _deep_merge(current, patch)
    new["schema"] = 1
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(new, f)
        tmp = f.name
    try:
        rc, out, err = C.run(["python3", kl, "validate", tmp], timeout=20)
    finally:
        os.unlink(tmp)
    if rc != 0:
        raise KnobError([ln[len("ERROR: "):] if ln.startswith("ERROR: ") else ln
                         for ln in (out + err).splitlines() if ln.strip()] or ["knobslib refused the change"])
    before = (sl_get(base).get("effective") or {})
    eff_after = _deep_merge(before, {k: v for k, v in new.items() if k != "schema"})
    return path, raw, json.dumps(new, indent=2, sort_keys=True) + "\n", _changes(before, eff_after)


# --- apex-dispatch -----------------------------------------------------------------------

def _dispatch_root():
    return C.sibling("apex-dispatch")


def dispatch_overlay_path(top):
    return os.path.join(top, ".claude", "apex-dispatch", "policy.json")


def _merged(top, overlay_file=None):
    root = _dispatch_root()
    if not root:
        return None, "apex-dispatch is not installed"
    argv = ["python3", os.path.join(root, "scripts", "lib", "compile.py"), root, "--print-merged"]
    env = dict(os.environ)
    env.pop("APEX_DISPATCH_POLICY", None)
    if overlay_file:
        argv += ["--overlay", overlay_file]
    rc, out, err = C.run(argv, cwd=top, env=env, timeout=60)
    if rc != 0:
        return None, (err or out).strip()[:800]
    try:
        return json.loads(out), None
    except ValueError:
        return None, "compile.py --print-merged did not print JSON"


def _doctor(base):
    best = None
    for name in ("dispatch", "dispatch-shadow"):
        for sd in ac_collect.state_dirs(base)[0]:
            p = os.path.join(sd, name, "doctor.json")
            d = C.read_json(p)
            if isinstance(d, dict) and (best is None or str(d.get("generated_at")) > str(best.get("generated_at"))):
                best = d
    return best or {}


def dispatch_get(top, base):
    root = _dispatch_root()
    if not root:
        return {"available": False, "reason": "apex-dispatch is not installed"}
    merged, err = _merged(top)
    default = C.read_json(os.path.join(root, "resources", "dispatch.default.json"), {}) or {}
    dprov = {p["id"]: p for p in default.get("providers", []) if isinstance(p, dict)}
    if merged is None:
        return {"available": True, "error": err, "overlay_path": dispatch_overlay_path(top)}
    doc = _doctor(base)
    docp = doc.get("providers") or {}
    seconds = list(doc.get("second_families") or [])
    provs = []
    for p in merged.get("providers", []):
        d = dprov.get(p["id"], {})
        dp = docp.get(p["id"]) or {}
        provs.append({"id": p["id"], "enabled": p.get("enabled", True), "family": p.get("family"),
                      "roles_allowed": p.get("roles_allowed") or [], "roles_default": d.get("roles_allowed") or [],
                      "min_acceptance": p.get("min_acceptance"), "min_acceptance_floor": d.get("min_acceptance"),
                      "status": p.get("status"), "available": dp.get("available"), "demoted": dp.get("demoted"),
                      "second_family": p["id"] in seconds, "key_env": p.get("key_env")})
    return {"available": True, "overlay_path": dispatch_overlay_path(top),
            "overlay_exists": os.path.isfile(dispatch_overlay_path(top)),
            "providers": provs, "escalation": {"max_review_rounds": (merged.get("escalation") or {}).get("max_review_rounds")},
            "second_families": seconds, "doctor_at": doc.get("generated_at")}


def dispatch_plan(top, base, patch):
    if not isinstance(patch, dict) or set(patch) - {"providers", "escalation"}:
        raise KnobError(["dispatch changes are under providers and escalation only"])
    root = _dispatch_root()
    if not root:
        raise KnobError(["apex-dispatch is not installed"])
    path = dispatch_overlay_path(top)
    raw = _read_text(path)
    overlay = json.loads(raw) if raw else {}
    default = C.read_json(os.path.join(root, "resources", "dispatch.default.json"), {}) or {}
    dprov = {p["id"]: p for p in default.get("providers", []) if isinstance(p, dict)}
    cur = dispatch_get(top, base)
    curp = {p["id"]: p for p in cur.get("providers", [])}
    new = copy.deepcopy(overlay)
    entries = {p["id"]: p for p in new.get("providers", []) if isinstance(p, dict) and "id" in p}
    errors = []
    for pid, ch in (patch.get("providers") or {}).items():
        if pid not in dprov:
            errors.append("unknown provider %s" % pid)
            continue
        if not isinstance(ch, dict) or set(ch) - {"enabled", "reviewer", "min_acceptance"}:
            errors.append("%s: only enabled, reviewer and min_acceptance can change" % pid)
            continue
        e = entries.setdefault(pid, {"id": pid})
        if "enabled" in ch:
            e["enabled"] = bool(ch["enabled"])
        if "reviewer" in ch:
            roles = list(curp.get(pid, {}).get("roles_allowed") or dprov[pid].get("roles_allowed") or [])
            if ch["reviewer"] and "reviewer" not in roles:
                if "reviewer" not in (dprov[pid].get("roles_allowed") or []):
                    errors.append("%s cannot review: its default roles do not include reviewer" % pid)
                    continue
                roles.append("reviewer")
            if not ch["reviewer"]:
                roles = [r for r in roles if r != "reviewer"]
            e["roles_allowed"] = roles
        if "min_acceptance" in ch:
            e["min_acceptance"] = ch["min_acceptance"]
    if entries:
        new["providers"] = list(entries.values())
    if "escalation" in patch:
        esc = patch["escalation"] or {}
        if set(esc) - {"max_review_rounds"}:
            errors.append("escalation: only max_review_rounds can change")
        else:
            new.setdefault("escalation", {}).update(esc)
    if errors:
        raise KnobError(errors)
    text = json.dumps(new, indent=2, sort_keys=True) + "\n"
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        f.write(text)
        tmp = f.name
    try:
        merged, err = _merged(top, tmp)
    finally:
        os.unlink(tmp)
    if merged is None:
        raise KnobError([ln.replace(tmp, "<overlay>") for ln in err.splitlines() if ln.strip()][:12] or ["apex-dispatch refused the overlay"])
    before = {"providers": {p["id"]: {"enabled": p["enabled"], "roles_allowed": p["roles_allowed"],
                                      "min_acceptance": p["min_acceptance"]} for p in cur.get("providers", [])},
              "escalation": cur.get("escalation")}
    after = {"providers": {p["id"]: {"enabled": p.get("enabled", True), "roles_allowed": p.get("roles_allowed") or [],
                                     "min_acceptance": p.get("min_acceptance")} for p in merged.get("providers", [])},
             "escalation": {"max_review_rounds": (merged.get("escalation") or {}).get("max_review_rounds")}}
    return path, raw, text, _changes(before, after)


# --- apex-decision-layer ----------------------------------------------------------------

DECISION_KEYS = ("egress", "state_fields", "primary", "shadow")


def decision_path(top):
    return os.path.join(top, ".claude", "apex-decision-layer", "config.json")


def _decide():
    root = C.sibling("apex-decision-layer")
    mods = C.import_from(root, "decide") if root else None
    return (root, mods[0]) if mods else (root, None)


def _rubrics(root):
    out = []
    rd = os.path.join(root, "rubrics")
    for dp, _dn, fn in os.walk(rd):
        for f in fn:
            if f.endswith(".json"):
                out.append(os.path.relpath(os.path.join(dp, f), rd)[:-5])
    return sorted(out)


def decision_get(top):
    root, decide = _decide()
    if not root:
        return {"available": False, "reason": "apex-decision-layer is not installed"}
    raw = _read_text(decision_path(top))
    user = json.loads(raw) if raw else {}
    cfg = {"egress": user.get("egress", "none"), "state_fields": user.get("state_fields", "structured"),
           "primary": user.get("primary", {"default": "none"}), "shadow": user.get("shadow", {})}
    return {"available": True, "path": decision_path(top), "exists": raw is not None, "config": cfg,
            "rubrics": _rubrics(root), "backends": ["none", "jev", "frontier"],
            "key_envs": [((user.get(s) or {}).get("api_key_env")) for s in ("jev", "frontier")
                         if isinstance(user.get(s), dict) and (user.get(s) or {}).get("api_key_env")]}


def decision_plan(top, patch):
    if not isinstance(patch, dict) or set(patch) - set(DECISION_KEYS):
        raise KnobError(["decision-layer changes are under %s only (calibration_lock is never edited here)"
                         % ", ".join(DECISION_KEYS)])
    root, decide = _decide()
    if not decide:
        raise KnobError(["apex-decision-layer is not installed"])
    path = decision_path(top)
    raw = _read_text(path)
    user = json.loads(raw) if raw else {}
    new = copy.deepcopy(user)
    for k, v in patch.items():
        new[k] = v                                   # primary and shadow are replaced whole
    text = json.dumps(new, indent=2, sort_keys=True) + "\n"
    tmpd = tempfile.mkdtemp()
    try:
        cdir = os.path.join(tmpd, decide.CONFIG_REL)
        os.makedirs(cdir)
        with open(os.path.join(cdir, "config.json"), "w") as f:
            f.write(text)
        try:
            decide.load_config(tmpd)
        except Exception as e:
            raise KnobError([str(getattr(e, "detail", None) or e).replace(tmpd, "<repo>")])
    finally:
        import shutil
        shutil.rmtree(tmpd, ignore_errors=True)
    before = decision_get(top)["config"]
    after = {k: new.get(k, before.get(k)) for k in DECISION_KEYS}
    return path, raw, text, _changes(before, after)


# --- one entry point ------------------------------------------------------------------

def plan(snap, plugin, patch):
    """(path, previous text or None, new text, changes, warnings) without writing."""
    warnings = []
    if snap.get("lock"):
        lk = snap["lock"]
        warnings.append("A task is running (%s line %s, stage %s): the change applies from its next check."
                        % (lk.get("kind"), lk.get("line"), lk.get("stage")))
    if plugin == "scope-loop":
        path, raw, text, changes = sl_plan(snap["state_base"], patch)
        loosen = [c for c in changes if c["key"].startswith("tiers.exempt") and c["to"]]
        if loosen:
            warnings.append("Exemptions loosen Tier C: matching paths no longer trigger it by path or content.")
    elif plugin == "dispatch":
        path, raw, text, changes = dispatch_plan(snap["top"], snap["state_base"], patch)
    elif plugin == "decision":
        path, raw, text, changes = decision_plan(snap["top"], patch)
        if patch.get("egress") == "hosted":
            warnings.append("egress hosted sends task state to the configured provider on every decision.")
    else:
        raise KnobError(["plugin is scope-loop, dispatch or decision"])
    if not changes:
        raise KnobError(["nothing changes"])
    return path, raw, text, changes, warnings


def write(path, text):
    """Write a knob file (text) or remove it (None)."""
    if text is None:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        return
    C.write_atomic(path, text, 0o644)
