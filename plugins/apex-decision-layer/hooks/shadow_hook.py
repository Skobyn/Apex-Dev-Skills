#!/usr/bin/env python3
"""Build the state for a seeded rubric from a hook payload, then ask apex-decide in a detached child.

  shadow_hook.py done-claim|tool-risk PROJECT_DIR   (hook payload JSON on stdin)

Prints nothing. The parent returns as soon as the child is forked; the child double-forks into a
new session with stdio on /dev/null, so the hook's 10 s budget never waits on a backend.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = os.path.join(HERE, "..", "bin", "apex-decide")
CLAIM = re.compile(r"\b(done|completed?|finished|implemented|fixed|all (tests|checks) pass(ed|ing)?|ready for review)\b", re.I)
MAX_TEXT = 4000
TAIL_BYTES = 2 * 1024 * 1024
DEADLINE_MS = "20000"


def _text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text")
    return ""


def _is_tool_results(content):
    return isinstance(content, list) and bool(content) and all(
        isinstance(c, dict) and c.get("type") == "tool_result" for c in content)


def done_claim_state(payload):
    """The last assistant text of the final turn, and whether that turn ran a Bash command."""
    if payload.get("stop_hook_active"):
        return None
    try:
        with open(payload.get("transcript_path") or "", "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - TAIL_BYTES))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return None
    turn = []
    for line in reversed(lines):
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if not isinstance(ev, dict):
            continue
        msg = ev.get("message") if isinstance(ev.get("message"), dict) else {}
        if ev.get("type") == "user" and not _is_tool_results(msg.get("content")):
            break                                   # the person's own message: the turn starts after it
        turn.append(ev)
    turn.reverse()
    claim, bash_ids, results = "", set(), []
    for ev in turn:
        msg = ev.get("message") if isinstance(ev.get("message"), dict) else {}
        content = msg.get("content")
        if ev.get("type") == "assistant":
            t = _text(content)
            if t.strip():
                claim = t
            for c in content if isinstance(content, list) else []:
                if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") == "Bash":
                    bash_ids.add(c.get("id"))
        elif ev.get("type") == "user" and isinstance(content, list):
            results += [c for c in content if isinstance(c, dict) and c.get("type") == "tool_result"
                        and c.get("tool_use_id") in bash_ids]
    if not claim or not CLAIM.search(claim):
        return None                                 # not a completion claim: nothing to ask
    state = {"claim_text": claim.strip()[-MAX_TEXT:], "test_output_present": bool(results)}
    if results:
        state["last_command_exit"] = 1 if results[-1].get("is_error") else 0
    return state


def tool_risk_state(payload):
    ti = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    cmd = ti.get("command") if isinstance(ti.get("command"), str) else ""
    if not cmd.strip():
        return None
    return {"tool_name": str(payload.get("tool_name") or "Bash"), "command": cmd[:MAX_TEXT]}


KINDS = {"done-claim": ("done-claim@1", done_claim_state), "tool-risk": ("tool-risk@1", tool_risk_state)}


def main(argv):
    if len(argv) < 3 or argv[1] not in KINDS:
        return 0
    rubric, build = KINDS[argv[1]]
    proj = argv[2]
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return 0
    state = build(payload) if isinstance(payload, dict) else None
    if state is None:
        return 0
    if os.fork():
        return 0                                    # the hook process returns now
    os.setsid()
    if os.fork():
        os._exit(0)
    try:
        r, w = os.pipe()
        os.write(w, json.dumps(state).encode())
        os.close(w)
        dn = os.open(os.devnull, os.O_RDWR)
        os.dup2(r, 0)
        os.dup2(dn, 1)
        os.dup2(dn, 2)
        os.execv("/bin/bash", ["bash", CLI, "--repo", proj, "--rubric", rubric, "--state", "-", "--json",
                               "--deadline-ms", DEADLINE_MS, "--no-shadow"])
    finally:
        os._exit(0)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception:  # noqa: BLE001 — observational: never fail the hook
        sys.exit(0)
