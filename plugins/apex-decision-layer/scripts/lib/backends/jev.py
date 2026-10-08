"""The `jev` backend (spec 2026-10-08 §6.3, §6.4): TypeSafe System One over either transport.

  typesafe    POST https://api.typesafe.ai/v1/systemone          key: TYPESAFE_API_KEY or JEV_API_KEY
  openrouter  POST https://openrouter.ai/api/v1/systemone        key: OPENROUTER_API_KEY

The two transports accept disjoint model ids (Phase 0), so the rubric's
backend_models.jev is a transport -> model id map and decide.model_for() picks the
id for the configured transport. Untrusted state fields go on the wire as
`untrusted_<field>` and the rubric's data_handling clause is appended to every
question (§10.3). The response is returned as received for the validator; usage.cost
is kept when the transport reports it (OpenRouter) and estimated from the price
otherwise (TypeSafe), marked usage.cost_estimated.
"""
import os
import urllib.parse

from . import BackendUnavailable
from . import transport

TRANSPORTS = {
    "typesafe": {"base": "https://api.typesafe.ai", "path": "/v1/systemone",
                 "keys": ("TYPESAFE_API_KEY", "JEV_API_KEY")},
    "openrouter": {"base": "https://openrouter.ai", "path": "/api/v1/systemone",
                   "keys": ("OPENROUTER_API_KEY",)},
}
BASE_ENV = "APEX_DECIDE_JEV_BASE"
PRICE_PER_MTOK_INPUT = 0.042        # survey; output tokens are free
PRIOR_P50_MS = {"typesafe": 232, "openrouter": 256}   # Phase 0 run 4


def transport_of(cfg):
    t = (cfg.get("jev") or {}).get("transport", "openrouter")
    if t not in TRANSPORTS:
        raise BackendUnavailable("provider_error", "jev.transport must be one of %s" % ", ".join(sorted(TRANSPORTS)))
    return t


def key_envs(cfg):
    """The env vars that may hold the key, in order: the config's api_key_env first."""
    t = transport_of(cfg)
    named = (cfg.get("jev") or {}).get("api_key_env")
    return tuple(dict.fromkeys(([named] if named else []) + list(TRANSPORTS[t]["keys"])))


def find_key(cfg):
    for name in key_envs(cfg):
        v = os.environ.get(name, "")
        if v:
            return name, v
    return None, ""


def endpoint(cfg):
    t = transport_of(cfg)
    base = transport.resolve_base(TRANSPORTS[t]["base"], BASE_ENV)
    return base + TRANSPORTS[t]["path"]


def _sentence(text):
    text = " ".join(str(text).split())
    return text if not text or text[-1] in ".?!" else text + "."


def instructions_text(ins, data_handling):
    parts = [_sentence(ins.get("question", ""))]
    if ins.get("focus"):
        parts.append("Focus on: " + _sentence(ins["focus"]))
    if ins.get("ignore"):
        parts.append("Ignore: " + "; ".join(ins["ignore"]) + ".")
    if ins.get("caution"):
        parts.append("Caution: " + _sentence(ins["caution"]))
    parts.append(_sentence(data_handling))
    return " ".join(p for p in parts if p)


def criterion_text(c):
    if isinstance(c, str):
        return c
    parts = [_sentence(c.get("what", ""))]
    if c.get("examples"):
        parts.append("Examples: " + "; ".join(c["examples"]) + ".")
    if c.get("not_for"):
        parts.append("Not for: " + "; ".join(c["not_for"]) + ".")
    return " ".join(p for p in parts if p)


def wire_questions(rubric):
    """The rubric's questions in the System One wire shape (§6.3)."""
    out = {}
    for qid, q in rubric["questions"].items():
        w = {"type": q["type"], "instructions": instructions_text(q["instructions"], rubric["data_handling"])}
        if q["type"] == "score":
            w["criteria"] = [criterion_text(c) for c in q["criteria"]]
        else:
            w["criteria"] = {lab: criterion_text(c) for lab, c in q["criteria"].items()}
        out[qid] = w
    return out


def wire_state(state, untrusted):
    return {("untrusted_" + k if k in untrusted else k): v for k, v in state.items()}


def request_body(req):
    return {"model": req["model"], "state": wire_state(req["state"], set(req["untrusted"])),
            "questions": wire_questions(req["rubric"])}


class JevBackend:
    name, hosted = "jev", True

    def ask(self, req):
        cfg = req["config"]
        t = transport_of(cfg)
        if not req.get("model"):
            raise BackendUnavailable("provider_error", "rubric %s has no backend_models.jev id for transport %s"
                                     % (req["rubric_version"], t))
        key_name, key = find_key(cfg)
        if not key:
            raise BackendUnavailable("provider_error", "no jev API key: set %s (the %s transport)"
                                     % (" or ".join(key_envs(cfg)), t))
        url = endpoint(cfg)
        loop = transport.is_loopback(urllib.parse.urlsplit(url).hostname)
        state = transport.State(req.get("state_dir"), "jev/%s%s" % (t, "@loopback" if loop else ""), PRIOR_P50_MS[t])
        resp, meta = transport.post_json(url, request_body(req), {"Authorization": "Bearer " + key},
                                         req["deadline"], state, secrets=(key,), name="jev (%s)" % t)
        if isinstance(resp, dict):
            usage = resp.get("usage") if isinstance(resp.get("usage"), dict) else {}
            if "cost" not in usage and isinstance(usage.get("input_tokens"), (int, float)):
                usage = dict(usage, cost=round(usage["input_tokens"] * PRICE_PER_MTOK_INPUT / 1e6, 10), cost_estimated=1)
                resp = dict(resp, usage=usage)
        req.setdefault("meta", {}).update(transport=t, attempts=meta["attempts"], http_latency_ms=meta["latency_ms"])
        return resp
