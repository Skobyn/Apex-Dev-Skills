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
timeout, nice, ...) and their option values are peeled off; when the program
is a text tool (echo, printf, grep, rg, git, sed, cat, ...) its arguments are
data, not flags, so `grep -- --yolo notes.md` and `git commit -m "drop
--full-auto"` pass.

Quoting follows bash: a scanner walks the command once, tracking quotes.
Single-quoted text and the bodies of quoted heredocs (<<'EOF', <<"EOF",
<<\EOF) are literal, so a backtick or $( ) inside them is not a command.
Command substitutions ($( ) and backticks) outside quotes, inside double
quotes and inside unquoted heredoc bodies are checked as commands. `<<`
inside $(( )) arithmetic is a shift, not a heredoc.

Launchers: any program that is not a text tool may run its arguments as a
command line (tmux, screen, docker, script -c, su -c, ssh, ...). So every
argument of such a program that contains whitespace is checked as a nested
command (literally: its own backticks are not expanded), and `<shell> -c ARG`
anywhere in its arguments is checked as a full nested command. Nesting is
depth-capped. The launcher rules apply to every program that is not a pure
text tool, including git, gh and glab; for those three only the VALUES of
prose options are exempt: long ones always (gh/glab --title/--body/
--description/--notes/--message/--field/..., git --message/--file/--author/
--grep/--format/--pretty), short ones only for the subcommands where they take
prose (git commit/tag/merge/notes -m -F, git log/show/shortlog -S -G, gh/glab
pr|issue|release|mr create|edit|comment|review|close|note -t -b -d -n -f -F,
gh api -f -F), and never a next argument that is option-shaped (`--?name[=v]`, no
whitespace); a bullet value such as '- removes --yolo' is still a value, so `gh codespace ssh '...'`, `gh alias set x '...'`,
`git rebase -x '...'` and `git bisect run ...` are checked.

Heredocs fed to a command interpreter are scripts and their bodies are checked
as commands whatever their quoting: the segment's program is a shell, ssh or su
(`bash <<EOF`, `bash -s <<'EOF'`); or, for a program that is not a text tool,
a shell/ssh/su is among its arguments (`docker exec -i c sh <<EOF`,
`kubectl exec -i pod -- bash <<EOF`, `ssh -t host bash <<EOF`); or the segment,
or the ( ) / { } group containing it, is piped into such a command later in
the pipeline (`cat <<'EOF' | bash`, `(cat <<EOF) | bash`, `{ cat <<'EOF'; } | sh`).
"""
import json
import os
import re
import shlex
import sys

BYPASS_PREFIXES = ("--dangerously-", "--yolo", "--always-approve", "--full-auto")
# Text tools that cannot execute their arguments: their arguments are data, not flags or commands.
TEXT_TOOLS = {"echo", "printf", "grep", "egrep", "fgrep", "rg", "ag", "sed", "awk", "cat", "head", "tail",
              "less", "wc", "jq", "cut", "sort"}
# Wrappers run the rest of their arguments as the command; value-taking options per wrapper.
WRAPPER_VALUE_OPTS = {
    "sudo": {"-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U", "-T", "--user", "--group", "--host",
             "--prompt", "--close-from", "--chdir", "--role", "--type", "--other-user", "--command-timeout"},
    "doas": {"-u", "-C"},
    "env": {"-u", "--unset", "-C", "--chdir", "-S", "--split-string"},
    "timeout": {"-s", "--signal", "-k", "--kill-after"},
    "nice": {"-n", "--adjustment"},
    "ionice": {"-c", "-n", "-p", "--class", "--classdata"},
    "stdbuf": {"-i", "-o", "-e", "--input", "--output", "--error"},
    "xargs": {"-I", "-n", "-P", "-d", "-L", "-s", "-E", "-a", "--max-args", "--max-procs", "--delimiter",
              "--arg-file", "--replace"},
    "nohup": set(), "command": set(), "builtin": set(), "exec": {"-a"}, "time": set(), "chronic": set(),
    "unbuffer": set(),
}
# Wrappers whose first positional is not the command (timeout DURATION cmd ...).
WRAPPER_SKIP_POSITIONAL = {"timeout": 1}
RESERVED = {"if", "then", "else", "elif", "fi", "do", "done", "while", "until", "esac", "!", "{", "}"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "fish"}
# Programs that run what arrives on stdin as commands: a heredoc fed to them is a script.
STDIN_RUNNERS = SHELLS | {"ssh", "su"}
# Exec-capable programs with prose options: only the VALUE of these options is exempt from the
# launcher rules (git rebase -x, git bisect run, gh codespace ssh, gh alias set still are checked).
_GH_LONG = {"--title", "--body", "--description", "--notes", "--message", "--subject", "--field",
            "--raw-field", "--comment", "--text"}
# Long prose options are prose for every subcommand; short letters only where they mean prose.
PROSE_FLAGS = {"gh": _GH_LONG, "glab": _GH_LONG,
               "git": {"--message", "--file", "--author", "--grep", "--format", "--pretty"}}
_GH_ACTIONS = {"create", "edit", "comment", "review", "close", "note", "merge"}
OPTION_TOKEN_RE = re.compile(r"--?[A-Za-z][\w-]*(=\S*)?")


def prose_shorts(base, args):
    """Short option letters that take a prose value for this subcommand (empty if none):
    git commit/tag/merge/notes add|append: m F; git log/show/shortlog: S G; gh/glab
    pr|issue|release|mr create|edit|comment|review|close|note: t b d n f F; gh api: f F."""
    pos, i = [], 0
    while i < len(args) and len(pos) < 2:
        a = args[i]
        if base == "git" and a in ("-C", "-c"):
            i += 2
            continue
        if not a.startswith("-"):
            pos.append(a)
        i += 1
    sub = pos[0] if pos else ""
    act = pos[1] if len(pos) > 1 else ""
    if base == "git":
        if sub in ("commit", "tag", "merge") or (sub == "notes" and act in ("add", "append")):
            return set("mF")
        if sub in ("log", "show", "shortlog"):
            return set("SG")
        return set()
    if sub == "api" and base == "gh":
        return set("fF")
    if sub in ("pr", "issue", "release", "mr") and act in _GH_ACTIONS:
        return set("tbdnfF")
    if sub in ("repo", "gist") and act == "create":
        return set("d")
    return set()


HEREDOC = "__APEX_HEREDOC_%d__"
HEREDOC_RE = re.compile(r"^__APEX_HEREDOC_(\d+)__$")
SEPARATORS = {";", "&&", "||", "|", "&", "|&", ";;", "(", ")", "\n"}
ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
SUBST = "__APEX_SUBST__"
MAX_DEPTH = 5


def _match_paren(s, i):
    """s[i] == '('; index of its matching ')' (quote-aware), or len(s)."""
    depth, q = 0, None
    while i < len(s):
        c = s[i]
        if q:
            if c == "\\" and q == '"':
                i += 2
                continue
            if c == q:
                q = None
        elif c == "\\":
            i += 2
            continue
        elif c in "'\"":
            q = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return len(s)


def _backtick_end(s, i):
    """s[i] == '`'; index of the closing backtick, or len(s)."""
    j = i + 1
    while j < len(s):
        if s[j] == "\\":
            j += 2
            continue
        if s[j] == "`":
            return j
        j += 1
    return len(s)


def _heredoc_delim(s, i):
    """At s[i:] == '<<' (not '<<<'): (delimiter, quoted, strip_tabs, end_index) or None."""
    j = i + 2
    strip = j < len(s) and s[j] == "-"
    if strip:
        j += 1
    while j < len(s) and s[j] in " \t":
        j += 1
    word, quoted = [], False
    while j < len(s) and s[j] not in " \t\n;&|<>()":
        c = s[j]
        if c in "'\"":
            quoted = True
            k = s.find(c, j + 1)
            k = len(s) if k < 0 else k
            word.append(s[j + 1:k])
            j = k + 1
            continue
        if c == "\\":
            quoted = True
            word.append(s[j + 1:j + 2])
            j += 2
            continue
        word.append(c)
        j += 1
    w = "".join(word)
    return (w, quoted, strip, j) if w else None


def scan(cmd, expand=True):
    """Walk a command string as bash would quote it. Returns (code, substs):
    code  -- the command with heredoc bodies and comments removed and every
             command substitution replaced by a placeholder word;
    substs -- the bodies of the command substitutions bash would run
             (outside quotes, in double quotes, in unquoted heredoc bodies).
    expand=False treats substitutions as literal text (removed from code, not
    returned): used for argument strings handed to another program.
    heredocs -- every heredoc body, indexed by the placeholder word
             (__APEX_HEREDOC_<k>__) that replaces its `<<DELIM` in code.
    Returns (code, substs, heredocs)."""
    out, substs, pending, heredocs = [], [], [], []
    i, n, dq = 0, len(cmd), False

    def subst_at(k):
        """Command substitution / arithmetic starting at cmd[k] ('$' or '`'): (end, body or None)."""
        if cmd[k] == "`":
            e = _backtick_end(cmd, k)
            return e + 1, cmd[k + 1:e]
        if cmd.startswith("$((", k):
            e = _match_paren(cmd, k + 1)
            return e + 1, None                      # arithmetic, not a command
        e = _match_paren(cmd, k + 1)
        return e + 1, cmd[k + 2:e]

    def heredoc_bodies(k):
        """cmd[k] is the newline ending a line with pending heredocs: skip their bodies."""
        k += 1
        for delim, quoted, strip, idx in pending:
            while k < n:
                e = cmd.find("\n", k)
                e = n if e < 0 else e
                line = cmd[k:e]
                k = e + 1
                if (line.lstrip("\t") if strip else line) == delim:
                    break
                heredocs[idx].append(line)
                if not quoted and expand:
                    for body in scan_body(line):
                        substs.append(body)
        pending.clear()
        return k

    def scan_body(text):
        found, k = [], 0
        while k < len(text):
            if text[k] == "\\":
                k += 2
                continue
            if text[k] == "`" or text.startswith("$(", k):
                end, body = _sub_in(text, k)
                if body is not None:
                    found.append(body)
                k = end
                continue
            k += 1
        return found

    while i < n:
        c = cmd[i]
        if dq:
            if c == "\\":
                out.append(cmd[i:i + 2]); i += 2; continue
            if c == '"':
                dq = False; out.append(c); i += 1; continue
            if c == "`" or cmd.startswith("$(", i):
                end, body = subst_at(i)
                if body is not None and expand:
                    substs.append(body)
                out.append(SUBST if body is not None else cmd[i:end]); i = end; continue
            out.append(c); i += 1; continue
        if c == "\\":
            out.append(cmd[i:i + 2]); i += 2; continue
        if c == "'":
            e = cmd.find("'", i + 1)
            e = n - 1 if e < 0 else e
            out.append(cmd[i:e + 1]); i = e + 1; continue
        if c == '"':
            dq = True; out.append(c); i += 1; continue
        if c == "#" and (i == 0 or cmd[i - 1] in " \t\n;&|()"):
            e = cmd.find("\n", i)
            i = n if e < 0 else e
            continue
        if c == "`" or cmd.startswith("$(", i):
            end, body = subst_at(i)
            if body is not None and expand:
                substs.append(body)
            out.append(" %s " % SUBST if body is not None else cmd[i:end]); i = end; continue
        if cmd.startswith("<<", i) and not cmd.startswith("<<<", i):
            h = _heredoc_delim(cmd, i)
            if h:
                pending.append(h[:3] + (len(heredocs),))
                out.append(" " + HEREDOC % len(heredocs) + " ")
                heredocs.append([])
                i = h[3]; continue
        if c == "\n" and pending:
            out.append(c)
            i = heredoc_bodies(i)
            continue
        out.append(c); i += 1
    return "".join(out), substs, ["\n".join(b) for b in heredocs]


def _sub_in(text, k):
    if text[k] == "`":
        e = _backtick_end(text, k)
        return e + 1, text[k + 1:e]
    if text.startswith("$((", k):
        return _match_paren(text, k + 1) + 1, None
    e = _match_paren(text, k + 1)
    return e + 1, text[k + 2:e]


def tokens(cmd):
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=";&|()<>\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    try:
        return list(lex)
    except ValueError:                       # unbalanced quotes: best effort, still checked
        return re.findall(r"[^\s;&|()<>]+|[;&|()<>\n]+", cmd)


def program(words):
    """(basename of the program, its arguments) after assignments, reserved words
    and wrappers (with their option values) are peeled off."""
    i = 0
    while i < len(words):
        w = words[i]
        if ASSIGN_RE.match(w) or w in RESERVED:
            i += 1
            continue
        base = os.path.basename(w)
        if base in WRAPPER_VALUE_OPTS:
            valued = WRAPPER_VALUE_OPTS[base]
            i += 1
            while i < len(words):
                a = words[i]
                if a == "--":
                    i += 1
                    break
                if ASSIGN_RE.match(a) and base == "env":
                    i += 1
                elif a.startswith("-") and a != "-":
                    i += 2 if (a in valued and "=" not in a) else 1
                else:
                    break
            i += WRAPPER_SKIP_POSITIONAL.get(base, 0)
            continue
        return base, words[i + 1:]
    return "", []


def strip_prose_values(base, args):
    """Drop the values of prose options (titles, bodies, messages, search strings) for
    gh/glab/git: long options everywhere (`--body V`, `--body=V`); short ones only where the
    subcommand gives them a prose value (`-b V`, `-bV`, `git commit -am V`). A next argument
    that starts with `-` is an option, never a value, so it is kept. Everything else is kept
    for the launcher rules (git rebase -S/-m --exec, gh codespace ssh -d ... stay checked)."""
    if base not in PROSE_FLAGS:
        return args
    longs, shorts = PROSE_FLAGS[base], prose_shorts(base, args)
    out, i = [], 0
    while i < len(args):
        a = args[i]
        # The next argument is an option (kept) only if it looks like one; '- removes --yolo' is a value.
        nxt_is_value = i + 1 < len(args) and not (OPTION_TOKEN_RE.fullmatch(args[i + 1])
                                                   and not any(c in args[i + 1] for c in " \t\n"))
        if a in longs:
            i += 2 if nxt_is_value else 1
            continue
        if a.startswith("--") and "=" in a and a.split("=", 1)[0] in longs:
            i += 1
            continue
        if shorts and re.fullmatch(r"-[A-Za-z]+", a) and a[-1] in shorts:
            i += 2 if nxt_is_value else 1             # -m V, -am V
            continue
        if shorts and len(a) > 2 and a[0] == "-" and a[1] != "-" and a[1] in shorts:
            i += 1                                    # -bVALUE, -S'text'
            continue
        out.append(a)
        i += 1
    return out


def _split_sep(t):
    """A separator token (possibly fused, e.g. ')|') into events."""
    ev, i = [], 0
    while i < len(t):
        for op, kind in (("||", "SEP"), ("|&", "PIPE"), ("&&", "SEP"), (";;", "SEP"), ("|", "PIPE"),
                         (";", "SEP"), ("&", "SEP"), ("\n", "SEP"), ("(", "OPEN"), (")", "CLOSE")):
            if t.startswith(op, i):
                ev.append(kind)
                i += len(op)
                break
        else:
            i += 1
    return ev


def structure(code):
    """Pipelines of units at the top level. A unit is ('seg', words) or ('grp', pipelines)
    for a ( ... ) subshell or { ...; } group; units of one pipeline are joined by |."""
    events, words = [], []
    for t in tokens(code):
        if t in SEPARATORS or (t and all(c in ";&|()\n" for c in t)):
            if words:
                events.append(("SEG", words))
            words = []
            events += [(k, None) for k in _split_sep(t)]
        elif not words and t in ("{", "}"):
            events.append(("OPEN" if t == "{" else "CLOSE", None))
        else:
            words.append(t)
    if words:
        events.append(("SEG", words))

    def parse(i, depth):
        pipelines, cur = [], []
        while i < len(events):
            kind, w = events[i]
            if kind == "SEG":
                cur.append(("seg", w))
            elif kind == "OPEN":
                sub, i = parse(i + 1, depth + 1)
                cur.append(("grp", sub))
                continue
            elif kind == "CLOSE" and depth > 0:
                if cur:
                    pipelines.append(cur)
                return pipelines, i + 1
            elif kind != "PIPE":                      # SEP (or a stray close at top level)
                if cur:
                    pipelines.append(cur)
                cur = []
            i += 1
        if cur:
            pipelines.append(cur)
        return pipelines, i

    return parse(0, 0)[0]


def is_runner(words):
    """Does this simple command run its stdin as commands? A shell/ssh/su program, or (for a
    program that is not a text tool) a shell/ssh/su among its arguments: docker exec -i c sh,
    kubectl exec -i pod -- bash, ssh -t host bash."""
    base, args = program(words)
    if base in STDIN_RUNNERS:
        return True
    return base not in TEXT_TOOLS and any(os.path.basename(a) in STDIN_RUNNERS for a in args)


def script_heredocs(pipelines, forced=False):
    """Indices of heredocs whose bodies a shell will run."""
    out = []
    for units in pipelines:
        runner_at = [n for n, (kind, v) in enumerate(units) if kind == "seg" and is_runner(v)]
        for n, (kind, v) in enumerate(units):
            fed = forced or any(r > n for r in runner_at)
            if kind == "grp":
                out += script_heredocs(v, forced=fed)
            elif fed or n in runner_at:
                out += [int(m.group(1)) for m in (HEREDOC_RE.match(w) for w in v) if m]
    return out


def flat_segments(pipelines):
    for units in pipelines:
        for kind, v in units:
            if kind == "grp":
                yield from flat_segments(v)
            else:
                yield v


def bypass_flag(cmd, depth=0, expand=True):
    """The first permission-bypass flag `cmd` would pass to a program, or None."""
    if depth > MAX_DEPTH or not cmd:
        return None
    code, substs, heredocs = scan(cmd, expand)
    for inner in substs:
        hit = bypass_flag(inner, depth + 1)
        if hit:
            return hit
    pipelines = structure(code)
    # A heredoc fed to a shell (or ssh/su) -- by its own command, a shell among that command's
    # arguments, or a pipe from it (or from its group) into one -- is a script: check its body.
    for k in script_heredocs(pipelines):
        hit = bypass_flag(heredocs[k], depth + 1)
        if hit:
            return hit
    for words in flat_segments(pipelines):
        base, args = program(words)
        if base.startswith(BYPASS_PREFIXES):
            return base
        if base in TEXT_TOOLS:
            continue
        for a in args:
            if a.startswith(BYPASS_PREFIXES):
                return a.split("=", 1)[0]
        args = strip_prose_values(base, args)       # gh/glab/git: prose option values only
        # Launchers: `<shell> -c ARG` anywhere in the arguments runs ARG as a script ...
        for n, a in enumerate(args):
            prev = os.path.basename(args[n - 1]) if n else base
            if n + 1 < len(args) and (a == "-c" or (a.startswith("-") and not a.startswith("--") and "c" in a[1:])) \
                    and (prev in SHELLS or base in SHELLS or base in ("su", "script")):
                hit = bypass_flag(args[n + 1], depth + 1)
                if hit:
                    return hit
        # ... and any argument with whitespace may be a command line (tmux, ssh, docker, script -c, ...).
        for a in args:
            if any(ch in a for ch in " \t\n") and a != SUBST and not HEREDOC_RE.match(a):
                hit = bypass_flag(a, depth + 1, expand=False)
                if hit:
                    return hit
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
