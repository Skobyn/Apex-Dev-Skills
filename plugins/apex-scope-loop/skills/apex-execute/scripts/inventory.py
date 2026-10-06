#!/usr/bin/env python3
"""inventory.py TOP -- GIT... : every entry in the working tree TOP that is
not accounted for by the head, one per line (nothing when the tree is clean).

A positive inventory, independent of what git chooses to look at: the tree is
walked directly (os.walk, symlinks not followed) and each entry must be
  - an index path whose bytes are its blob's bytes or exactly what a
    checkout of the blob writes (every regular file is compared; a directory
    where the index has a file is reported),
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
import hashlib
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import unicodedata

CHUNK = 8192   # bytes of paths per check-ignore round trip: its answers stay far below a pipe buffer


def nfc(b):
    try:
        return unicodedata.normalize("NFC", b.decode("utf-8")).encode("utf-8")
    except UnicodeDecodeError:
        return b


def main():
    top = os.fsencode(sys.argv[1])
    git = sys.argv[3:] if sys.argv[2] == "--" else sys.argv[2:]
    out = []

    def timed_out(*_):
        raise TimeoutError("took longer than %ss (APEX_INVENTORY_TIMEOUT)" % limit)
    limit = int(os.environ.get("APEX_INVENTORY_TIMEOUT", "600"))
    signal.signal(signal.SIGALRM, timed_out)
    signal.alarm(limit)

    # Names are compared as bytes. Only where git itself folds names to NFC
    # (core.precomposeUnicode, macOS, whose filesystems treat both spellings
    # as one file) are on-disk names folded to match the index.
    fold = subprocess.run(git + ["config", "--bool", "core.precomposeUnicode"],
                          capture_output=True).stdout.strip() == b"true"
    key_of = nfc if fold else (lambda b: b)

    staged = subprocess.run(git + ["ls-files", "-z", "--stage"], capture_output=True, check=True).stdout
    files, links, dirs = set(), set(), set()
    blobs = {}   # regular files: path -> blob id
    for e in staged.split(b"\0"):
        if not e:
            continue
        meta, path = e.split(b"\t", 1)
        mode, sha = meta.split(b" ")[:2]
        (links if mode == b"160000" else files).add(path)
        if mode in (b"100644", b"100755"):
            blobs[path] = sha
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
            if c == b"\0":
                return bytes(buf)
            if c == b"":
                raise RuntimeError("git check-ignore stopped")
            buf += c

    def ask(batch):
        ci.stdin.write(b"".join(b"./" + r + b"\0" for r in batch))
        ci.stdin.flush()
        ans = {}
        for _ in batch:
            source, _, pattern, path = field(), field(), field(), field()
            ans[path[2:] if path.startswith(b"./") else path] = (
                source in tracked_ignores and bool(pattern) and not pattern.startswith(b"!"))
        return [ans.get(r, False) for r in batch]

    def ignored(rels):
        """For each on-disk path: does a committed rule ignore it? Asked in
        chunks, each answered before the next is sent (no pipe deadlock)."""
        res, batch, size = [], [], 0
        for r in rels:
            batch.append(r)
            size += len(r) + 3
            if size >= CHUNK:
                res += ask(batch)
                batch, size = [], 0
        if batch:
            res += ask(batch)
        return res

    def report(rel, why):
        out.append(os.fsdecode(rel) + (" (" + why + ")" if why else ""))

    stack = [b""]
    while stack:   # a loop, not recursion: no depth limit
        rel = stack.pop()
        here = os.path.join(top, rel) if rel else top
        try:
            names = sorted(os.listdir(here))
        except OSError:
            report(rel, "cannot be listed")
            continue
        unknown = []
        for name in names:
            r = rel + b"/" + name if rel else name
            key = key_of(r)
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
                stack.append(r)
                continue
            unknown.append((r, isdir))
        if unknown:
            for (r, isdir), ign in zip(unknown, ignored([r for r, _ in unknown])):
                if ign:
                    continue
                if isdir:
                    stack.append(r)   # an untracked directory: report what it holds (an empty one holds nothing)
                else:
                    report(r, "")
    ci.stdin.close()
    ci.wait(timeout=60)

    # Content, byte for byte, for every tracked regular file -- not git
    # status, whose comparison runs the file back through whatever
    # conversions its attributes ask for (ident, crlf/text/eol, encodings),
    # several of which map other bytes onto the same blob. A file passes when
    # its bytes are its blob's bytes (hashed here the way git hashes a blob)
    # or exactly what a checkout of its blob writes (checkout-index into a
    # private directory, for the files that differ from the blob). Filter
    # drivers' commands are git config, not head content.
    algo = subprocess.run(git + ["rev-parse", "--show-object-format"], capture_output=True).stdout.strip() or b"sha1"
    if algo not in (b"sha1", b"sha256"):
        raise RuntimeError("unknown object format %r" % algo)

    def same(p, q):
        with open(p, "rb") as f, open(q, "rb") as g:
            while True:
                a, b = f.read(1 << 20), g.read(1 << 20)
                if a != b:
                    return False
                if not a:
                    return True

    differ = []
    for path in sorted(blobs):
        p = os.path.join(top, path)
        if os.path.islink(p) or not os.path.isfile(p):
            continue   # a type change or deletion: git status reports it
        h = hashlib.new(algo.decode())
        h.update(b"blob %d\0" % os.path.getsize(p))
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        if h.hexdigest().encode() != blobs[path]:
            differ.append(path)
    if differ:
        tmp = tempfile.mkdtemp(prefix="apex-inventory.")
        try:
            # Attributes from the head only: an untracked .gitattributes (even
            # one committed rules ignore) must not decide what a checkout of
            # the head writes. --attr-source needs git 2.40; older git fails
            # here, which is reported.
            subprocess.run(git + ["--attr-source=HEAD", "checkout-index", "-z", "--stdin", "--prefix=" + tmp + "/"],
                           input=b"".join(p + b"\0" for p in differ), capture_output=True, check=True)
            for path in differ:
                if not same(os.path.join(top, path), os.path.join(os.fsencode(tmp), path)):
                    report(path, "differs from the head")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    signal.alarm(0)
    out.sort()
    for line in out[:20]:
        print(line)
    if len(out) > 20:
        print("... and %d more" % (len(out) - 20))


if __name__ == "__main__":
    try:
        main()
    except BaseException as e:   # anything unexpected: the tree is not shown to be clean
        print("(could not take the inventory: %s)" % (e or type(e).__name__))
