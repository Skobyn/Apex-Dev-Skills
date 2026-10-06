#!/usr/bin/env python3
"""inventory.py TOP -- GIT... : every entry in the working tree TOP that is
not accounted for by the head, one per line (nothing when the tree is clean).

A positive inventory, independent of what git chooses to look at: the tree is
walked directly (os.walk, symlinks not followed) and each entry must be
  - an index path (its content is git status's job; a directory where the
    index has a file is reported),
  - a directory (walked: one leading to index paths, or an untracked one
    that committed rules do not ignore -- an empty directory holds nothing),
  - a gitlink (not walked; apex_dirty checks submodules itself), or
  - ignored by a committed .gitignore: git check-ignore names a tracked
    .gitignore and a non-negated pattern as the deciding rule (so an
    untracked .gitignore, .git/info/exclude or core.excludesFile never
    decides); ignored directories are not walked.
Anything else is reported: untracked files, symlinks and special files,
directories that cannot be listed, and any entry named .git (any case) other
than TOP's own .git -- git never looks inside such a path, and git commands
run below it answer from it. Any error is reported too.

GIT is the git command to run in TOP (argv), e.g. git --no-pager -C TOP.
"""
import os
import subprocess
import sys
import unicodedata


def nfc(b):
    try:
        return unicodedata.normalize("NFC", b.decode("utf-8")).encode("utf-8")
    except UnicodeDecodeError:
        return b


def main():
    top = os.fsencode(sys.argv[1])
    git = sys.argv[3:] if sys.argv[2] == "--" else sys.argv[2:]
    out = []

    staged = subprocess.run(git + ["ls-files", "-z", "--stage"], capture_output=True, check=True).stdout
    files, links, dirs = set(), set(), set()
    for e in staged.split(b"\0"):
        if not e:
            continue
        meta, path = e.split(b"\t", 1)
        path = nfc(path)
        (links if meta.startswith(b"160000 ") else files).add(path)
        parts = path.split(b"/")
        for i in range(1, len(parts)):
            dirs.add(b"/".join(parts[:i]))
    tracked_ignores = {p for p in files if p == b".gitignore" or p.endswith(b"/.gitignore")}

    ci = subprocess.Popen(git + ["-c", "core.excludesFile=/dev/null", "check-ignore", "-z", "-v", "-n", "--stdin"],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

    def field():
        buf = bytearray()
        while True:
            c = ci.stdout.read(1)
            if c in (b"\0", b""):
                return bytes(buf), c == b""
            buf += c

    def ignored(rels):
        """{rel: True} for each rel a committed rule ignores."""
        ci.stdin.write(b"".join(b"./" + r + b"\0" for r in rels))
        ci.stdin.flush()
        ans = {}
        for _ in rels:
            f = []
            for _ in range(4):
                v, eof = field()
                if eof:
                    raise RuntimeError("git check-ignore stopped")
                f.append(v)
            source, _, pattern, path = f
            ans[path[2:] if path.startswith(b"./") else path] = (
                source in tracked_ignores and bool(pattern) and not pattern.startswith(b"!"))
        return [ans.get(r, False) for r in rels]

    def report(rel, why):
        out.append(os.fsdecode(rel) + (" (" + why + ")" if why else ""))

    def walk(rel):
        here = os.path.join(top, rel) if rel else top
        try:
            names = sorted(os.listdir(here))
        except OSError:
            report(rel, "cannot be listed")
            return
        unknown = []
        for name in names:
            r = rel + b"/" + name if rel else name
            key = nfc(r)
            p = os.path.join(here, name)
            if name.lower() == b".git":
                if rel or name != b".git":
                    report(r, "a .git entry")
                continue
            if key in links:
                continue
            isdir = os.path.isdir(p) and not os.path.islink(p)
            if key in files:
                if isdir:
                    report(r, "a directory where the head has a file")
                continue
            if isdir and key in dirs:
                walk(r)
                continue
            unknown.append((r, key, isdir))
        if unknown:
            for (r, key, isdir), ign in zip(unknown, ignored([k for _, k, _ in unknown])):
                if ign:
                    continue
                if isdir:
                    walk(r)          # an untracked directory: report what it holds (an empty one holds nothing)
                else:
                    report(r, "")

    try:
        walk(b"")
        ci.stdin.close()
        ci.wait(timeout=60)
    except Exception as e:  # anything unexpected: the tree is not shown to be clean
        out.append("(could not take the inventory: %s)" % e)
        try:
            ci.kill()
        except Exception:
            pass
    for line in out[:20]:
        print(line)
    if len(out) > 20:
        print("... and %d more" % (len(out) - 20))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print("(could not take the inventory: %s)" % e)
