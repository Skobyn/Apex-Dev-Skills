#!/usr/bin/env python3
"""apex-dispatch PreToolUse hook engine (python3 stdlib only), spec §5.3 D/E/F.

Called by hooks/pre-{agent,bash,edit,mcp}.sh through scripts/lib/hook-common.bash
only when the run's ACTIVE lock exists (the bash prelude no-ops otherwise, without
starting python). Reads the PreToolUse payload on stdin and prints exactly one JSON
object: {} (no opinion) or a PreToolUse hookSpecificOutput with
permissionDecision deny (or allow + updatedInput for the Agent model fill).

  hooks.py KIND PLUGIN_ROOT STATE_BASE EXEC_SCRIPTS REPO_ROOT   (KIND: agent|bash|edit|mcp)

Fail open: unparseable stdin or an internal error prints {} with a stderr
advisory and a hook_error ledger row when the run's ledger is writable.

Trust model (ADR-0001 "Hook contract"): agents are not malicious. The Bash rules
match the command *string* (tokenised with shlex, nested `bash -c`/`eval`/`$(...)`
strings parsed recursively); they stop accidents and realistic misuse, not a
determined adversary (a script written to disk and executed, python -c, variable
indirection and encodings are invisible to them).
"""
import sys

sys.dont_write_bytecode = True

import datetime  # noqa: E402
import fcntl  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import shlex  # noqa: E402
import subprocess  # noqa: E402
import time  # noqa: E402

T0 = time.monotonic()
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ledger  # noqa: E402  (the single ledger writer)

MODELS = ("sonnet", "opus", "haiku", "fable")           # Agent `model` enum (spec §5.3 E)
REVIEWER_ROLES = {"reviewer", "adversarial-reviewer", "reviewer-exec"}
OWN_PREFIXES = ("apex-dispatch:", "apex-scope-loop:")
EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
LOCKED_STAGES = {"GATE", "REVIEW"}
GATE_OK = {"PASS", "SKIPPED"}                           # what checkpoint.sh complete accepts

# Tamper hardening (spec §5.3 E): environment that changes what the harness
# enforces. value None = any assignment or unset is denied; otherwise the
# predicate says which assigned values are denied.
TAMPER_ENV = {
    "APEX_GIBSON": lambda v: v == "0",                   # turns the Gibson harness off
    "APEX_HALT": lambda v: v != "1",                     # setting the kill switch is fine
    "APEX_DISPATCH_MODE": None,
    "APEX_DISPATCH_ENFORCE": None,
    "APEX_DISPATCH_POLICY": None,
    "APEX_FORCE_UNLOCK": None,
    "APEX_STATE_ROOT": None,
    "APEX_SCOPE_LOOP_ROOT": None,
    "APEX_DISPATCH_ROOT": None,
    "APEX_REVIEW_CAP": None,
    "APEX_ERROR_BUDGET": None,
    "APEX_ESCALATE_AFTER": None,
}
# Layer A bypass families: denied anywhere in a command.
BYPASS_PREFIXES = ("--dangerously-", "--yolo", "--always-approve", "--full-auto")
BYPASS_SUBSTRINGS = ("danger-full-access",)
PROVIDER_BINS = {"claude", "codex", "grok", "opencode", "aider"}
PROVIDER_PACKAGES = re.compile(r"(^|/|@)(claude-code|codex|grok|opencode(-ai)?|aider(-chat)?)(@|$)")
INFO_ARGS = {"--version", "-V", "-v", "--help", "-h", "version", "help"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "fish"}
WRAPPERS = {"sudo", "doas", "command", "builtin", "exec", "nohup", "time", "nice", "ionice", "stdbuf", "chronic", "unbuffer"}
ASSIGN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)

# git: subcommands that never change the repository or the worktree.
GIT_READ = {"status", "diff", "log", "show", "rev-parse", "ls-files", "ls-tree", "blame", "grep", "cat-file",
            "merge-base", "describe", "shortlog", "for-each-ref", "show-ref", "rev-list", "name-rev",
            "check-ignore", "check-attr", "check-ref-format", "count-objects", "fsck", "verify-commit",
            "verify-tag", "var", "version", "help", "whatchanged", "range-diff", "diff-tree", "diff-index",
            "diff-files", "show-branch", "cherry", "fetch", "ls-remote", "annotate", "hash-object"}
GIT_CFG_KEYS = re.compile(r"^(core|filter|diff|merge|include|includeif)\.", re.I)
GIT_CFG_HARMLESS = re.compile(r"^core\.(editor|pager)=", re.I)       # cosmetic; cannot hide or alter content
LEDGER_CODE = re.compile(r"(^|[;\n])\s*(import\s+[\w., ]*\bledger\b|from\s+ledger\s+import\b)|\bledger\.append\s*\("
                         r"|apex-dispatch/scripts/lib/ledger\.py\b")
LEDGER_PATH = re.compile(r"(^|/)apex-dispatch/scripts/lib/ledger\.py$")
# Shell reserved words that can lead a simple command; peeled like wrappers.
RESERVED = {"if", "then", "else", "elif", "fi", "do", "done", "while", "until", "esac", "!", "{", "}", "time"}
# Commands that print or search text: a bypass flag in their arguments is data, not a flag.
TEXT_TOOLS = {"echo", "printf", "grep", "egrep", "fgrep", "rg", "ag", "git", "sed", "awk", "cat", "head", "tail",
              "less", "wc", "jq", "cut", "sort"}
UPDATE_INDEX_HIDING = {"--assume-unchanged", "--skip-worktree", "--fsmonitor-valid"}

# Write-shaped commands (spec §5.3 D/E) and where their targets are.
WRITE_ALL = {"rm", "rmdir", "unlink", "shred", "touch", "mkdir", "truncate", "tee", "mv"}
WRITE_SKIP_FIRST = {"chmod", "chown", "chgrp"}
WRITE_DEST = {"cp", "install", "ln", "rsync"}
OUT_REDIRS = {">", ">>", ">|", "&>", "&>>", "<>", ">&"}
OPS = sorted([">>", "&>>", "&>", ">|", ">&", "<&", "<<<", "<<", "<>", "&&", "||", "|&", ";;", ">", "<", "|", "&",
              ";", "(", ")", "\n"], key=len, reverse=True)
SEPARATORS = {";", "&&", "||", "|", "&", "|&", ";;", "(", ")", "\n", "{", "}"}
REDIRS = {">", ">>", ">|", "&>", "&>>", "<>", ">&", "<&", "<", "<<", "<<<"}


class Deny(Exception):
    pass


# ---------------------------------------------------------------- context ----

def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def git(repo, *args):
    try:
        out = subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True, timeout=5)
    except Exception:
        return None
    return out.stdout.strip() if out.returncode == 0 else None


def real(p):
    return os.path.realpath(os.path.expanduser(p))


def under(path, root):
    return bool(root) and (path == root or path.startswith(root.rstrip("/") + "/"))


class Ctx:
    def __init__(self, kind, plugin_root, state_base, exec_scripts, repo_root):
        self.kind, self.plugin_root, self.exec_scripts = kind, real(plugin_root), exec_scripts
        self.state_base, self.repo_root = real(state_base), real(repo_root)
        self.scope_loop_root = real(os.path.join(exec_scripts, "..", "..", "..")) if exec_scripts else None
        self.owner = read_json(os.path.join(state_base, "ACTIVE", "owner.json"))
        self.owner_ok = isinstance(self.owner, dict) and bool(self.owner)
        o = self.owner if self.owner_ok else {}
        self.stage = str(o.get("stage") or "")
        oid = str(o.get("id") or "")
        self.state_dir = None
        if re.fullmatch(r"[0-9a-f]{12}", oid):
            self.state_dir = os.path.join(state_base, "adhoc", oid) if o.get("kind") == "adhoc" else os.path.join(state_base, oid)
        self.checkpoint = read_json(os.path.join(self.state_dir, "checkpoint.json"), {}) if self.state_dir else {}
        if not isinstance(self.checkpoint, dict):
            self.checkpoint = {}
        self._policy = self._route = self._worktree = None
        wt = self.checkpoint.get("worktree_path")
        self.state_worktree = real(wt) if isinstance(wt, str) and wt and os.path.isdir(wt) else None
        self.notes = []

    def stale(self):
        """An owner whose stage is DONE or whose plan landed is reclaimable: no run."""
        return self.owner_ok and (self.stage == "DONE" or bool(self.checkpoint.get("landed")))

    @property
    def worktree(self):
        if self._worktree is None:
            wt = self.checkpoint.get("worktree_path")
            if isinstance(wt, str) and os.path.isdir(wt):
                self._worktree = real(wt)
            else:
                plan = (self.owner or {}).get("plan") if self.owner_ok else None
                top = git(os.path.dirname(plan), "rev-parse", "--show-toplevel") if isinstance(plan, str) and os.path.isfile(plan) else None
                self._worktree = real(top) if top else self.repo_root
        return self._worktree

    @property
    def policy(self):
        if self._policy is None:
            import compile as policy_compiler  # scripts/lib/compile.py, not the builtin
            try:
                self._policy = policy_compiler.runtime_policy(self.plugin_root)
            except Exception as e:  # an invalid overlay: fall back to the committed default
                self.advise("overlay-merged policy unavailable (%s); using resources/compiled/policy.json" % str(e).split("\n")[0])
                self._policy = read_json(os.path.join(self.plugin_root, "resources", "compiled", "policy.json"), {}) or {}
        return self._policy

    def roles(self):
        return {r["id"]: r for r in self.policy.get("roles", []) if isinstance(r, dict) and "id" in r}

    @property
    def route(self):
        """The active route record when it belongs to the ACTIVE task, else {}."""
        if self._route is None:
            self._route = {}
            if self.state_dir:
                rec = read_json(os.path.join(ledger.dispatch_dir(self.state_dir), "active-route.json"), {}) or {}
                o = self.owner
                if o.get("kind") == "adhoc":
                    ok = rec.get("adhoc_id") == o.get("id")
                else:
                    ok = rec.get("plan_hash") == o.get("id") and str(rec.get("line")) == str(o.get("line_no"))
                if rec and ok and rec.get("status") == "READY":
                    self._route = rec
        return self._route

    def enforcing_route(self):
        return bool(self.route) and self.route.get("route_mode") not in ("baseline", "shadow")

    def advise(self, msg):
        print("apex-dispatch %s: %s" % (self.kind, msg), file=sys.stderr)

    def ledger_row(self, event, data, route_id=None):
        if not self.state_dir or not os.path.isdir(self.state_dir):
            return None
        data = dict(data)
        data["hook_ms"] = int((time.monotonic() - T0) * 1000)
        try:
            return ledger.append(self.state_dir, event, data, "hook", route_id=route_id or self.route.get("route_id"),
                                 route_mode=self.route.get("route_mode"))
        except Exception as e:
            self.advise("ledger row %s not written: %s" % (event, e))
            return None


def role_of(agent_type):
    """apex-dispatch:<role> (or apex-scope-loop:<role>) -> role, else None."""
    if isinstance(agent_type, str):
        for p in OWN_PREFIXES:
            if agent_type.startswith(p):
                return agent_type[len(p):]
    return None


def caller_role(payload):
    """The role of the agent making this tool call (Phase 0 spike 5): agent_id
    present = inside a subagent; agent_type without agent_id = a worker session
    running as that role (claude -p --agent). Never inferred otherwise."""
    return role_of(payload.get("agent_type"))


def deny(reason):
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                   "permissionDecisionReason": "apex-dispatch: " + reason}}


def halt_reason(ctx):
    if os.environ.get("APEX_HALT", "0") == "1":
        return "APEX_HALT=1"
    files = [os.path.join(ctx.repo_root, ".dev-plan-state", "HALT"), os.path.join(ctx.state_base, "HALT"),
             os.path.join(ctx.repo_root, "gibson", "HALT")]
    if ctx.state_dir:
        files.append(os.path.join(ctx.state_dir, "HALT"))
    for f in files:
        if os.path.isfile(f):
            return "kill switch file present: " + f
    if ctx.checkpoint.get("halted"):
        return "checkpoint halted: %s" % ctx.checkpoint.get("halt_reason", "")
    return None


# ---------------------------------------------------------- protected paths ----

def protected_reason(ctx, path, removal=True):
    """Why `path` (absolute, normalised) may not be written by anyone during a run.
    removal=False: the write cannot delete or move `path` itself (a cp/mv/ln/rsync
    destination, a patch/chmod/touch target, a find -delete start), so the plan
    worktree's own root is fair game; removing or moving the root never is."""
    comps = path.split("/")
    wt = ctx.state_worktree
    if wt and under(path, wt) and (path != wt or not removal):
        # apex-scope-loop puts the plan worktree inside the run state
        # (<state>/worktree): its tree is the work, not run state; only a
        # .dev-plan-state nested inside it is.
        if ".dev-plan-state" in os.path.relpath(path, wt).split("/"):
            return "run state (.dev-plan-state/) is written only by the apex-scope-loop and apex-dispatch scripts"
    elif ".dev-plan-state" in comps or under(path, ctx.state_base):
        return "run state (.dev-plan-state/) is written only by the apex-scope-loop and apex-dispatch scripts"
    if ".git" in comps:
        return "git internals (.git/: config, info/, hooks/, index) are not written during a run"
    if re.search(r"(^|/)\.claude/apex-dispatch(/|$)", path):
        return ".claude/apex-dispatch/ (policy overlay, tracked ledger) is not written during a run"
    if re.search(r"(^|/)\.claude/settings[^/]*\.json$", path):
        return ".claude/settings*.json is not written during a run"
    if re.search(r"(^|/)\.claude/hooks(/|$)", path):
        return "hook registrations are not written during a run"
    if os.path.basename(path) == ".mcp.json":
        return ".mcp.json is not written during a run"
    if os.path.basename(path) == ".gitconfig" or re.search(r"(^|/)\.config/git(/|$)", path) or path == "/etc/gitconfig":
        return "git configuration files are not written during a run"
    for root, what in ((ctx.plugin_root, "apex-dispatch"), (ctx.scope_loop_root, "apex-scope-loop")):
        if root and under(path, root):
            return "the installed %s plugin (its hooks and scripts) is not written during a run" % what
    return None


def tmp_path(path):
    roots = ["/tmp", "/var/tmp", "/dev"]
    if os.environ.get("TMPDIR"):
        roots.append(real(os.environ["TMPDIR"]))
    return any(under(path, r) or under(path, real(r)) for r in roots)


def in_checkout(ctx, path):
    """Inside the plan worktree or the repository's base checkout."""
    roots = {ctx.worktree, ctx.repo_root}
    if os.path.basename(ctx.state_base) == ".dev-plan-state":
        roots.add(os.path.dirname(ctx.state_base))
    return any(under(path, r) for r in roots if r)


# ------------------------------------------------------------- pre-agent ----

def spawns_for(ctx, route_id):
    n = 0
    for row in ledger.read_rows(ctx.state_dir):
        if row.get("event") == "spawn_request" and row.get("route_id") == route_id \
                and row.get("role") not in REVIEWER_ROLES:
            n += 1
    return n


def set_stage(ctx, stage):
    """apex_lock stage for the current owner, same flock as _lib.sh."""
    base = ctx.state_base
    try:
        with open(os.path.join(base, ".active.lock"), "a+") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            path = os.path.join(base, "ACTIVE", "owner.json")
            o = read_json(path)
            if not isinstance(o, dict) or o.get("id") != ctx.owner.get("id"):
                return False
            o["stage"] = stage
            o["updated_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            tmp = path + ".tmp"
            with open(tmp, "w") as fh:
                json.dump(o, fh, indent=2)
            os.replace(tmp, path)
            return True
    except OSError as e:
        ctx.advise("could not set stage %s: %s" % (stage, e))
        return False


def route_minutes(rec):
    try:
        ts = datetime.datetime.strptime(rec.get("ts", ""), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        return None
    return (datetime.datetime.now(datetime.timezone.utc) - ts).total_seconds() / 60.0


def pre_agent(ctx, p):
    if p.get("tool_name") not in ("Agent", "Task"):
        return {}
    ti = p.get("tool_input") if isinstance(p.get("tool_input"), dict) else {}
    st = ti.get("subagent_type") or "general-purpose"
    model = ti.get("model")
    if p.get("agent_id") or caller_role(p):
        raise Deny("nested spawn refused: agents spawn at depth 1 only (the orchestrator spawns; %s may not)"
                   % (p.get("agent_type") or "a subagent"))
    h = halt_reason(ctx)
    if h:
        raise Deny("spawns are refused while halted (%s)" % h)
    role = role_of(st) if st.startswith("apex-dispatch:") else None
    is_reviewer = role in REVIEWER_ROLES
    rec = ctx.route
    router = rec.get("router") or {}
    rid = rec.get("route_id")
    eff_model = model
    out = {}
    if ctx.enforcing_route():
        roster = router.get("roster") or []
        if role is None or role not in roster:
            raise Deny("subagent_type %r is not on route %s's roster (%s); spawn only apex-dispatch:<role> for a roster role"
                       % (st, rid, ",".join(roster) or "empty"))
        if is_reviewer:
            gate = read_json(os.path.join(ctx.state_dir, "gate", "last.json"), {}) or {}
            head = git(ctx.worktree, "rev-parse", "HEAD")
            if gate.get("result") not in GATE_OK or not head or gate.get("head_sha") != head:
                raise Deny("reviewer spawns need a green gate bound to HEAD (gate/last.json: result %s at %s; HEAD %s) — run green-gate.sh check"
                           % (gate.get("result") or "none", str(gate.get("head_sha") or "-")[:12], (head or "?")[:12]))
        else:
            if ctx.stage in LOCKED_STAGES:
                raise Deny("builder-side spawns are refused during stage %s (re-route to return to BUILD)" % ctx.stage)
            rmodel = router.get("model")
            if rmodel in MODELS:
                if model is None:
                    eff_model = rmodel
                    new = dict(ti)
                    new["model"] = rmodel
                    out = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow",
                                                  "permissionDecisionReason": "apex-dispatch: model pinned to the route's %s" % rmodel,
                                                  "updatedInput": new}}
                elif model != rmodel:
                    raise Deny("model %r does not match route %s's ROUTE_MODEL %s (deny-on-mismatch; pass model: %s)"
                               % (model, rid, rmodel, rmodel))
            budgets = router.get("budgets") or {}
            cap = budgets.get("spawns")
            if isinstance(cap, int) and spawns_for(ctx, rid) >= cap:
                raise Deny("route %s's spawn budget is spent (%d of %d builder-side spawns); halt and ask, do not continue inline"
                           % (rid, spawns_for(ctx, rid), cap))
            mins = budgets.get("minutes")
            el = route_minutes(rec)
            if isinstance(mins, (int, float)) and el is not None and el > mins:
                raise Deny("route %s's wall-clock budget is spent (%.0f of %s minutes)" % (rid, el, mins))
    elif not rec:
        raise Deny("no READY route for the ACTIVE task (stage %s); run route.sh (or iterate.sh) before spawning"
                   % (ctx.stage or "?"))
    else:
        ctx.notes.append("route_mode %s: roster/model/budget recorded, not enforced" % rec.get("route_mode"))
    ctx.ledger_row("spawn_request", {"role": role or st, "model": eff_model or "inherit", "subagent_type": st,
                                     "tool_use_id": p.get("tool_use_id"), "session_id": p.get("session_id"),
                                     "stage": ctx.stage, "notes": ctx.notes}, route_id=rid)
    if is_reviewer and ctx.enforcing_route() and ctx.stage != "REVIEW":
        set_stage(ctx, "REVIEW")
    return out


# ---------------------------------------------------------------- pre-edit ----

def glob_re(g):
    g = g.strip()
    while g.startswith("./"):
        g = g[2:]
    if g.endswith("/"):
        g += "**"
    out, i = "", 0
    while i < len(g):
        if g.startswith("**/", i):
            out, i = out + "(?:.*/)?", i + 3
        elif g.startswith("**", i):
            out, i = out + ".*", i + 2
        elif g[i] == "*":
            out, i = out + "[^/]*", i + 1
        elif g[i] == "?":
            out, i = out + "[^/]", i + 1
        else:
            out, i = out + re.escape(g[i]), i + 1
    if not any(c in g for c in "*?"):
        out += "(?:/.*)?"                                 # a bare directory owns what is below it
    return re.compile("^" + out + "$")


def lane_globs(ctx):
    router = ctx.route.get("router") or {}
    if not str(router.get("fanout", "")).startswith("lanes"):
        return None
    lanes = [int(x) for x in router.get("lanes") or [] if str(x).isdigit()]
    plan = ctx.owner.get("plan")
    if not lanes or not isinstance(plan, str) or not os.path.isfile(plan) or not ctx.exec_scripts:
        return []
    sys.path.insert(0, ctx.exec_scripts)
    import planlib
    by_line = {t["line_no"]: t for t in planlib.parse(plan)}
    globs = []
    for ln in lanes:
        globs += list((by_line.get(ln) or {}).get("paths") or [])
    return globs


def pre_edit(ctx, p):
    if p.get("tool_name") not in EDIT_TOOLS:
        return {}
    ti = p.get("tool_input") if isinstance(p.get("tool_input"), dict) else {}
    target = ti.get("file_path") or ti.get("notebook_path")
    if not isinstance(target, str) or not target:
        return {}
    cwd = p.get("cwd") if isinstance(p.get("cwd"), str) else os.getcwd()
    path = real(os.path.join(cwd, target))
    why = protected_reason(ctx, path)
    if why:
        raise Deny("%s (%s)" % (why, target))
    if ctx.stage in LOCKED_STAGES:
        raise Deny("writes are refused during stage %s: the gate and the reviewers are bound to HEAD" % ctx.stage)
    role = caller_role(p)
    if role and (ctx.roles().get(role) or {}).get("read_only"):
        raise Deny("role %s is read-only" % role)
    wt = ctx.worktree
    if not under(path, wt):
        if tmp_path(path) and not in_checkout(ctx, path):
            return {}                                     # scratch files outside every checkout
        raise Deny("%s is outside the plan worktree %s" % (target, wt))
    globs = lane_globs(ctx) if ctx.enforcing_route() else None
    if globs is not None:
        rel = os.path.relpath(path, wt)
        if not any(glob_re(g).match(rel) for g in globs):
            raise Deny("%s is outside the lanes' Paths (%s)" % (rel, ", ".join(globs) or "none recorded"))
    return {}


# ----------------------------------------------------------------- pre-mcp ----

def pre_mcp(ctx, p):
    name = p.get("tool_name") or ""
    if not name.startswith("mcp__"):
        return {}
    mcp = ctx.policy.get("mcp") or {}
    if mcp.get("default_deny") is not True:
        return {}
    server = name.split("__")[1] if name.count("__") >= 1 else ""
    allow = list(mcp.get("servers_allow") or [])
    role = caller_role(p)
    if role:
        allow += list((ctx.roles().get(role) or {}).get("mcp_allow") or [])
    for a in allow:
        if a in (server, name, "mcp__" + server) or (a.endswith("*") and name.startswith(a[:-1])):
            return {}
    raise Deny("MCP tool %s is not on the allowlist for %s (mcp.default_deny)" % (name, role or "the orchestrator"))


# ---------------------------------------------------------------- pre-bash ----

def strip_heredocs(cmd):
    out, delim = [], None
    for line in cmd.split("\n"):
        if delim is not None:
            if line.strip() == delim:
                delim = None
            continue
        out.append(line)
        m = re.search(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", line.replace("<<<", "   "))
        if m:
            delim = m.group(2)
    return "\n".join(out)


def split_ops(tok):
    out, i = [], 0
    while i < len(tok):
        for op in OPS:
            if tok.startswith(op, i):
                out.append(op)
                i += len(op)
                break
        else:
            out.append(tok[i])
            i += 1
    return out


def tokens(cmd):
    lex = shlex.shlex(cmd.replace("`", " "), posix=True, punctuation_chars=";&|()<>\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    try:
        raw = list(lex)
    except ValueError:                                   # unbalanced quotes: best effort
        raw = re.findall(r"[^\s;&|()<>]+|[;&|()<>\n]+", cmd)
    out = []
    for t in raw:
        out += split_ops(t) if t and all(c in ";&|()<>\n" for c in t) else [t]
    return out


def segments(cmd):
    """[(words, [(redir_op, target)])] for each simple command."""
    toks, segs, words, redirs, i = tokens(strip_heredocs(cmd)), [], [], [], 0
    while i < len(toks):
        t = toks[i]
        if t in SEPARATORS:
            if words or redirs:
                segs.append((words, redirs))
            words, redirs = [], []
        elif t in REDIRS:
            target = toks[i + 1] if i + 1 < len(toks) and toks[i + 1] not in SEPARATORS | REDIRS else None
            if target is not None:
                i += 1
                if not (t in (">&", "<&") and (target.isdigit() or target == "-")):
                    redirs.append((t, target))
        elif t.isdigit() and i + 1 < len(toks) and toks[i + 1] in REDIRS:
            pass                                          # an fd number (2>file)
        else:
            words.append(t)
        i += 1
    if words or redirs:
        segs.append((words, redirs))
    return segs


def subst_strings(word):
    """Command substitutions inside one word ($(...) and backtick bodies)."""
    found, i = [], 0
    while True:
        j = word.find("$(", i)
        if j < 0:
            break
        depth, k = 0, j + 1
        while k < len(word):
            if word[k] == "(":
                depth += 1
            elif word[k] == ")":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        found.append(word[j + 2:k])
        i = k + 1
    return found


class Cmd:
    """One simple command after env assignments and wrappers are peeled off."""

    def __init__(self, words, redirs):
        self.assigns, self.unsets, self.redirs = {}, set(), redirs
        i, self.listed = 0, []
        while i < len(words):
            t = words[i]
            if t in RESERVED:
                i += 1
                continue
            if t in ("for", "select", "case"):
                self.listed = words[i:]                   # a word list or pattern, not a command
                i = len(words)
                break
            m = ASSIGN_RE.match(t)
            if m:
                self.assigns[m.group(1)] = m.group(2)
                i += 1
                continue
            b = os.path.basename(t)
            if b == "env":
                i += 1
                while i < len(words) and (words[i].startswith("-") or ASSIGN_RE.match(words[i])):
                    w = words[i]
                    if w in ("-u", "--unset") and i + 1 < len(words):
                        self.unsets.add(words[i + 1])
                        i += 2
                        continue
                    if w.startswith("--unset="):
                        self.unsets.add(w.split("=", 1)[1])
                    elif w.startswith("-u") and len(w) > 2:
                        self.unsets.add(w[2:])
                    elif ASSIGN_RE.match(w):
                        mm = ASSIGN_RE.match(w)
                        self.assigns[mm.group(1)] = mm.group(2)
                    i += 1
                continue
            if b in WRAPPERS:
                i += 1
                while i < len(words) and words[i].startswith("-"):
                    i += 2 if words[i] in ("-n", "-u", "-g", "-o", "-i", "-e", "-c") and b in ("nice", "sudo", "stdbuf", "ionice") else 1
                continue
            if b == "timeout":
                i += 1
                while i < len(words) and words[i].startswith("-"):
                    i += 2 if words[i] in ("-s", "-k", "--signal", "--kill-after") else 1
                i += 1                                    # the duration
                continue
            if b == "xargs":
                i += 1
                while i < len(words) and words[i].startswith("-"):
                    i += 2 if words[i] in ("-I", "-n", "-P", "-L", "-d", "-E", "-s", "-a") else 1
                continue
            break
        self.words = words[i:]
        self.base = os.path.basename(self.words[0]) if self.words else ""
        self.args = self.words[1:]
        if self.base in ("export", "declare", "typeset", "readonly", "local"):
            for a in self.args:
                mm = ASSIGN_RE.match(a)
                if mm:
                    self.assigns[mm.group(1)] = mm.group(2)
        if self.base == "unset":
            self.unsets.update(a for a in self.args if not a.startswith("-"))

    def positionals(self):
        return [a for a in self.args if not a.startswith("-") or a == "-"]

    def nested(self):
        """Command strings this command runs: sh -c, eval, find -exec, submodule foreach, $(...)."""
        out = []
        b, a = self.base, self.args
        if b in SHELLS or b == "su":
            for k, w in enumerate(a):
                if re.fullmatch(r"-[a-zA-Z]*c[a-zA-Z]*", w) and k + 1 < len(a):
                    out.append(a[k + 1])
                    break
        elif b == "eval":
            out.append(" ".join(a))
        elif b == "find":
            for k, w in enumerate(a):
                if w in ("-exec", "-execdir", "-ok", "-okdir"):
                    rest = []
                    for x in a[k + 1:]:
                        if x in (";", "+"):
                            break
                        rest.append(shlex.quote(x))
                    out.append(" ".join(rest))
        elif b == "git":
            g = GitCmd(self)
            if g.sub == "submodule" and g.args[:1] == ["foreach"]:
                out.append(" ".join(x for x in g.args[1:] if not x.startswith("--")))
        for w in self.words + self.listed:
            out += subst_strings(w)
        return out

    def target_dirs(self):
        """(values, given) of cp/mv/install/ln -t forms: `-t D`, clusters `-vt D`,
        attached `-tD`/`-vtD`, `--target-directory D`, and abbreviations `--target=D`."""
        a, vals, given = self.args, set(), False
        for k, w in enumerate(a):
            if w.startswith("--"):
                name, eq, val = w.partition("=")
                if len(name) >= 4 and "--target-directory".startswith(name):
                    given = True
                    if eq:
                        vals.add(val)
                    elif k + 1 < len(a):
                        vals.add(a[k + 1])
                continue
            m = re.fullmatch(r"-[A-Za-z]*t(.*)", w)
            if m:
                given = True
                if m.group(1):
                    vals.add(m.group(1))
                elif k + 1 < len(a):
                    vals.add(a[k + 1])
        return vals, given

    def find_parts(self):
        """(start points, deletes): find's start points (after -H/-L/-P/-O/-D) and
        whether it deletes (-delete, or -exec/-ok running rm/rmdir/unlink/shred/mv)."""
        a, i = self.args, 0
        while i < len(a) and (a[i] in ("-H", "-L", "-P") or re.fullmatch(r"-O\d*", a[i]) or a[i] == "-D"):
            i += 2 if a[i] == "-D" else 1
        starts = []
        while i < len(a) and not (a[i].startswith("-") or a[i] in ("(", "!", ")")):
            starts.append(a[i])
            i += 1
        deletes = "-delete" in a or any(w in ("-exec", "-execdir", "-ok", "-okdir") and k + 1 < len(a)
                                        and os.path.basename(a[k + 1]) in ("rm", "rmdir", "unlink", "shred", "mv")
                                        for k, w in enumerate(a))
        return starts or ["."], deletes

    def removal_targets(self):
        """Targets this command deletes or moves away (not merely writes into)."""
        b, pos = self.base, self.positionals()
        if b in ("rm", "rmdir", "unlink", "shred"):
            return set(pos)
        if b == "mv":
            tdir, given = self.target_dirs()
            return set(pos) - tdir if given else set(pos[:-1])
        if b == "find":
            starts, deletes = self.find_parts()
            # `.` (the cwd itself) may be a deletion start: its matches go, not the directory.
            return {x for x in starts if x not in (".", "./")} if deletes else set()
        return set()

    def write_targets(self):
        """(targets, write_shaped) for this command, redirects included."""
        b, a, t = self.base, self.args, []
        shaped = False
        pos = self.positionals()
        if b in WRITE_ALL:
            shaped, t = True, list(pos)
            if b == "mv":
                t += sorted(self.target_dirs()[0] - set(t))
        elif b in WRITE_SKIP_FIRST:
            shaped, t = True, pos[1:]
        elif b in WRITE_DEST:
            shaped = True
            tdir, given = self.target_dirs() if b != "rsync" else (set(), False)
            t = sorted(tdir) if given else pos[-1:]
        elif b == "sed" and any(w == "--in-place" or w.startswith("--in-place=") or re.fullmatch(r"-[a-zA-Z]*i.*", w) for w in a):
            shaped = True
            script_given = any(w in ("-e", "-f", "--expression", "--file") for w in a)
            t = pos if script_given else pos[1:]
        elif b == "perl" and any(re.fullmatch(r"-[a-zA-Z]*i.*", w) and not w.startswith(("-M", "-m")) for w in a):
            shaped = True
            skip = {a[k + 1] for k, w in enumerate(a) if re.fullmatch(r"-[a-zA-Z]*[eE]", w) and k + 1 < len(a)}
            t = [x for x in pos if x not in skip]
        elif b == "dd":
            t = [w[3:] for w in a if w.startswith("of=")]
            shaped = bool(t)
        elif b == "patch":
            shaped, t = True, (pos or ["."])
        elif b == "find" and self.find_parts()[1]:
            shaped, t = True, self.find_parts()[0]
        for op, target in self.redirs:
            if op in OUT_REDIRS:
                shaped = True
                t.append(target)
        return t, shaped


class GitCmd:
    def __init__(self, cmd):
        w, i = cmd.args, 0
        self.cfg = []
        while i < len(w) and w[i].startswith("-"):
            x = w[i]
            if x in ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix", "--attr-source") \
                    and i + 1 < len(w):
                if x in ("-c", "--config-env"):
                    self.cfg.append(w[i + 1])
                i += 2
                continue
            if x.startswith("--config-env="):
                self.cfg.append(x.split("=", 1)[1])
            elif x.startswith("-c") and len(x) > 2:
                self.cfg.append(x[2:])
            i += 1
        self.sub = w[i] if i < len(w) else None
        self.args = w[i + 1:]
        self.env = cmd.assigns

    def pos(self, valued=()):
        out, skip = [], False
        for x in self.args:
            if skip:
                skip = False
                continue
            if x in valued:
                skip = True
                continue
            if x.startswith("-"):
                continue
            out.append(x)
        return out

    def config_write(self):
        if self.sub != "config":
            return False
        a = self.args
        first = self.pos(("--file", "-f", "--blob", "--type", "--default", "--comment", "-t"))
        if first and first[0] in ("get", "list"):
            return False
        if first and first[0] in ("set", "unset", "rename-section", "remove-section", "edit", "replace-all"):
            return True
        if any(x in ("--unset", "--unset-all", "--add", "--replace-all", "--rename-section", "--remove-section",
                     "-e", "--edit") for x in a):
            return True
        if any(x in ("-l", "--list") or x.startswith("--get") for x in a):
            return False
        return len(first) >= 2

    def mutating(self):
        s, a = self.sub, self.args
        if s is None or s in GIT_READ:
            return False
        pos = self.pos()
        if s == "config":
            return self.config_write()
        if s == "stash":
            return not (pos[:1] in (["list"], ["show"]))
        if s == "branch":
            if any(x in a for x in ("-d", "-D", "--delete", "-m", "-M", "--move", "-c", "-C", "--copy", "-u",
                                    "--set-upstream-to", "--unset-upstream", "--edit-description", "-f", "--force")) \
                    or any(x.startswith("--set-upstream-to=") for x in a):
                return True
            if any(x in a for x in ("-l", "--list", "--show-current")):
                return False
            return bool(self.pos(("--contains", "--no-contains", "--merged", "--no-merged", "--points-at",
                                  "--format", "--sort", "--color", "--column")))
        if s == "tag":
            if any(x in a for x in ("-d", "--delete", "-a", "--annotate", "-s", "--sign", "-f", "--force",
                                    "-m", "--message", "-F", "--file", "-u")):
                return True
            if any(x in a for x in ("-l", "--list", "-v", "--verify")):
                return False
            return bool(self.pos(("--contains", "--no-contains", "--merged", "--no-merged", "--points-at",
                                  "--format", "--sort", "--color", "--column", "-n")))
        if s == "worktree":
            return pos[:1] != ["list"]
        if s == "notes":
            return not (pos[:1] in (["list"], ["show"]) or not pos)
        if s == "submodule":
            return not (not pos or pos[0] in ("status", "summary", "foreach"))
        if s == "remote":
            return not (not pos or pos[0] in ("show", "get-url"))
        if s == "reflog":
            return bool(pos) and pos[0] in ("expire", "delete")
        if s == "bisect":
            return not (pos[:1] in (["log"], ["visualize"], ["view"]))
        if s == "sparse-checkout":
            return pos[:1] != ["list"]
        if s == "apply":
            return not any(x in a for x in ("--check", "--stat", "--numstat", "--summary")) or "--apply" in a
        if s == "symbolic-ref":
            return len(pos) >= 2 or "-d" in a or "--delete" in a
        return True                                        # unknown subcommands and aliases: assume it writes


def resolve_target(ctx, cwd, prefix, t):
    t = os.path.expanduser(t)
    base = os.path.join(cwd, prefix) if prefix else cwd
    return os.path.normpath(os.path.join(base, t))


def bash_rules(ctx, p, cmd, depth=0, prefix=""):
    """Raise Deny on the first rule a command string breaks. Recurses into nested command strings."""
    if depth > 4:
        return
    for inner in re.findall(r"`([^`]*)`", cmd):          # backtick bodies, quoted or not
        bash_rules(ctx, p, inner, depth + 1, prefix)
    cmd = re.sub(r"`[^`]*`", " ", cmd)
    cwd = p.get("cwd") if isinstance(p.get("cwd"), str) else os.getcwd()
    role = caller_role(p)
    read_only = bool(role and (ctx.roles().get(role) or {}).get("read_only"))
    providers = {x.get("id"): x for x in ctx.policy.get("providers", []) if isinstance(x, dict)}
    bins = PROVIDER_BINS | {x.get("binary") for x in providers.values() if x.get("binary")}
    for words, redirs in segments(cmd):
        c = Cmd(words, redirs)
        # 1. Tamper hardening: the harness's own switches.
        for name, val in c.assigns.items():
            if name in TAMPER_ENV and (TAMPER_ENV[name] is None or TAMPER_ENV[name](val)):
                raise Deny("%s=%s would change what the harness enforces; it is set by the human, never by a command during a run" % (name, val))
            if name.startswith("GIT_CONFIG") and (c.base in ("export", "declare", "typeset") or (c.base == "git" and GitCmd(c).mutating())):
                raise Deny("%s overrides git configuration for a mutating git command" % name)
        for name in c.unsets:
            if name in TAMPER_ENV:
                raise Deny("unsetting %s would change what the harness enforces" % name)
        # 2. Layer A bypass flags, anywhere.
        for w in ([] if c.base in TEXT_TOOLS else c.words):
            if w.startswith(BYPASS_PREFIXES) or any(re.search(r"(^|[=\s])" + re.escape(s) + r"\b", w) for s in BYPASS_SUBSTRINGS):
                raise Deny("bypass flag %s is forbidden" % w)
        # 3. Provider CLIs only through bin/worker-*.sh.
        b = c.base
        if re.fullmatch(r"worker-[a-z0-9-]+\.sh", b) or (b in SHELLS and c.args and re.search(r"/bin/worker-[a-z0-9-]+\.sh$", c.args[0])):
            shim = b if b.startswith("worker-") else os.path.basename(c.args[0])
            if role and role != "provider-runner":
                raise Deny("provider shims run only from the orchestrator or provider-runner, not %s" % role)
            prov = providers.get(shim[len("worker-"):-3]) or {}
            for f in prov.get("forbidden_flags") or []:
                if f in c.args or any(a.startswith(f + "=") for a in c.args):
                    raise Deny("flag %s is forbidden for provider %s" % (f, prov.get("id")))
        elif b in bins or (b in ("npx", "bunx", "pnpx", "uvx", "pipx", "pnpm", "yarn") and any(PROVIDER_PACKAGES.search(a) for a in c.args[:3])):
            info = c.args and all(a in INFO_ARGS or a == "plugin" or a == "validate" for a in c.args)
            if b == "claude":
                if any(a in ("-p", "--print") or re.fullmatch(r"-[a-zA-Z]*p[a-zA-Z]*", a) for a in c.args):
                    raise Deny("`claude -p` runs only through bin/worker-claude-p.sh (forced flags, budget, ledger)")
            elif not info:
                raise Deny("provider CLI %s runs only through bin/worker-*.sh (forced flags, sandbox probe, ledger)" % b)
        # 4. The ledger has one sanctioned writer interface.
        ledger_py = real(os.path.join(ctx.plugin_root, "scripts", "lib", "ledger.py"))
        if re.fullmatch(r"python[0-9.]*", b) and (any(os.path.basename(a) == "ledger.py" and (
                                                        real(resolve_target(ctx, cwd, prefix, a)) == ledger_py
                                                        or LEDGER_PATH.search(real(resolve_target(ctx, cwd, prefix, a))))
                                                    for a in c.args)
                                                    or any(LEDGER_CODE.search(a) for a in c.args)
                                                    or ("-m" in c.args and "ledger" in c.args)):
            raise Deny("the ledger is written only in-process by route.py, the hooks and the shims (use ledger.sh)")
        # 5. Git configuration and repository internals the clean-worktree check trusts.
        if b == "git":
            g = GitCmd(c)
            if g.config_write():
                raise Deny("`git config` writes are refused during a run (the gate and land trust local git configuration; reads like --get/--list are fine)")
            if g.sub == "update-index" and any(a in UPDATE_INDEX_HIDING for a in g.args):
                raise Deny("git update-index %s hides edits from status; refused during a run" % " ".join(a for a in g.args if a in UPDATE_INDEX_HIDING))
            if g.sub == "worktree" and g.pos()[:1] in (["remove"], ["move"]) and len(g.pos()) >= 2:
                target = real(resolve_target(ctx, cwd, prefix, g.pos()[1]))
                if target in {w for w in (ctx.state_worktree, ctx.worktree) if w}:
                    raise Deny("git worktree %s of the plan worktree is refused during a run (land.sh removes it)" % g.pos()[0])
            if g.sub == "sparse-checkout" and g.mutating():
                raise Deny("git sparse-checkout changes skip-worktree flags; refused during a run")
            if g.mutating():
                bad = [x for x in g.cfg if GIT_CFG_KEYS.match(x) and not GIT_CFG_HARMLESS.match(x)]
                if bad:
                    raise Deny("git -c %s on a mutating command overrides core/filter/diff/merge configuration" % bad[0])
                if ctx.stage in LOCKED_STAGES:
                    raise Deny("git %s is refused during stage %s (the gate and reviewers are bound to HEAD)" % (g.sub, ctx.stage))
                if read_only:
                    raise Deny("role %s is read-only: git %s refused" % (role, g.sub))
        # 6. Write-shaped commands: protected paths always; the checkout during GATE/REVIEW or for read-only roles.
        targets, shaped = c.write_targets()
        removals = c.removal_targets()
        # A recursive delete rooted at a worktree's top would take its `.git` link file.
        roots = {w for w in (ctx.state_worktree, ctx.worktree) if w}
        if b == "find" and c.find_parts()[1] and not any(
                w in ("-name", "-iname", "-path", "-ipath", "-wholename", "-iwholename", "-regex", "-iregex") for w in c.args):
            if any(real(resolve_target(ctx, cwd, prefix, x)) in roots for x in c.find_parts()[0]):
                raise Deny("find -delete at the worktree root without a -name/-path filter would delete its .git link")
        if b == "rsync" and any(w.startswith("--delete") or w == "--remove-source-files" for w in c.args) and c.positionals():
            dest = real(resolve_target(ctx, cwd, prefix, c.positionals()[-1]))
            if dest in roots and not any(".git" in w for w in c.args):
                raise Deny("rsync --delete into the worktree root would delete its .git link (add --exclude=.git)")
        for t in targets:
            if t in ("-",):
                continue
            path = resolve_target(ctx, cwd, prefix, t)
            if b == "touch" and os.path.basename(path) == "HALT":
                continue                                  # setting a kill switch only tightens
            why = protected_reason(ctx, real(path), removal=t in removals)
            if why:
                raise Deny("%s (%s %s)" % (why, b or "redirect", t))
            if (ctx.stage in LOCKED_STAGES or read_only) and not path.startswith("/dev/"):
                if "$" in t or "`" in t or in_checkout(ctx, real(path)):
                    raise Deny("write to %s refused %s" % (t, "during stage " + ctx.stage if ctx.stage in LOCKED_STAGES else "for read-only role " + role))
        # Nested command strings, then cd tracking for later segments.
        for inner in c.nested():
            bash_rules(ctx, p, inner, depth + 1, prefix)
        if b in ("cd", "pushd") and c.positionals():
            prefix = os.path.join(prefix, os.path.expanduser(c.positionals()[0]))


def pre_bash(ctx, p):
    if p.get("tool_name") != "Bash":
        return {}
    ti = p.get("tool_input") if isinstance(p.get("tool_input"), dict) else {}
    cmd = ti.get("command")
    if not isinstance(cmd, str) or not cmd.strip():
        return {}
    bash_rules(ctx, p, cmd)
    return {}


HANDLERS = {"agent": pre_agent, "bash": pre_bash, "edit": pre_edit, "mcp": pre_mcp}


def main(argv):
    if len(argv) < 6 or argv[1] not in HANDLERS:
        print("{}")
        print("usage: hooks.py agent|bash|edit|mcp PLUGIN_ROOT STATE_BASE EXEC_SCRIPTS REPO_ROOT", file=sys.stderr)
        return 0
    ctx = Ctx(argv[1], argv[2], argv[3], argv[4], argv[5])
    hook = "pre-%s.sh" % argv[1]
    if not ctx.owner_ok and ctx.owner is not None:
        ctx.advise("ACTIVE/owner.json is unreadable; applying the run-independent rules only")
    if ctx.stale():
        print("{}")
        return 0
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            raise ValueError("payload is not a JSON object")
    except ValueError as e:
        ctx.advise("unparseable stdin, failing open: %s" % e)
        ctx.ledger_row("hook_error", {"hook": hook, "error": "unparseable stdin: %s" % e})
        print("{}")
        return 0
    try:
        out = HANDLERS[argv[1]](ctx, payload)
    except Deny as d:
        reason = str(d)
        ctx.ledger_row("hook_advisory", {"hook": hook, "advisory": "denied: " + reason,
                                         "tool_use_id": payload.get("tool_use_id")})
        out = deny(reason)
    except Exception as e:  # fail open, loudly
        ctx.advise("internal error, failing open: %s: %s" % (type(e).__name__, e))
        ctx.ledger_row("hook_error", {"hook": hook, "error": "%s: %s" % (type(e).__name__, e)})
        out = {}
    print(json.dumps(out, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
