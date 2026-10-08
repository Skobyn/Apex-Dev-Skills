#!/usr/bin/env python3
"""A scripted loopback HTTP server for the smoke test (no network in smoke).

  stub_http.py SCRIPT.json RECORD.jsonl PORTFILE

SCRIPT.json is re-read on every request: {"<path>": [response, ...]}, where a response
is {"status": 200, "headers": {...}, "body": <JSON value, or a string sent as is>,
"delay_ms": N, "bytes": N (a body of N 'x' bytes)}. The n-th request to a path gets
the n-th response (the last one repeats). Counters reset whenever the script changes.
Every request is appended to RECORD.jsonl as {path, headers, body}.
"""
import hashlib
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT, RECORD, PORTFILE = sys.argv[1:4]
LOCK = threading.Lock()
STATE = {"digest": None, "counts": {}}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n)
        try:
            body = json.loads(raw.decode() or "null")
        except ValueError:
            body = raw.decode("utf-8", "replace")
        with LOCK:
            text = open(SCRIPT, "rb").read()
            d = hashlib.sha256(text).hexdigest()
            if d != STATE["digest"]:
                STATE.update(digest=d, counts={})
            script = json.loads(text)
            i = STATE["counts"].get(self.path, 0)
            STATE["counts"][self.path] = i + 1
            with open(RECORD, "a") as f:
                f.write(json.dumps({"path": self.path, "headers": dict(self.headers), "body": body}) + "\n")
        seq = script.get(self.path) or [{"status": 404, "body": {"error": "no script for " + self.path}}]
        r = seq[min(i, len(seq) - 1)]
        if r.get("delay_ms"):
            time.sleep(r["delay_ms"] / 1000.0)
        if "bytes" in r:
            out = b"x" * int(r["bytes"])
        elif isinstance(r.get("body"), str):
            out = r["body"].encode()
        else:
            out = json.dumps(r.get("body")).encode()
        try:
            self.send_response(int(r.get("status", 200)))
            for k, v in (r.get("headers") or {}).items():
                self.send_header(k, str(v))
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
        except (BrokenPipeError, ConnectionResetError):
            pass

    do_GET = do_POST


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
srv.daemon_threads = True
with open(PORTFILE + ".tmp", "w") as f:
    f.write(str(srv.server_address[1]))
import os  # noqa: E402
os.replace(PORTFILE + ".tmp", PORTFILE)
srv.serve_forever()
