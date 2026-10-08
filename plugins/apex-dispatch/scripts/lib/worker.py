#!/usr/bin/env python3
"""apex-dispatch provider worker engine (python3 stdlib), spec §5.4, §5.3 H/I.

Called only through bin/worker-common.sh (sourced by bin/worker-<provider>.sh)
and scripts/apply.sh, never directly:

  worker.py run   PROVIDER PLUGIN_ROOT STATE_BASE EXEC_SCRIPTS REPO_ROOT -- \
                  --route ID --role ROLE --brief FILE [--mode build|write|readonly]
                  [--base SHA] [--out DIR] [--timeout-sec N]
  worker.py apply PLUGIN_ROOT STATE_BASE EXEC_SCRIPTS REPO_ROOT -- --worker DIR [--route ID]
  worker.py smoke PROVIDER PLUGIN_ROOT STATE_BASE REPO_ROOT -- [--record] [--enable] [--timeout-sec N]
                  [--attempts N] [--keep]

`run` refuses before anything starts when the run, route, provider, role,
stage, budget or doctor.json says no; builds the provider command only from the
overlay-merged policy (forced flags + structured fields; the caller passes no
flags of its own); confines the run (write mode: a detached `git worktree` off
the plan worktree HEAD under <D>/worktrees/; read-only mode: a plain-file
snapshot of HEAD there, written by `git read-tree` + `git checkout-index` into a
throwaway index, so export-ignore/export-subst attributes cannot drop or rewrite
files the reviewer must see); scrubs the environment to an allowlist; wraps the provider in
`timeout`; writes <out>/result.json, patch.diff (write mode), stdout.log,
stderr.log; appends `worker_run` (and, for reviewers, `verdict`) ledger rows
in-process with source `shim`; prints `DISPATCH-DONE exit=N` last.

`apply` turns a write-mode worker's patch into one commit on the plan worktree
(owned Paths and the never-touch list checked, never during GATE/REVIEW) and
writes a `worker_applied` row (a refusal writes `worker_rejected`).

`smoke` (scripts/provider-smoke.sh) is the per-version smoke of one provider:
the real CLI, on the same command builder, run-only files, parser and patch
capture as `run`, against a throwaway fixture repository; on a pass `--record`
lists the installed version under the overlay's verified_versions (and
`--enable` sets enabled: true). It refuses while a run holds the ACTIVE lock.

Exit codes (run): 0 the provider finished (exit 0, output parsed); 1 it ran and
failed (non-zero exit, timeout, truncated or unparseable output: result.json
still written); 2 usage; 3 refused by policy, route, stage or budget; 4 the
provider is unavailable (doctor.json missing or says the CLI or its auth is
unavailable, or the binary is gone); 5 confinement could not be set up;
6 the provider is a stub seam with no runner (kind stub; no shipped provider is
one since openai-sdk's runner landed in 0.4.0).
A brief too large to pass as one argv string to an argv-brief provider (codex,
opencode: over ARGV_BRIEF_MAX) is a usage refusal (2) that still writes
result.json (ok false, `refused`) and prints the sentinel.
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
import time  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
os.environ.pop("APEX_DISPATCH_WORKER_WT", None)        # the shim is never itself a worker session
import hooks  # noqa: E402  (Ctx, parse_review, live_agents, set_stage, glob_re, ...)
import ledger  # noqa: E402  (the single ledger writer)

EXIT_OK, EXIT_FAILED, EXIT_USAGE, EXIT_REFUSED, EXIT_UNAVAILABLE, EXIT_CONFINE = 0, 1, 2, 3, 4, 5
EXIT_NOT_IMPLEMENTED = 6

# Shim roles: builder-side roles write (a throwaway worktree, applied with
# apply.sh); reviewers and diagnosers are read-only (a snapshot) and never write.
WRITE_ROLES = {"builder", "tester", "docs"}
READ_ROLES = {"reviewer", "adversarial-reviewer", "diagnoser"}
REVIEW_ROLES = {"reviewer", "adversarial-reviewer"}
# The subprocess shims this plugin ships (bin/<ledger.SHIMS[pid]>); openai-sdk's
# binary is the runner under harnesses/ (ledger.provider_binary).
SHIM_PROVIDERS = ("claude-p", "codex", "grok", "opencode-ollama", "aider-ollama", "openai-sdk")
MAX_BRIEF_BYTES = 256 * 1024
# Providers that take the brief as one argv string (codex `-- "<brief>"`, opencode
# `run [message]`). Linux caps one argument at MAX_ARG_STRLEN (128 KiB); above this
# the run is refused with exit 2 (result.json still written) rather than relying
# on an unverified stdin form of the CLI.
ARGV_BRIEF_PROVIDERS = ("codex", "opencode-ollama")
ARGV_BRIEF_MAX = 120 * 1024
# A claude -p reviewer/diagnoser gets at least this --max-budget-usd: a reviewer
# reads the whole diff, so a docs class's builder budget ($0.50) would truncate it.
REVIEWER_MIN_USD = 2.0
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
ENV_PROVIDER = {"claude-p": {"CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN"}, "codex": {"CODEX_HOME"},
                "grok": {"GROK_HOME"}, "opencode-ollama": {"OLLAMA_HOST"},
                "aider-ollama": {"OLLAMA_HOST", "OLLAMA_API_BASE"},
                "openai-sdk": {"OPENAI_BASE_URL", "OPENAI_ORG_ID", "OPENAI_PROJECT_ID"}}
# Case-insensitive: on a case-insensitive filesystem (macOS, Windows) .ENV or
# .Claude/Settings.json is the same file as the protected one.
NEVER_TOUCH = tuple((re.compile(rx, re.I), what) for rx, what in (
    (r"(^|/)\.dev-plan-state(/|$)", "run state (.dev-plan-state/)"),
    (r"(^|/)\.git(/|$)", "git internals (.git)"),
    (r"(^|/)\.claude/apex-dispatch(/|$)", ".claude/apex-dispatch/"),
    (r"(^|/)\.claude/apex-decision-layer(/|$)", ".claude/apex-decision-layer/"),
    (r"(^|/)\.claude/settings[^/]*\.json$", ".claude/settings*.json"),
    (r"(^|/)\.claude/hooks(/|$)", ".claude/hooks/"),
    (r"(^|/)hooks/hooks\.json$", "hooks/hooks.json (hook registrations)"),
    (r"(^|/)\.mcp\.json$", ".mcp.json"),
    (r"(^|/)\.gitmodules$", ".gitmodules"),
    (r"(^|/)\.env(\.[^/]*)?$", "a .env secrets file"),
    (r"(^|/)\.envrc$", "a .envrc (direnv runs it on cd)"),
    (r"(^|/)(id_rsa|id_ecdsa|id_ed25519)[^/]*$|\.pem$", "a private key file"),
))


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
    if p.get("kind") == "stub":
        raise Refuse(EXIT_NOT_IMPLEMENTED, "provider %s is a stub seam (status %s): not implemented; no runner exists "
                                           "(see bin/%s)" % (pid, p.get("status"), ledger.shim_name(pid)))
    if p.get("kind") != "subprocess":
        raise Refuse(EXIT_REFUSED, "provider %s is %s, not a subprocess worker" % (pid, p.get("kind")))
    if not p.get("enabled"):
        raise Refuse(EXIT_REFUSED, "provider %s is disabled in the policy (status %s)" % (pid, p.get("status")))
    if p.get("status") != "verified":
        # Flagged-off providers (grok, opencode, aider): the overlay must enable them
        # explicitly AND attest a passed per-version smoke (verified_versions); the
        # installed version is matched against that list in doctor_gate.
        if not explicitly_enabled(pid):
            raise Refuse(EXIT_REFUSED, "provider %s has status %s, not verified, and this repository's overlay does not "
                                       "enable it explicitly (.claude/apex-dispatch/policy.json providers[%s].enabled: true)"
                         % (pid, p.get("status"), pid))
        if not p.get("verified_versions"):
            raise Refuse(EXIT_REFUSED, "provider %s has status %s and no per-version smoke is recorded: after the smoke "
                                       "passes on the installed version, list it under the overlay's "
                                       "providers[%s].verified_versions" % (pid, p.get("status"), pid))
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
    if p.get("status") != "verified" and e.get("version") not in (p.get("verified_versions") or []):
        raise Refuse(EXIT_REFUSED, "provider %s %s is installed (doctor.json) but the overlay's verified_versions (%s) does "
                                   "not list it: run the per-version smoke on this version first"
                     % (pid, e.get("version") or "(version unknown)", ", ".join(p.get("verified_versions") or []) or "none"))
    path = ledger.provider_binary(p, ctx.plugin_root)
    if not path:
        raise Refuse(EXIT_UNAVAILABLE, "binary %s is not available any more (doctor.json is stale; re-run doctor.sh)"
                     % p.get("binary"))
    return path, doc


def acceptance_gate(ctx, pid, p):
    """Rolling acceptance (spec §5.2 step 6): a provider below min_acceptance over
    its last acceptance_window decided dispatches is demoted and refused."""
    a = ledger.acceptance(ctx.state_dir, [p], ctx.worktree).get(pid)
    if a and a["status"] == "demoted":
        raise Refuse(EXIT_REFUSED, "provider %s is demoted: %s; recent rejections: %s. Route the work elsewhere "
                                   "(claude-session); the provider is eligible again once rejections older than %d days "
                                   "leave its window" % (pid, ledger.acceptance_line(pid, a, named=False),
                                                         "; ".join(a["last_rejections"]) or "none",
                                                         ledger.ACCEPTANCE_MAX_AGE_DAYS))
    return a


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
    # Pre-approved tools: the role's own tools, never Bash. dontAsk denies whatever is
    # neither pre-approved here nor allowed by the user's own permissions.allow:
    # `--setting-sources user` loads ~/.claude/settings.json, so a user-level allow
    # rule widens what runs without a prompt. The bounds that hold regardless are the
    # agent's tools/disallowedTools frontmatter, the deny rules and the hooks.
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


GROK_SETTINGS = {
    # Written into the confined directory for the run only (restored before the diff),
    # because the grok CLI alone cannot set dontAsk (spec §5.4). Shape per the spec's
    # grok row; unverified until grok's per-version smoke.
    "permissions": {"defaultMode": "dontAsk", "deny": ["Bash(git push*)", "Bash(curl*)", "Bash(wget*)"]},
    "sandbox": {"enabled": True, "failIfUnavailable": True, "profile": {"extends": "strict"}},
}


def build_grok(ctx, p, binary, role, mode, router, usd, cwd, out):
    """grok -p --prompt-file <brief> + the policy's forced flags (--sandbox strict,
    --no-subagents, stream-json, --deny rules). No --worktree: the shim's throwaway
    worktree is the confinement, and grok's own worktree would put its edits
    outside the captured patch (the policy forbids the flag)."""
    argv = [binary] + list(p.get("forced_flags") or []) + ["--prompt-file", os.path.join(out, "brief.md")]
    if p.get("model"):
        argv += ["--model", p["model"]]
    files = {os.path.join(".claude", "settings.json"): json.dumps(GROK_SETTINGS, indent=2, sort_keys=True) + "\n"}
    return argv, {"model": p.get("model") or "provider-default", "tier": None, "agent": None, "stdin": "devnull",
                  "worktree_files": files}


def opencode_config(ctx, mode):
    """opencode permissions: no `ask` anywhere (nothing needs auto-approval), edits
    only inside the owned Paths, no git push/commit, no network fetch, nothing
    outside the directory. Passed through OPENCODE_CONFIG from the out dir, so it is
    never part of the patch."""
    globs = owned_globs(ctx) if mode == "write" else None
    if mode != "write":
        edit = "deny"
    elif globs:
        edit = dict([(g, "allow") for g in globs] + [("*", "deny")])
    else:
        edit = "allow"
    return {"$schema": "https://opencode.ai/config.json", "share": "disabled", "autoupdate": False,
            "permission": {"edit": edit, "webfetch": "deny", "external_directory": "deny",
                           "bash": {"git push*": "deny", "git commit*": "deny", "git config*": "deny",
                                    "curl*": "deny", "wget*": "deny", "*": "allow" if mode == "write" else "deny"}}}


OPENCODE_PROJECT_CONFIG = ("opencode.json", "opencode.jsonc", ".opencode")


def build_opencode(ctx, p, binary, role, mode, router, usd, cwd, out):
    """The generated permissions go in OPENCODE_CONFIG_CONTENT, which opencode's
    docs say loads after (overrides) the global and project configs, and in
    OPENCODE_CONFIG; the confined directory's own opencode.json(c) and .opencode/
    are moved aside for the run anyway (precedence is from the docs and must be
    asserted by the per-version smoke)."""
    cfg_obj = opencode_config(ctx, mode)
    cfg = os.path.join(out, "opencode.jsonc")
    with open(cfg, "w", encoding="utf-8") as f:
        json.dump(cfg_obj, f, indent=2, sort_keys=True)
        f.write("\n")
    argv = [binary] + list(p.get("forced_flags") or []) + ["--dir", cwd, "--model", p.get("model") or "ollama/unset"]
    return argv, {"model": p.get("model"), "tier": None, "agent": None, "stdin": "devnull", "brief_arg": True,
                  "brief_no_dash": True, "hide": [n for n in OPENCODE_PROJECT_CONFIG if os.path.lexists(os.path.join(cwd, n))],
                  "env": {"OPENCODE_CONFIG": cfg, "OPENCODE_CONFIG_CONTENT": json.dumps(cfg_obj, sort_keys=True)}}


def aider_project_config(cwd):
    """Files aider reads from the git root / cwd regardless of --config/--env-file:
    .env and the .aider* configs (.aider.conf.yml, .aider.model.settings.yml,
    .aider.model.metadata.json, ...); .aiderignore only narrows, so it stays."""
    try:
        names = os.listdir(cwd)
    except OSError:
        return []
    return sorted(n for n in names if n == ".env" or (n.startswith(".aider") and n != ".aiderignore"))


AIDER_CONFIG = ("# generated by apex-dispatch worker.py: the only config aider reads for this run\n"
                "auto-commits: false\ndirty-commits: false\ngit: false\nauto-lint: false\nauto-test: false\n"
                "yes-always: false\ncheck-update: false\n")


def build_aider(ctx, p, binary, role, mode, router, usd, cwd, out):
    """aider --message-file <brief> with a generated --config and an empty
    --env-file, so the repository's .aider.conf.yml (which can run commands at
    startup) and .env are never read. Never --yes-always: confirmations meet a
    closed stdin. The owned Paths' tracked files are passed after `--` so aider can
    edit them without asking to add them."""
    conf, envf = os.path.join(out, "aider.conf.yml"), os.path.join(out, "aider.env")
    with open(conf, "w", encoding="utf-8") as f:
        f.write(AIDER_CONFIG)
    open(envf, "w").close()
    argv = [binary] + list(p.get("forced_flags") or []) + ["--config", conf, "--env-file", envf,
                                                            "--message-file", os.path.join(out, "brief.md"),
                                                            "--model", p.get("model") or "ollama/unset"]
    hide = aider_project_config(cwd)
    globs = owned_globs(ctx) or []
    if mode == "write" and globs:
        r = git(cwd, "ls-files", "-z")
        names = [x for x in r.stdout.decode("utf-8", "replace").split("\0") if x] if r.returncode == 0 else []
        files = [x for x in names if not x.startswith("-") and x.split("/")[0] not in hide
                 and any(hooks.glob_re(g).match(x) for g in globs)][:50]
        if files:
            argv += ["--"] + files
    return argv, {"model": p.get("model"), "tier": None, "agent": None, "stdin": "devnull", "hide": hide}


def role_contract(ctx, agent):
    """The generated agents/<agent>.md body (frontmatter dropped): the role contract
    a non-Claude runner gets as its instructions."""
    try:
        with open(os.path.join(ctx.plugin_root, "agents", agent + ".md"), encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return "You are the %s role of apex-dispatch, dispatched for one routed task." % agent
    m = re.match(r"^---\n.*?\n---\n", text, re.S)
    return text[m.end():].strip() if m else text.strip()


def build_openai_sdk(ctx, p, binary, role, mode, router, usd, cwd, out):
    """harnesses/openai_sdk_runner.py run + the policy's forced flags, a run config
    in the out dir (the confined directory, the mode, the owned Paths as globs and
    as hooks.glob_re patterns, the policy model, the role's turn limit and its
    generated contract) and the brief file. The runner's only tools are file
    tools confined to the directory; no shell, network tool or MCP server."""
    agent = role
    if role == "builder":
        eff = router.get("effort")
        variants = (ctx.roles().get("builder") or {}).get("effort_variants") or []
        agent = "builder-%s" % eff if eff in variants else "builder"
    rp = ctx.roles().get(agent) or ctx.roles().get(role) or {}
    globs = owned_globs(ctx) if mode == "write" else None
    cfg = {"root": cwd, "mode": mode, "owned": globs, "owned_rx": [hooks.glob_re(g).pattern for g in globs] if globs else None,
           "model": p.get("model") or None, "max_turns": int(rp.get("maxTurns") or 30),
           "instructions": role_contract(ctx, agent)}
    if globs is not None and not globs:
        cfg["owned"], cfg["owned_rx"] = [], []
    path = os.path.join(out, "openai-sdk.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, sort_keys=True)
        f.write("\n")
    argv = [binary] + list(p.get("forced_flags") or []) + ["--config", path, "--brief-file", os.path.join(out, "brief.md")]
    return argv, {"model": p.get("model") or "provider-default", "tier": None, "agent": "openai-agents:%s" % agent,
                  "stdin": "devnull"}


BUILDERS = {"claude-p": build_claude_p, "codex": build_codex, "grok": build_grok,
            "opencode-ollama": build_opencode, "aider-ollama": build_aider, "openai-sdk": build_openai_sdk}


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


def parse_opencode(stdout_text, rc):
    """opencode run --format json: JSON events (shape unverified until the per-version
    smoke): finished = exit 0 with at least one JSON event and no error event; text =
    the last `text` string seen; usage = the last `tokens` object, if any."""
    events, text, usage, failed = 0, None, None, False
    for ln in stdout_text.splitlines():
        try:
            e = json.loads(ln)
        except ValueError:
            continue
        if not isinstance(e, dict):
            continue
        events += 1
        if e.get("type") == "error" or e.get("error"):
            failed = True
        stack = [e]
        while stack:
            x = stack.pop()
            if isinstance(x, dict):
                if isinstance(x.get("text"), str):
                    text = x["text"]
                t = x.get("tokens")
                if isinstance(t, dict):
                    cache = t.get("cache") if isinstance(t.get("cache"), dict) else {}
                    usage = hooks.norm_usage({"input_tokens": t.get("input"), "output_tokens": t.get("output"),
                                              "cache_read_input_tokens": cache.get("read")})
                stack.extend(v for v in x.values() if isinstance(v, (dict, list)))
            elif isinstance(x, list):
                stack.extend(x)
    return {"sentinel": rc == 0 and events > 0, "error": failed, "text": text, "usage": usage, "usd": None, "model": None}


def parse_aider(stdout_text, rc):
    """aider has no structured output and reports no usage: exit 0 is the finish
    signal and the run is costed by wall-clock only."""
    tail = stdout_text[-20000:] if stdout_text else None
    return {"sentinel": rc == 0, "error": False, "text": tail, "usage": None, "usd": None, "model": None}


def parse_output(pid, stdout_text, out, rc):
    if pid in ("claude-p", "grok", "openai-sdk"):       # the same (stream-)json result shape
        return parse_claude(stdout_text)
    if pid == "codex":
        return parse_codex(stdout_text, os.path.join(out, "result.last.md"))
    if pid == "opencode-ollama":
        return parse_opencode(stdout_text, rc)
    return parse_aider(stdout_text, rc)


def usd_estimate(ctx, model, usage, reported):
    if reported is not None:
        return reported
    fam = hooks.family(model)
    prices = hooks.price_table(ctx)
    if not usage or fam not in prices:
        return None
    return round(hooks.row_usd(prices, {"usage": usage, "resolved_model": fam}), 6)


def extract_snapshot(repo, sha, dest):
    """Read-only confinement: the tree at sha as plain files (no .git). `git
    read-tree` into a throwaway index, then `git checkout-index --all` into dest:
    unlike `git archive`, export-ignore and export-subst attributes neither drop
    nor rewrite files, so the reviewer sees exactly the committed tree (gitlinks,
    i.e. submodules, are not checked out)."""
    os.makedirs(dest)
    idx = dest.rstrip("/") + ".index"
    env = dict(os.environ, GIT_INDEX_FILE=idx)
    for k in ("GIT_DIR", "GIT_WORK_TREE"):
        env.pop(k, None)
    try:
        git(repo, "read-tree", sha, check=True, timeout=300, env=env)
        git(repo, "checkout-index", "--all", "--force", "--prefix=%s/" % dest.rstrip("/"), check=True, timeout=300, env=env)
    finally:
        try:
            os.remove(idx)
        except OSError:
            pass


def remove_tree(path):
    shutil.rmtree(path, ignore_errors=True)


# ---------------------------------------------------------------------- run ----

class RunFiles:
    """Run-only changes to the confined directory, undone before the diff and
    again in a finally: `worktree_files` written for the run (grok's settings),
    `hide` paths moved aside into <out>/hidden/ (a provider's project config the
    repository carries). restore() is idempotent; whatever the provider left at a
    restored path is replaced by the original."""

    def __init__(self, confine, out):
        self.confine, self.out, self.saved, self.hidden, self.done = confine, out, {}, [], False

    def apply(self, meta):
        for rel in meta.get("hide") or []:
            src, dst = os.path.join(self.confine, rel), os.path.join(self.out, "hidden", rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            os.rename(src, dst)
            self.hidden.append(rel)
        for rel, text in (meta.get("worktree_files") or {}).items():
            fp = os.path.join(self.confine, rel)
            try:
                with open(fp, "rb") as f:
                    self.saved[rel] = f.read()
            except OSError:
                self.saved[rel] = None
            os.makedirs(os.path.dirname(fp), exist_ok=True)
            with open(fp, "w", encoding="utf-8") as f:
                f.write(text)

    @staticmethod
    def _clear(fp):
        if os.path.isdir(fp) and not os.path.islink(fp):
            shutil.rmtree(fp, ignore_errors=True)
        elif os.path.lexists(fp):
            os.remove(fp)

    def restore(self):
        if self.done:
            return
        self.done = True
        for rel, old in self.saved.items():
            fp = os.path.join(self.confine, rel)
            try:
                if old is None:
                    self._clear(fp)
                else:
                    with open(fp, "wb") as f:
                        f.write(old)
            except OSError:
                pass
        for rel in self.hidden:
            fp = os.path.join(self.confine, rel)
            try:
                self._clear(fp)
                os.rename(os.path.join(self.out, "hidden", rel), fp)
            except OSError:
                pass


def refuse_recorded(ctx, pid, p, role, mode, rid, head, out, run_id, msg):
    """A refusal after the out dir exists: result.json (ok false, `refused`) and
    worker.json say why, the sentinel is printed, no ledger row is written (nothing
    ran, so no spawn budget is spent) and the exit is 2 (usage)."""
    ts = now_ts()
    result = {"schema": 1, "source": "shim", "record_id": None, "run_id": run_id, "provider": pid,
              "family": p.get("family"), "model": None, "tier": None, "agent": None, "role": role, "worker_role": role,
              "mode": mode, "route": rid, "route_id": rid, "head_sha": head, "sha": head, "base_sha": head,
              "verdict": None, "lens": None, "usage": None, "usage_source": None, "usd_estimate": None,
              "exit_code": EXIT_USAGE, "exit": EXIT_USAGE, "timed_out": False, "sentinel_seen": False, "ok": False,
              "refused": msg, "files_changed": [], "patch": None, "patch_sha256": None, "wall_ms": 0,
              "started_at": ts, "ended_at": ts}
    write_json(os.path.join(out, "result.json"), result, exclusive=True)
    write_json(os.path.join(out, "worker.json"), {"run_id": run_id, "provider": pid, "role": role, "mode": mode,
                                                  "route_id": rid, "base_sha": head, "out": out, "started_at": ts,
                                                  "status": "refused", "refused_reason": msg[:300]})
    print("DISPATCH-REFUSED: usage: %s" % msg, file=sys.stderr)
    print("WORKER_RUN: %s" % run_id)
    print("WORKER_OUT: %s" % out)
    print("WORKER_RESULT: %s" % os.path.join(out, "result.json"))
    print("DISPATCH-DONE exit=%d" % EXIT_USAGE)
    return EXIT_USAGE


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
    acceptance_gate(ctx, pid, p)
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
        # not the builders' budget; each run gets the route's per-run caps, and a
        # claude -p reviewer at least REVIEWER_MIN_USD (the class's builder budget
        # would cut a reading of the whole diff short).
        usd_cap, minutes = max(usd_budget or FALLBACK_USD, REVIEWER_MIN_USD), mins_budget or FALLBACK_MINUTES
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
    nbytes = len(brief.encode("utf-8"))
    if pid in ARGV_BRIEF_PROVIDERS and nbytes > ARGV_BRIEF_MAX:
        return refuse_recorded(ctx, pid, p, role, mode, rid, head, out, run_id,
                               "the brief is %d bytes; %s takes it as one argument, capped at %d bytes (the kernel's "
                               "per-argument limit is 128 KiB): shorten it or route to claude-p, which reads it on stdin"
                               % (nbytes, pid, ARGV_BRIEF_MAX))
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
    runfiles = RunFiles(confine, out)
    try:
        if mode == "write":
            git(wt_plan, "worktree", "add", "--detach", confine, head, check=True)
        else:
            extract_snapshot(wt_plan, head, confine)
        home = os.environ.get("HOME") or ""
        confinement = {"kind": "git-worktree" if mode == "write" else "git-checkout-index-snapshot", "path": confine,
                       "os_sandbox": "absent" if home and os.access(home, os.W_OK) else "present-or-home-readonly",
                       "env": "scrubbed-allowlist"}
        argv, meta = BUILDERS[pid](ctx, p, binary, role, mode, router, usd_cap, confine, out)
        check_flags(p, argv)                               # the flags; the brief is a prompt, not a flag
        if meta.get("brief_arg"):
            # A brief that starts with "-" would be read as an option by the CLI.
            argv = argv + [("Brief:\n" + brief) if meta.get("brief_no_dash") and brief.lstrip().startswith("-") else brief]
        reg.update({"status": "running", "command": argv[:-1] + ["<brief>"] if meta.get("brief_arg") else argv})
        write_json(os.path.join(out, "worker.json"), reg)
        with open(os.path.join(out, "brief.md"), "w", encoding="utf-8") as f:
            f.write(brief)
        extra = {"APEX_DISPATCH_WORKER_WT": confine} if (pid == "claude-p" and mode == "write") else {}
        extra.update(meta.get("env") or {})
        env = scrub_env(pid, p, extra)
        runfiles.apply(meta)
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
                runfiles.restore()                         # run-only files never reach the patch
        wall_ms = int((time.monotonic() - t0) * 1000)
        timed_out = rc in (124, 137)
        with open(os.path.join(out, "stdout.log"), encoding="utf-8", errors="replace") as f:
            stdout_text = f.read()
        parsed = parse_output(pid, stdout_text, out, rc)
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
        if pid != "codex" and parsed.get("text") is not None:
            with open(os.path.join(out, "result.last.md"), "w", encoding="utf-8") as f:
                f.write(parsed["text"])
            result["text_file"] = "result.last.md"
        write_json(os.path.join(out, "result.json"), result, exclusive=True)
        wr = {"provider": pid, "role": role, "exit_code": rc, "mode": mode, "run_id": run_id, "record_id": record_id,
              "resolved_model": model, "usage": usage, "usd": usd, "usd_estimate": usd, "duration_ms": wall_ms,
              "timed_out": timed_out, "sentinel_seen": bool(parsed.get("sentinel")), "ok": bool(ok),
              "files_changed": len(files),
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
        runfiles.restore()                                 # also on a refusal or error after apply()
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
        if res.get("provider") and res.get("source") == "shim":   # counts against the provider's acceptance
            ledger.append(ctx.state_dir, "worker_rejected", {"provider": res["provider"], "run_id": run_id,
                                                             "reason": msg[:300], "record_id": res.get("record_id")},
                          "shim", route_id=rid, route_mode=rec.get("route_mode"), head_sha=git_out(ctx.worktree, "rev-parse", "HEAD"))
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


# -------------------------------------------------------------------- smoke ----
# The per-version smoke of a provider (ADR-0001 "Flagged-off providers": no run of
# an unverified provider before its per-version smoke). It runs the real CLI with
# exactly what `run` would build (the same builder, run-only files, scrubbed
# environment, parser and patch capture) against a throwaway fixture repository,
# and asserts what the shims rely on but smoke.sh can only stub:
#   flags      the forced flags are accepted (`<bin> <forced> --help`, as doctor);
#   version    the installed version is readable (it is what gets attested);
#   run        the CLI finishes non-interactively, stdin closed, inside the timeout;
#   parse      its output parses (the sentinel; no error result);
#   usage      it reports usage when the policy says it does (reports_usage);
#   patch      write roles: the asked-for edit to an owned file lands in the
#              captured patch and nothing else does (the planted project configs
#              and secrets the builder moves aside are restored and untouched);
#   readonly   read-only roles: a parseable APPROVE verdict and a snapshot left
#              byte-identical.
# A provider model is asked to do one small thing; a run that fails only on
# content is retried (--attempts, default 2).

SMOKE_FILES = {"README.md": "# Smoke fixture\n\nA throwaway repository for apex-dispatch's provider smoke.\n",
               "docs/guide.md": "# Guide\n\nThe guide of the smoke fixture.\n",
               "src/app.py": "def greet(name):\n    return 'hello ' + name\n",
               # Canaries: a provider's project config and secrets the builders move aside
               # for the run (opencode, aider) or replace (grok's .claude/settings.json).
               "opencode.json": '{"permission": {"edit": "allow", "bash": "allow"}}\n',
               ".opencode/canary.txt": "opencode project dir canary\n",
               ".aider.conf.yml": "# canary: a repository aider config\nauto-commits: true\n",
               ".env": "APEX_SMOKE_CANARY=1\n",
               ".claude/settings.json": '{"permissions": {"defaultMode": "default"}}\n'}
SMOKE_OWNED = ["docs/**"]
SMOKE_EDIT = "docs/guide.md"


class SmokeCtx:
    """The slice of hooks.Ctx the command builders read, for a fixture task."""

    def __init__(self, plugin_root, policy, owned):
        self.plugin_root, self.policy = plugin_root, policy
        self.route = {"router": {"fanout": "single", "tier": "cheap", "effort": "low"}, "paths_owned": owned}
        self.owner, self.exec_scripts, self.state_dir = {}, None, None

    def roles(self):
        return {r["id"]: r for r in self.policy.get("roles", []) if isinstance(r, dict) and "id" in r}


def tree_digest(root, skip=()):
    h = {}
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x != ".git"]
        for f in files:
            fp = os.path.join(d, f)
            rel = os.path.relpath(fp, root).replace(os.sep, "/")
            if rel in skip or os.path.islink(fp):
                continue
            h[rel] = sha256_file(fp)
    return h


def smoke_fixture(base):
    repo = os.path.join(base, "repo")
    os.makedirs(repo)
    for rel, text in SMOKE_FILES.items():
        fp = os.path.join(repo, rel)
        os.makedirs(os.path.dirname(fp), exist_ok=True)
        with open(fp, "w", encoding="utf-8") as f:
            f.write(text)
    env = dict(os.environ, GIT_AUTHOR_NAME="apex-dispatch smoke", GIT_AUTHOR_EMAIL="smoke@localhost",
               GIT_COMMITTER_NAME="apex-dispatch smoke", GIT_COMMITTER_EMAIL="smoke@localhost")
    for args in (["init", "-q"], ["add", "-A", "-f"], ["commit", "-q", "--no-verify", "-m", "smoke fixture"]):
        git(repo, *args, check=True, env=env)
    return repo, git_out(repo, "rev-parse", "HEAD")


def smoke_once(ctx, pid, p, binary, role, mode, base, attempt, secs):
    """One run of the provider on a fresh fixture. Returns (checks, result dict)."""
    nonce = os.urandom(4).hex()
    root = os.path.join(base, "a%d" % attempt)
    os.makedirs(root)
    repo, head = smoke_fixture(root)
    out = os.path.join(root, "out")
    os.makedirs(out)
    confine = os.path.join(root, "confined")
    checks = []

    def check(cid, ok, detail):
        checks.append({"id": cid, "ok": bool(ok), "detail": detail})
        return ok
    if mode == "write":
        git(repo, "worktree", "add", "-q", "--detach", confine, head, check=True)
        brief = ("Append one new line to the end of the file %s. The line must be exactly:\n\napex-dispatch smoke %s\n\n"
                 "Change no other file and create no file. Do not run git. When you are done, reply with the "
                 "single line: DONE %s\n" % (SMOKE_EDIT, nonce, nonce))
    else:
        extract_snapshot(repo, head, confine)
        brief = ("Read README.md and src/app.py. Change no file. End your reply with exactly these two lines:\n\n"
                 "LENS: correctness\nVERDICT: APPROVE\n")
    before = tree_digest(confine)
    router = ctx.route["router"]
    argv, meta = BUILDERS[pid](ctx, p, binary, role, mode, router, FALLBACK_USD, confine, out)
    check_flags(p, argv)
    if meta.get("brief_arg"):
        argv = argv + [brief]
    with open(os.path.join(out, "brief.md"), "w", encoding="utf-8") as f:
        f.write(brief)
    brief_path = os.path.join(out, "brief.md")
    env = scrub_env(pid, p, meta.get("env"))
    runfiles = RunFiles(confine, out)
    runfiles.apply(meta)
    t0 = time.monotonic()
    try:
        with open(os.path.join(out, "stdout.log"), "wb") as so, open(os.path.join(out, "stderr.log"), "wb") as se:
            stdin = open(brief_path, "rb") if meta.get("stdin") == "brief" else subprocess.DEVNULL
            try:
                rc = subprocess.run([shutil.which("timeout"), "--kill-after=%d" % KILL_AFTER_SEC, "%ds" % secs] + argv,
                                    cwd=confine, env=env, stdin=stdin, stdout=so, stderr=se).returncode
            finally:
                if stdin is not subprocess.DEVNULL:
                    stdin.close()
    finally:
        runfiles.restore()
    wall = int((time.monotonic() - t0) * 1000)
    with open(os.path.join(out, "stdout.log"), encoding="utf-8", errors="replace") as f:
        stdout_text = f.read()
    with open(os.path.join(out, "stderr.log"), encoding="utf-8", errors="replace") as f:
        stderr_tail = f.read()[-600:].strip()
    parsed = parse_output(pid, stdout_text, out, rc)
    check("run", rc == 0, "exit %d after %.1f s%s" % (rc, wall / 1000.0, " (timed out)" if rc in (124, 137) else "")
          + ("; stderr: " + stderr_tail.replace("\n", " | ")[:300] if rc != 0 and stderr_tail else ""))
    check("parse", parsed.get("sentinel") and not parsed.get("error"),
          "sentinel %s, error %s" % (bool(parsed.get("sentinel")), bool(parsed.get("error"))))
    if p.get("reports_usage"):
        u = parsed.get("usage") or {}
        check("usage", u.get("output") or u.get("input"), "usage %s" % (json.dumps(u, sort_keys=True) if u else "missing"))
    if mode == "write":
        git(confine, "add", "-A", check=True)
        names = git(confine, "diff", "--cached", "--name-only", "-z", "--no-renames", head, check=True).stdout
        files = [x for x in names.decode("utf-8", "replace").split("\0") if x]
        try:
            with open(os.path.join(confine, SMOKE_EDIT), encoding="utf-8") as f:
                edited = "apex-dispatch smoke %s" % nonce in f.read()
        except OSError:
            edited = False
        check("patch", files == [SMOKE_EDIT] and edited,
              "patch names %s (expected exactly %s with the nonce line: %s)" % (files or "nothing", SMOKE_EDIT,
                                                                               "present" if edited else "missing"))
        git(repo, "worktree", "remove", "--force", confine)
    else:
        after = tree_digest(confine)
        changed = sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k))
        check("readonly", not changed, "snapshot %s" % ("unchanged" if not changed else "changed: " + ", ".join(changed[:6])))
        if role in REVIEW_ROLES:
            verdict, _ = hooks.parse_review(parsed.get("text"))
            check("verdict", verdict == "APPROVE", "parsed verdict %s" % verdict)
    return checks, {"attempt": attempt, "exit_code": rc, "wall_ms": wall, "model": parsed.get("model") or meta.get("model"),
                    "usage": parsed.get("usage"), "out": out}


def record_attestation(plugin_root, repo_root, pid, version, enable, evidence):
    """Add version to the overlay's providers[pid].verified_versions (and enabled:
    true with --enable), validated through the same merge as compile --print-merged
    before it replaces the file; write the evidence beside it."""
    import compile as policy_compiler
    path = os.environ.get("APEX_DISPATCH_POLICY") or os.path.join(repo_root, ".claude", "apex-dispatch", "policy.json")
    ov = policy_compiler.load_json(path, "overlay") if os.path.isfile(path) else {}
    provs = ov.setdefault("providers", [])
    e = next((x for x in provs if isinstance(x, dict) and x.get("id") == pid), None)
    if e is None:
        e = {"id": pid}
        provs.append(e)
    vv = [v for v in e.get("verified_versions") or [] if v != version] + [version]
    e["verified_versions"] = vv
    if enable:
        e["enabled"] = True
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(ov, f, indent=2)
        f.write("\n")
    try:
        policy_compiler.merged_with_overlay(policy_compiler.load_inputs(plugin_root), tmp)
    except policy_compiler.PolicyError as err:
        os.remove(tmp)
        raise Refuse(EXIT_REFUSED, "the overlay would be invalid, not recorded: %s" % "; ".join(err.errors))
    os.replace(tmp, path)
    ev = os.path.join(os.path.dirname(os.path.abspath(path)), "smoke", "%s-%s.json" % (pid, version))
    os.makedirs(os.path.dirname(ev), exist_ok=True)
    write_json(ev, evidence)
    return path, ev


def cmd_smoke(pid, plugin_root, state_base, repo_root, argv):
    flags = {"--record", "--enable", "--keep"}
    a = opts([x for x in argv if x not in flags], {"--timeout-sec", "--attempts"})
    for f in flags:
        a[f[2:]] = f in argv
    if a["enable"] and not a["record"]:
        raise Refuse(EXIT_USAGE, "--enable needs --record (a provider is enabled only with its smoke recorded)")
    if not re.fullmatch(r"[0-9]{1,4}", a.get("timeout_sec") or "600") or not re.fullmatch(r"[0-9]", a.get("attempts") or "2"):
        raise Refuse(EXIT_USAGE, "--timeout-sec 1..3600, --attempts 1..5")
    secs, attempts = int(a.get("timeout_sec") or 600), int(a.get("attempts") or 2)
    if not (0 < secs <= 3600 and 0 < attempts <= 5):
        raise Refuse(EXIT_USAGE, "--timeout-sec 1..3600, --attempts 1..5")
    for t in ("git", "timeout"):
        if not shutil.which(t):
            raise Refuse(EXIT_UNAVAILABLE, "%s is required" % t)
    if state_base and os.path.isdir(os.path.join(state_base, "ACTIVE")):
        ctx = hooks.Ctx("smoke", plugin_root, state_base, None, repo_root)
        if ctx.owner_ok and not ctx.stale():
            raise Refuse(EXIT_REFUSED, "a run holds the ACTIVE lock in this repository: the provider smoke runs a real "
                                       "provider CLI outside the shims, so run it between runs, as a human")
    import compile as policy_compiler
    try:
        policy = policy_compiler.runtime_policy(plugin_root)
    except policy_compiler.PolicyError as e:
        raise Refuse(EXIT_REFUSED, "the merged policy is invalid: %s" % "; ".join(e.errors))
    p = {x.get("id"): x for x in policy.get("providers", []) if isinstance(x, dict)}.get(pid)
    if not p:
        raise Refuse(EXIT_USAGE, "provider %s is not in the policy (%s)" % (pid, ", ".join(
            x.get("id") for x in policy.get("providers", []) if x.get("kind") == "subprocess")))
    if p.get("kind") != "subprocess" or pid not in BUILDERS:
        raise Refuse(EXIT_USAGE, "provider %s is %s: there is nothing to smoke" % (pid, p.get("kind")))
    binary = ledger.provider_binary(p, plugin_root)
    if not binary:
        raise Refuse(EXIT_UNAVAILABLE, "provider %s's binary %s is not available" % (pid, p.get("binary")))
    rc, vout = 0, ""
    try:
        r = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=30)
        rc, vout = r.returncode, (r.stdout or "") + (r.stderr or "")
    except (OSError, subprocess.SubprocessError) as e:
        rc, vout = 1, str(e)
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", vout) if rc == 0 else None
    version = ".".join(m.groups()) if m else None
    write_roles = [x for x in ("docs", "tester", "builder") if x in (p.get("roles_allowed") or [])]
    read_roles = [x for x in ("reviewer", "diagnoser") if x in (p.get("roles_allowed") or [])]
    role = (write_roles or read_roles or [None])[0]
    if role is None:
        raise Refuse(EXIT_USAGE, "provider %s takes no role the smoke can exercise" % pid)
    mode = "write" if role in WRITE_ROLES else "readonly"
    checks = [{"id": "version", "ok": bool(version), "detail": "%s --version: %s" % (binary, (vout.strip().splitlines() or ["no output"])[0][:120])}]
    try:
        fr = subprocess.run([binary] + list(p.get("forced_flags") or []) + ["--help"], capture_output=True, text=True, timeout=30)
        fout = (fr.stdout or "") + (fr.stderr or "")
        bad = re.search(r"unexpected argument|unknown option|unrecognized option|unknown flag|invalid option", fout, re.I)
        checks.append({"id": "flags", "ok": fr.returncode == 0 and not bad,
                       "detail": "forced flags %s with --help: exit %d%s" % (" ".join(p.get("forced_flags") or []), fr.returncode,
                                                                             (": " + bad.group(0)) if bad else "")})
    except (OSError, subprocess.SubprocessError) as e:
        checks.append({"id": "flags", "ok": False, "detail": "forced-flag probe failed: %s" % e})
    for c in checks:
        print("SMOKE_CHECK: %-19s %-4s %s" % (c["id"], "ok" if c["ok"] else "FAIL", c["detail"]))
    import tempfile
    base = tempfile.mkdtemp(prefix="apex-provider-smoke-%s-" % pid)
    runs = []
    try:
        if all(c["ok"] for c in checks):
            ctx = SmokeCtx(plugin_root, policy, SMOKE_OWNED)
            for n in range(1, attempts + 1):
                got, info = smoke_once(ctx, pid, p, binary, role, mode, base, n, secs)
                info["checks"] = got
                runs.append(info)
                for c in got:
                    print("SMOKE_CHECK: attempt %d %-9s %-4s %s" % (n, c["id"], "ok" if c["ok"] else "FAIL", c["detail"]))
                if all(c["ok"] for c in got):
                    break
                if any(c["id"] == "run" and "(timed out)" in c["detail"] for c in got):
                    break                                   # a timeout will not improve on a retry
    finally:
        if not a["keep"]:
            shutil.rmtree(base, ignore_errors=True)
    passed = all(c["ok"] for c in checks) and bool(runs) and all(c["ok"] for c in runs[-1]["checks"])
    evidence = {"schema": 1, "provider": pid, "version": version, "binary": binary, "role": role, "mode": mode,
                "model": runs[-1]["model"] if runs else None, "passed": passed, "at": now_ts(),
                "checks": checks, "runs": [{k: v for k, v in r.items() if k != "out"} for r in runs],
                "forced_flags": p.get("forced_flags"), "plugin_version": (ledger.read_json(os.path.join(
                    plugin_root, ".claude-plugin", "plugin.json"), {}) or {}).get("version")}
    print("SMOKE_PROVIDER: %s" % pid)
    print("SMOKE_VERSION: %s" % (version or "unknown"))
    print("SMOKE_ROLE: %s (%s)" % (role, mode))
    if a["keep"]:
        print("SMOKE_DIR: %s" % base)
    if not passed:
        print("SMOKE_STATUS: FAIL")
        return EXIT_FAILED
    print("SMOKE_STATUS: PASS")
    if a["record"]:
        path, ev = record_attestation(plugin_root, repo_root, pid, version, a["enable"], evidence)
        print("SMOKE_RECORDED: %s verified_versions += %s%s" % (path, version, "; enabled: true" if a["enable"] else ""))
        print("SMOKE_EVIDENCE: %s" % ev)
        print("SMOKE_NEXT: re-run doctor.sh so doctor.json sees the attested version")
    else:
        print("SMOKE_NEXT: re-run with --record (and --enable) to attest %s %s in this repository's overlay" % (pid, version))
    return EXIT_OK


def main(argv):
    try:
        if len(argv) >= 7 and argv[1] == "run" and argv[7:8] == ["--"]:
            return cmd_run(argv[2], argv[3], argv[4], argv[5], argv[6], argv[8:])
        if len(argv) >= 6 and argv[1] == "apply" and argv[6:7] == ["--"]:
            return cmd_apply(argv[2], argv[3], argv[4], argv[5], argv[7:])
        if len(argv) >= 6 and argv[1] == "smoke" and argv[6:7] == ["--"]:
            return cmd_smoke(argv[2], argv[3], argv[4], argv[5], argv[7:])
        print("usage: worker.py run PROVIDER ROOT STATE_BASE EXEC REPO -- ARGS | worker.py apply ROOT STATE_BASE EXEC REPO -- ARGS"
              " | worker.py smoke PROVIDER ROOT STATE_BASE REPO -- ARGS", file=sys.stderr)
        return EXIT_USAGE
    except Refuse as r:
        word = {EXIT_USAGE: "usage", EXIT_UNAVAILABLE: "unavailable", EXIT_NOT_IMPLEMENTED: "not-implemented"}.get(r.code, "refused")
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
