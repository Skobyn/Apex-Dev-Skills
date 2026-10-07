#!/usr/bin/env python3
"""apex-dispatch provider worker engine (python3 stdlib), spec §5.4, §5.3 H/I.

Called only through bin/worker-common.sh (sourced by bin/worker-<provider>.sh)
and scripts/apply.sh, never directly:

  worker.py run   PROVIDER PLUGIN_ROOT STATE_BASE EXEC_SCRIPTS REPO_ROOT -- \
                  --route ID --role ROLE --brief FILE [--mode build|write|readonly]
                  [--base SHA] [--out DIR] [--timeout-sec N]
  worker.py apply PLUGIN_ROOT STATE_BASE EXEC_SCRIPTS REPO_ROOT -- --worker DIR [--route ID]

`run` refuses before anything starts when the run, route, provider, role,
stage, budget or doctor.json says no; builds the provider command only from the
overlay-merged policy (forced flags + structured fields; the caller passes no
flags of its own); confines the run (write mode: a detached `git worktree` off
the plan worktree HEAD under <D>/worktrees/; read-only mode: a `git archive`
snapshot there); scrubs the environment to an allowlist; wraps the provider in
`timeout`; writes <out>/result.json, patch.diff (write mode), stdout.log,
stderr.log; appends `worker_run` (and, for reviewers, `verdict`) ledger rows
in-process with source `shim`; prints `DISPATCH-DONE exit=N` last.

`apply` turns a write-mode worker's patch into one commit on the plan worktree
(owned Paths and the never-touch list checked, never during GATE/REVIEW) and
writes a `worker_applied` row.

Exit codes (run): 0 the provider finished (exit 0, output parsed); 1 it ran and
failed (non-zero exit, timeout, truncated or unparseable output: result.json
still written); 2 usage; 3 refused by policy, route, stage or budget; 4 the
provider is unavailable (doctor.json missing or says the CLI or its auth is
unavailable, or the binary is gone); 5 confinement could not be set up.
Exit codes (apply): 0 applied; 1 refused (the patch is kept under
<D>/rejected/); 2 usage; 3 refused before inspection (no run, stage, route).
"""
import sys

sys.dont_write_bytecode = True

import datetime  # noqa: E402
import hashlib  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import shutil  # noqa: E402
import subprocess  # noqa: E402
import tarfile  # noqa: E402
import time  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
os.environ.pop("APEX_DISPATCH_WORKER_WT", None)        # the shim is never itself a worker session
import hooks  # noqa: E402  (Ctx, parse_review, live_agents, set_stage, glob_re, ...)
import ledger  # noqa: E402  (the single ledger writer)

EXIT_OK, EXIT_FAILED, EXIT_USAGE, EXIT_REFUSED, EXIT_UNAVAILABLE, EXIT_CONFINE = 0, 1, 2, 3, 4, 5

# Shim roles: builder-side roles write (a throwaway worktree, applied with
# apply.sh); reviewers and diagnosers are read-only (a snapshot) and never write.
WRITE_ROLES = {"builder", "tester", "docs"}
READ_ROLES = {"reviewer", "adversarial-reviewer", "diagnoser"}
REVIEW_ROLES = {"reviewer", "adversarial-reviewer"}
SHIM_PROVIDERS = ("claude-p", "codex")                 # the shims this plugin ships
MAX_BRIEF_BYTES = 256 * 1024
FALLBACK_USD = 1.00          # baseline/shadow routes carry no USD budget: cap a claude -p run here
FALLBACK_MINUTES = 30        # ... and no minutes budget
KILL_AFTER_SEC = 5
# Environment the provider may see (spec §5.4: PATH, HOME, the provider key, proxy vars),
# plus locale, temp, the CA bundle the proxy needs, the provider's own config dir, and
# the run-state switches the hooks inside a claude -p worker must resolve the same way.
ENV_ALLOW = {"PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TMPDIR", "TZ", "USER", "LOGNAME", "SHELL",
             "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "no_proxy", "ALL_PROXY", "all_proxy",
             "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE", "NODE_EXTRA_CA_CERTS", "CURL_CA_BUNDLE",
             "APEX_STATE_ROOT", "APEX_SCOPE_LOOP_ROOT", "APEX_HALT"}
ENV_PROVIDER = {"claude-p": {"CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN"}, "codex": {"CODEX_HOME"}}
NEVER_TOUCH = (
    (re.compile(r"(^|/)\.dev-plan-state(/|$)"), "run state (.dev-plan-state/)"),
    (re.compile(r"(^|/)\.git(/|$)"), "git internals (.git)"),
    (re.compile(r"(^|/)\.claude/apex-dispatch(/|$)"), ".claude/apex-dispatch/"),
    (re.compile(r"(^|/)\.claude/settings[^/]*\.json$"), ".claude/settings*.json"),
    (re.compile(r"(^|/)\.claude/hooks(/|$)"), ".claude/hooks/"),
    (re.compile(r"(^|/)hooks/hooks\.json$"), "hooks/hooks.json (hook registrations)"),
    (re.compile(r"(^|/)\.mcp\.json$"), ".mcp.json"),
    (re.compile(r"(^|/)\.gitmodules$"), ".gitmodules"),
    (re.compile(r"(^|/)\.env(\.[^/]*)?$"), "a .env secrets file"),
    (re.compile(r"(^|/)(id_rsa|id_ecdsa|id_ed25519)[^/]*$|\.pem$"), "a private key file"),
)


class Refuse(Exception):
    def __init__(self, code, msg):
        super().__init__(msg)
        self.code = code


def now_ts():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def git(repo, *args, check=False, timeout=60, **kw):
    r = subprocess.run(["git", "-C", repo] + list(args), capture_output=True, timeout=timeout, **kw)
    if check and r.returncode != 0:
        err = r.stderr.decode("utf-8", "replace") if isinstance(r.stderr, bytes) else r.stderr
        raise Refuse(EXIT_CONFINE, "git %s failed in %s: %s" % (args[0], repo, (err or "").strip()[:300]))
    return r


def git_out(repo, *args):
    r = git(repo, *args)
    return r.stdout.decode("utf-8", "replace").strip() if r.returncode == 0 else None


def write_json(path, obj, exclusive=False):
    hooks.write_json_atomic(path, obj, exclusive=exclusive)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def opts(argv, valued, aliases=None):
    """--name VALUE options only; anything else (a free-form flag included) is a usage error."""
    aliases = aliases or {}
    out, i = {}, 0
    while i < len(argv):
        a = aliases.get(argv[i], argv[i])
        if a in valued and i + 1 < len(argv):
            out[a[2:].replace("-", "_")] = argv[i + 1]
            i += 2
            continue
        raise Refuse(EXIT_USAGE, "unknown or incomplete argument %r (the shim takes no provider flags; "
                                 "its command line comes only from the policy)" % argv[i])
    return out


def context(plugin_root, state_base, exec_scripts, repo_root):
    ctx = hooks.Ctx("worker", plugin_root, state_base, exec_scripts, repo_root)
    if not ctx.owner_ok or not ctx.state_dir or ctx.stale():
        raise Refuse(EXIT_REFUSED, "no ACTIVE apex-scope-loop/apex-dispatch run in this repository "
                                   "(route a task first: iterate.sh or route.sh)")
    h = hooks.halt_reason(ctx)
    if h:
        raise Refuse(EXIT_REFUSED, "halted (%s)" % h)
    return ctx


def provider_policy(ctx, pid, plugin_root):
    """The provider's merged-policy entry, refused unless it may run (status, enabled)."""
    provs = {p.get("id"): p for p in ctx.policy.get("providers", []) if isinstance(p, dict)}
    p = provs.get(pid)
    if not p:
        raise Refuse(EXIT_REFUSED, "provider %s is not in the policy" % pid)
    if p.get("kind") != "subprocess":
        raise Refuse(EXIT_REFUSED, "provider %s is %s, not a subprocess worker" % (pid, p.get("kind")))
    if not p.get("enabled"):
        raise Refuse(EXIT_REFUSED, "provider %s is disabled in the policy (status %s)" % (pid, p.get("status")))
    if p.get("status") != "verified" and not explicitly_enabled(pid):
        raise Refuse(EXIT_REFUSED, "provider %s has status %s, not verified, and this repository's overlay does not "
                                   "enable it explicitly (.claude/apex-dispatch/policy.json providers[%s].enabled: true)"
                     % (pid, p.get("status"), pid))
    if pid not in SHIM_PROVIDERS:
        raise Refuse(EXIT_REFUSED, "no worker shim is shipped for provider %s (shipped: %s)" % (pid, ", ".join(SHIM_PROVIDERS)))
    return p


def explicitly_enabled(pid):
    import compile as policy_compiler
    path = policy_compiler.find_overlay()
    if not path:
        return False
    try:
        ov = policy_compiler.load_json(path, "overlay")
    except Exception:
        return False
    return any(isinstance(e, dict) and e.get("id") == pid and e.get("enabled") is True for e in ov.get("providers") or [])


def doctor_gate(ctx, pid, p):
    """doctor.json must show the CLI and its auth available (spec §5.1 doctor; §5.2 step 6)."""
    ddir = ledger.dispatch_dir(ctx.state_dir)
    doc = ledger.read_json(os.path.join(ddir, "doctor.json"))
    if not isinstance(doc, dict):
        raise Refuse(EXIT_UNAVAILABLE, "no doctor.json for this run: run %s/scripts/doctor.sh --state %s first"
                     % (ctx.plugin_root, ctx.state_dir))
    e = (doc.get("providers") or {}).get(pid) or {}
    if not e.get("available"):
        raise Refuse(EXIT_UNAVAILABLE, "doctor.json shows provider %s unavailable (%s); re-run doctor.sh after installing it"
                     % (pid, e.get("why") or "binary not found"))
    if e.get("flags_ok") is False:
        raise Refuse(EXIT_UNAVAILABLE, "doctor.json shows %s rejects its forced flags (%s)" % (pid, e.get("flags_detail")))
    if pid == "claude-p":
        if doc.get("claude_p_auth") != "available":
            raise Refuse(EXIT_UNAVAILABLE, "doctor.json shows claude -p auth unavailable (no ANTHROPIC_API_KEY, OAuth token "
                                           "or credentials file); Tier C diversity degrades to warn")
    elif not e.get("auth_ok"):
        raise Refuse(EXIT_UNAVAILABLE, "doctor.json shows no auth for %s (%s unset and no credentials file)"
                     % (pid, p.get("key_env")))
    name = os.environ.get("APEX_CLAUDE_BIN") or "claude" if p.get("binary") == "claude" else p.get("binary")
    path = shutil.which(name)
    if not path:
        raise Refuse(EXIT_UNAVAILABLE, "binary %s is not on PATH any more (doctor.json is stale; re-run doctor.sh)" % name)
    return path, doc


def tier_of(ctx, tid):
    return {t.get("id"): t for t in ctx.policy.get("tiers", [])}.get(tid)


def model_for(ctx, p, router):
    """claude -p: the route tier's model, capped at the provider's max_tier."""
    tiers = sorted(ctx.policy.get("tiers", []), key=lambda t: t.get("rank", 0))
    cap = tier_of(ctx, p.get("max_tier")) or tiers[0]
    t = tier_of(ctx, router.get("tier")) or cap
    if t.get("rank", 0) > cap.get("rank", 0):
        t = cap
    return t.get("model"), t.get("effort"), t.get("id")


def check_flags(p, argv):
    """Defence in depth: the built command never carries a forbidden or bypass flag."""
    for a in argv:
        for f in p.get("forbidden_flags") or []:
            if a == f or a.startswith(f + "="):
                raise Refuse(EXIT_REFUSED, "internal: forbidden flag %s in the built command" % f)
        if a.startswith(hooks.BYPASS_PREFIXES) or any(s in a for s in hooks.BYPASS_SUBSTRINGS):
            raise Refuse(EXIT_REFUSED, "internal: bypass flag %s in the built command" % a)


def build_claude_p(ctx, p, binary, role, mode, router, usd, cwd, out):
    model, _, tier_id = model_for(ctx, p, router)
    agent = role
    if role == "builder":
        eff = router.get("effort")
        variants = (ctx.roles().get("builder") or {}).get("effort_variants") or []
        agent = "builder-%s" % eff if eff in variants else "builder"
    rp = ctx.roles().get(agent) or ctx.roles().get(role) or {}
    # Pre-approved tools: the role's own tools, never Bash (dontAsk denies the rest).
    tools = [t for t in rp.get("tools") or [] if t not in ("Bash", "Agent")]
    if mode == "readonly":
        tools = [t for t in tools if t in ("Read", "Grep", "Glob")]
    argv = [binary] + list(p.get("forced_flags") or [])
    argv += ["--plugin-dir", ctx.plugin_root]
    g = os.path.realpath(os.path.join(ctx.plugin_root, "..", "apex-guardrails"))
    if os.path.isfile(os.path.join(g, ".claude-plugin", "plugin.json")):
        argv += ["--plugin-dir", g]
    argv += ["--agent", "apex-dispatch:%s" % agent, "--model", model, "--max-budget-usd", "%.2f" % usd]
    argv += ["--allowedTools"] + tools                    # variadic: last; the brief arrives on stdin
    return argv, {"model": model, "tier": tier_id, "agent": "apex-dispatch:%s" % agent, "stdin": "brief"}


def build_codex(ctx, p, binary, role, mode, router, usd, cwd, out):
    forced = list(p.get("forced_flags") or [])
    if mode == "readonly":                                # tighten, never loosen: workspace-write -> read-only
        forced = ["read-only" if i > 0 and forced[i - 1] in ("--sandbox", "-s") else a for i, a in enumerate(forced)]
    argv = [binary] + forced + ["-C", cwd, "-o", os.path.join(out, "result.last.md"), "--"]
    return argv, {"model": "provider-default", "tier": None, "agent": None, "stdin": "devnull", "brief_arg": True}


BUILDERS = {"claude-p": build_claude_p, "codex": build_codex}


def scrub_env(pid, p, extra=None):
    allow = ENV_ALLOW | ENV_PROVIDER.get(pid, set())
    if p.get("key_env"):
        allow.add(p["key_env"])
    env = {k: v for k, v in os.environ.items() if k in allow or k.startswith("LC_")}
    env.update(extra or {})
    return env


def parse_claude(stdout_text):
    """claude -p --output-format json: one result object (the last JSON line wins)."""
    obj = None
    for ln in reversed(stdout_text.strip().splitlines()):
        try:
            o = json.loads(ln)
        except ValueError:
            continue
        if isinstance(o, dict):
            obj = o
            break
    if obj is None:
        try:
            o = json.loads(stdout_text)
            obj = o if isinstance(o, dict) else None
        except ValueError:
            obj = None
    if not obj or obj.get("type") != "result":
        return {"sentinel": False, "text": None}
    mu = obj.get("modelUsage") if isinstance(obj.get("modelUsage"), dict) else {}
    cost = obj.get("total_cost_usd")
    return {"sentinel": True, "error": bool(obj.get("is_error")) or obj.get("subtype") not in (None, "success"),
            "text": obj.get("result") if isinstance(obj.get("result"), str) else None,
            "usage": hooks.norm_usage(obj.get("usage")),
            "usd": float(cost) if isinstance(cost, (int, float)) and not isinstance(cost, bool) else None,
            "model": sorted(mu)[0] if mu else None}


def parse_codex(stdout_text, last_md):
    """codex exec --json: JSONL events; usage from the last turn.completed; text from -o or the last agent_message."""
    usage, text, done, failed, model = None, None, False, False, None
    for ln in stdout_text.splitlines():
        try:
            e = json.loads(ln)
        except ValueError:
            continue
        if not isinstance(e, dict):
            continue
        t = e.get("type")
        if isinstance(e.get("model"), str):
            model = e["model"]
        if t == "turn.completed":
            done = True
            u = e.get("usage") if isinstance(e.get("usage"), dict) else {}
            usage = hooks.norm_usage({"input_tokens": u.get("input_tokens"), "output_tokens": u.get("output_tokens"),
                                      "cache_read_input_tokens": u.get("cached_input_tokens")})
        elif t in ("turn.failed", "error"):
            failed = True
        elif t == "item.completed" and isinstance(e.get("item"), dict) and e["item"].get("type") in ("agent_message", "assistant_message"):
            if isinstance(e["item"].get("text"), str):
                text = e["item"]["text"]
    try:
        with open(last_md, encoding="utf-8") as f:
            md = f.read()
        if md.strip():
            text = md
    except OSError:
        pass
    return {"sentinel": done, "error": failed, "text": text, "usage": usage, "usd": None, "model": model}


def usd_estimate(ctx, model, usage, reported):
    if reported is not None:
        return reported
    fam = hooks.family(model)
    prices = hooks.price_table(ctx)
    if not usage or fam not in prices:
        return None
    return round(hooks.row_usd(prices, {"usage": usage, "resolved_model": fam}), 6)


def extract_snapshot(repo, sha, dest):
    """Read-only confinement: the tree at sha as plain files (no .git), via git archive."""
    os.makedirs(dest)
    r = subprocess.run(["git", "-C", repo, "archive", "--format=tar", sha], capture_output=True, timeout=300)
    if r.returncode != 0:
        raise Refuse(EXIT_CONFINE, "git archive failed: %s" % r.stderr.decode("utf-8", "replace").strip()[:300])
    import io
    with tarfile.open(fileobj=io.BytesIO(r.stdout), mode="r:") as tf:
        for m in tf.getmembers():
            n = m.name
            if n.startswith("/") or ".." in n.split("/") or not (m.isfile() or m.isdir() or m.issym()):
                raise Refuse(EXIT_CONFINE, "unexpected archive member %r" % n)
        if hasattr(tarfile, "data_filter"):
            tf.extractall(dest, filter="data")
        else:
            tf.extractall(dest)


def remove_tree(path):
    shutil.rmtree(path, ignore_errors=True)


# ---------------------------------------------------------------------- run ----

def cmd_run(pid, plugin_root, state_base, exec_scripts, repo_root, argv):
    a = opts(argv, {"--route", "--role", "--brief", "--mode", "--base", "--out", "--timeout-sec"},
             aliases={"--task-file": "--brief"})
    for k in ("route", "role", "brief"):
        if not a.get(k):
            raise Refuse(EXIT_USAGE, "--%s is required" % k)
    role = a["role"]
    if role not in WRITE_ROLES | READ_ROLES:
        raise Refuse(EXIT_USAGE, "--role must be one of %s" % ", ".join(sorted(WRITE_ROLES | READ_ROLES)))
    mode = {"build": "write", "write": "write", "readonly": "readonly", None: None}.get(a.get("mode"), "?")
    if mode == "?":
        raise Refuse(EXIT_USAGE, "--mode must be build, write or readonly")
    mode = mode or ("write" if role in WRITE_ROLES else "readonly")
    if role in READ_ROLES and mode != "readonly":
        raise Refuse(EXIT_USAGE, "role %s is read-only: --mode readonly only" % role)
    if role in WRITE_ROLES and mode != "write":
        raise Refuse(EXIT_USAGE, "role %s builds: --mode build/write only" % role)
    timeout_cap = None
    if a.get("timeout_sec") is not None:
        if not re.fullmatch(r"[1-9][0-9]{0,5}", a["timeout_sec"]):
            raise Refuse(EXIT_USAGE, "--timeout-sec must be a positive integer (it can only lower the route's budget)")
        timeout_cap = int(a["timeout_sec"])
    brief_path = os.path.realpath(a["brief"])
    try:
        if os.path.getsize(brief_path) > MAX_BRIEF_BYTES:
            raise Refuse(EXIT_USAGE, "the brief is larger than %d bytes" % MAX_BRIEF_BYTES)
        with open(brief_path, encoding="utf-8") as f:
            brief = f.read()
    except (OSError, UnicodeDecodeError) as e:
        raise Refuse(EXIT_USAGE, "cannot read the brief %s: %s" % (a["brief"], e))
    if not brief.strip():
        raise Refuse(EXIT_USAGE, "the brief is empty")

    ctx = context(plugin_root, state_base, exec_scripts, repo_root)
    rec = ctx.route
    if not rec or rec.get("route_id") != a["route"]:
        raise Refuse(EXIT_REFUSED, "route %s is not the ACTIVE task's READY route (active: %s)"
                     % (a["route"], rec.get("route_id") or "none"))
    router = rec.get("router") or {}
    rid = rec["route_id"]
    enforcing = ctx.enforcing_route()
    p = provider_policy(ctx, pid, plugin_root)
    if role not in (p.get("roles_allowed") or []):
        raise Refuse(EXIT_REFUSED, "provider %s does not take role %s (roles_allowed: %s)"
                     % (pid, role, ", ".join(p.get("roles_allowed") or [])))
    if enforcing:
        if router.get("class") not in (p.get("allowed_classes") or []):
            raise Refuse(EXIT_REFUSED, "provider %s does not take class %s" % (pid, router.get("class")))
        roster = router.get("roster") or []
        on_roster = role in roster or (role == "builder" and any(r.startswith("builder") for r in roster))
        if not on_roster:
            raise Refuse(EXIT_REFUSED, "role %s is not on route %s's roster (%s)" % (role, rid, ",".join(roster)))
        if role in WRITE_ROLES:
            if router.get("provider") != pid:
                raise Refuse(EXIT_REFUSED, "route %s routes its builders to %s, not %s" % (rid, router.get("provider"), pid))
            t, cap = tier_of(ctx, router.get("tier")), tier_of(ctx, p.get("max_tier"))
            if t and cap and t.get("rank", 0) > cap.get("rank", 0):
                raise Refuse(EXIT_REFUSED, "route tier %s is above provider %s's max_tier %s" % (t["id"], pid, cap["id"]))
    binary, doc = doctor_gate(ctx, pid, p)
    wt_plan = ctx.worktree
    head = git_out(wt_plan, "rev-parse", "HEAD")
    if not head or not ledger.SHA_RE.match(head):
        raise Refuse(EXIT_REFUSED, "the plan worktree %s has no HEAD commit" % wt_plan)
    if a.get("base") and a["base"] != head:
        raise Refuse(EXIT_REFUSED, "--base %s is not the plan worktree HEAD %s" % (a["base"][:12], head[:12]))

    # Stage and budgets (spec §5.3 D/H), mirroring pre-agent for in-session spawns.
    budgets = router.get("budgets") or {}
    usd_budget = budgets.get("usd") if isinstance(budgets.get("usd"), (int, float)) and budgets.get("usd") > 0 else None
    mins_budget = budgets.get("minutes") if isinstance(budgets.get("minutes"), (int, float)) and budgets.get("minutes") > 0 else None
    if role in WRITE_ROLES:
        if ctx.stage in hooks.LOCKED_STAGES:
            raise Refuse(EXIT_REFUSED, "builder-side workers are refused during stage %s (re-route to return to BUILD)" % ctx.stage)
        spent = hooks.route_usd(ctx, rid)
        if enforcing:
            cap = budgets.get("spawns")
            used = hooks.spawns_for(ctx, rid) + sum(
                1 for r in ledger.read_rows(ctx.state_dir) if r.get("event") == "worker_run" and r.get("source") == "shim"
                and r.get("route_id") == rid and r.get("role") in WRITE_ROLES)
            if isinstance(cap, int) and used >= cap:
                raise Refuse(EXIT_REFUSED, "route %s's spawn budget is spent (%d of %d builder-side spawns and worker runs)"
                             % (rid, used, cap))
            el = hooks.route_minutes(rec)
            if mins_budget and el is not None and el >= mins_budget:
                raise Refuse(EXIT_REFUSED, "route %s's wall-clock budget is spent (%.0f of %s minutes)" % (rid, el, mins_budget))
            if usd_budget and spent >= usd_budget:
                raise Refuse(EXIT_REFUSED, "route %s's USD budget is spent (estimated $%.2f of $%.2f)" % (rid, spent, usd_budget))
            usd_cap = (usd_budget - spent) if usd_budget else FALLBACK_USD
            minutes = (mins_budget - (el or 0)) if mins_budget else FALLBACK_MINUTES
        else:
            usd_cap, minutes = usd_budget or FALLBACK_USD, mins_budget or FALLBACK_MINUTES
    else:
        # Reviewers and diagnosers: bounded by the review shape and the three-round cap,
        # not the builders' budget; each run gets the route's per-run caps.
        usd_cap, minutes = usd_budget or FALLBACK_USD, mins_budget or FALLBACK_MINUTES
        if role in REVIEW_ROLES and enforcing:
            if ctx.owner.get("kind") == "adhoc":
                if hooks.worktree_dirty(wt_plan):
                    raise Refuse(EXIT_REFUSED, "an ad-hoc route's reviewers need a committed, clean HEAD: commit the work first")
            else:
                gate = ledger.read_json(os.path.join(ctx.state_dir, "gate", "last.json"), {}) or {}
                if gate.get("result") not in hooks.GATE_OK or gate.get("head_sha") != head:
                    raise Refuse(EXIT_REFUSED, "reviewer workers need a green gate bound to HEAD (gate/last.json: result %s at %s; "
                                               "HEAD %s) — run green-gate.sh check"
                                 % (gate.get("result") or "none", str(gate.get("head_sha") or "-")[:12], head[:12]))
            busy = [x for x in hooks.live_agents(ctx) if x.get("role") not in hooks.REVIEWER_ROLES]
            if busy:
                raise Refuse(EXIT_REFUSED, "%d builder-side agent(s) or worker(s) are still running (%s); wait for them first"
                             % (len(busy), ", ".join(str(x.get("agent_id")) for x in busy[:4])))
    secs = int(max(1, minutes) * 60)
    if timeout_cap:
        secs = min(secs, timeout_cap)

    # Output directory: one level inside <D>/workers (where checkpoint.sh review --worker looks).
    ddir = ledger.dispatch_dir(ctx.state_dir, write=True)
    workers = os.path.join(ddir, "workers")
    os.makedirs(workers, exist_ok=True)
    run_id = "w-%s-%s" % (pid, os.urandom(6).hex())
    if a.get("out"):
        out = os.path.realpath(a["out"])
        if os.path.dirname(out) != os.path.realpath(workers):
            raise Refuse(EXIT_USAGE, "--out must be a new directory directly inside %s (checkpoint.sh review --worker reads "
                                     "only there); omit it to get one" % workers)
        run_id = os.path.basename(out)
        if not re.fullmatch(r"[A-Za-z0-9_-]{8,64}", run_id):
            raise Refuse(EXIT_USAGE, "--out basename must be 8-64 of [A-Za-z0-9_-]")
    else:
        out = os.path.join(os.path.realpath(workers), run_id)
    try:
        os.mkdir(out)
    except FileExistsError:
        raise Refuse(EXIT_USAGE, "--out %s already exists (one directory per worker run)" % out)
    if role in REVIEW_ROLES and enforcing and ctx.stage != "REVIEW":
        hooks.set_stage(ctx, "REVIEW")

    started_at, t0 = now_ts(), time.monotonic()
    confine = os.path.join(ddir, "worktrees", run_id)
    os.makedirs(os.path.dirname(confine), exist_ok=True)
    reg = {"run_id": run_id, "provider": pid, "role": role, "mode": mode, "route_id": rid, "base_sha": head,
           "worktree": confine if mode == "write" else None, "snapshot": confine if mode == "readonly" else None,
           "out": out, "started_at": started_at, "status": "starting", "pid": os.getpid()}
    write_json(os.path.join(out, "worker.json"), reg)
    agent_reg = os.path.join(hooks.agents_dir(ctx, write=True), run_id + ".json")
    if role in WRITE_ROLES:                                # REVIEW waits for running builder-side workers
        write_json(agent_reg, {"agent_id": run_id, "agent_type": "apex-dispatch-shim:%s" % pid, "role": role,
                               "route_id": rid, "started_at": started_at, "kind": "shim"})
    try:
        if mode == "write":
            git(wt_plan, "worktree", "add", "--detach", confine, head, check=True)
        else:
            extract_snapshot(wt_plan, head, confine)
        home = os.environ.get("HOME") or ""
        confinement = {"kind": "git-worktree" if mode == "write" else "git-archive-snapshot", "path": confine,
                       "os_sandbox": "absent" if home and os.access(home, os.W_OK) else "present-or-home-readonly",
                       "env": "scrubbed-allowlist"}
        argv, meta = BUILDERS[pid](ctx, p, binary, role, mode, router, usd_cap, confine, out)
        check_flags(p, argv)                               # the flags; the brief is a prompt, not a flag
        if meta.get("brief_arg"):
            argv = argv + [brief]
        reg.update({"status": "running", "command": argv[:-1] + ["<brief>"] if meta.get("brief_arg") else argv})
        write_json(os.path.join(out, "worker.json"), reg)
        with open(os.path.join(out, "brief.md"), "w", encoding="utf-8") as f:
            f.write(brief)
        extra = {"APEX_DISPATCH_WORKER_WT": confine} if (pid == "claude-p" and mode == "write") else {}
        env = scrub_env(pid, p, extra)
        timeout_bin = shutil.which("timeout")
        if not timeout_bin:
            raise Refuse(EXIT_CONFINE, "coreutils `timeout` is required for the wall-clock budget")
        full = [timeout_bin, "--kill-after=%d" % KILL_AFTER_SEC, "%ds" % secs] + argv
        with open(os.path.join(out, "stdout.log"), "wb") as so, open(os.path.join(out, "stderr.log"), "wb") as se:
            stdin = open(brief_path, "rb") if meta.get("stdin") == "brief" else subprocess.DEVNULL
            try:
                rc = subprocess.run(full, cwd=confine, env=env, stdin=stdin, stdout=so, stderr=se).returncode
            finally:
                if stdin is not subprocess.DEVNULL:
                    stdin.close()
        wall_ms = int((time.monotonic() - t0) * 1000)
        timed_out = rc in (124, 137)
        with open(os.path.join(out, "stdout.log"), encoding="utf-8", errors="replace") as f:
            stdout_text = f.read()
        parsed = parse_claude(stdout_text) if pid == "claude-p" else parse_codex(stdout_text, os.path.join(out, "result.last.md"))
        ok = rc == 0 and parsed.get("sentinel") and not parsed.get("error")
        files, patch_sha, patch = [], None, None
        if mode == "write":
            git(confine, "add", "-A", check=True)
            d = git(confine, "diff", "--cached", "--binary", "--no-renames", "--full-index", head, check=True)
            patch = os.path.join(out, "patch.diff")
            with open(patch, "wb") as f:
                f.write(d.stdout)
            patch_sha = sha256_file(patch)
            names = git(confine, "diff", "--cached", "--name-only", "-z", "--no-renames", head, check=True).stdout
            files = [x for x in names.decode("utf-8", "replace").split("\0") if x]
        model = parsed.get("model") or meta.get("model")
        usage = parsed.get("usage")
        usd = usd_estimate(ctx, model, usage, parsed.get("usd"))
        verdict = lens = None
        rrole = role
        stale = None
        now_head = git_out(wt_plan, "rev-parse", "HEAD")
        if role in REVIEW_ROLES:
            if role == "adversarial-reviewer":
                rrole = "adversarial"
            if ok:
                verdict, lens = hooks.parse_review(parsed.get("text"))
                if role == "reviewer" and lens in hooks.LENSES:
                    rrole = "lens:" + lens
                elif role == "reviewer":
                    rrole = "reviewer"
            if now_head and now_head != head:
                stale = "HEAD moved from %s to %s while the worker ran" % (head[:12], now_head[:12])
        elif role == "diagnoser":
            rrole = "diagnoser"
        record_id = "%s-%s" % (run_id[:48], os.urandom(8).hex())
        o = ctx.owner
        line = rec.get("line") if rec.get("line") is not None else (o.get("line_no") if o.get("kind") != "adhoc" else None)
        ended_at = now_ts()
        result = {"schema": 1, "source": "shim", "record_id": record_id, "run_id": run_id, "provider": pid,
                  "family": p.get("family"), "model": model, "tier": meta.get("tier"), "agent": meta.get("agent"),
                  "role": rrole, "worker_role": role, "mode": mode, "route": rid, "route_id": rid, "line": line,
                  "plan_hash": o.get("id"), "head_sha": head, "sha": head, "base_sha": head,
                  "verdict": verdict, "lens": lens, "text_file": "result.last.md" if pid == "codex" else "stdout.log",
                  "usage": usage, "usage_source": "provider" if usage else None, "usd_estimate": usd,
                  "usd_reported": parsed.get("usd"), "exit_code": rc, "exit": rc, "timed_out": timed_out,
                  "timeout_sec": secs, "sentinel_seen": bool(parsed.get("sentinel")), "ok": bool(ok),
                  "files_changed": files, "patch": "patch.diff" if patch else None, "patch_sha256": patch_sha,
                  "wall_ms": wall_ms, "started_at": started_at, "ended_at": ended_at, "confinement": confinement,
                  "max_budget_usd": round(usd_cap, 2) if pid == "claude-p" else None}
        if stale:
            result["stale"] = stale
        if pid == "claude-p" and parsed.get("text") is not None:
            with open(os.path.join(out, "result.last.md"), "w", encoding="utf-8") as f:
                f.write(parsed["text"])
            result["text_file"] = "result.last.md"
        write_json(os.path.join(out, "result.json"), result, exclusive=True)
        wr = {"provider": pid, "role": role, "exit_code": rc, "mode": mode, "run_id": run_id, "record_id": record_id,
              "resolved_model": model, "usage": usage, "usd": usd, "usd_estimate": usd, "duration_ms": wall_ms,
              "timed_out": timed_out, "sentinel_seen": bool(parsed.get("sentinel")), "files_changed": len(files),
              "patch_sha256": patch_sha, "family": p.get("family"), "line": line}
        ledger.append(ctx.state_dir, "worker_run", wr, "shim", route_id=rid, route_mode=rec.get("route_mode"), head_sha=head)
        if verdict is not None:
            ledger.append(ctx.state_dir, "verdict", {"role": rrole, "verdict": verdict, "record_id": record_id, "line": line,
                                                     "lens": lens, "provider": pid, "family": p.get("family"),
                                                     "run_id": run_id, "stale": bool(stale), "model": model},
                          "shim", route_id=rid, route_mode=rec.get("route_mode"), head_sha=head)
        reg.update({"status": "finished" if mode == "readonly" else ("ready-to-apply" if ok else "failed"),
                    "ended_at": ended_at, "exit_code": rc})
        write_json(os.path.join(out, "worker.json"), reg)
        print("WORKER_RUN: %s" % run_id)
        print("WORKER_OUT: %s" % out)
        print("WORKER_RESULT: %s" % os.path.join(out, "result.json"))
        print("WORKER_HEAD: %s" % head)
        if role in REVIEW_ROLES:
            print("WORKER_VERDICT: %s%s" % (verdict or "none (the run failed)", " (stale)" if stale else ""))
        if mode == "write":
            print("WORKER_FILES: %d" % len(files))
            print("WORKER_APPLY: %s/scripts/apply.sh --worker %s" % (plugin_root, out))
        if timed_out:
            print("WORKER_TIMEOUT: the provider was stopped after %d s" % secs)
        print("DISPATCH-DONE exit=%d" % rc)
        return EXIT_OK if ok else EXIT_FAILED
    finally:
        # Keep a write worktree only while its patch awaits apply.sh; everything else is removed.
        if reg.get("status") != "ready-to-apply":
            if mode == "write" and os.path.isdir(confine):
                git(wt_plan, "worktree", "remove", "--force", confine)
            remove_tree(confine)
            git(wt_plan, "worktree", "prune")
            if reg.get("status") in ("starting", "running"):
                reg["status"] = "aborted"
                try:
                    write_json(os.path.join(out, "worker.json"), reg)
                except OSError:
                    pass
        if role in WRITE_ROLES:
            r = ledger.read_json(agent_reg)
            if isinstance(r, dict) and not r.get("stopped_at"):
                r.update({"stopped_at": now_ts(), "stopped_by": "shim"})
                write_json(agent_reg, r)


# -------------------------------------------------------------------- apply ----

def path_problem(path, globs):
    if path.startswith("/") or ".." in path.split("/") or "\\" in path:
        return "not a plain repository-relative path"
    for rx, what in NEVER_TOUCH:
        if rx.search(path):
            return "never-touch path: %s" % what
    if globs is not None and not any(hooks.glob_re(g).match(path) for g in globs):
        return "outside the route's owned Paths (%s)" % (", ".join(globs) or "none recorded")
    return None


def owned_globs(ctx):
    """Lanes: the union of the lanes' Paths; else the task's own Paths; else no restriction (None)."""
    lanes = hooks.lane_globs(ctx)
    if lanes is not None:
        return lanes
    st = ctx.route.get("state") or {}
    paths = ctx.route.get("paths_owned") or st.get("paths") or []
    return list(paths) if paths else None


def cmd_apply(plugin_root, state_base, exec_scripts, repo_root, argv):
    if argv and not argv[0].startswith("--"):
        argv = ["--worker"] + argv
    a = opts(argv, {"--worker", "--route"})
    if not a.get("worker"):
        raise Refuse(EXIT_USAGE, "--worker DIR is required")
    ctx = context(plugin_root, state_base, exec_scripts, repo_root)
    if ctx.stage in hooks.LOCKED_STAGES:
        raise Refuse(EXIT_REFUSED, "apply is refused during stage %s: the gate and the reviewers are bound to HEAD; re-route "
                                   "(route.sh plan / iterate.sh) to return to BUILD" % ctx.stage)
    rec = ctx.route
    if not rec:
        raise Refuse(EXIT_REFUSED, "no READY route for the ACTIVE task")
    ddir = ledger.dispatch_dir(ctx.state_dir, write=True)
    out = os.path.realpath(a["worker"])
    if os.path.dirname(out) != os.path.realpath(os.path.join(ddir, "workers")):
        raise Refuse(EXIT_USAGE, "--worker %s is not a worker directory inside %s" % (a["worker"], os.path.join(ddir, "workers")))
    res = ledger.read_json(os.path.join(out, "result.json"))
    reg = ledger.read_json(os.path.join(out, "worker.json"), {}) or {}
    if not isinstance(res, dict):
        raise Refuse(EXIT_REFUSED, "no readable result.json in %s" % out)
    rid = rec.get("route_id")
    run_id = res.get("run_id") or os.path.basename(out)

    def reject(msg):
        rej = os.path.join(ddir, "rejected")
        os.makedirs(rej, exist_ok=True)
        src = os.path.join(out, "patch.diff")
        if os.path.isfile(src):
            shutil.copyfile(src, os.path.join(rej, run_id + ".diff"))
        write_json(os.path.join(rej, run_id + ".json"), {"run_id": run_id, "route_id": rid, "reason": msg, "at": now_ts(),
                                                         "provider": res.get("provider"), "files": res.get("files_changed")})
        tw = reg.get("worktree")
        if tw and os.path.isdir(tw):                       # the patch is the evidence; the throwaway goes
            git(ctx.worktree, "worktree", "remove", "--force", tw)
            remove_tree(tw)
            git(ctx.worktree, "worktree", "prune")
        if reg:
            reg.update({"status": "rejected", "rejected_reason": msg[:300]})
            write_json(os.path.join(out, "worker.json"), reg)
        raise Refuse(EXIT_FAILED, msg + " (patch kept under %s/)" % rej)

    if os.path.exists(os.path.join(out, "applied.json")):
        raise Refuse(EXIT_REFUSED, "this worker's patch was already applied (%s)" % os.path.join(out, "applied.json"))
    if res.get("source") != "shim" or res.get("mode") != "write":
        raise Refuse(EXIT_REFUSED, "not a write-mode shim result (mode %s)" % res.get("mode"))
    if res.get("route") != rid or (a.get("route") and a["route"] != rid):
        raise Refuse(EXIT_REFUSED, "the worker ran for route %s; the ACTIVE route is %s" % (res.get("route"), rid))
    if res.get("exit_code") != 0 or not res.get("sentinel_seen") or not res.get("ok"):
        reject("the worker run did not finish cleanly (exit %s, sentinel %s)" % (res.get("exit_code"), res.get("sentinel_seen")))
    patch = os.path.join(out, "patch.diff")
    if not os.path.isfile(patch) or os.path.getsize(patch) == 0:
        reject("the worker produced an empty patch")
    if sha256_file(patch) != res.get("patch_sha256"):
        reject("patch.diff does not match result.json's patch_sha256")
    wt = ctx.worktree
    head = git_out(wt, "rev-parse", "HEAD")
    if head != res.get("base_sha"):
        reject("the plan worktree moved since the worker forked (base %s, HEAD %s): re-run the worker"
               % (str(res.get("base_sha"))[:12], (head or "?")[:12]))
    if hooks.worktree_dirty(wt):
        raise Refuse(EXIT_REFUSED, "the plan worktree %s has uncommitted changes: commit or discard them first" % wt)
    num = git(wt, "apply", "--numstat", "-z", patch)
    summ = git(wt, "apply", "--summary", patch)
    if num.returncode != 0 or summ.returncode != 0:
        reject("git apply cannot read the patch: %s" % (num.stderr or summ.stderr).decode("utf-8", "replace").strip()[:300])
    paths = []
    for rec_ in num.stdout.decode("utf-8", "replace").split("\0"):
        parts = rec_.split("\t", 2)
        if len(parts) == 3 and parts[2]:
            paths.append(parts[2].lstrip("\n"))
    summary = summ.stdout.decode("utf-8", "replace")
    if re.search(r"mode (120000|160000)", summary):
        reject("the patch creates or changes a symlink or submodule (not applied from workers)")
    if not paths:
        reject("the patch names no paths")
    globs = owned_globs(ctx)
    bad = [(x, path_problem(x, globs)) for x in paths]
    bad = [(x, why) for x, why in bad if why]
    if bad:
        reject("refused paths: %s" % "; ".join("%s (%s)" % b for b in bad[:6]))
    r = git(wt, "apply", "--index", "--binary", "--whitespace=nowarn", patch)
    if r.returncode != 0:
        reject("git apply failed: %s" % r.stderr.decode("utf-8", "replace").strip()[:300])
    msg = ("dispatch: apply %s %s worker for %s\n\nDispatch-Route: %s\nDispatch-Provider: %s\nDispatch-Model: %s\n"
           "Dispatch-Result: %s\n" % (res.get("provider"), res.get("worker_role"), rid, rid, res.get("provider"),
                                      res.get("model"), res.get("record_id")))
    c = git(wt, "commit", "-q", "-m", msg)
    if c.returncode != 0:
        git(wt, "reset", "-q", "--hard", head)            # the worktree was clean at head before the apply
        reject("git commit failed: %s" % (c.stderr or c.stdout).decode("utf-8", "replace").strip()[:300])
    new = git_out(wt, "rev-parse", "HEAD")
    ledger.append(ctx.state_dir, "worker_applied", {"provider": res.get("provider"), "run_id": run_id,
                                                    "record_id": res.get("record_id"), "commit_sha": new,
                                                    "base_sha": head, "files": paths[:200], "model": res.get("model")},
                  "shim", route_id=rid, route_mode=rec.get("route_mode"), head_sha=new)
    write_json(os.path.join(out, "applied.json"), {"commit_sha": new, "at": now_ts(), "files": paths}, exclusive=True)
    tw = reg.get("worktree")
    if tw and os.path.isdir(tw):
        git(wt, "worktree", "remove", "--force", tw)
        remove_tree(tw)
    git(wt, "worktree", "prune")
    reg.update({"status": "applied", "applied_commit": new})
    write_json(os.path.join(out, "worker.json"), reg)
    print("APPLIED: %s" % new)
    print("APPLIED_FILES: %d" % len(paths))
    return EXIT_OK


def main(argv):
    try:
        if len(argv) >= 7 and argv[1] == "run" and argv[7:8] == ["--"]:
            return cmd_run(argv[2], argv[3], argv[4], argv[5], argv[6], argv[8:])
        if len(argv) >= 6 and argv[1] == "apply" and argv[6:7] == ["--"]:
            return cmd_apply(argv[2], argv[3], argv[4], argv[5], argv[7:])
        print("usage: worker.py run PROVIDER ROOT STATE_BASE EXEC REPO -- ARGS | worker.py apply ROOT STATE_BASE EXEC REPO -- ARGS",
              file=sys.stderr)
        return EXIT_USAGE
    except Refuse as r:
        word = "usage" if r.code == EXIT_USAGE else ("unavailable" if r.code == EXIT_UNAVAILABLE else "refused")
        print("DISPATCH-REFUSED: %s: %s" % (word, r), file=sys.stderr)
        return r.code
    except ledger.LedgerError as e:
        print("DISPATCH-REFUSED: ledger: %s" % e, file=sys.stderr)
        return EXIT_FAILED
    except (OSError, subprocess.SubprocessError, ValueError) as e:
        print("DISPATCH-FAILED: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        return EXIT_FAILED


if __name__ == "__main__":
    sys.exit(main(sys.argv))
