#!/usr/bin/env python3
"""apex-dispatch routing (python3 stdlib only), called by scripts/route.sh.

route.sh resolves paths, kill switches and the ACTIVE lock with apex-scope-loop's
_lib.sh and hands the results here. This module is a pure function of trusted
features (tags, directive presence, persisted tiers and failure counts, files
on disk) plus the policy: no free text from the plan, an issue or a web page
enters the state object, and every step may only tighten the one before it
(spec §5.2).

  route.py ROOT version
  route.py ROOT plan   --plan P --line N --state DIR --plan-hash H --exec-scripts D
                       [--checkpoint F] [--repo DIR] [--base SHA] [--lanes CSV]
                       [--dry-run] [--halted REASON] [--busy OWNER]
  route.py ROOT adhoc  --tags CSV --id ID --state DIR --exec-scripts D [--paths G]
                       [--acceptance CMD] [--repo DIR] [--dry-run] [--halted R] [--busy O]
  route.py ROOT escalate ROUTE_ID --state-base DIR
  route.py ROOT review-shape (TIER | ROUTE_ID --tier TIER [--state-base DIR])

Output is a KEY: VALUE block (iterate.sh style). Exit 0 for every routing
status (READY, NEEDS_SPEC, HUMAN_GATE, HALTED, BUSY); 1 for an error (bad
policy, unreadable plan); 2 for usage.
"""
import sys

sys.dont_write_bytecode = True

import datetime  # noqa: E402
import json  # noqa: E402
import math  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import shlex  # noqa: E402
import shutil  # noqa: E402
import subprocess  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ledger  # noqa: E402  (the single ledger writer, scripts/lib/ledger.py)

EFFORTS = ["low", "medium", "high", "xhigh"]
SHAPES = ["none", "solo", "six-lens", "fanout6+adversarial"]
DIVERSITY = ["off", "warn", "block"]
RISK = ["A", "B", "C"]
TIER_C_TAGS = {"security", "tier:c", "tier-c"}       # checkpoint.sh forced_c, the same set
TIER_B_TAGS = {"tier:b", "tier-b"}
TAG_OK = re.compile(r"[a-z0-9:@._+-]{1,40}")
ROUTE_ID_RE = re.compile(r"^(r)-([0-9a-f]{12})-L([0-9]{1,9})-([0-9]{1,6})$|^(a)-([0-9a-f]{12})-([0-9]{1,6})$")
# A command-like token: a known runner or shell construct (the promote-to-loop
# [gate:auto] pattern, widened), a backticked command, or a first word that is
# an executable on PATH ("true", "make", "./x.sh").
CMD_RE = re.compile(
    r"(pytest|\bnpm\b|\bnpx\b|\bpnpm\b|\byarn\b|\bbun\b|\bcurl\b|\bgrep\b|\bpython3?\b|\bbash\b|\bnode\b|\bcargo\b|"
    r"\bgo |\bmake\b|\buv |\bcd |&&|\|\||\.sh\b|\.py\b|\.js\b|\.ts\b|\bruff\b|\beslint\b|\btsc\b|\bjest\b|\bvitest\b|"
    r"\bdeno\b|\bmvn\b|\bgradle\b|\bdotnet\b|\brake\b|\bbundle\b|\bjust\b|\btox\b|\bnox\b|\bgit \b|\btest -)")
TOOLCHAIN_MARKERS = ["package.json", "pyproject.toml", "setup.py", "setup.cfg", "pytest.ini", "tox.ini", "Makefile",
                     "makefile", "GNUmakefile", "Cargo.toml", "go.mod", "justfile", "Justfile", "build.gradle",
                     "build.gradle.kts", "pom.xml", "Gemfile", "mix.exs", "deno.json", "composer.json"]


class RouteError(Exception):
    pass


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def die(msg, code=1):
    print("route: " + msg, file=sys.stderr)
    sys.exit(code)


# ------------------------------------------------------------------ policy ----

def load_policy(plugin_root):
    sys.path.insert(0, os.path.join(plugin_root, "scripts", "lib"))
    import compile as policy_compiler  # the one merge (compile.py); not the builtin
    try:
        return policy_compiler.runtime_policy(plugin_root)
    except policy_compiler.PolicyError as e:
        die("policy is invalid: " + "; ".join(e.errors))


class Policy:
    def __init__(self, p):
        self.raw = p
        self.tiers = sorted(p["tiers"], key=lambda t: t["rank"])
        self.tier = {t["id"]: t for t in self.tiers}
        self.classes = {c["id"]: c for c in p["classes"]}
        self.providers = {x["id"]: x for x in p["providers"]}
        self.roles = {r["id"]: r for r in p["roles"]}
        self.tag_classes = p.get("tag_classes", [])
        self.hard_rules = [r for r in p.get("hard_rules", []) if r.get("kind") == "route_floor"]
        self.escalation = p.get("escalation", {})
        self.semantic = p.get("semantic", {})

    def rank(self, tier_id):
        return self.tier[tier_id]["rank"]

    def tier_at(self, rank):
        rank = max(0, min(rank, self.tiers[-1]["rank"]))
        return [t for t in self.tiers if t["rank"] == rank][0]

    def table_class(self, tags):
        for tc in self.tag_classes:
            if any(t in tc["tags"] for t in tags) and tc["class"] in self.classes:
                return tc["class"], "tag_classes:" + tc["id"]
        return None, None

    def default_class(self):
        # `auto` with no decision falls back to feature: standard tier, a
        # runnable Acceptance required (the safe middle, never the frontier).
        return "feature" if "feature" in self.classes else sorted(self.classes)[0]

    def class_cost(self, cid):
        c = self.classes[cid]
        return (self.rank(c["tier_floor"]), c["budgets"]["usd"])


# ------------------------------------------------------------------ helpers ----

def max_by(order, *vals):
    vals = [v for v in vals if v in order]
    return max(vals, key=order.index) if vals else None


def command_like(acc):
    if not acc:
        return False
    if CMD_RE.search(acc) or re.search(r"`[^`]+`", acc):
        return True
    first = acc.strip().split()[0]
    if first.startswith("./") or first.startswith("../"):
        return True
    return bool(re.fullmatch(r"[a-z0-9._+-]+", first)) and shutil.which(first) is not None


def toolchains(repo):
    if not repo or not os.path.isdir(repo):
        return []
    return [m for m in TOOLCHAIN_MARKERS if os.path.isfile(os.path.join(repo, m))]


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def write_json_atomic(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def ledger_rows(state_dir):
    """Rows of the ledger the next append writes (read only; ledger.sh verify checks the chain)."""
    return ledger.read_rows(state_dir, write=True)


def ledger_append(state_dir, event, data, route_id=None, route_mode=None, head_sha=None):
    """Append through the one ledger writer (hash chain, flock). A ledger that
    refuses the row is an error: a route that is not ledgered is not emitted."""
    try:
        return ledger.append(state_dir, event, data, "cli", route_id=route_id, route_mode=route_mode,
                             head_sha=head_sha)
    except ledger.LedgerError as e:
        die("ledger refused the %s row: %s" % (event, e))


def git_head(repo):
    return ledger._git_head(repo)


def emit(block):
    for k, v in block:
        if isinstance(v, (list, tuple)):
            v = ",".join(str(x) for x in v) if v else "none"
        elif v is None or v == "":
            v = "none"
        elif isinstance(v, bool):
            v = "yes" if v else "no"
        print("%s: %s" % (k, v))


def dispatch_mode():
    m = os.environ.get("APEX_DISPATCH_MODE", "") or "table"
    if m not in ("table", "baseline", "shadow", "off"):
        die("APEX_DISPATCH_MODE must be baseline, shadow, off or unset (got %r)" % m, 2)
    return m


# --------------------------------------------------------------- decision ----

def semantic_fill(pol, state, default_cls):
    """Step 5. Returns (class_or_None, uncertain, source, info). class is set
    only when the decision may move the route: calibrated with max p >= min_p,
    or uncalibrated and the move is safer or more expensive."""
    sem = pol.semantic
    cmd = os.environ.get(sem.get("cmd_env", "APEX_DECIDE_CMD"), "")
    if not sem.get("enabled", True) or not cmd:
        return None, False, "table", {"backend": "none"}
    rubric = sem.get("rubrics", {}).get("task_class", "dispatch/task-class@1")
    timeout = max(0.1, sem.get("timeout_ms", 2000) / 1000.0)
    try:
        argv = shlex.split(cmd) + ["--rubric", rubric, "--state", json.dumps(state, sort_keys=True), "--json"]
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return None, False, "table", {"backend": "none", "fallback": "timeout"}
    except (OSError, ValueError) as e:
        return None, False, "table", {"backend": "none", "fallback": "provider_error", "error": str(e)[:200]}
    if p.returncode != 0:
        return None, False, "table", {"backend": "none", "fallback": "provider_error", "exit": p.returncode}
    try:
        d = json.loads(p.stdout)
    except ValueError:
        return None, False, "table", {"backend": "none", "fallback": "provider_error", "error": "not JSON"}
    info = {"raw": d, "backend": d.get("backend") if isinstance(d, dict) else None,
            "decision_id": d.get("decision_id") if isinstance(d, dict) else None}
    # The same fail-closed validator for every backend (spec §4).
    probs = d.get("probabilities") if isinstance(d, dict) else None
    ok = isinstance(probs, dict) and probs and all(
        isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and 0 <= v <= 1
        for v in probs.values())
    ok = ok and abs(sum(probs.values()) - 1.0) <= 0.02 and any(v > 0 for v in probs.values())
    verdict = d.get("verdict") if isinstance(d, dict) else None
    ok = ok and isinstance(verdict, str) and verdict in probs and set(probs) <= set(pol.classes) | {"__uncertain__", "none"}
    if not ok:
        info["fallback"] = "invalid_answer"
        return None, False, "table", info
    calibrated = d.get("calibrated") is True
    uncertain = d.get("uncertain") is True or verdict == "__uncertain__"
    top = max(probs.values())
    info.update({"verdict": verdict, "calibrated": calibrated, "uncertain": uncertain, "max_p": top})
    if uncertain:
        info["fallback"] = "low_confidence"
        return None, True, "decision", info
    if verdict not in pol.classes or verdict == "gate":
        info["fallback"] = "no_safe_candidate"
        return None, False, "decision-shadow", info
    if calibrated and top >= sem.get("min_p", 0.8):
        return verdict, False, "decision", info
    # Uncalibrated (or below min_p): may only move safer or more expensive.
    if not sem.get("uncalibrated_may_lower_cost", False) and pol.class_cost(verdict) < pol.class_cost(default_cls):
        info["fallback"] = "uncalibrated_cheaper"
        return None, False, "decision-shadow", info
    return verdict, False, "decision", info


# ------------------------------------------------------------------ routing ----

def rule_matches(rule, feats):
    when = rule.get("when", {})
    checks = []
    for k, v in when.items():
        if k == "risk_tier":
            checks.append(feats["risk_tier"] == v)
        elif k == "tags_any":
            checks.append(any(t in v for t in feats["tags"]))
        elif k == "runnable_check":
            checks.append(feats["runnable_check"] == v)
        elif k == "consecutive_failures_gte":
            checks.append(feats["consecutive_failures"] >= v)
        else:
            return None   # a provider/role rule: evaluated at provider selection
    if not checks:
        return False
    return any(checks) if rule.get("match") == "any" else all(checks)


def provider_rule_ok(pol, prov, cls_id, tier_id, role):
    """Evaluate the provider/role hard rules (external-builder-scope)."""
    external = prov["kind"] != "in-session" and not str(prov.get("family", "")).startswith("anthropic")
    for r in pol.hard_rules:
        when = r.get("when", {})
        if "provider_external" not in when and "role" not in when:
            continue
        if when.get("provider_external", external) != external or when.get("role", role) != role:
            continue
        then = r.get("then", {})
        if "classes_only" in then and cls_id not in then["classes_only"]:
            return False, r["id"]
        if "tier_ceiling" in then and pol.rank(tier_id) > pol.rank(then["tier_ceiling"]):
            return False, r["id"]
    return True, None


DIRECTIVE_PROVIDERS = {"claude": ["claude-session"], "claude-p": ["claude-p"], "codex": ["codex"], "grok": ["grok"],
                       "local": ["opencode-ollama", "aider-ollama"]}


def pick_provider(pol, cls, tier_id, role, risk, external_ok, requested, notes, role_for_family=None):
    """First eligible provider: the requested one when the policy allows it,
    else the first of the class's providers_allowed (claude-session)."""
    def eligible(pid):
        prov = pol.providers.get(pid)
        if not prov:
            return False, "unknown provider"
        if not prov.get("enabled"):
            return False, "disabled"
        if pid not in cls["providers_allowed"]:
            return False, "not allowed for class %s" % cls["id"]
        if cls["id"] not in prov["allowed_classes"]:
            return False, "provider does not take class %s" % cls["id"]
        if role not in prov["roles_allowed"]:
            return False, "provider does not take role %s" % role
        if pol.rank(tier_id) > pol.rank(prov["max_tier"]):
            return False, "tier %s above the provider's max_tier %s" % (tier_id, prov["max_tier"])
        external = prov["kind"] != "in-session" and not str(prov.get("family", "")).startswith("anthropic")
        if external and role in ("builder", "tester", "docs") and (not external_ok or risk == "C"):
            return False, "external builders are not allowed here"
        ok, rid = provider_rule_ok(pol, prov, cls["id"], tier_id, role)
        if not ok:
            return False, "hard rule " + rid
        if prov["kind"] == "subprocess" and not (prov.get("binary") and shutil.which(prov["binary"])):
            return False, "binary %s not found (doctor.sh not run)" % prov.get("binary")
        if prov["kind"] == "stub":
            return False, "stub"
        return True, None
    if requested and requested != "auto":
        for pid in DIRECTIVE_PROVIDERS.get(requested, [requested]):
            ok, why = eligible(pid)
            if ok:
                return pid
            notes.append("provider %s refused: %s" % (pid, why))
    for pid in cls["providers_allowed"]:
        if eligible(pid)[0]:
            return pid
    return "claude-session"


def builder_role(cls):
    for r in cls["roster"]:
        if r in ("builder", "docs", "tester"):
            return r
    return cls["roster"][0] if cls["roster"] else "builder"


def roster_for(pol, cls, effort, shape, diagnoser):
    out = []
    for r in cls["roster"]:
        if r == "builder":
            variant = "builder-" + effort if "builder" in pol.roles and effort in pol.roles["builder"].get("effort_variants", []) else "builder"
            out.append(variant)
        else:
            out.append(r)
    if diagnoser and "diagnoser" not in out:
        out.insert(0, "diagnoser")
    if shape == "fanout6+adversarial" and "adversarial-reviewer" not in out and "adversarial-reviewer" in pol.roles:
        out.append("adversarial-reviewer")
    if shape != "none" and "reviewer" not in out and "reviewer" in pol.roles:
        out.append("reviewer")
    return out


def review_for(pol, cls, risk, floors_then, directive_review):
    shape = cls["review_shape"][risk]
    div = cls["review_diversity"][risk]
    for then in floors_then:
        shape = max_by(SHAPES, shape, then.get("review_shape"))
        div = max_by(DIVERSITY, div, then.get("review_diversity"))
    tighten = {"solo": "solo", "six-lens": "six-lens", "fanout": "fanout6+adversarial"}.get(directive_review or "auto")
    if tighten and shape != "none":
        shape = max_by(SHAPES, shape, tighten)
    return shape, div


def compute(pol, feats, task, lanes_ctx, mode, escal):
    """Steps 2-8 for one task. Returns a dict describing the route."""
    r = {"status": "READY", "missing": [], "notes": [], "floors": [], "semantic_source": "table", "decision": None,
         "risk_tier": feats["risk_tier"]}
    tags = feats["tags"]
    directive = task.get("route", {}) or {}
    # 2. Fail-closed input gate.
    gate_tags = [t for t in tags if t == "gate" or t.startswith("gate:")]
    if not feats["acceptance_present"]:
        r["status"] = "NEEDS_SPEC"
        r["missing"].append("acceptance")
        return r
    if gate_tags:
        r["status"] = "HUMAN_GATE"
        r["class"] = "gate"
        r["human_gate"] = gate_tags[0]
        return r
    # 3. Hard floors.
    floors_then = []
    for rule in pol.hard_rules:
        if rule_matches(rule, feats):
            floors_then.append(rule.get("then", {}))
            r["floors"].append(rule["id"])
    floor_class = None
    for then in floors_then:
        if then.get("class") in pol.classes:
            floor_class = then["class"]
    # 4. Class table.
    explicit = directive.get("class")
    tag_cls, tag_src = pol.table_class(tags)
    if floor_class:
        cls_id, src = floor_class, "hard_rule"
        if explicit and explicit not in ("auto", floor_class):
            r["notes"].append("Route: class=%s is below the hard floor; routed as %s" % (explicit, floor_class))
    elif explicit and explicit != "auto" and explicit in pol.classes:
        cls_id, src = explicit, "directive"
    elif tag_cls:
        cls_id, src = tag_cls, tag_src
    else:
        cls_id, src = None, "auto"
    table_cls = cls_id or pol.default_class()
    if pol.classes[table_cls]["requires_command_acceptance"] and not feats["acceptance_command"]:
        r["status"] = "NEEDS_SPEC"
        r["class"] = table_cls
        r["missing"].append("acceptance-command (class %s needs a runnable command in Acceptance)" % table_cls)
        return r
    # 5. Semantic fill, only for a class still `auto`.
    uncertain = False
    if cls_id is None and mode != "baseline":
        dec_cls, uncertain, sem_src, info = semantic_fill(pol, feats, table_cls)
        r["semantic_source"], r["decision"] = sem_src, info
        if dec_cls and dec_cls != table_cls:
            dc = pol.classes[dec_cls]
            if dc["requires_command_acceptance"] and not feats["acceptance_command"]:
                r["notes"].append("decision class %s needs a runnable Acceptance; kept %s" % (dec_cls, table_cls))
            else:
                cls_id, src = dec_cls, "decision"
        r["decision_choice"] = info.get("verdict")
    cls_id = cls_id or table_cls
    if src == "auto":
        src = "auto-default"
    cls = pol.classes[cls_id]
    r["class"], r["class_source"] = cls_id, src
    # Tier: the class floor, raised by every hard floor; ceilings never lower a hard floor.
    risk = feats["risk_tier"]
    rank = pol.rank(cls["tier_floor"])
    for then in floors_then:
        if then.get("tier_floor") in pol.tier:
            rank = max(rank, pol.rank(then["tier_floor"]))
        if then.get("tier_floor_rungs_above_last"):
            last = escal.get("last_tier")
            if last in pol.tier:
                rank = max(rank, pol.rank(last) + then["tier_floor_rungs_above_last"])
    if uncertain:
        rank = max(rank, pol.rank(pol.semantic.get("uncertain_tier", "standard")))
    if rank > pol.rank(cls["tier_ceiling"]) and not floors_then:
        rank = pol.rank(cls["tier_ceiling"])
    tier = pol.tier_at(rank)
    effort = tier["effort"]
    if cls.get("effort"):
        effort = max_by(EFFORTS, effort, cls["effort"])
    size = cls.get("size_rule")
    if size and risk in ("B", "C"):
        effort = max_by(EFFORTS, effort, size.get("large_effort"))
    # 8. Escalation ladder (consecutive failures on this task).
    diagnoser = False
    rung = escal.get("rung")
    if rung:
        r["mode_override"] = "escalated"
        if rung["action"] == "effort_up":
            prev = escal.get("last_effort") or effort
            effort = max_by(EFFORTS, effort, EFFORTS[min(EFFORTS.index(prev) + 1, len(EFFORTS) - 1)])
        elif rung["action"] == "model_up":
            last = escal.get("last_tier") or tier["id"]
            tier = pol.tier_at(max(tier["rank"], pol.rank(last) + 1))
            effort = max_by(EFFORTS, tier["effort"], effort)
            diagnoser = bool(rung.get("diagnoser"))
        r["rung"] = rung["id"]
    # Review shape (from the risk tier) and the human gate.
    shape, div = review_for(pol, cls, risk, floors_then, directive.get("review"))
    human_gate = cls.get("human_gate")
    for then in floors_then:
        human_gate = then.get("human_gate") or human_gate
    external_ok = cls.get("external_builders", False) and all(then.get("external_builders", True) for then in floors_then)
    # 6. Provider for the building role.
    brole = builder_role(cls)
    provider = pick_provider(pol, cls, tier["id"], brole, risk, external_ok, directive.get("provider"), r["notes"])
    model = tier["model"] if pol.providers[provider]["family"].startswith("anthropic") else "provider-default"
    diag_provider = None
    if diagnoser:
        fam = pol.providers[provider]["family"]
        for pid in ["codex", "claude-p", "claude-session"]:
            prov = pol.providers.get(pid)
            if prov and prov.get("enabled") and "diagnoser" in prov["roles_allowed"] and \
                    (prov["family"] != fam or pid == "claude-session") and \
                    (prov["kind"] == "in-session" or (prov.get("binary") and shutil.which(prov["binary"]))):
                diag_provider = pid
                break
        if diag_provider and pol.providers[diag_provider]["family"] == fam:
            r["notes"].append("no different-family diagnoser available; using %s" % diag_provider)
    # 7. Fan-out.
    fanout, lanes = "single", []
    want_lanes = lanes_ctx.get("lanes") or []
    single_forced = any(then.get("fanout") == "single" for then in floors_then) or risk == "C"
    if want_lanes:
        why = None
        if cls["fanout"]["shape"] != "lanes":
            why = "class %s does not fan out" % cls_id
        elif single_forced:
            why = "a hard floor forces single"
        elif directive.get("fanout") != "lanes":
            why = "the task does not ask for fanout=lanes"
        else:
            ok, why = lanes_ctx["check"](cls)
            if ok:
                lanes = ok
        if lanes:
            cap = min(cls["fanout"]["max_lanes"], cls["budgets"]["spawns"])
            lanes = lanes[:cap]
            if len(lanes) >= 2:
                fanout = "lanes:%d" % len(lanes)
            else:
                lanes = []
                why = "fewer than two lanes fit the lane and spawn caps"
        if why and not lanes:
            r["notes"].append("fan-out single: " + why)
    # Budgets: the class's, lowered (never raised) by Budget:.
    budgets = dict(cls["budgets"])
    for k, v in (task.get("budget") or {}).items():
        if k in budgets:
            try:
                budgets[k] = min(budgets[k], float(v) if k == "usd" else int(v))
            except (TypeError, ValueError):
                pass
    r.update({"tier": tier["id"], "model": model, "effort": effort, "provider": provider,
              "roster": roster_for(pol, cls, effort, shape, diagnoser), "fanout": fanout, "lanes": lanes,
              "review_shape": shape, "diversity": div, "human_gate": human_gate, "budgets": budgets,
              "risk_tier": risk, "diagnoser_provider": diag_provider,
              "context_budget_tokens": tier["context_budget_tokens"], "max_turns": tier["maxTurns"]})
    if lanes:
        n = len(lanes)
        r["counterfactual"] = {"estimate": True, "single_minutes": n * budgets["minutes"],
                               "lanes_minutes": budgets["minutes"], "usd_both": n * budgets["usd"]}
    return r


def escalation_ctx(pol, failures, prior):
    """The rung for `failures` consecutive failures and the last attempt's tier/effort."""
    ctx = {"failures": failures, "last_tier": (prior or {}).get("tier"), "last_effort": (prior or {}).get("effort")}
    rungs = sorted(pol.escalation.get("rungs", []), key=lambda x: x["at_failures"])
    hit = None
    for rg in rungs:
        if failures >= rg["at_failures"]:
            hit = rg
    ctx["rung"] = hit
    return ctx


def baseline_block(task_swarm):
    """The 0.2.0 route: the orchestrator routes by the Swarm: directive and
    the agents' own frontmatter; review by the scope loop's risk tier."""
    return {"class": "baseline", "tier": "inherit", "model": "inherit", "effort": "inherit",
            "provider": "claude-session", "roster": [task_swarm] if task_swarm else ["orchestrator"],
            "fanout": "single", "lanes": [], "review_shape": "by-risk-tier", "diversity": "off",
            "human_gate": None, "budgets": {"usd": None, "spawns": None, "minutes": None}}


def route_block(status, route_id, mode, r, sem_src, extra=()):
    b = r.get("budgets") or {}
    block = [("ROUTE_STATUS", status), ("ROUTE_ID", route_id), ("ROUTE_MODE", mode),
             ("ROUTE_CLASS", r.get("class")), ("ROUTE_TIER", r.get("tier")), ("ROUTE_RISK_TIER", r.get("risk_tier")),
             ("ROUTE_MODEL", r.get("model")), ("ROUTE_EFFORT", r.get("effort")), ("ROUTE_PROVIDER", r.get("provider")),
             ("ROUTE_ROSTER", r.get("roster")), ("ROUTE_FANOUT", r.get("fanout")), ("ROUTE_LANES", r.get("lanes")),
             ("ROUTE_REVIEW_SHAPE", r.get("review_shape")), ("ROUTE_DIVERSITY", r.get("diversity")),
             ("ROUTE_HUMAN_GATE", r.get("human_gate")),
             ("ROUTE_BUDGET_USD", b.get("usd")), ("ROUTE_BUDGET_SPAWNS", b.get("spawns")),
             ("ROUTE_BUDGET_MINUTES", b.get("minutes")), ("ROUTE_MISSING", r.get("missing")),
             ("ROUTE_FLOORS", r.get("floors")), ("SEMANTIC_SOURCE", sem_src)]
    if status != "READY":   # nothing is dispatched: only what the caller needs to act on
        keep = {"ROUTE_STATUS", "ROUTE_ID", "ROUTE_MODE", "ROUTE_CLASS", "ROUTE_RISK_TIER", "ROUTE_HUMAN_GATE",
                "ROUTE_MISSING", "SEMANTIC_SOURCE"}
        block = [kv for kv in block if kv[0] in keep]
    block += list(extra)
    for n in r.get("notes", []):
        block.append(("ROUTE_NOTE", n))
    return block


def finish(args, pol, feats, task, r, kind, ident, state_dir, extra_record):
    """Step 9: mode handling, the ROUTE block, active-route.json, the ledger `route` row."""
    mode = dispatch_mode()
    status = r["status"]
    dstate = ledger.dispatch_dir(state_dir, write=True)
    if kind == "plan":
        prefix = "r-%s-L%s-" % (ident, task["line_no"])
    else:
        prefix = "a-%s-" % ident
    if args.get("dry_run"):
        route_id = prefix + "0"
    else:
        seq = 1 + sum(1 for row in ledger_rows(state_dir) if str(row.get("route_id", "")).startswith(prefix)
                      and row.get("event") == "route")
        route_id = prefix + str(seq)
    if mode in ("baseline", "shadow"):
        table = r
        emitted = dict(baseline_block(task.get("swarm")))
        emitted.update({"risk_tier": feats["risk_tier"], "missing": [], "floors": [], "notes": []})
        emit_status = "READY"
        out_mode = mode
        sem_src = r.get("semantic_source", "table") if mode == "shadow" else "none"
        tc = "status=%s class=%s tier=%s model=%s effort=%s provider=%s fanout=%s review=%s" % (
            table["status"], table.get("class"), table.get("tier"), table.get("model"), table.get("effort"),
            table.get("provider"), table.get("fanout"), table.get("review_shape"))
        extra = [("ROUTE_TABLE_CHOICE", tc)]
    else:
        emitted, emit_status = r, status
        out_mode = r.get("mode_override") or ("decision" if r.get("class_source") == "decision" else "table")
        sem_src = r.get("semantic_source", "table")
        extra = []
        table = None
    if r.get("rung") and mode not in ("baseline", "shadow"):
        extra.append(("ROUTE_RUNG", r["rung"]))
        extra.append(("ROUTE_PRIOR", extra_record.get("prior_route_id")))
    if r.get("diagnoser_provider") and mode not in ("baseline", "shadow"):
        extra.append(("ROUTE_DIAGNOSER_PROVIDER", r["diagnoser_provider"]))
    written = None
    record = {"event": "route", "route_id": route_id, "route_mode": out_mode, "status": emit_status, "ts": now(),
              "origin": kind, "state": feats, "router": {k: v for k, v in emitted.items() if k not in ("notes",)},
              "notes": emitted.get("notes", []), "decision": r.get("decision"),
              "decision_choice": r.get("decision_choice"), "semantic_source": sem_src}
    if table is not None:
        record["table_choice"] = {k: v for k, v in table.items() if k != "decision"}
    record.update(extra_record)
    if not args.get("dry_run") and (emit_status == "READY" or table is not None):
        row = ledger_append(state_dir, "route", {k: v for k, v in record.items() if k not in ("event", "ts")},
                            route_id=route_id, route_mode=out_mode, head_sha=git_head(args.get("repo")))
        record.update({"head_sha": row["head_sha"], "ledger_seq": row["seq"], "ledger_hash": row["hash"]})
    if not args.get("dry_run") and emit_status == "READY":
        written = os.path.join(dstate, "active-route.json")
        write_json_atomic(written, record)
    if emit_status != "READY":
        route_id = "none"
    if written:
        extra.append(("ROUTE_FILE", written))
        extra.append(("ROUTE_ENFORCED", os.path.basename(dstate) == "dispatch"))
    emit(route_block(emit_status, route_id, out_mode, emitted, sem_src, extra))


# ------------------------------------------------------------- subcommands ----

def parse_opts(argv, flags, valued):
    out, pos, i = {}, [], 0
    while i < len(argv):
        a = argv[i]
        if a in flags:
            out[a.lstrip("-").replace("-", "_")] = True
        elif a in valued:
            if i + 1 >= len(argv):
                die("%s needs a value" % a, 2)
            out[a.lstrip("-").replace("-", "_")] = argv[i + 1]
            i += 1
        else:
            pos.append(a)
        i += 1
    return out, pos


def early_status(args, status, reason):
    emit([("ROUTE_STATUS", status), ("ROUTE_ID", "none"), ("ROUTE_MODE", dispatch_mode()),
          ("ROUTE_REASON", reason), ("ROUTE_MISSING", "none"), ("SEMANTIC_SOURCE", "none")])


def cmd_plan(plugin_root, argv):
    a, pos = parse_opts(argv, {"--dry-run"}, {"--plan", "--line", "--state", "--plan-hash", "--exec-scripts",
                                              "--checkpoint", "--repo", "--base", "--lanes", "--halted", "--busy"})
    if a.get("halted"):
        return early_status(a, "HALTED", a["halted"])
    if a.get("busy"):
        return early_status(a, "BUSY", "another ACTIVE owner: " + a["busy"])
    sys.path.insert(0, a["exec_scripts"])
    import planlib
    try:
        tasks = planlib.parse(a["plan"])
    except planlib.PlanError as e:
        die("plan is invalid: %s" % e)
    try:
        line = int(a["line"])
    except (KeyError, ValueError):
        die("--line must be a plan line number", 2)
    by_line = {t["line_no"]: t for t in tasks}
    task = by_line.get(line)
    if task is None:
        die("line %s is not a task in %s" % (line, a["plan"]))
    pol = Policy(load_policy(plugin_root))
    cp = read_json(a.get("checkpoint") or "", {}) or {}
    if cp.get("halted"):
        return early_status(a, "HALTED", "checkpoint halted: %s" % cp.get("halt_reason", ""))
    failures = int(cp.get("consecutive_failures", 0) or 0)
    halt_at = min([rg["at_failures"] for rg in pol.escalation.get("rungs", []) if rg["action"] == "halt"] or [0]) or None
    if halt_at and failures >= halt_at:
        return early_status(a, "HALTED", "%d consecutive failures reached the escalation HALT rung" % failures)
    feats = features(pol, task, cp, a.get("repo"), "plan")
    prior = None
    if failures:
        rows = [row for row in ledger_rows(a["state"])
                if row.get("event") == "route" and row.get("status") == "READY"
                and str(row.get("route_id", "")).startswith("r-%s-L%d-" % (a["plan_hash"], line))]
        prior = rows[-1] if rows else None
    prior_router = (prior or {}).get("table_choice") or (prior or {}).get("router") or {}
    escal = escalation_ctx(pol, failures, prior_router) if failures else {}

    def lane_check(cls):
        want = []
        for x in (a.get("lanes") or "").split(","):
            x = x.strip()
            if x.isdigit():
                want.append(int(x))
        if line not in want:
            want.insert(0, line)
        # Tier C tags plus every tag a hard rule that forces fanout=single names
        # (tier-c-floor: security, migration, auth, pii, money, billing, ...).
        single_tags = set(TIER_C_TAGS)
        for rule in pol.hard_rules:
            if (rule.get("then") or {}).get("fanout") == "single":
                single_tags |= set((rule.get("when") or {}).get("tags_any") or [])
        picked = []
        for ln in want:
            t = by_line.get(ln)
            if t is None or t["checked"]:
                return None, "lane line %s is not an open task" % ln
            if not t["paths"] or not t["acceptance"]:
                return None, "lane line %s lacks Paths or Acceptance" % ln
            if set(t["tags"]) & single_tags:
                return None, "lane line %s is Tier C (or carries a tag a single-fan-out hard rule names)" % ln
            if not all(planlib.disjoint(t["paths"], o["paths"]) for o in picked):
                return None, "lane line %s overlaps another lane's Paths" % ln
            picked.append(t)
        return [t["line_no"] for t in picked], None

    lanes_ctx = {"lanes": [x for x in (a.get("lanes") or "").split(",") if x.strip()], "check": lane_check}
    r = compute(pol, feats, task, lanes_ctx, dispatch_mode(), escal)
    extra = {"plan_hash": a["plan_hash"], "line": line, "task_id": task.get("id"), "base": a.get("base"),
             "acceptance_command_present": feats["acceptance_command"]}
    if prior:
        extra["prior_route_id"] = prior.get("route_id")
    finish(a, pol, feats, task, r, "plan", a["plan_hash"], a["state"], extra)


def features(pol, task, cp, repo, source):
    """Step 1: the state object. Trusted features only, no free text."""
    tags = sorted(set(task.get("tags") or []))
    acc = task.get("acceptance") or ""
    line = str(task.get("line_no", ""))
    tier_rec = ((cp.get("tiers") or {}).get(line) or {}).get("tier") if cp else None
    if tier_rec in RISK:
        risk, risk_src = tier_rec, "checkpoint"
    elif set(tags) & TIER_C_TAGS:
        risk, risk_src = "C", "tag-floor"
    elif set(tags) & TIER_B_TAGS:
        risk, risk_src = "B", "tag-floor"
    else:
        risk, risk_src = "A", "tag-floor"
    chains = toolchains(repo)
    acc_cmd = command_like(acc)
    rounds = len((((cp.get("reviews") or {}).get(line) or {}).get("rounds") or [])) if cp else 0
    route = {k: v for k, v in (task.get("route") or {}).items() if k != "_invalid"}
    budget = {k: v for k, v in (task.get("budget") or {}).items() if k != "_invalid"}
    return {"source": source, "tags": tags, "acceptance_present": bool(acc.strip()), "acceptance_command": acc_cmd,
            "route_directive": route, "paths": list(task.get("paths") or []), "budget_directive": budget,
            "risk_tier": risk, "risk_tier_source": risk_src,
            "consecutive_failures": int((cp or {}).get("consecutive_failures", 0) or 0), "review_rounds": rounds,
            "toolchains": chains, "runnable_check": bool(chains) or acc_cmd, "doctor_profile": None}


def cmd_adhoc(plugin_root, argv):
    a, pos = parse_opts(argv, {"--dry-run"}, {"--tags", "--paths", "--acceptance", "--id", "--state", "--repo",
                                              "--exec-scripts", "--halted", "--busy"})
    tags = [t.strip().lower() for t in (a.get("tags") or "").split(",") if t.strip()]
    if not tags:
        die("adhoc requires --tags <csv> (caller-supplied tags only, never free text)", 2)
    bad = [t for t in tags if not TAG_OK.fullmatch(t)]
    if bad:
        die("adhoc --tags must be tag tokens [a-z0-9:@._+-]: %s" % ",".join(bad), 2)
    if a.get("halted"):
        return early_status(a, "HALTED", a["halted"])
    if a.get("busy"):
        return early_status(a, "BUSY", "another ACTIVE owner: " + a["busy"])
    pol = Policy(load_policy(plugin_root))
    paths = [p.strip() for p in (a.get("paths") or "").split(",") if p.strip()]
    task = {"line_no": 0, "tags": tags, "acceptance": a.get("acceptance") or "", "paths": paths,
            "route": {}, "budget": {}, "swarm": ""}
    feats = features(pol, task, {}, a.get("repo"), "adhoc")
    r = compute(pol, feats, task, {"lanes": []}, dispatch_mode(), {})
    extra = {"adhoc_id": a["id"], "acceptance": task["acceptance"], "paths_owned": paths}
    finish(a, pol, feats, task, r, "adhoc", a["id"], a["state"], extra)


def locate(route_id, state_base):
    m = ROUTE_ID_RE.match(route_id or "")
    if not m:
        die("not a route id: %r (r-<plan-hash>-L<line>-<n> or a-<adhoc-id>-<n>)" % route_id, 2)
    if m.group(1):
        return "plan", os.path.join(state_base, m.group(2)), int(m.group(3))
    return "adhoc", os.path.join(state_base, "adhoc", m.group(6)), 0


def find_route(state_dir, route_id):
    act = read_json(os.path.join(ledger.dispatch_dir(state_dir, write=True), "active-route.json"), {}) or {}
    if act.get("route_id") == route_id:
        return act
    for row in reversed(ledger_rows(state_dir)):
        if row.get("route_id") == route_id and row.get("event") == "route":
            return row
    return None


def cmd_escalate(plugin_root, argv):
    a, pos = parse_opts(argv, set(), {"--state-base", "--state"})
    if len(pos) != 1:
        die("usage: route.sh escalate ROUTE_ID [--state DIR]", 2)
    route_id = pos[0]
    kind, state_dir, line = locate(route_id, a.get("state_base") or "")
    if a.get("state"):   # the caller's own state dir (checkpoint.sh fail) wins over resolving from $PWD
        state_dir = a["state"]
    rec = find_route(state_dir, route_id)
    if rec is None:
        die("route %s is not recorded under %s" % (route_id, state_dir))
    pol = Policy(load_policy(plugin_root))
    if kind == "plan":
        cp = read_json(os.path.join(state_dir, "checkpoint.json"), {}) or {}
        failures = int(cp.get("consecutive_failures", 0) or 0) or 1
    else:
        failures = 1 + sum(1 for row in ledger_rows(state_dir) if row.get("event") == "escalate"
                           and row.get("prior_route_id") == route_id)
    prior = rec.get("table_choice") or rec.get("router") or {}
    ctx = escalation_ctx(pol, failures, prior)
    rung = ctx["rung"]
    if rung is None:
        emit([("RUNG", "none"), ("FAILURES", failures), ("PRIOR_ROUTE", route_id)])
        return
    out = [("RUNG", "%s (%s)" % (rung["id"], {"effort_up": "effort=+1", "model_up": "model=+1",
                                                "halt": "HALT"}.get(rung["action"], rung["action"]))),
           ("FAILURES", failures), ("PRIOR_ROUTE", route_id)]
    nxt = {}
    if rung["action"] == "effort_up":
        cur = prior.get("effort") if prior.get("effort") in EFFORTS else "medium"
        nxt = {"tier": prior.get("tier"), "model": prior.get("model"),
               "effort": EFFORTS[min(EFFORTS.index(cur) + 1, len(EFFORTS) - 1)]}
        out += [("NEXT_TIER", nxt["tier"]), ("NEXT_MODEL", nxt["model"]), ("NEXT_EFFORT", nxt["effort"]),
                ("NEXT_BUILDER", "builder-" + nxt["effort"] if nxt["effort"] in ("high", "xhigh") else "builder"),
                ("PRIOR_FAILURE_SUMMARY_TOKENS", pol.escalation.get("prior_failure_summary_tokens", 400))]
    elif rung["action"] == "model_up":
        cur = prior.get("tier") if prior.get("tier") in pol.tier else "standard"
        t = pol.tier_at(pol.rank(cur) + 1)
        nxt = {"tier": t["id"], "model": t["model"], "effort": t["effort"]}
        out += [("NEXT_TIER", t["id"]), ("NEXT_MODEL", t["model"]), ("NEXT_EFFORT", t["effort"]),
                ("DIAGNOSER", "%s (read-only, %s family)" % (pol.escalation.get("diagnoser_role", "diagnoser"),
                                                            pol.escalation.get("diagnoser_family", "different")))]
    else:
        out += [("ACTION", "HALT — record it: checkpoint.sh PLAN halt \"escalation ladder exhausted\"; "
                           "the Ask Contract (what, what it does, why, risks) goes to the human")]
    emit(out)
    ledger_append(state_dir, "escalate", {"prior_route_id": route_id, "failures": failures, "rung": rung["id"],
                                          "action": rung["action"], "next": nxt, "line": line},
                  route_id=route_id, route_mode="escalated")


def generic_review(risk):
    shape = {"A": "solo", "B": "six-lens", "C": "fanout6+adversarial"}[risk]
    div = {"A": "off", "B": "warn", "C": "block"}[risk]
    return shape, div, ("G12" if risk == "C" else None)


def cmd_review_shape(plugin_root, argv):
    a, pos = parse_opts(argv, set(), {"--tier", "--state-base"})
    tier = (a.get("tier") or (pos[0] if pos and pos[0].upper() in RISK else "")).upper()
    if tier not in RISK:
        die("usage: route.sh review-shape TIER | review-shape ROUTE_ID --tier TIER (TIER is A, B or C)", 2)
    route_id = next((p for p in pos if p.upper() not in RISK), None)
    pol = Policy(load_policy(plugin_root))
    if route_id:
        kind, state_dir, _ = locate(route_id, a.get("state_base") or "")
        rec = find_route(state_dir, route_id)
        if rec is None:
            die("route %s is not recorded under %s" % (route_id, state_dir))
        router = rec.get("table_choice") or rec.get("router") or {}
        cid = router.get("class") if router.get("class") in pol.classes else pol.default_class()
        cls = pol.classes[cid]
        feats = dict(rec.get("state") or {})
        feats.update({"risk_tier": tier, "tags": feats.get("tags", []),
                      "runnable_check": feats.get("runnable_check", True),
                      "consecutive_failures": feats.get("consecutive_failures", 0)})
        floors = [rule.get("then", {}) for rule in pol.hard_rules if rule_matches(rule, feats)]
        directive = (feats.get("route_directive") or {}).get("review")
        shape, div = review_for(pol, cls, tier, floors, directive)
        gate = cls.get("human_gate")
        for then in floors:
            gate = then.get("human_gate") or gate
        if tier == "C":
            gate = gate or "G12"
    else:
        shape, div, gate = generic_review(tier)
    reviewers = {"none": 0, "solo": 1, "six-lens": 1, "fanout6+adversarial": 6}[shape]
    emit([("REVIEW_TIER", tier), ("REVIEW_SHAPE", shape), ("REVIEW_DIVERSITY", div),
          ("REVIEW_LENS_REVIEWERS", reviewers),
          ("REVIEW_ADVERSARIAL", shape == "fanout6+adversarial"),
          ("REVIEW_HUMAN_GATE", gate), ("REVIEW_ROUTE", route_id),
          ("REVIEW_EXTERNAL_BUILDERS", "forbidden" if tier == "C" else "per-class")])


def main(argv):
    if len(argv) < 2:
        die("usage: route.py PLUGIN_ROOT (version|plan|adhoc|escalate|review-shape) ...", 2)
    root, cmd, rest = argv[0], argv[1], argv[2:]
    if cmd == "version":
        print(json.load(open(os.path.join(root, ".claude-plugin", "plugin.json")))["version"])
        return 0
    if cmd in ("plan", "adhoc", "escalate", "review-shape"):
        {"plan": cmd_plan, "adhoc": cmd_adhoc, "escalate": cmd_escalate, "review-shape": cmd_review_shape}[cmd](root, rest)
        return 0
    die("unknown subcommand %s" % cmd, 2)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
