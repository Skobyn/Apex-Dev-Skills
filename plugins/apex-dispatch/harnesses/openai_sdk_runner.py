#!/usr/bin/env python3
"""apex-dispatch openai-sdk runner: one routed worker on the OpenAI Agents SDK
(`pip install openai-agents`), spec §5.4. Run only by scripts/lib/worker.py
(bin/worker-openai-sdk.sh); pre-bash.sh refuses it anywhere else.

  openai_sdk_runner.py --version            the openai-agents version (exit 4 when it is not importable)
  openai_sdk_runner.py run --output-format json --config FILE --brief-file FILE

FILE (written by worker.py into the run's out dir, never into the worktree):
  {"root": <the confined directory>, "mode": "write"|"readonly", "owned": [glob, ...] | null,
   "owned_rx": [regex, ...] | null (hooks.glob_re of each glob, so Paths match exactly as apply.sh
   matches them), "model": <model> | null, "max_turns": N, "instructions": <the role contract>}

The agent gets no shell, no network tool, no MCP server and no handoff: only
file tools whose every path is resolved inside `root` with symlinks followed.
Read-only mode has list/read/search; write mode adds write/replace/delete, which
refuse `.git`, run state, governance files, secrets, symlinks and anything
outside the owned Paths (the same never-touch list apply.sh checks again).
A refused call returns an ERROR string to the model; nothing is approved on its
behalf. Tracing to OpenAI is disabled.

stdout: one JSON line in the claude -p result shape, which worker.py parses:
  {"type": "result", "subtype": "success"|"error_max_turns"|"error", "is_error": bool,
   "result": <final output>, "usage": {input_tokens, output_tokens, cache_read_input_tokens},
   "modelUsage": {<model>: {...}}, "num_turns": N}
Exit: 0 finished, 1 the run failed (result line still printed), 2 usage,
4 the SDK is not installed.
"""
import argparse
import fnmatch
import json
import os
import re
import sys

MAX_READ_BYTES = 256 * 1024
MAX_WRITE_BYTES = 1024 * 1024
MAX_LIST = 500
MAX_HITS = 200
SKIP_DIRS = {".git", "node_modules", ".dev-plan-state", "__pycache__", ".venv", "venv"}
# Mirrors worker.py NEVER_TOUCH (apply.sh checks the patch against it again).
NEVER_TOUCH = tuple(re.compile(rx, re.I) for rx in (
    r"(^|/)\.dev-plan-state(/|$)", r"(^|/)\.git(/|$)", r"(^|/)\.claude/apex-dispatch(/|$)",
    r"(^|/)\.claude/settings[^/]*\.json$", r"(^|/)\.claude/hooks(/|$)", r"(^|/)hooks/hooks\.json$",
    r"(^|/)\.mcp\.json$", r"(^|/)\.gitmodules$", r"(^|/)\.env(\.[^/]*)?$", r"(^|/)\.envrc$",
    r"(^|/)(id_rsa|id_ecdsa|id_ed25519)[^/]*$|\.pem$"))
EXIT_OK, EXIT_FAILED, EXIT_USAGE, EXIT_UNAVAILABLE = 0, 1, 2, 4


def sdk_version():
    try:
        from importlib import metadata
        return metadata.version("openai-agents")
    except Exception:
        return None


class Workspace:
    """Every file operation of the agent, confined to root."""

    def __init__(self, root, mode, owned, owned_rx):
        self.root = os.path.realpath(root)
        self.mode, self.owned = mode, owned
        self.owned_rx = [re.compile(x) for x in owned_rx] if owned_rx is not None else None
        self.changed = []

    def rel(self, path):
        """(relative path, absolute path) inside root, or raise ValueError."""
        if not isinstance(path, str) or not path.strip() or "\0" in path:
            raise ValueError("a path is required")
        p = path.strip()
        full = os.path.realpath(os.path.join(self.root, p.lstrip("/") if not os.path.isabs(p) else p))
        if full != self.root and not full.startswith(self.root + os.sep):
            raise ValueError("%s is outside the workspace" % path)
        rel = os.path.relpath(full, self.root).replace(os.sep, "/")
        return ("." if rel == "." else rel), full

    def readable(self, rel):
        if rel != "." and re.search(r"(^|/)\.git(/|$)", rel):
            raise ValueError("%s: git internals are not readable" % rel)

    def writable(self, rel, full):
        if self.mode != "write":
            raise ValueError("this run is read-only: no file may be changed")
        if rel == ".":
            raise ValueError("the workspace root cannot be written")
        for rx in NEVER_TOUCH:
            if rx.search(rel):
                raise ValueError("%s is on the never-touch list" % rel)
        if self.owned_rx is not None and not any(rx.match(rel) for rx in self.owned_rx):
            raise ValueError("%s is outside the task's owned Paths (%s)" % (rel, ", ".join(self.owned) or "none"))
        lex = os.path.join(self.root, rel)
        if os.path.islink(lex):
            raise ValueError("%s is a symlink: not written" % rel)

    # -- tools ------------------------------------------------------------

    def list_files(self, path=".", pattern="*"):
        rel, full = self.rel(path)
        self.readable(rel)
        if not os.path.isdir(full):
            raise ValueError("%s is not a directory" % rel)
        out = []
        for d, dirs, files in os.walk(full):
            dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS)
            for f in sorted(files):
                r = os.path.relpath(os.path.join(d, f), self.root).replace(os.sep, "/")
                if fnmatch.fnmatch(os.path.basename(r), pattern or "*"):
                    out.append(r)
                    if len(out) >= MAX_LIST:
                        return "\n".join(out + ["... (truncated at %d entries)" % MAX_LIST])
        return "\n".join(out) or "(no files)"

    def read_file(self, path, start_line=1, max_lines=2000):
        rel, full = self.rel(path)
        self.readable(rel)
        if not os.path.isfile(full):
            raise ValueError("%s is not a file" % rel)
        with open(full, "rb") as f:
            data = f.read(MAX_READ_BYTES + 1)
        text = data[:MAX_READ_BYTES].decode("utf-8", "replace")
        lines = text.splitlines()
        s = max(1, int(start_line or 1))
        n = max(1, min(int(max_lines or 2000), 5000))
        body = "\n".join("%6d\t%s" % (i + s, ln) for i, ln in enumerate(lines[s - 1:s - 1 + n]))
        more = len(data) > MAX_READ_BYTES or s - 1 + n < len(lines)
        return body + ("\n... (more lines: read again with a later start_line)" if more else "")

    def search_files(self, regex, path=".", glob="*"):
        rel, full = self.rel(path)
        self.readable(rel)
        try:
            rx = re.compile(regex)
        except re.error as e:
            raise ValueError("bad regex: %s" % e)
        hits = []
        for d, dirs, files in os.walk(full) if os.path.isdir(full) else [(os.path.dirname(full), [], [os.path.basename(full)])]:
            dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS)
            for f in sorted(files):
                if not fnmatch.fnmatch(f, glob or "*"):
                    continue
                fp = os.path.join(d, f)
                try:
                    with open(fp, "rb") as fh:
                        data = fh.read(MAX_READ_BYTES)
                except OSError:
                    continue
                if b"\0" in data[:4096]:
                    continue
                r = os.path.relpath(fp, self.root).replace(os.sep, "/")
                for i, ln in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
                    if rx.search(ln):
                        hits.append("%s:%d:%s" % (r, i, ln[:300]))
                        if len(hits) >= MAX_HITS:
                            return "\n".join(hits + ["... (truncated at %d hits)" % MAX_HITS])
        return "\n".join(hits) or "(no matches)"

    def write_file(self, path, content):
        rel, full = self.rel(path)
        self.writable(rel, full)
        data = (content or "").encode("utf-8")
        if len(data) > MAX_WRITE_BYTES:
            raise ValueError("content over %d bytes" % MAX_WRITE_BYTES)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as f:
            f.write(data)
        self.changed.append(rel)
        return "wrote %s (%d bytes)" % (rel, len(data))

    def replace_in_file(self, path, old, new):
        rel, full = self.rel(path)
        self.writable(rel, full)
        if not os.path.isfile(full):
            raise ValueError("%s is not a file" % rel)
        with open(full, encoding="utf-8") as f:
            text = f.read()
        n = text.count(old or "")
        if not old or n != 1:
            raise ValueError("`old` must occur exactly once in %s (found %d)" % (rel, n if old else 0))
        return self.write_file(rel, text.replace(old, new or "", 1)).replace("wrote", "edited")

    def delete_file(self, path):
        rel, full = self.rel(path)
        self.writable(rel, full)
        if not os.path.isfile(full):
            raise ValueError("%s is not a file" % rel)
        os.remove(full)
        self.changed.append(rel)
        return "deleted %s" % rel


def make_tools(ws, function_tool):
    """The SDK function tools over ws. A refused call is an ERROR string the model
    reads, never an exception that ends the run."""
    def guard(fn, *a):
        try:
            return fn(*a)
        except (ValueError, OSError, UnicodeDecodeError) as e:
            return "ERROR: %s" % e

    @function_tool
    def list_files(path: str = ".", pattern: str = "*") -> str:
        """List files under a directory of the workspace (recursive; .git and dependency folders skipped).

        Args:
            path: directory relative to the workspace root.
            pattern: shell-style file name filter, e.g. "*.md".
        """
        return guard(ws.list_files, path, pattern)

    @function_tool
    def read_file(path: str, start_line: int = 1, max_lines: int = 2000) -> str:
        """Read a text file of the workspace, with line numbers.

        Args:
            path: file relative to the workspace root.
            start_line: first line to return (1-based).
            max_lines: how many lines to return (at most 5000).
        """
        return guard(ws.read_file, path, start_line, max_lines)

    @function_tool
    def search_files(regex: str, path: str = ".", glob: str = "*") -> str:
        """Search file contents with a Python regular expression; returns path:line:text hits.

        Args:
            regex: the pattern.
            path: file or directory to search, relative to the workspace root.
            glob: shell-style file name filter.
        """
        return guard(ws.search_files, regex, path, glob)

    tools = [list_files, read_file, search_files]
    if ws.mode == "write":
        @function_tool
        def write_file(path: str, content: str) -> str:
            """Create or overwrite a file in the workspace (only inside the task's owned paths).

            Args:
                path: file relative to the workspace root.
                content: the complete new content.
            """
            return guard(ws.write_file, path, content)

        @function_tool
        def replace_in_file(path: str, old: str, new: str) -> str:
            """Replace one exact occurrence of `old` with `new` in a workspace file.

            Args:
                path: file relative to the workspace root.
                old: text that occurs exactly once in the file.
                new: replacement text.
            """
            return guard(ws.replace_in_file, path, old, new)

        @function_tool
        def delete_file(path: str) -> str:
            """Delete a file in the workspace (only inside the task's owned paths).

            Args:
                path: file relative to the workspace root.
            """
            return guard(ws.delete_file, path)

        tools += [write_file, replace_in_file, delete_file]
    return tools


def instructions_for(cfg, ws):
    base = (cfg.get("instructions") or "").strip()
    extra = ["", "## Workspace", "You work through the file tools only; there is no shell and no network.",
             "Paths are relative to the workspace root (the repository checkout for this task)."]
    if ws.mode == "write":
        extra.append("You may change only files matching the owned Paths: %s." % (", ".join(ws.owned) if ws.owned else "any "
                     "file outside the never-touch list"))
        extra.append("Your changes are captured as a patch and reviewed; do not commit (there is no git tool).")
    else:
        extra.append("This run is read-only: no tool can change a file.")
    return (base + "\n" + "\n".join(extra)).strip()


def result_line(subtype, text, usage, model, turns):
    u = usage or {}
    print(json.dumps({"type": "result", "subtype": subtype, "is_error": subtype != "success",
                      "result": text if isinstance(text, str) else (json.dumps(text) if text is not None else None),
                      "usage": {"input_tokens": u.get("input_tokens"), "output_tokens": u.get("output_tokens"),
                                "cache_read_input_tokens": u.get("cached_tokens")},
                      "modelUsage": {model: {}} if model else {}, "num_turns": turns}, sort_keys=True))
    sys.stdout.flush()


def usage_of(ctxw):
    u = getattr(ctxw, "usage", None)
    if u is None:
        return None
    det = getattr(u, "input_tokens_details", None)
    return {"input_tokens": getattr(u, "input_tokens", None), "output_tokens": getattr(u, "output_tokens", None),
            "cached_tokens": getattr(det, "cached_tokens", None) if det is not None else None,
            "requests": getattr(u, "requests", None)}


def cmd_run(args):
    try:
        with open(args.config, encoding="utf-8") as f:
            cfg = json.load(f)
        with open(args.brief_file, encoding="utf-8") as f:
            brief = f.read()
    except (OSError, ValueError) as e:
        print("openai-sdk runner: cannot read the config or brief: %s" % e, file=sys.stderr)
        return EXIT_USAGE
    if cfg.get("mode") not in ("write", "readonly") or not isinstance(cfg.get("root"), str) or not os.path.isdir(cfg["root"]):
        print("openai-sdk runner: the config needs mode write|readonly and an existing root", file=sys.stderr)
        return EXIT_USAGE
    owned, owned_rx = cfg.get("owned"), cfg.get("owned_rx")
    for v in (owned, owned_rx):
        if v is not None and not (isinstance(v, list) and all(isinstance(g, str) for g in v)):
            print("openai-sdk runner: owned and owned_rx must be lists of strings or null", file=sys.stderr)
            return EXIT_USAGE
    if (owned is None) != (owned_rx is None):
        print("openai-sdk runner: owned and owned_rx go together", file=sys.stderr)
        return EXIT_USAGE
    try:
        [re.compile(x) for x in owned_rx or []]
    except re.error as e:
        print("openai-sdk runner: a bad owned_rx pattern: %s" % e, file=sys.stderr)
        return EXIT_USAGE
    try:
        import agents
        from agents import Agent, Runner, function_tool
    except Exception as e:
        print("openai-sdk runner: the OpenAI Agents SDK is not importable (pip install openai-agents): %s" % e, file=sys.stderr)
        return EXIT_UNAVAILABLE
    if hasattr(agents, "set_tracing_disabled"):
        agents.set_tracing_disabled(True)              # no trace export: the ledger is the record
    ws = Workspace(cfg["root"], cfg["mode"], owned, owned_rx)
    model = cfg.get("model") or None
    if not model:
        try:
            from agents.models import get_default_model
            model = get_default_model()
        except Exception:
            model = None
    agent = Agent(name="apex-dispatch-worker", instructions=instructions_for(cfg, ws), model=model,
                  tools=make_tools(ws, function_tool))
    max_turns = int(cfg.get("max_turns") or 30)
    try:
        result = Runner.run_sync(agent, brief, max_turns=max_turns)
    except Exception as e:                              # MaxTurnsExceeded, API and model errors
        name = type(e).__name__
        print("openai-sdk runner: %s: %s" % (name, str(e)[:500]), file=sys.stderr)
        run_data = getattr(e, "run_data", None)
        usage = usage_of(getattr(run_data, "context_wrapper", None)) if run_data is not None else None
        result_line("error_max_turns" if name == "MaxTurnsExceeded" else "error", None, usage, model, None)
        return EXIT_FAILED
    turns = len(getattr(result, "raw_responses", None) or []) or None
    result_line("success", result.final_output, usage_of(result.context_wrapper), model, turns)
    return EXIT_OK


def main(argv):
    if argv[:1] in (["--version"], ["-V"]):
        v = sdk_version()
        if not v:
            print("openai-agents is not installed for %s (pip install openai-agents)" % sys.executable, file=sys.stderr)
            return EXIT_UNAVAILABLE
        print("openai-agents %s" % v)
        return EXIT_OK
    ap = argparse.ArgumentParser(prog="openai_sdk_runner.py", description="apex-dispatch openai-sdk worker runner")
    sub = ap.add_subparsers(dest="cmd")
    r = sub.add_parser("run", help="run one worker")
    r.add_argument("--output-format", choices=["json"], required=True)
    r.add_argument("--config", required=True)
    r.add_argument("--brief-file", required=True)
    args = ap.parse_args(argv)
    if args.cmd != "run":
        ap.print_usage(sys.stderr)
        return EXIT_USAGE
    return cmd_run(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
