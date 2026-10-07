#!/usr/bin/env python3
"""apex-guardrails — Bash command scoping and the always-on bypass-flag check.

Used by block-destructive-bash.sh when python3 is available (the hook falls
back to a pure-bash approximation otherwise). Pure stdlib.

  bash_scope.py command   stdin: the PreToolUse event JSON.
                          stdout: tool_input.command, verbatim (nothing when it
                          is absent or not a string). Only that field is read:
                          a "command" key anywhere else in the event (another
                          object, a description, a future field) is ignored, so
                          it can neither hide nor stand in for the real command.
  bash_scope.py bypass    stdin: a Bash command string.
                          stdout: the first permission-bypass flag it passes to
                          a program, or nothing.

Bypass flags (always denied, whatever the policy says):
  --dangerously-*  (--dangerously-skip-permissions,
                    --dangerously-bypass-approvals-and-sandbox, ...)
  --yolo  --always-approve  --full-auto

False denies are avoided the way apex-dispatch's pre-bash hook avoids them
(plugins/apex-dispatch/scripts/lib/hooks.py, bash_rules step 2): the command
is tokenised into simple commands; env assignments and wrappers (sudo, env,
nohup, ...) are peeled off; when the program is a text tool (echo, printf,
grep, rg, git, sed, cat, ...) its arguments are data, not flags, so
`grep -- --yolo notes.md` and `git commit -m "drop --full-auto"` pass. Heredoc
bodies are data too. Nested command strings (`bash -c '...'`, `$(...)`,
backticks) are checked as commands in their own right.
"""
import json
import os
import re
import shlex
import sys

BYPASS_PREFIXES = ("--dangerously-", "--yolo", "--always-approve", "--full-auto")
TEXT_TOOLS = {"echo", "printf", "grep", "egrep", "fgrep", "rg", "ag", "git", "sed", "awk", "cat", "head", "tail",
              "less", "wc", "jq", "cut", "sort"}
WRAPPERS = {"sudo", "doas", "command", "builtin", "exec", "nohup", "time", "nice", "ionice", "stdbuf", "chronic",
            "unbuffer", "env", "xargs", "timeout"}
RESERVED = {"if", "then", "else", "elif", "fi", "do", "done", "while", "until", "esac", "!", "{", "}"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "fish"}
SEPARATORS = {";", "&&", "||", "|", "&", "|&", ";;", "(", ")", "\n"}
ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


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


def tokens(cmd):
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=";&|()<>\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    try:
        return list(lex)
    except ValueError:                       # unbalanced quotes: best effort, still checked
        return re.findall(r"[^\s;&|()<>]+|[;&|()<>\n]+", cmd)


def segments(cmd):
    segs, words = [], []
    for t in tokens(cmd):
        if t in SEPARATORS or (t and all(c in ";&|()\n" for c in t)):
            if words:
                segs.append(words)
            words = []
        elif t and all(c in "<>" for c in t):
            words.append(t)                  # a redirect operator; its target follows
        else:
            words.append(t)
    if words:
        segs.append(words)
    return segs


def program(words):
    """(basename of the program, its arguments) after assignments and wrappers."""
    i = 0
    while i < len(words):
        w = words[i]
        if ASSIGN_RE.match(w) or w in RESERVED:
            i += 1
            continue
        base = os.path.basename(w)
        if base in WRAPPERS:
            i += 1
            while i < len(words) and (words[i].startswith("-") or ASSIGN_RE.match(words[i])):
                i += 1                       # the wrapper's own options / env's assignments
            continue
        return base, words[i + 1:]
    return "", []


def substitutions(cmd):
    found = re.findall(r"`([^`]*)`", cmd)
    i = 0
    while True:
        j = cmd.find("$(", i)
        if j < 0:
            break
        depth, k = 0, j + 1
        while k < len(cmd):
            if cmd[k] == "(":
                depth += 1
            elif cmd[k] == ")":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        found.append(cmd[j + 2:k])
        i = k + 1
    return found


def bypass_flag(cmd, depth=0):
    if depth > 4 or not cmd:
        return None
    for inner in substitutions(cmd):
        hit = bypass_flag(inner, depth + 1)
        if hit:
            return hit
    for words in segments(strip_heredocs(re.sub(r"`[^`]*`", " ", cmd))):
        base, args = program(words)
        if base.startswith(BYPASS_PREFIXES):
            return base
        if base in SHELLS:
            for n, a in enumerate(args):
                if a == "-c" or (a.startswith("-") and not a.startswith("--") and "c" in a[1:]):
                    if n + 1 < len(args):
                        hit = bypass_flag(args[n + 1], depth + 1)
                        if hit:
                            return hit
                    break
        if base in TEXT_TOOLS:
            continue
        for a in args:
            if a.startswith(BYPASS_PREFIXES):
                return a.split("=", 1)[0]
    return None


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    raw = sys.stdin.read()
    if mode == "command":
        try:
            ev = json.loads(raw) if raw.strip() else {}
        except ValueError:
            return 0
        ti = ev.get("tool_input") if isinstance(ev, dict) else None
        cmd = ti.get("command") if isinstance(ti, dict) else None
        if isinstance(cmd, str):
            sys.stdout.write(cmd)
        return 0
    if mode == "bypass":
        hit = bypass_flag(raw)
        if hit:
            sys.stdout.write(hit)
        return 0
    sys.stderr.write("usage: bash_scope.py command|bypass\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
