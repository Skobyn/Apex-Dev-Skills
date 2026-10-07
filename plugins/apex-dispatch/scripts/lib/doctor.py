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

    # Credentials files a CLI reads when its key variable is unset (looked at, never read
    # or sent anywhere): Claude Code's OAuth login, codex's `codex login`.
    CRED_FILES = {"claude-p": ("CLAUDE_CONFIG_DIR", ".claude", ".credentials.json"),
                  "codex": ("CODEX_HOME", ".codex", "auth.json")}
    EXTRA_AUTH_ENV = {"claude-p": ("CLAUDE_CODE_OAUTH_TOKEN",)}
    FLAG_ERRORS = re.compile(r"unexpected argument|unknown option|unrecognized option|unknown flag|invalid option", re.I)

    def auth_of(self, pid, p):
        """env | credentials-file | none | n/a: how the provider would authenticate (no network call)."""
        keys = ([p["key_env"]] if p.get("key_env") else []) + list(self.EXTRA_AUTH_ENV.get(pid, ()))
        if any(os.environ.get(k) for k in keys):
            return "env"
        cf = self.CRED_FILES.get(pid)
        if cf:
            base = os.environ.get(cf[0]) or os.path.join(os.path.expanduser("~"), cf[1])
            if os.path.isfile(os.path.join(base, cf[2])):
                return "credentials-file"
        return "none" if keys or cf else "n/a"

    def providers(self, pol):
        prov = {}
        for p in pol.get("providers", []):
            pid = p.get("id")
            status = p.get("status")
            shim = os.path.join(self.root, "bin", "worker-%s.sh" % pid)
            has_shim = os.path.isfile(shim) and os.access(shim, os.X_OK)
            entry = {"enabled": bool(p.get("enabled")), "available": False, "binary": p.get("binary"), "version": None,
                     "status": status, "verified": status == "verified", "shim": has_shim}
            prov[pid] = entry
            if not p.get("enabled"):
                self.add("provider:%s" % pid, "skipped", "disabled in policy (status %s)" % status)
                continue
            if p.get("kind") == "in-session":
                entry["available"] = self.facts.get("claude_version") is not None
                self.add("provider:%s" % pid, "ok" if entry["available"] else "fail",
                         "in-session (needs the claude binary)")
                continue
            b = p.get("binary")
            if not b or p.get("kind") == "stub":
                entry["why"] = "stub"
                self.add("provider:%s" % pid, "skipped", "no binary (%s)" % p.get("kind"))
                continue
            path = shutil.which(os.environ.get("APEX_CLAUDE_BIN") or b) if b == "claude" else shutil.which(b)
            if not path:
                entry["why"] = "binary %s not on PATH" % b
                self.add("provider:%s" % pid, "warn", "binary %r not on PATH: routes fall back to claude-session" % b)
                continue
            rc, out = run([path, "--version"], timeout=5)
            v = vtuple(out) if rc == 0 else None
            auth = self.auth_of(pid, p)
            entry.update({"available": True, "path": path, "version": vstr(v) if v else None, "auth": auth,
                          "auth_ok": auth in ("env", "credentials-file", "n/a")})
            # Forced flags verified by running the exact forced set with --help (spec §5.1):
            # a CLI that no longer accepts one says "unexpected argument" (codex 0.160 on -a).
            frc, fout = run([path] + list(p.get("forced_flags") or []) + ["--help"], timeout=15)
            bad = self.FLAG_ERRORS.search(fout or "")
            entry["flags_ok"] = frc == 0 and not bad
            entry["flags_detail"] = ("exit %d%s" % (frc, ": " + bad.group(0) if bad else "")) if not entry["flags_ok"] else "accepted"
            parts = ["%s %s at %s" % (b, vstr(v) if v else "(version unknown)", path), "auth %s" % auth,
                     "shim %s" % ("bin/worker-%s.sh" % pid if has_shim else "missing"), "forced flags %s" % entry["flags_detail"]]
            st = "ok"
            if status != "verified":
                st = "warn"
                parts.append("status %s: enabled by this repository's overlay, not verified (shims refuse it unless "
                             "the overlay enables it explicitly)" % status)
            if not entry["flags_ok"]:
                st, entry["available"] = "warn", False
                entry["why"] = "forced flags rejected (%s)" % entry["flags_detail"]
            if not entry["auth_ok"]:
                st = "warn"
                parts.append("no auth: %s unset and no credentials file" % (p.get("key_env") or "key"))
            if not has_shim:
                st = "warn"
            self.add("provider:%s" % pid, st, "; ".join(parts))
        self.facts["providers"] = prov
        cp = prov.get("claude-p") or {}
        self.facts["claude_p_auth"] = "available" if cp.get("available") and cp.get("auth_ok") else "unavailable"
        return prov

    def forbidden_flags(self):
        probed = {k: v for k, v in (self.facts.get("providers") or {}).items() if "flags_ok" in v}
        if not probed:
            return self.add("provider-forced-flags-probe", "unverified",
                            "no enabled subprocess provider binary on PATH, so no forced flag set could be probed with --help")
        bad = sorted(k for k, v in probed.items() if not v["flags_ok"])
        if bad:
            return self.add("provider-forced-flags-probe", "warn", "forced flags rejected by %s (those providers are "
                            "marked unavailable)" % ", ".join(bad))
        return self.add("provider-forced-flags-probe", "ok", "forced flags accepted with --help by %s" % ", ".join(sorted(probed)))

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
        # Non-writing probe (the spec's `touch $HOME/probe` would write): is HOME writable here?
        home = os.path.expanduser("~")
        if home and os.access(home, os.W_OK):
            return self.add("sandbox-confinement", "warn",
                            "no OS sandbox detected (HOME is writable): provider shims still run in a throwaway worktree or "
                            "snapshot with a scrubbed environment and apply.sh checks every path, but the OS does not "
                            "confine them; apply resources/settings-snippet.json's sandbox settings for layer I")
        return self.add("sandbox-confinement", "ok", "HOME is not writable: an OS sandbox appears active")


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
    # One rule with checkpoint.sh complete (ledger.second_families): a second
    # family counts only when its provider is available AND its bin/worker-*.sh
    # shim ships, since pre-bash.sh refuses provider CLIs outside the shims.
    second = ledger.second_families({"providers": d.facts.get("providers") or {},
                                     "claude_p_auth": d.facts.get("claude_p_auth")}, root)
    tier_c_diversity = "block" if second else ("warn (no second reviewer family: no enabled provider with a shipped "
                                               "bin/worker-*.sh shim is available with working auth and flags)")
    out = {"schema": 1, "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "status": overall, "profile": profile, "repo": repo, "state": opts["state"], "temp_state": bool(opts.get("temp")),
           "enforcing": ledger.enforcing(root), "claude_version": d.facts.get("claude_version"),
           "claude_p_auth": d.facts.get("claude_p_auth"),
           "tier_c_diversity": tier_c_diversity,
           "second_families": second,
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
