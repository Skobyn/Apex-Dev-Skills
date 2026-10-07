#!/usr/bin/env python3
"""apex-dispatch hook engine (python3 stdlib only), spec §5.1, §5.3 D/E/F/H/J.

Called by every hooks/*.sh through scripts/lib/hook-common.bash only when the
run's ACTIVE lock exists (the bash prelude no-ops otherwise, without starting
python). Reads the hook payload on stdin and prints exactly one JSON object:
{} (no opinion), a PreToolUse hookSpecificOutput with permissionDecision deny
(or allow + updatedInput for the Agent model fill), or a PostToolUse
additionalContext. SubagentStop's audit refusal and the Stop gate exit 2 with
the reason on stderr (and still print {}); everything else exits 0.

  hooks.py KIND PLUGIN_ROOT STATE_BASE EXEC_SCRIPTS REPO_ROOT
  KIND: agent|bash|edit|mcp (PreToolUse), post-agent, post-bash, subagent-start, subagent-stop, stop

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
LEDGER_CODE = re.compile(r"(^|[;\n])\s*(import\s+[\w, ]*\bledger\b(?!\.)|from\s+ledger\s+import\b)|\bledger\.append\s*\("
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
    if removal:
        # Removing or moving an ancestor of the run takes the run with it:
        # `rm -rf ../../..` from the plan worktree, `rm -rf .` in the base checkout.
        for p, what in ((ctx.state_base, "the run state"), (wt, "the plan worktree"), (ctx.worktree, "the plan worktree")):
            if p and path != p and under(p, path):
                return "removing or moving %s would delete %s (%s) during a run" % (path, what, p)
    if wt and path == wt and removal:
        return "the plan worktree root is not removed or moved during a run (land.sh removes it)"
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


def now_ts():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def age_minutes(ts):
    try:
        t = datetime.datetime.strptime(str(ts), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        return None
    return (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() / 60.0


def write_json_atomic(path, obj, exclusive=False):
    """Write JSON via a temp file and rename (exclusive: never replace an existing file)."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, sort_keys=True)
        f.write("\n")
    if exclusive:
        try:
            os.link(tmp, path)                            # fails if path exists
        finally:
            os.unlink(tmp)
    else:
        os.replace(tmp, path)


# ----------------------------------------------------------- agent registry ----
# SubagentStart registers agent_id -> role -> route_id as <D>/agents/<agent_id>.json
# (one file per agent: parallel starts never contend); SubagentStop (and
# PostToolUse Agent, for a foreground agent) records the stop. The live set is
# the current route's registrations without a stop, younger than the route's
# wall-clock budget (default LIVE_TTL_MIN): a lost SubagentStop delays review by
# at most that, never wedges it, and a re-route (a new route id) clears it.

AGENT_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
LIVE_TTL_MIN = 120


def agents_dir(ctx, write=False):
    return os.path.join(ledger.dispatch_dir(ctx.state_dir, write=write), "agents")


def mark_stopped(ctx, agent_id, how):
    if not (ctx.state_dir and isinstance(agent_id, str) and AGENT_ID_RE.match(agent_id)):
        return None
    path = os.path.join(agents_dir(ctx), agent_id + ".json")
    rec = read_json(path)
    if not isinstance(rec, dict):
        return None
    if not rec.get("stopped_at"):
        rec.update({"stopped_at": now_ts(), "stopped_by": how})
        try:
            write_json_atomic(path, rec)
        except OSError as e:
            ctx.advise("could not record the stop of %s: %s" % (agent_id, e))
    return rec


def live_agents(ctx):
    d = agents_dir(ctx) if ctx.state_dir else None
    if not d or not os.path.isdir(d):
        return []
    mins = ((ctx.route.get("router") or {}).get("budgets") or {}).get("minutes")
    ttl = mins if isinstance(mins, (int, float)) and mins > 0 else LIVE_TTL_MIN
    out = []
    for f in sorted(os.listdir(d))[:500]:
        if not f.endswith(".json"):
            continue
        rec = read_json(os.path.join(d, f))
        if not isinstance(rec, dict) or rec.get("stopped_at"):
            continue
        if ctx.route.get("route_id") and rec.get("route_id") not in (None, ctx.route.get("route_id")):
            continue                                      # another route's agent: a re-route starts clean
        age = age_minutes(rec.get("started_at"))
        if age is None or age > ttl:
            continue
        out.append(rec)
    return out


# ------------------------------------------------------------- usage / USD ----

FAMILIES = ("haiku", "sonnet", "opus", "fable")


def family(model):
    m = str(model or "").lower()
    for f in FAMILIES:
        if f in m:
            return f
    return None


def price_table(ctx):
    out = {}
    for t in sorted(ctx.policy.get("tiers", []), key=lambda x: x.get("rank", 0)):
        out.setdefault(t.get("model"), t.get("price_usd_per_mtok") or {})
    return out


def norm_usage(u):
    """PostToolUse Agent usage (API field names) -> the ledger's {input, output, cache_read, cache_write}."""
    if not isinstance(u, dict):
        return None
    m = {"input": ("input", "input_tokens"), "output": ("output", "output_tokens"),
         "cache_read": ("cache_read", "cache_read_input_tokens"),
         "cache_write": ("cache_write", "cache_creation_input_tokens")}
    out = {}
    for k, keys in m.items():
        for src in keys:
            v = u.get(src)
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                out[k] = int(v)
                break
    return out or None


def row_usd(prices, row):
    """Estimated USD of one worker_run row: its own `usd`, else usage x the tier price of its resolved family."""
    if isinstance(row.get("usd"), (int, float)) and not isinstance(row.get("usd"), bool):
        return float(row["usd"])
    u, fam = row.get("usage"), family(row.get("resolved_model"))
    if not isinstance(u, dict) or fam not in prices:
        return 0.0
    p = prices[fam]
    return sum(float(u.get(k) or 0) * float(p.get(k) or 0) for k in ("input", "output", "cache_read", "cache_write")) / 1e6


def route_usd(ctx, route_id, rows=None):
    prices = price_table(ctx)
    rows = ledger.read_rows(ctx.state_dir) if rows is None else rows
    return sum(row_usd(prices, r) for r in rows if r.get("event") == "worker_run" and r.get("route_id") == route_id
               and r.get("source") in ("hook", "shim"))


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
        if is_reviewer and ctx.owner.get("kind") == "adhoc":
            # An ad-hoc route has no plan line, so no green-gate.sh result: its
            # reviewers need a committed, clean HEAD (the Acceptance command is the
            # orchestrator's to run before review, as /apex-dispatch:run says).
            if not git(ctx.worktree, "rev-parse", "HEAD") or worktree_dirty(ctx.worktree):
                raise Deny("an ad-hoc route's reviewers need a committed, clean HEAD: commit the work first")
        elif is_reviewer:
            gate = read_json(os.path.join(ctx.state_dir, "gate", "last.json"), {}) or {}
            head = git(ctx.worktree, "rev-parse", "HEAD")
            if gate.get("result") not in GATE_OK or not head or gate.get("head_sha") != head:
                raise Deny("reviewer spawns need a green gate bound to HEAD (gate/last.json: result %s at %s; HEAD %s) — run green-gate.sh check"
                           % (gate.get("result") or "none", str(gate.get("head_sha") or "-")[:12], (head or "?")[:12]))
        if is_reviewer:
            # Spec §5.3 D: the move to REVIEW is refused while builder-side
            # agents are still running (registered by subagent-start.sh, no stop yet).
            busy = [a for a in live_agents(ctx) if a.get("role") not in REVIEWER_ROLES]
            if busy:
                raise Deny("%d builder-side agent(s) are still registered as running (%s); wait for them to finish and "
                           "commit before review. A registration whose stop was lost clears itself after the route's "
                           "minutes budget, or re-route (route.sh plan / iterate.sh) to start a fresh route"
                           % (len(busy), ", ".join("%s %s" % (a.get("role"), a.get("agent_id")) for a in busy[:4])))
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
            usd = budgets.get("usd")
            if isinstance(usd, (int, float)) and usd > 0:
                est = route_usd(ctx, rid)
                if est >= usd:
                    raise Deny("route %s's USD budget is spent (estimated $%.2f of $%.2f from post-agent usage rows); "
                               "halt and ask, do not continue inline" % (rid, est, usd))
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
        raise Deny("writes are refused during stage %s: the gate and the reviewers are bound to HEAD; re-route "
                   "(route.sh plan / iterate.sh) to return to BUILD before committing fixes" % ctx.stage)
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


# A quoted or escaped `(`/`)` standing alone ('(' "(" \( and the same for `)`) is
# an argument (find's grouping), not a subshell: it is kept as a word. shlex in
# punctuation mode cannot tell a quoted paren from a bare one, so such words are
# swapped for placeholders before tokenising and mapped to WORD_PARENS after.
QPAREN_RE = {"__APEX_QLP__": re.compile(r"""(?<![^\s;&|])(?:'\('|"\("|\\\()(?=$|[\s;&|])"""),
             "__APEX_QRP__": re.compile(r"""(?<![^\s;&|])(?:'\)'|"\)"|\\\))(?=$|[\s;&|])""")}
QPAREN_TOK = {"__APEX_QLP__": "\x00(", "__APEX_QRP__": "\x00)"}
WORD_PARENS = {"\x00(": "(", "\x00)": ")"}


def tokens(cmd):
    for ph, rx in QPAREN_RE.items():
        cmd = rx.sub(" %s " % ph, cmd)
    lex = shlex.shlex(cmd.replace("`", " "), posix=True, punctuation_chars=";&|()<>\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    try:
        raw = list(lex)
    except ValueError:                                   # unbalanced quotes: best effort
        raw = re.findall(r"[^\s;&|()<>]+|[;&|()<>\n]+", cmd)
    out = []
    for t in raw:
        out += split_ops(t) if t and all(c in ";&|()<>\n" for c in t) else [QPAREN_TOK.get(t, t)]
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
            words.append(WORD_PARENS.get(t, t))
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
        return set()                                     # find: bash_rules judges its start points (find_root_reason)

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
        self.cfg, self.cdirs = [], []
        while i < len(w) and w[i].startswith("-"):
            x = w[i]
            if x in ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix", "--attr-source") \
                    and i + 1 < len(w):
                if x in ("-c", "--config-env"):
                    self.cfg.append(w[i + 1])
                elif x == "-C":
                    self.cdirs.append(w[i + 1])
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

    def prefix(self, prefix=""):
        """The cd-prefix git runs in after its -C options (cumulative, as git applies them)."""
        return os.path.join(prefix, *[os.path.expanduser(d) for d in self.cdirs]) if self.cdirs else prefix

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


def opt_values(args, names):
    """Values of options in `names`, given as `--opt V` or `--opt=V`."""
    out = []
    for k, w in enumerate(args):
        if w in names and k + 1 < len(args):
            out.append(args[k + 1])
        elif "=" in w and w.split("=", 1)[0] in names:
            out.append(w.split("=", 1)[1])
    return out


def base_checkout(ctx):
    return os.path.dirname(ctx.state_base) if os.path.basename(ctx.state_base) == ".dev-plan-state" else ctx.repo_root


def find_root_reason(ctx, c, cwd, prefix, roots):
    """A deleting find whose start point resolves to a worktree root, or to an
    ancestor of the run state or the plan worktree (the base checkout, `../..`),
    may delete only filtered matches: never the root itself, its `.git`, nor a
    directory on the way down to the run state or the worktree. Starts are
    compared resolved, so `.`, `../worktree`, an absolute path and
    `cd src && find ..` are judged alike. A start containing `$` or a backtick
    may be any of them: its -name values are checked against the basenames of
    every root, the base checkout, `.git` and `.dev-plan-state`."""
    import fnmatch
    a = c.args
    names = opt_values(a, ("-name",))
    inames = opt_values(a, ("-iname",))
    paths = opt_values(a, ("-path", "-ipath", "-wholename", "-iwholename"))
    regexes = opt_values(a, ("-regex", "-iregex"))
    filtered = bool(names or inames or paths or regexes or "-empty" in a)
    negated = [w for w in a if w in ("!", "-not", "-o", "-or", "-prune")]
    protected = [p for p in (ctx.state_base, ctx.state_worktree, ctx.worktree) if p]
    for x in c.find_parts()[0]:
        unresolved = "$" in x or "`" in x               # may be a root: judged as one
        rp = None if unresolved else real(resolve_target(ctx, cwd, prefix, x))
        below = [p for p in protected if rp and p != rp and under(p, rp)]
        if not unresolved and rp not in roots and not below:
            continue
        if unresolved:
            where = "a start point that may be the worktree root (%s)" % x
        elif rp in roots:
            where = "the worktree root"
        else:
            where = "%s, an ancestor of the run state or the plan worktree" % x
        if not filtered:
            return "find -delete at %s without a -name/-path/-regex/-empty filter would delete its .git link or the run" % where
        if negated:
            return ("find -delete at %s with %s could match the root, its .git link or the run state; run it from a "
                    "subdirectory or with a positive -name filter only" % (where, negated[0]))
        comps = sorted({tuple(os.path.relpath(p, rp).split("/")) for p in below})
        if unresolved:
            bases = {".git", ".dev-plan-state"} | {os.path.basename(p) for p in protected + list(roots) + [base_checkout(ctx)] if p}
        else:
            bases = {".git", os.path.basename(rp) or "/"} | {part for t in comps for part in t}
        hits = [n for n in names if any(fnmatch.fnmatchcase(b, n) for b in bases)]
        hits += [n for n in inames if any(fnmatch.fnmatch(b.lower(), n.lower()) for b in bases)]
        stem = x.rstrip("/") or "/"
        targets = {stem, stem + "/.git"} | {stem + "/" + "/".join(t[:k]) for t in comps for k in range(1, len(t) + 1)}
        hits += [p for p in paths if any(fnmatch.fnmatch(t, p) for t in targets)]
        for r in regexes:
            try:
                if any(re.fullmatch(r, t) for t in targets):
                    hits.append(r)
            except re.error:
                hits.append(r)
        if hits:
            return "find -delete filter %s matches the worktree root, its .git link or the way to the run state" % hits[0]
    return None


def rsync_root_reason(ctx, c, cwd, prefix, roots):
    """rsync that deletes in the destination may not run into a worktree root unless it
    excludes exactly `.git` (the worktree's link file) and does not delete excluded files."""
    a = c.args
    if not any(w == "--del" or w.startswith("--delete") or w == "--remove-source-files" for w in a):
        return None
    pos = c.positionals()
    if not pos:
        return None
    dest = pos[-1]
    if "$" not in dest and "`" not in dest and real(resolve_target(ctx, cwd, prefix, dest)) not in roots:
        return None
    excl = opt_values(a, ("--exclude",))
    rules = opt_values(a, ("--filter", "-f"))
    rules += [w[2:] for w in a if w.startswith("-f") and len(w) > 2 and not w.startswith("--")]
    ok = any(e in (".git", "/.git") for e in excl) or any(
        re.fullmatch(r"\s*(-|exclude)\s+/?\.git\s*", r) for r in rules)
    if ok and "--delete-excluded" not in a:
        return None
    return "rsync with delete into the worktree root (or an unresolvable destination) needs an exact --exclude=.git and no --delete-excluded"


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
                                                    or ("-m" in c.args and c.args.index("-m") + 1 < len(c.args) and c.args[c.args.index("-m") + 1] == "ledger")):
            raise Deny("the ledger is written only in-process by route.py, the hooks and the shims (use ledger.sh)")
        # 5. Git configuration and repository internals the clean-worktree check trusts.
        if b == "git":
            g = GitCmd(c)
            if g.config_write():
                raise Deny("`git config` writes are refused during a run (the gate and land trust local git configuration; reads like --get/--list are fine)")
            if g.sub == "update-index" and any(a in UPDATE_INDEX_HIDING for a in g.args):
                raise Deny("git update-index %s hides edits from status; refused during a run" % " ".join(a for a in g.args if a in UPDATE_INDEX_HIDING))
            if g.sub == "worktree" and g.pos()[:1] in (["remove"], ["move"]) and len(g.pos()) >= 2:
                raw = [g.pos()[1]] + g.cdirs
                target = real(resolve_target(ctx, cwd, g.prefix(prefix), g.pos()[1]))
                if any("$" in x or "`" in x for x in raw) or target in {w for w in (ctx.state_worktree, ctx.worktree) if w}:
                    raise Deny("git worktree %s of the plan worktree is refused during a run (land.sh removes it)" % g.pos()[0])
            if g.sub == "sparse-checkout" and g.mutating():
                raise Deny("git sparse-checkout changes skip-worktree flags; refused during a run")
            if g.mutating():
                bad = [x for x in g.cfg if GIT_CFG_KEYS.match(x) and not GIT_CFG_HARMLESS.match(x)]
                if bad:
                    raise Deny("git -c %s on a mutating command overrides core/filter/diff/merge configuration" % bad[0])
                if ctx.stage in LOCKED_STAGES:
                    raise Deny("git %s is refused during stage %s (the gate and reviewers are bound to HEAD); re-route "
                               "(route.sh plan / iterate.sh) to return to BUILD before committing fixes" % (g.sub, ctx.stage))
                if read_only:
                    raise Deny("role %s is read-only: git %s refused" % (role, g.sub))
        # 6. Write-shaped commands: protected paths always; the checkout during GATE/REVIEW or for read-only roles.
        targets, shaped = c.write_targets()
        removals = c.removal_targets()
        roots = {w for w in (ctx.state_worktree, ctx.worktree) if w}
        if b == "find" and c.find_parts()[1]:
            why = find_root_reason(ctx, c, cwd, prefix, roots)
            if why:
                raise Deny(why)
        if b == "rsync":
            why = rsync_root_reason(ctx, c, cwd, prefix, roots)
            if why:
                raise Deny(why)
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
                    raise Deny("write to %s refused %s" % (t, "during stage %s; re-route (route.sh plan / iterate.sh) to return to "
                                                                "BUILD before committing fixes" % ctx.stage
                                                           if ctx.stage in LOCKED_STAGES else "for read-only role " + role))
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


# ------------------------------------------------------- post-agent (3.2) ----

class Block(Exception):
    """Exit 2 with the reason on stderr (SubagentStop audit refusal, Stop gate)."""


def response_obj(p):
    r = p.get("tool_response")
    if isinstance(r, str):
        try:
            r = json.loads(r)
        except ValueError:
            return {"text": r}
    return r if isinstance(r, dict) else {}


# Agent tool_response statuses that mean the agent is over (Phase 0 spike 6 saw
# "completed"; the rest are the failure/stop spellings). Missing or unknown
# (async_launched, running, ...) leaves the registration live.
TERMINAL_STATUSES = {"completed", "failed", "error", "cancelled", "canceled", "interrupted", "killed", "aborted"}


def post_agent(ctx, p):
    """PostToolUse / PostToolUseFailure, Agent|Task (spec §5.1, Phase 0 spike 6):
    a worker_run row per tool_use_id with resolvedModel, usage, duration and tool
    count; a model_mismatch row when the resolved family is not ROUTE_MODEL on a
    builder-side role (advisory: the spawn already ran); the route's USD
    estimate, which pre-agent enforces against ROUTE_BUDGET_USD at the next spawn."""
    if p.get("tool_name") not in ("Agent", "Task"):
        return {}
    event = p.get("hook_event_name") or "PostToolUse"
    ti = p.get("tool_input") if isinstance(p.get("tool_input"), dict) else {}
    st = str(ti.get("subagent_type") or "general-purpose")
    role = role_of(st) if st.startswith("apex-dispatch:") else st
    resp = response_obj(p)
    failed = event == "PostToolUseFailure" or str(resp.get("status") or "").lower() in ("failed", "error")
    tuid = p.get("tool_use_id")
    rid = ctx.route.get("route_id")
    rows = ledger.read_rows(ctx.state_dir) if ctx.state_dir else []
    if tuid and any(r.get("event") == "worker_run" and r.get("tool_use_id") == tuid for r in rows):
        return {}                                          # one row per tool use (usage deduped)
    resolved = resp.get("resolvedModel")
    usage = norm_usage(resp.get("usage"))
    agent_id = resp.get("agentId")
    status = resp.get("status") or ("failed" if failed else "unknown")
    if isinstance(agent_id, str):
        if failed:
            mark_stopped(ctx, agent_id, "post-agent-failure")
        elif str(status).lower() in TERMINAL_STATUSES:
            mark_stopped(ctx, agent_id, "post-agent")  # a foreground agent is over, however it ended
    if not failed and not resolved and usage is None:
        # A background launch returns before the agent ran: nothing to price yet.
        ctx.ledger_row("hook_advisory", {"hook": "post-agent.sh", "tool_use_id": tuid,
                                         "advisory": "Agent %s returned status %s without resolvedModel or usage; usage unverified"
                                         % (st, status)}, route_id=rid)
        return {}
    data = {"provider": "claude-session", "role": role, "exit_code": 1 if failed else 0, "status": status,
            "agent_id": agent_id if isinstance(agent_id, str) else None, "tool_use_id": tuid, "subagent_type": st,
            "requested_model": ti.get("model"), "resolved_model": resolved if isinstance(resolved, str) else None,
            "usage": usage, "token_source": "real" if usage else "none",
            "duration_ms": resp.get("totalDurationMs"), "tool_count": resp.get("totalToolUseCount"),
            "total_tokens": resp.get("totalTokens"), "session_id": p.get("session_id")}
    if isinstance(resp.get("modelsUsed"), (list, dict)):
        data["models_used"] = resp["modelsUsed"]
    if failed:
        data["error"] = str(p.get("error") or resp.get("error") or "")[:300]
    data["usd_estimate"] = round(row_usd(price_table(ctx), data), 6)
    row = ctx.ledger_row("worker_run", data, route_id=rid)
    notes = []
    router = ctx.route.get("router") or {}
    rmodel = router.get("model")
    if role not in REVIEWER_ROLES and rmodel in MODELS and resolved and family(resolved) != rmodel:
        ctx.ledger_row("model_mismatch", {"route_model": rmodel, "resolved_model": resolved, "role": role,
                                          "agent_id": data["agent_id"], "tool_use_id": tuid}, route_id=rid)
        notes.append("the %s ran on %s, not ROUTE_MODEL %s (recorded as model_mismatch)" % (role, resolved, rmodel))
    cap = (router.get("budgets") or {}).get("usd")
    if rid and isinstance(cap, (int, float)) and cap > 0:
        est = route_usd(ctx, rid, rows + ([row] if row else []))
        if est >= cap:
            notes.append("route %s's estimated USD ($%.2f) has reached ROUTE_BUDGET_USD $%.2f: further builder-side "
                         "spawns are denied; halt and ask" % (rid, est, cap))
    if notes and event == "PostToolUse":
        return {"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "apex-dispatch: " + "; ".join(notes)}}
    return {}


# -------------------------------------------------- subagent start / stop ----

def subagent_start(ctx, p):
    """SubagentStart (Phase 0 spike 7: agent_id, agent_type): register agent_id ->
    role -> route_id and write a hook-sourced `spawn` row. Phase 0 did not verify
    additionalContext on SubagentStart, so the role contract stays in the
    generated agent file and the orchestrator's brief: nothing is injected."""
    at, aid = p.get("agent_type"), p.get("agent_id")
    role = role_of(at)
    if role is None:
        return {}
    if not (isinstance(aid, str) and AGENT_ID_RE.match(aid)):
        ctx.advise("SubagentStart without a usable agent_id; not registered")
        ctx.ledger_row("hook_advisory", {"hook": "subagent-start.sh", "advisory": "agent_id %r not registered" % (aid,)})
        return {}
    rid = ctx.route.get("route_id")
    rec = {"agent_id": aid, "agent_type": at, "role": role, "route_id": rid, "stage": ctx.stage,
           "session_id": p.get("session_id"), "started_at": now_ts(), "stopped_at": None,
           "head_at_start": git(ctx.worktree, "rev-parse", "HEAD")}
    write_json_atomic(os.path.join(agents_dir(ctx, write=True), aid + ".json"), rec)
    ctx.ledger_row("spawn", {"agent_id": aid, "role": role, "agent_type": at, "stage": ctx.stage,
                             "session_id": p.get("session_id")}, route_id=rid or "unrouted")
    return {}


VERDICT_LINE_RE = re.compile(r"^verdict\s*:\s*(.*)$", re.I)
APPROVE_RE = re.compile(r"approve[.!]?", re.I)                 # exactly APPROVE (any case)
# APPROVE, a separator (whitespace + dash/en/em dash, or colon/comma/paren), then a remark.
APPROVE_REMARK_RE = re.compile(r"approve(\s*[:,(\u2014\u2013]|\s+-)(.*)$", re.I | re.S)
# A remark counts only if every word is one of these (an allowlist: anything else may be a condition).
REMARK_WORDS = {"nit", "nits", "nitpick", "nitpicks", "non-blocking", "nonblocking", "minor", "optional", "cosmetic",
                "style", "lgtm", "only", "with", "and", "a", "few", "some", "small", "suggestions", "comments", "notes",
                "looks", "good", "findings", "clear", "all", "lenses", "cleanups", "noted"}
# Multi-word allowed phrases, replaced before the word check ("no" alone is ambiguous).
REMARK_PHRASES = ("no blocking findings", "no blockers")
CHANGES_RE = re.compile(r"request[ _-]?changes\b", re.I)      # trailing text allowed
# A template placeholder naming both outcomes ("APPROVE or VERDICT: REQUEST_CHANGES", "<APPROVE|REQUEST_CHANGES>").
TOKEN = r"(approve|request[ _-]?changes)"
TEMPLATE_RE = re.compile(r"^\W*" + TOKEN + r"\W*(\bor\b|\||/)\W*(verdict\s*:\s*)?\W*" + TOKEN + r"\W*$", re.I)
BLOCKING_LINE_RE = re.compile(r"^\s*(?:[-*+]|\d+[.)])?\s*(?:\[blocking\]|\(blocking\))(.*)$", re.I)
BLOCKING_NONE = {"none", "n/a", "na", "nothing", "none found", "none identified"}
# The reviewer template's own placeholder tokens: a line made only of these is a pasted template.
PLACEHOLDERS_RE = re.compile(r"^((<path:line>|<file:line>|<lens>|<failure scenario>|<scenario>)[\s\u2014\u2013-]*)+$", re.I)
FENCE_RE = re.compile(r"^ {0,3}(```|~~~)")
LENS_RE = re.compile(r"^LENS:\s*(.{1,60})$", re.I)
# The six canonical lenses (and the adversarial pass); anything else is no lens.
LENSES = ("correctness", "security", "consent-pii", "money", "performance", "maintainability")


def canonical_lens(raw):
    """'Consent / PII', 'consent/pii', 'PII' -> consent-pii; 'Security' -> security;
    'adversarial' -> adversarial; unknown -> None."""
    v = re.sub(r"[^a-z]+", "-", str(raw or "").lower()).strip("-")
    if v in LENSES or v == "adversarial":
        return v
    if v in ("consent", "pii", "consent-and-pii", "privacy", "consent-privacy"):
        return "consent-pii"
    return None
READ_ONLY_PROBE = "apex-dispatch:reviewer"                # audit identity when the payload names none


def verdict_value(v):
    """Classify one VERDICT value: APPROVE, REQUEST_CHANGES, UNPARSED, or None for a
    template placeholder that names both outcomes (an echo of the brief, not a verdict)."""
    if TEMPLATE_RE.match(re.sub(r"[<>\[\]\"'`]", " ", v)):
        return None
    if APPROVE_RE.fullmatch(v):
        return "APPROVE"
    if CHANGES_RE.match(v):
        return "REQUEST_CHANGES"
    m = APPROVE_REMARK_RE.match(v)
    if m:
        remark = re.sub(r"[^a-z-]+", " ", m.group(2).lower())
        for phrase in REMARK_PHRASES:
            remark = re.sub(r"\b%s\b" % phrase, " ", remark)
        words = [w.strip("-") for w in remark.split()]
        if all(w in REMARK_WORDS for w in words if w):
            return "APPROVE"
    return "UNPARSED"


def parse_review(msg):
    """(verdict, lens) from a reviewer's last message, fail-closed.

    Every line `verdict: <value>` (any case, markdown emphasis and backticks
    ignored) is a verdict line. Its value is APPROVE when it is exactly APPROVE,
    or APPROVE + a separator (whitespace then - / en or em dash, or : , ( ) + a
    remark whose every word is in REMARK_WORDS (nits, non-blocking, minor,
    optional, cosmetic, style, LGTM, only, suggestions, looks good, all lenses
    clear, nits noted, ... plus the phrases "no blockers" / "no blocking
    findings"; a bare "no" or "above" is not allowed): an allowlist, so
    "APPROVE, provided ..." or "APPROVE (assuming CI goes green)" is UNPARSED;
    REQUEST_CHANGES when it starts with REQUEST CHANGES / REQUEST_CHANGES /
    request-changes; a template placeholder naming both outcomes joined by
    or / | / slash is no verdict; anything else ("APPROVED", "APPROVE-ish",
    "LGTM") is UNPARSED.

    Context only discounts approvals: an APPROVE line inside a fenced code block,
    a blockquote (`>`) or indented code (4+ spaces or a tab) is an example and is
    skipped, but a REQUEST_CHANGES or UNPARSED line counts wherever it is. A fence
    left open at the end of the message adds UNPARSED. Any line -- inside a code
    fence too -- that starts with `[blocking]` or `(blocking)` (optionally as a
    `-`/`*` or numbered list item) forces REQUEST_CHANGES, unless the text after
    the tag is only the template's own placeholders (`<path:line>`, `<file:line>`,
    `<lens>`, `<failure scenario>`, `<scenario>`) or says
    none / (none) / n/a / none found / none identified.

    The result is REQUEST_CHANGES if a blocking finding is listed; otherwise the
    last non-approving value if any; otherwise APPROVE if there is at least one
    counted APPROVE; otherwise UNPARSED. The lens is the last prose `LENS:` line,
    canonicalised."""
    values, lens, fenced, blocking = [], None, False, False
    for raw in str(msg or "").splitlines():
        if FENCE_RE.match(raw):
            fenced = not fenced
            continue
        b = BLOCKING_LINE_RE.match(re.sub(r"[*_`]", "", raw.lstrip(" \t>")))
        if b:
            rest = b.group(1).strip(" :.-\u2014\u2013")
            if rest.strip("() ").lower() not in BLOCKING_NONE and not PLACEHOLDERS_RE.match(rest):
                blocking = True
        example = fenced or raw.startswith(("    ", "\t")) or raw.lstrip().startswith(">")
        line = re.sub(r"[*`]", "", raw).strip().strip("_#> ").strip()
        m = VERDICT_LINE_RE.match(line)
        if m:
            v = verdict_value(m.group(1).strip().strip("_*` "))
            if v is not None and not (example and v == "APPROVE"):
                values.append(v)
            continue
        m = LENS_RE.match(line.rstrip("."))
        if m and not example:
            lens = canonical_lens(m.group(1))
    if fenced:
        values.append("UNPARSED")
    if blocking:
        return "REQUEST_CHANGES", lens
    bad = [v for v in values if v != "APPROVE"]
    if bad:
        return bad[-1], lens
    return ("APPROVE" if values else "UNPARSED"), lens


def audit_transcript(ctx, p):
    """Post-hoc audit of a read-only agent's transcript (spec §5.3 F): Write/Edit
    tool uses, Agent spawns, and Bash commands that pre-bash would refuse a
    read-only role (git mutation, writes into the checkout, run state). A tool use
    whose result is an error (a hook denied it) is not a violation. Bounded: the
    last 4 MB of the transcript, at most 2000 tool uses."""
    path = p.get("agent_transcript_path")
    if not isinstance(path, str) or not os.path.isfile(path):
        return None                                          # unavailable: nothing to audit
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(max(0, size - 4 * 1024 * 1024))
            data = f.read().decode("utf-8", "replace")
    except OSError:
        return None
    uses, errors = [], set()
    for line in data.splitlines():
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        msg = obj.get("message") if isinstance(obj, dict) else None
        content = msg.get("content") if isinstance(msg, dict) else None
        if not isinstance(content, list):
            continue
        for it in content:
            if not isinstance(it, dict):
                continue
            if it.get("type") == "tool_use" and len(uses) < 2000:
                uses.append((it.get("id"), it.get("name"), it.get("input") if isinstance(it.get("input"), dict) else {},
                             obj.get("cwd")))
            elif it.get("type") == "tool_result" and it.get("is_error"):
                errors.add(it.get("tool_use_id"))
    out = []
    for uid, name, inp, cwd in uses:
        if uid in errors:
            continue
        if name in EDIT_TOOLS:
            out.append("%s %s" % (name, inp.get("file_path") or inp.get("notebook_path") or "?"))
        elif name in ("Agent", "Task"):
            out.append("%s spawn of %s" % (name, inp.get("subagent_type") or "?"))
        elif name == "Bash" and isinstance(inp.get("command"), str):
            # The agent's own identity, as live pre-bash saw it: provider-runner may
            # run bin/worker-*.sh; gibson-reviewer (no apex-dispatch role) gets what
            # pre-bash allowed it, so a record is never refused for an allowed command.
            probe = {"cwd": cwd if isinstance(cwd, str) and os.path.isdir(cwd) else p.get("cwd"),
                     "agent_type": p.get("agent_type") or READ_ONLY_PROBE, "agent_id": p.get("agent_id") or "audit"}
            try:
                bash_rules(ctx, probe, inp["command"])
            except Deny as d:
                out.append("Bash %r: %s" % (inp["command"][:120], d))
    return out


def subagent_stop(ctx, p):
    """SubagentStop (Phase 0 spike 7: agent_id, agent_type, agent_transcript_path,
    last_assistant_message, stop_hook_active). Records the stop; audits read-only
    roles' transcripts; for reviewer roles writes the raw review record
    <D>/reviews-raw/<agent_id>.json (record_id, line, head_sha at stop, role from
    agent_type and LENS, verdict, provider family) and a `verdict` row, which
    checkpoint.sh review --agent-id consumes. A violation refuses the record,
    writes policy_violation and blocks the stop once (exit 2)."""
    at, aid = p.get("agent_type"), p.get("agent_id")
    role = role_of(at)
    if role is None or not (isinstance(aid, str) and AGENT_ID_RE.match(aid)):
        return {}
    reg = mark_stopped(ctx, aid, "subagent-stop")
    gibson = at == "apex-scope-loop:gibson-reviewer"
    reviewer = role in REVIEWER_ROLES or gibson
    read_only = reviewer or bool((ctx.roles().get(role) or {}).get("read_only"))
    rid = ctx.route.get("route_id")
    raw_dir = os.path.join(ledger.dispatch_dir(ctx.state_dir, write=True), "reviews-raw")
    rec_path = os.path.join(raw_dir, aid + ".json")
    viol = audit_transcript(ctx, p) if read_only else []
    if viol:
        reason = ("read-only role %s (agent %s) changed or tried to change the repository: %s"
                  % (role, aid, "; ".join(viol[:3]) + (" (+%d more)" % (len(viol) - 3) if len(viol) > 3 else "")))
        if not any(r.get("event") == "policy_violation" and r.get("agent_id") == aid for r in ledger.read_rows(ctx.state_dir)):
            ctx.ledger_row("policy_violation", {"hook": "subagent-stop.sh", "agent_id": aid, "role": role,
                                                "violation": reason[:800], "count": len(viol)}, route_id=rid)
        if reviewer and not os.path.exists(rec_path):
            try:
                o = ctx.owner if ctx.owner_ok else {}
                write_json_atomic(rec_path, {"agent_id": aid, "agent_type": at, "refused": reason[:800],
                                             "head_sha": git(ctx.worktree, "rev-parse", "HEAD"), "route": rid,
                                             "line": ctx.route.get("line") if ctx.route.get("line") is not None else o.get("line_no"),
                                             "written_at": now_ts(), "source": "hook:subagent-stop"}, exclusive=True)
            except OSError:
                pass
        if not p.get("stop_hook_active"):
            raise Block("apex-dispatch subagent-stop: %s. The review record is refused; stop without further changes."
                        % reason)
        return {}
    if not reviewer:
        return {}
    # Fail closed: a missing or unreadable verdict is recorded as UNPARSED, which
    # blocks checkpoint.sh complete at this head like a REQUEST_CHANGES.
    verdict, lens = parse_review(p.get("last_assistant_message"))
    if os.path.exists(rec_path):
        return {}                                          # one record per review run
    if role == "adversarial-reviewer" or (gibson and lens == "adversarial"):
        rrole = "adversarial"
    elif lens in LENSES:
        rrole = "lens:" + lens
    else:
        rrole = "reviewer"
    # The review is of the HEAD the reviewer started on (subagent-start stamps it);
    # if HEAD moved before it stopped, the record keeps the start HEAD and is
    # marked stale: never credited to (nor blocking) the new HEAD.
    head = git(ctx.worktree, "rev-parse", "HEAD")
    start_head = (reg or {}).get("head_at_start") if isinstance(reg, dict) else None
    stale = bool(start_head and head and start_head != head)
    if start_head:
        head = start_head
    o = ctx.owner if ctx.owner_ok else {}
    line = ctx.route.get("line") if ctx.route.get("line") is not None else o.get("line_no")
    record_id = "%s-%s" % (aid[:48], os.urandom(8).hex())
    rec = {"record_id": record_id, "line": line, "head_sha": head, "sha": head, "role": rrole, "lens": lens,
           "verdict": verdict, "agent_id": aid, "agent_type": at, "route": rid, "provider": "claude-session",
           "family": "anthropic", "plan_hash": o.get("id"), "session_id": p.get("session_id"),
           "written_at": now_ts(), "source": "hook:subagent-stop"}
    if stale:
        rec["stale"] = "HEAD moved from %s to %s while the reviewer ran" % (start_head[:12], git(ctx.worktree, "rev-parse", "HEAD")[:12])
    try:
        write_json_atomic(rec_path, rec, exclusive=True)
    except FileExistsError:
        return {}
    ctx.ledger_row("verdict", {"role": rrole, "verdict": verdict, "agent_id": aid, "record_id": record_id,
                               "line": line, "lens": lens, "provider": "claude-session", "family": "anthropic",
                               "head_sha": head, "stale": stale}, route_id=rid or "unrouted")
    return {}


# ------------------------------------------------------------- stop-gate ----

STOP_BLOCK_CAP = 8


def worktree_dirty(path):
    """Uncommitted or untracked work in the plan worktree (run state excluded; a
    git error or timeout counts as clean: the gate never blocks on a guess)."""
    try:
        r = subprocess.run(["git", "-C", path, "status", "--porcelain", "--untracked-files=normal"],
                           capture_output=True, text=True, timeout=5)
    except Exception:
        return False
    out = r.stdout if r.returncode == 0 else ""
    paths = [ln[3:].strip('"') for ln in out.splitlines() if len(ln) > 3]
    return any(not p.startswith(".dev-plan-state") for p in paths)


def stop_gate(ctx, p):
    """Stop (Phase 0 spike 10: exit 2 blocks once; the re-fired Stop carries
    stop_hook_active). Blocks at most once per route, and at most STOP_BLOCK_CAP
    times per run, while an enforced route is in BUILD and ending the turn would
    lose or bypass routed work: HEAD moved with no spawn/worker row (work done
    inline), or uncommitted changes in the plan worktree while no builder-side
    subagent is registered as running (live background builders never spend a
    block). Everything else is allowed. Escapes: HALT, a
    route that is not READY/enforced, stage other than BUILD, the lock released."""
    if p.get("stop_hook_active") or halt_reason(ctx) or not ctx.enforcing_route() or ctx.stage != "BUILD":
        return {}
    rid = ctx.route.get("route_id")
    rows = ledger.read_rows(ctx.state_dir)
    blocks = [r for r in rows if r.get("event") == "hook_advisory" and r.get("hook") == "stop-gate.sh" and r.get("blocked")]
    if any(r.get("route_id") == rid for r in blocks) or len(blocks) >= STOP_BLOCK_CAP:
        return {}
    spawned = any(r.get("event") in ledger.SPAWN_EVENTS and r.get("route_id") == rid and r.get("source") in ("hook", "shim")
                  for r in rows)
    head = git(ctx.worktree, "rev-parse", "HEAD")
    reasons = []
    if not spawned and head and ctx.route.get("head_sha") and head != ctx.route.get("head_sha"):
        reasons.append("HEAD moved since route %s was emitted but no subagent or worker was spawned for it (routed work "
                       "done inline): dispatch the route's roster, or record checkpoint.sh fail" % rid)
    # Live background builders are the documented run_in_background flow: ending
    # the turn while they run loses nothing, so they never spend a block (and a
    # dirty worktree is theirs to commit). A stuck registration clears after the
    # route's minutes budget or with a re-route.
    live = [a for a in live_agents(ctx) if a.get("role") not in REVIEWER_ROLES]
    if not live and worktree_dirty(ctx.worktree):
        reasons.append("the plan worktree %s has uncommitted changes: commit them, or discard them and record "
                       "checkpoint.sh fail" % ctx.worktree)
    if not reasons:
        if not spawned and not any(r.get("event") == "hook_advisory" and r.get("hook") == "stop-gate.sh"
                                   and r.get("route_id") == rid for r in rows):
            ctx.ledger_row("hook_advisory", {"hook": "stop-gate.sh", "advisory": "route %s is open with no spawn yet" % rid},
                           route_id=rid)
        return {}
    msg = ("apex-dispatch stop-gate: %s. (Blocks once per route; to stop deliberately, touch the HALT file or close "
           "the task with checkpoint.sh complete/fail.)" % "; ".join(reasons))
    ctx.ledger_row("hook_advisory", {"hook": "stop-gate.sh", "advisory": msg[:800], "blocked": True}, route_id=rid)
    raise Block(msg)


# -------------------------------------------------------- post-bash-prune ----

FAILURE_LINE = re.compile(r"\b(FAIL(ED|URE)?|ERROR|Error|error\[|error:|panicked|Traceback|AssertionError)\b|✗|✕")


def post_bash(ctx, p):
    """PostToolUse Bash. Phase 0 spike 9: a command hook cannot replace Bash
    output (updatedToolOutput was not applied), so this hook is record-only: for a
    recognised runner (policy pruning.runners) whose output exceeds
    pruning.max_lines it keeps the full log at <D>/logs/<tool_use_id>.log for the
    reviewer brief and writes one hook_advisory row. It never changes what the
    model sees."""
    if p.get("tool_name") != "Bash":
        return {}
    pruning = ctx.policy.get("pruning") or {}
    if not pruning.get("enabled"):
        return {}
    ti = p.get("tool_input") if isinstance(p.get("tool_input"), dict) else {}
    cmd = ti.get("command") if isinstance(ti.get("command"), str) else ""
    runner = next((r for r in pruning.get("runners") or [] if isinstance(r, dict) and r.get("pattern")
                   and r["pattern"] in cmd), None)
    if runner is None:
        return {}
    resp = p.get("tool_response")
    if isinstance(resp, dict):
        text = "\n".join(str(resp.get(k) or "") for k in ("stdout", "stderr") if resp.get(k))
    else:
        text = str(resp or "")
    lines = text.splitlines()
    limit = pruning.get("max_lines") if isinstance(pruning.get("max_lines"), int) else 200
    if len(lines) <= limit:
        return {}
    tuid = re.sub(r"[^A-Za-z0-9_-]", "_", str(p.get("tool_use_id") or "t%d" % int(time.time())))[:80]
    log = os.path.join(ledger.dispatch_dir(ctx.state_dir, write=True), "logs", tuid + ".log")
    os.makedirs(os.path.dirname(log), exist_ok=True)
    with open(log, "w", encoding="utf-8") as f:
        f.write(text)
    fails = [ln for ln in lines if FAILURE_LINE.search(ln)]
    ctx.ledger_row("hook_advisory", {"hook": "post-bash-prune.sh", "runner": runner.get("id"), "lines": len(lines),
                                     "failure_lines": len(fails), "log": log, "tool_use_id": p.get("tool_use_id"),
                                     "advisory": "%s output (%d lines) kept at %s; not trimmed (PostToolUse cannot replace "
                                                 "Bash output, Phase 0 spike 9)" % (runner.get("id"), len(lines), log)})
    return {}


# kind -> (hook script, handler)
HANDLERS = {"agent": ("pre-agent.sh", pre_agent), "bash": ("pre-bash.sh", pre_bash),
            "edit": ("pre-edit.sh", pre_edit), "mcp": ("pre-mcp.sh", pre_mcp),
            "post-agent": ("post-agent.sh", post_agent), "post-bash": ("post-bash-prune.sh", post_bash),
            "subagent-start": ("subagent-start.sh", subagent_start), "subagent-stop": ("subagent-stop.sh", subagent_stop),
            "stop": ("stop-gate.sh", stop_gate)}
PRE_KINDS = {"agent", "bash", "edit", "mcp"}


def main(argv):
    if len(argv) < 6 or argv[1] not in HANDLERS:
        print("{}")
        print("usage: hooks.py %s PLUGIN_ROOT STATE_BASE EXEC_SCRIPTS REPO_ROOT" % "|".join(HANDLERS), file=sys.stderr)
        return 0
    ctx = Ctx(argv[1], argv[2], argv[3], argv[4], argv[5])
    hook, handler = HANDLERS[argv[1]]
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
    rc = 0
    try:
        out = handler(ctx, payload)
    except Deny as d:
        reason = str(d)
        ctx.ledger_row("hook_advisory", {"hook": hook, "advisory": "denied: " + reason,
                                         "tool_use_id": payload.get("tool_use_id")})
        out = deny(reason) if argv[1] in PRE_KINDS else {}
    except Block as b:
        print(str(b), file=sys.stderr)
        out, rc = {}, 2
    except Exception as e:  # fail open, loudly
        ctx.advise("internal error, failing open: %s: %s" % (type(e).__name__, e))
        ctx.ledger_row("hook_error", {"hook": hook, "error": "%s: %s" % (type(e).__name__, e)})
        out = {}
    print(json.dumps(out, separators=(",", ":")))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
