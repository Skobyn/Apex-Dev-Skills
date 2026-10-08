"""Decision-layer backends (spec 2026-10-08 §6).

Every backend implements ask(req) -> raw response in the Jev wire shape
({model, answers, usage}); it never computes `uncertain`, `calibrated`,
`verdict` or `add_gate`, and its answer always goes through decide.validate().
A backend that cannot answer raises BackendUnavailable(reason, detail).
"""
import hashlib
import json
import os
import time


class BackendUnavailable(Exception):
    def __init__(self, reason, detail=""):
        super().__init__(detail or reason)
        self.reason = reason
        self.detail = detail


HOSTED = {"jev", "frontier"}
NAMES = ("none", "fake", "jev", "frontier")


def state_hash(state):
    return "sha256:" + hashlib.sha256(json.dumps(state, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


class NoneBackend:
    name, hosted = "none", False

    def ask(self, req):
        raise BackendUnavailable("backend_none", "no backend is configured for %s in this repository "
                                 "(.claude/apex-decision-layer/config.json)" % req["rubric_version"])


class FakeBackend:
    """Scripted answers for tests (APEX_DECIDE_FAKE = a JSON file).

    The file maps "<rubric>@<v>" (or "shadow:<rubric>@<v>" for a shadow call)
    to either one entry or {"<state sha256>" | "*": entry}. An entry is
      {"response": <raw wire response, or a string sent as an unparsable body>,
       "sleep_ms": N, "error": "<reason>"}.
    With APEX_DECIDE_FAKE_RECORD set, every request the backend receives is
    appended there as one JSON line (what a hosted backend would have been sent).
    """
    name, hosted = "fake", False

    def ask(self, req):
        path = os.environ.get("APEX_DECIDE_FAKE", "")
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError) as e:
            raise BackendUnavailable("provider_error", "fake backend: cannot read APEX_DECIDE_FAKE: %s" % e)
        rec = os.environ.get("APEX_DECIDE_FAKE_RECORD")
        if rec:
            with open(rec, "a", encoding="utf-8") as f:
                f.write(json.dumps({"rubric": req["rubric_version"], "shadow": req.get("shadow", False),
                                    "model": req["model"], "state": req["state"],
                                    "untrusted": sorted(req["untrusted"])}, sort_keys=True) + "\n")
        key = ("shadow:" if req.get("shadow") else "") + req["rubric_version"]
        entry = data.get(key, data.get(req["rubric_version"])) if req.get("shadow") else data.get(key)
        if isinstance(entry, dict) and not ({"response", "error", "sleep_ms"} & set(entry)):
            entry = entry.get(state_hash(req["state"]), entry.get("*"))
        if not isinstance(entry, dict):
            raise BackendUnavailable("provider_error", "fake backend: no scripted answer for %s" % key)
        sleep = float(entry.get("sleep_ms", 0)) / 1000.0
        if sleep:
            left = req["deadline"] - time.monotonic()
            time.sleep(max(0.0, min(sleep, left + 0.05)))
            if sleep > left:
                raise BackendUnavailable("deadline", "fake backend slept past the deadline")
        if entry.get("error"):
            raise BackendUnavailable(entry["error"], "fake backend: scripted %s" % entry["error"])
        resp = entry.get("response")
        if isinstance(resp, str):
            try:
                resp = json.loads(resp)
            except ValueError:
                raise BackendUnavailable("invalid_answer", "the backend's response is not JSON")
        return resp


def get_backend(name):
    if name == "none":
        return NoneBackend()
    if name == "fake":
        return FakeBackend()
    if name == "jev":
        from .jev import JevBackend
        return JevBackend()
    if name == "frontier":
        from .frontier import FrontierBackend
        return FrontierBackend()
    raise ValueError("unknown backend %r" % name)
