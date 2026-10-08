"""The hosted-backend transport policy (spec 2026-10-08 §6.4), shared by jev and frontier.

One wall-clock deadline across every attempt. Retry only 408, 429 and 5xx, honour
Retry-After only when it fits, and never retry when less than 2x the observed p50
latency remains. A circuit breaker (3 failures in 30 s) is persisted beside the
decision log so consecutive CLI processes share it. Responses are capped at 4 MiB,
a non-JSON 2xx is an error, the host is pinned (an override is accepted only for
loopback), redirects are refused, TLS is always verified (SSL_CERT_FILE /
REQUESTS_CA_BUNDLE are added to the trust store), and the key never appears in an
error, a log row or an envelope.
"""
import fcntl
import ipaddress
import json
import os
import socket
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

from . import BackendUnavailable

MAX_BYTES = 4 * 1024 * 1024
RETRY_STATUS = {408, 429}
MAX_ATTEMPTS = 3
BREAKER_FAILURES, BREAKER_WINDOW_S = 3, 30.0
LATENCY_SAMPLES = 20
LOCAL_MARGIN_S = 0.03          # time kept back for validating and writing the envelope
LOOPBACK_NAMES = {"localhost"}


def is_loopback(host):
    if (host or "").lower() in LOOPBACK_NAMES:
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def resolve_base(default, env_name):
    """The pinned base URL, or a loopback override from env_name (tests only)."""
    override = os.environ.get(env_name, "")
    if not override:
        return default
    u = urllib.parse.urlsplit(override)
    if u.scheme not in ("http", "https") or not is_loopback(u.hostname) or u.username or u.password:
        raise BackendUnavailable("provider_error", "%s is accepted only for a loopback host (127.0.0.1, ::1 or "
                                 "localhost); the configured host stays pinned" % env_name)
    return override.rstrip("/")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise _Redirected(code)


class _Redirected(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def tls_context():
    ctx = ssl.create_default_context()
    ctx.check_hostname = True
    ctx.verify_mode = ssl.CERT_REQUIRED
    for env in ("SSL_CERT_FILE", "REQUESTS_CA_BUNDLE"):
        path = os.environ.get(env)
        if path and os.path.isfile(path):
            try:
                ctx.load_verify_locations(cafile=path)
            except (ssl.SSLError, OSError):
                pass
    return ctx


def _opener(url):
    host = urllib.parse.urlsplit(url).hostname
    # Loopback never goes through a proxy; anything else follows the environment's proxy
    # settings (HTTPS_PROXY / NO_PROXY), as the agent proxy in a cloud session requires.
    proxy = urllib.request.ProxyHandler({}) if is_loopback(host) else urllib.request.ProxyHandler()
    return urllib.request.build_opener(proxy, _NoRedirect, urllib.request.HTTPSHandler(context=tls_context()))


def redact(text, secrets):
    text = str(text)
    for s in secrets:
        if s and len(s) >= 4:
            text = text.replace(s, "[redacted]")
    return text


# ------------------------------------------------------------- shared state ----

class State:
    """Breaker and latency samples for one backend+transport, in <dir>/transport.json under flock.
    Without a directory (a repository with no run state) the state lives for this process only."""

    def __init__(self, directory, key, prior_p50_ms):
        self.path = os.path.join(directory, "transport.json") if directory else None
        self.key, self.prior = key, prior_p50_ms
        self.mem = {}

    def _update(self, fn):
        if not self.path:
            ent = self.mem
            out = fn(ent)
            return out
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o644)
        except OSError:
            self.path = None
            return self._update(fn)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            raw = b""
            while True:
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                raw += chunk
            try:
                data = json.loads(raw.decode() or "{}")
                if not isinstance(data, dict):
                    data = {}
            except ValueError:
                data = {}
            ent = data.get(self.key) if isinstance(data.get(self.key), dict) else {}
            before = json.dumps(ent, sort_keys=True)
            out = fn(ent)
            if json.dumps(ent, sort_keys=True) != before:
                data[self.key] = ent
                body = json.dumps(data, sort_keys=True).encode()
                os.lseek(fd, 0, os.SEEK_SET)
                os.ftruncate(fd, 0)
                os.write(fd, body)
            return out
        finally:
            os.close(fd)

    def breaker_open(self, now):
        def f(ent):
            fails = [t for t in ent.get("failures", []) if now - t < BREAKER_WINDOW_S]
            if fails != ent.get("failures", []):
                ent["failures"] = fails
            return len(fails) >= BREAKER_FAILURES, (BREAKER_WINDOW_S - (now - fails[0])) if fails else 0
        return self._update(f)

    def failure(self, now):
        def f(ent):
            ent["failures"] = [t for t in ent.get("failures", []) if now - t < BREAKER_WINDOW_S][-(BREAKER_FAILURES * 2):] + [now]
        self._update(f)

    def success(self, latency_ms):
        def f(ent):
            ent["failures"] = []
            ent["latency_ms"] = (ent.get("latency_ms", []) + [int(latency_ms)])[-LATENCY_SAMPLES:]
        self._update(f)

    def p50_ms(self):
        def f(ent):
            xs = sorted(ent.get("latency_ms", []))
            return xs[len(xs) // 2] if xs else self.prior
        return self._update(f)


# --------------------------------------------------------------------- post ----

def _retry_after(v):
    try:
        return max(0.0, float(v))
    except ValueError:
        return None          # an HTTP-date is not honoured: treated as not fitting


def _read_capped(resp):
    cl = resp.headers.get("Content-Length")
    if cl and cl.isdigit() and int(cl) > MAX_BYTES:
        raise BackendUnavailable("provider_error", "response is %s bytes, over the 4 MiB cap" % cl)
    body = resp.read(MAX_BYTES + 1)
    if len(body) > MAX_BYTES:
        raise BackendUnavailable("provider_error", "response is over the 4 MiB cap")
    return body


def post_json(url, body, headers, deadline, state, secrets=(), name="backend"):
    """POST body as JSON to url under the policy. Returns (parsed JSON, meta) with
    meta = {"attempts": n, "status": code, "latency_ms": ms of the answering attempt}.
    Raises BackendUnavailable(provider_error | deadline). A failed call (all its
    attempts) counts once toward the circuit breaker; a breaker refusal counts nothing."""
    is_open, wait = state.breaker_open(time.time())
    if is_open:
        raise BackendUnavailable("provider_error", "%s circuit breaker open (%d failed calls in %d s); retry in %.0f s"
                                 % (name, BREAKER_FAILURES, BREAKER_WINDOW_S, max(wait, 0)))
    try:
        parsed, meta = _attempts(url, body, headers, deadline, state, secrets, name)
    except BackendUnavailable:
        state.failure(time.time())
        raise
    state.success(meta["latency_ms"])
    return parsed, meta


def _attempts(url, body, headers, deadline, state, secrets, name):
    data = json.dumps(body, ensure_ascii=True).encode()
    hdrs = dict({"Content-Type": "application/json", "Accept": "application/json",
                 "User-Agent": "apex-decide"}, **headers)
    opener = _opener(url)
    p50 = state.p50_ms() / 1000.0
    attempts, last = 0, "first attempt"
    while True:
        attempts += 1
        left = deadline - LOCAL_MARGIN_S - time.monotonic()
        if left <= 0:
            raise BackendUnavailable("deadline", "%s: no time left for attempt %d (%s)" % (name, attempts, last))
        t = time.monotonic()
        try:
            req = urllib.request.Request(url, data=data, headers=hdrs, method="POST")
            with opener.open(req, timeout=left) as resp:
                raw = _read_capped(resp)
                status = resp.status
        except _Redirected as e:
            raise BackendUnavailable("provider_error", "%s answered a redirect (%s); redirects are refused" % (name, e.code))
        except urllib.error.HTTPError as e:
            status = e.code
            try:
                snippet = e.read(512).decode("utf-8", "replace")
            except Exception:  # noqa: BLE001
                snippet = ""
            last = "HTTP %d %s" % (status, redact(" ".join(snippet.split())[:200], secrets))
            retryable = status in RETRY_STATUS or 500 <= status <= 599
            ra_header = e.headers.get("Retry-After") if e.headers else None
        except (socket.timeout, TimeoutError):
            raise BackendUnavailable("deadline", "%s did not answer within the deadline (attempt %d)" % (name, attempts))
        except (urllib.error.URLError, OSError, ssl.SSLError) as e:
            reason = getattr(e, "reason", e)
            if isinstance(reason, (socket.timeout, TimeoutError)):
                raise BackendUnavailable("deadline", "%s did not answer within the deadline (attempt %d)" % (name, attempts))
            raise BackendUnavailable("provider_error", "%s unreachable: %s" % (name, redact(reason, secrets)))
        else:
            ms = (time.monotonic() - t) * 1000
            if not 200 <= status <= 299:
                raise BackendUnavailable("provider_error", "%s answered HTTP %d" % (name, status))
            try:
                parsed = json.loads(raw.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                raise BackendUnavailable("provider_error", "%s answered %d with a body that is not JSON" % (name, status))
            return parsed, {"attempts": attempts, "status": status, "latency_ms": int(ms)}
        # A failed HTTP attempt: retry only 408/429/5xx, inside the deadline, with 2x p50 to spare.
        if not retryable or attempts >= MAX_ATTEMPTS:
            raise BackendUnavailable("provider_error", "%s: %s (attempt %d, %s)" % (
                name, last, attempts, "not retryable" if not retryable else "attempts exhausted"))
        if ra_header is not None:
            pause = _retry_after(ra_header)
            if pause is None:
                raise BackendUnavailable("provider_error", "%s: %s; Retry-After %r is not a number of seconds"
                                         % (name, last, ra_header[:40]))
        else:
            pause = 0.05 * attempts
        left = deadline - LOCAL_MARGIN_S - time.monotonic()
        if left - pause < 2 * p50:
            raise BackendUnavailable("provider_error", "%s: %s; no retry: %.0f ms left, less than 2x p50 (%.0f ms) after a %.0f ms pause"
                                     % (name, last, left * 1000, p50 * 1000, pause * 1000))
        time.sleep(pause)


def probe(url, headers, timeout_s, secrets=()):
    """Reachability for `doctor --probe`: POST an empty object through the same pinned,
    redirect-refusing, TLS-verified opener. The provider rejects the body before any model
    runs, so a probe costs nothing. Returns {"reachable", "status", "latency_ms", "detail"}."""
    hdrs = dict({"Content-Type": "application/json", "Accept": "application/json", "User-Agent": "apex-decide"}, **headers)
    t = time.monotonic()
    out = {"reachable": False, "status": None}
    try:
        with _opener(url).open(urllib.request.Request(url, data=b"{}", headers=hdrs, method="POST"), timeout=timeout_s) as r:
            out.update(reachable=True, status=r.status)
    except _Redirected as e:
        out.update(reachable=True, status=e.code, detail="answered a redirect, which the backend refuses")
    except urllib.error.HTTPError as e:
        out.update(reachable=True, status=e.code)
    except (urllib.error.URLError, OSError, ssl.SSLError) as e:
        out["detail"] = redact(getattr(e, "reason", e), secrets)
    out["latency_ms"] = int((time.monotonic() - t) * 1000)
    if out["reachable"] and "detail" not in out:
        s = out["status"]
        out["detail"] = ("key rejected" if s in (401, 403) else
                         "reachable; the empty probe was refused as expected" if s in (400, 404, 405, 415, 422) else
                         "reachable" if 200 <= s <= 299 else "reachable, HTTP %d" % s)
    return out
