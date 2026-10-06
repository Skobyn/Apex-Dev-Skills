#!/usr/bin/env python3
"""apex-dispatch doctor: preflight that makes load-bearing claims observable
(spec §5.1 doctor.sh, §11). python3 stdlib only.

  doctor.py ROOT --state DIR [--repo DIR] [--temp]

Writes <D>/doctor.json, where <D> is ledger.dispatch_dir(DIR, write=True)
(<state>/dispatch/ when enforcing, else <state>/dispatch-shadow/). Each check is
{"id", "status", "detail"} with status one of:
  ok          verified here
  warn        works, with a degrade path (route.sh/hooks read it)
  fail        a hard requirement is not met (exit 1)
  unverified  cannot be probed from a script (needs a live Claude Code session);
              recorded with the reason, never counted as ok
  skipped     not applicable (e.g. a disabled provider)
Overall: fail if any check fails, else warn if any warns, else ok.
Exit 0 (ok or warn), 1 (fail), 2 (usage). The JSON is written in every case.
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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ledger  # noqa: E402

MIN_CLAUDE = (2, 1, 251)
MIN_SCOPE_LOOP = (0, 3, 0)
VER_RE = re.compile(r"(\d+)\.(\d+)\.(\d+)")


def vtuple(s):
    m = VER_RE.search(s or "")
    return tuple(int(x) for x in m.groups()) if m else None


def vstr(t):
    return ".".join(str(x) for x in t)


def run(cmd, timeout=10):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except FileNotFoundError:
        return 127, "not found"
    except subprocess.TimeoutExpired:
        return 124, "timed out after %ss" % timeout
    except OSError as e:
        return 126, str(e)


class Doctor:
    def __init__(self, root, repo):
        self.root, self.repo = root, repo
        self.checks = []
        self.facts = {}

    def add(self, cid, status, detail, **extra):
        c = {"id": cid, "status": status, "detail": detail}
        c.update(extra)
        self.checks.append(c)
        return c

    # -- checks ----------------------------------------------------------

    def claude_binary(self):
        name = os.environ.get("APEX_CLAUDE_BIN") or "claude"
        path = shutil.which(name)
        if not path:
            self.facts["claude_version"] = None
            return self.add("claude-binary", "fail", "claude binary not found (%s); Claude Code >= %s is required"
                            % (name, vstr(MIN_CLAUDE)))
        real = os.path.realpath(path)
        rc, out = run([path, "--version"])
        v = vtuple(out) if rc == 0 else None
        self.facts["claude_version"] = vstr(v) if v else None
        if v is None:
            return self.add("claude-binary", "fail", "could not read a version from %s --version (exit %s)" % (path, rc),
                            path=path, resolved=real)
        st = "ok" if v >= MIN_CLAUDE else "fail"
        return self.add("claude-binary", st, "found %s at %s (resolved %s); required >= %s"
                        % (vstr(v), path, real, vstr(MIN_CLAUDE)), version=vstr(v), path=path, resolved=real)

    def scope_loop(self):
        cands = [os.environ.get("APEX_SCOPE_LOOP_ROOT") or "", os.path.join(self.root, "..", "apex-scope-loop")]
        for c in cands:
            pj = os.path.join(c, ".claude-plugin", "plugin.json") if c else ""
            if pj and os.path.isfile(pj):
                v = vtuple((ledger.read_json(pj, {}) or {}).get("version", ""))
                if v is None:
                    return self.add("scope-loop-sibling", "fail", "apex-scope-loop at %s has no semver version" % c)
                st = "ok" if v >= MIN_SCOPE_LOOP else "fail"
                return self.add("scope-loop-sibling", st, "apex-scope-loop %s at %s; required >= %s"
                                % (vstr(v), os.path.realpath(c), vstr(MIN_SCOPE_LOOP)), version=vstr(v))
        return self.add("scope-loop-sibling", "fail", "apex-scope-loop not found beside apex-dispatch (APEX_SCOPE_LOOP_ROOT)")

    def guardrails(self):
        g = os.path.join(self.root, "..", "apex-guardrails", ".claude-plugin", "plugin.json")
        if os.path.isfile(g):
            return self.add("guardrails-sibling", "ok", "apex-guardrails present (layer B floor)")
        return self.add("guardrails-sibling", "warn", "apex-guardrails not found beside apex-dispatch: the always-on "
                        "bypass-flag floor (layer B) is absent")

    def compile_check(self):
        rc, out = run([sys.executable, "-B", os.path.join(self.root, "scripts", "lib", "compile.py"), self.root, "--check"],
                      timeout=60)
        last = out.strip().splitlines()[-1] if out.strip() else ""
        return self.add("compile-check", "ok" if rc == 0 else "fail", "compile.sh --check: " + (last or "exit %d" % rc))

    def policy(self):
        rc, out = run([sys.executable, "-B", os.path.join(self.root, "scripts", "lib", "compile.py"), self.root,
                       "--print-merged"], timeout=60)
        if rc == 0:
            try:
                return json.loads(out)
            except ValueError:
                pass
        self.add("policy-merged", "fail", "the merged policy (default + this repo's overlay) is invalid: "
                 + (out.strip().splitlines() or ["no output"])[-1])
        return ledger.read_json(os.path.join(self.root, "resources", "compiled", "policy.json"), {}) or {}

    def providers(self, pol):
        prov = {}
        for p in pol.get("providers", []):
            pid = p.get("id")
            entry = {"enabled": bool(p.get("enabled")), "available": False, "binary": p.get("binary"), "version": None}
            prov[pid] = entry
            if not p.get("enabled"):
                self.add("provider:%s" % pid, "skipped", "disabled in policy")
                continue
            if p.get("kind") == "in-session":
                entry["available"] = self.facts.get("claude_version") is not None
                self.add("provider:%s" % pid, "ok" if entry["available"] else "fail",
                         "in-session (needs the claude binary)")
                continue
            b = p.get("binary")
            if not b:
                self.add("provider:%s" % pid, "skipped", "no binary (%s)" % p.get("kind"))
                continue
            path = shutil.which(os.environ.get("APEX_CLAUDE_BIN") or b) if b == "claude" else shutil.which(b)
            if not path:
                self.add("provider:%s" % pid, "warn", "binary %r not on PATH: routes fall back to claude-session" % b)
                continue
            rc, out = run([path, "--version"], timeout=5)
            v = vtuple(out) if rc == 0 else None
            entry.update({"available": True, "path": path, "version": vstr(v) if v else None})
            key = p.get("key_env")
            if key and not os.environ.get(key):
                entry["auth"] = "unknown"
                self.add("provider:%s" % pid, "warn", "%s %s at %s; %s is not set (subscription login may still work; "
                         "unverified)" % (b, vstr(v) if v else "(version unknown)", path, key))
            else:
                entry["auth"] = "env" if key else "n/a"
                self.add("provider:%s" % pid, "ok", "%s %s at %s" % (b, vstr(v) if v else "(version unknown)", path))
        self.facts["providers"] = prov
        cp = prov.get("claude-p") or {}
        self.facts["claude_p_auth"] = "available" if cp.get("available") and cp.get("auth") == "env" else "unavailable"
        return prov

    def forbidden_flags(self):
        return self.add("provider-forced-flags-probe", "unverified",
                        "deferred: forced flags are verified by running each shim's exact forced set with --help "
                        "(parse for 'unexpected argument') once bin/worker-*.sh ship (Phase 4)")

    def subagent_model_env(self):
        hits = sorted(k for k in os.environ if k.startswith("CLAUDE_CODE_SUBAGENT_MODEL"))
        if hits:
            return self.add("subagent-model-env", "fail", "%s set: it overrides every routed model pin; unset it"
                            % ", ".join(hits))
        return self.add("subagent-model-env", "ok", "no CLAUDE_CODE_SUBAGENT_MODEL* variable is set")

    def settings_snippet(self):
        snip = ledger.read_json(os.path.join(self.root, "resources", "settings-snippet.json"), {}) or {}
        want = list((snip.get("permissions") or {}).get("deny") or [])
        have = set()
        seen = []
        for name in ("settings.json", "settings.local.json"):
            p = os.path.join(self.repo, ".claude", name)
            s = ledger.read_json(p)
            if isinstance(s, dict):
                seen.append(p)
                have |= set((s.get("permissions") or {}).get("deny") or [])
        missing = [r for r in want if r not in have]
        if not missing:
            return self.add("settings-snippet", "ok", "deny rules present in %s" % ", ".join(seen))
        return self.add("settings-snippet", "warn", "%d of %d deny rules from resources/settings-snippet.json are not in "
                        "%s/.claude/settings.json: %s" % (len(missing), len(want), self.repo, ", ".join(missing)),
                        missing=missing)

    def plugin_version(self):
        pj = ledger.read_json(os.path.join(self.root, ".claude-plugin", "plugin.json"), {}) or {}
        mine = pj.get("version")
        compiled = {}
        try:
            with open(os.path.join(self.root, "resources", "compiled", "VERSION"), encoding="utf-8") as f:
                compiled = dict(ln.strip().split("=", 1) for ln in f if "=" in ln)
        except OSError:
            pass
        if compiled.get("version") != mine:
            self.add("compiled-version", "fail", "resources/compiled/VERSION says %s, plugin.json %s"
                     % (compiled.get("version"), mine))
        else:
            self.add("compiled-version", "ok", "compiled artifacts are for %s" % mine)
        home = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
        inst = ledger.read_json(os.path.join(home, "plugins", "installed_plugins.json"), {}) or {}
        found = []
        plugins = inst.get("plugins") if isinstance(inst.get("plugins"), dict) else inst
        for k, v in (plugins or {}).items():
            if isinstance(k, str) and k.split("@")[0] == "apex-dispatch":
                for e in (v if isinstance(v, list) else [v]):
                    if isinstance(e, dict):
                        found.append(e.get("version"))
        if not found:
            return self.add("installed-version", "unverified", "apex-dispatch is not in %s/plugins/installed_plugins.json "
                            "(running from source or --plugin-dir); plugin.json says %s" % (home, mine))
        if all(f == mine for f in found):
            return self.add("installed-version", "ok", "installed %s == plugin.json %s" % (", ".join(map(str, found)), mine))
        return self.add("installed-version", "warn", "installed %s, this plugin.json %s: run /plugin marketplace update"
                        % (", ".join(map(str, found)), mine))

    def live_probes(self):
        why = "needs a live Claude Code session (a one-tool subagent plus a probe hook); run /apex-dispatch:doctor inside one"
        self.add("probe:agent-id-in-tool-stdin", "unverified",
                 "whether tool-event stdin inside a subagent carries agent_id/agent_type: " + why,
                 degrade="layer F falls back to loader presence + stage lock + SubagentStop transcript audit")
        self.add("probe:updatedinput-model", "unverified",
                 "whether PreToolUse updatedInput on Agent changes the recorded model: " + why,
                 degrade="model pinned by deny-on-mismatch only")
        self.add("probe:plugin-root-in-hooks", "unverified", "${CLAUDE_PLUGIN_ROOT} resolution in hooks/commands: " + why)
        self.add("probe:mods-tool-check", "unverified", "installed mods handling tool.call|tool.check (route_mode "
                 "downgrades to advisory when present): " + why)
        if self.facts.get("claude_version"):
            name = shutil.which(os.environ.get("APEX_CLAUDE_BIN") or "claude")
            rc, out = run([name, "plugin", "validate", self.root], timeout=60)
            last = (out.strip().splitlines() or [""])[-1]
            self.add("claude-plugin-validate", "ok" if rc == 0 else "warn", "claude plugin validate: exit %d %s" % (rc, last))
        else:
            self.add("claude-plugin-validate", "unverified", "claude binary unavailable")

    def sandbox(self):
        return self.add("sandbox-confinement", "unverified",
                        "probed in-process by each provider shim (touch $HOME/probe, non-allowed host) once "
                        "bin/worker-*.sh ship (Phase 4)")


def main(argv):
    if not argv:
        print("usage: doctor.py ROOT --state DIR [--repo DIR] [--temp]", file=sys.stderr)
        return 2
    root, rest = os.path.abspath(argv[0]), argv[1:]
    opts, i = {}, 0
    while i < len(rest):
        a = rest[i]
        if a in ("--state", "--repo") and i + 1 < len(rest):
            opts[a[2:]] = rest[i + 1]
            i += 2
            continue
        if a == "--temp":
            opts["temp"] = True
            i += 1
            continue
        print("doctor: unknown argument %s" % a, file=sys.stderr)
        return 2
    if not opts.get("state"):
        print("usage: doctor.py ROOT --state DIR [--repo DIR] [--temp]", file=sys.stderr)
        return 2
    repo = opts.get("repo") or os.getcwd()
    d = Doctor(root, repo)
    d.claude_binary()
    d.scope_loop()
    d.guardrails()
    d.compile_check()
    pol = d.policy()
    d.providers(pol)
    d.forbidden_flags()
    d.subagent_model_env()
    d.settings_snippet()
    d.plugin_version()
    d.sandbox()
    d.live_probes()
    sts = [c["status"] for c in d.checks]
    overall = "fail" if "fail" in sts else ("warn" if "warn" in sts else "ok")
    profile_src = {"claude": d.facts.get("claude_version"), "claude_p_auth": d.facts.get("claude_p_auth"),
                   "providers": {k: v.get("available") for k, v in (d.facts.get("providers") or {}).items()},
                   "checks": {c["id"]: c["status"] for c in d.checks}}
    profile = hashlib.sha256(json.dumps(profile_src, sort_keys=True).encode()).hexdigest()[:12]
    out = {"schema": 1, "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "status": overall, "profile": profile, "repo": repo, "state": opts["state"], "temp_state": bool(opts.get("temp")),
           "enforcing": ledger.enforcing(root), "claude_version": d.facts.get("claude_version"),
           "claude_p_auth": d.facts.get("claude_p_auth"),
           "tier_c_diversity": "block" if d.facts.get("claude_p_auth") == "available" else "warn (claude -p auth unavailable)",
           "providers": d.facts.get("providers") or {}, "checks": d.checks,
           "counts": {s: sts.count(s) for s in ("ok", "warn", "fail", "unverified", "skipped")}}
    ddir = ledger.dispatch_dir(opts["state"], write=True, root=root)
    os.makedirs(ddir, exist_ok=True)
    path = os.path.join(ddir, "doctor.json")
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)
    for c in d.checks:
        print("DOCTOR_CHECK: %-28s %-10s %s" % (c["id"], c["status"], c["detail"]))
    print("DOCTOR_COUNTS: " + ", ".join("%s=%d" % kv for kv in out["counts"].items()))
    print("DOCTOR_STATUS: %s" % overall)
    print("DOCTOR_FILE: %s" % path)
    return 1 if overall == "fail" else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
