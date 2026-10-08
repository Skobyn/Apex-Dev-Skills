#!/usr/bin/env python3
"""Write a synthetic decision log and labels into a repository, for smoke and for the runbook.

  make_corpus.py REPO RUBRIC BACKEND MODE N [SEED]

MODE is one of
  pass        informative probabilities; the code-only baseline is right about half the time
  fail        probabilities unrelated to the label (AUROC near 0.5)
  degenerate  exactly one-hot answers, as Jev mostly gives (Phase 0 spike 6)
Rows go to <state-base>/decisions/decisions.jsonl (store_state: full, so replay has states).
Human labels cover 70% of rows (.claude/apex-decision-layer/labels/<rubric>.jsonl); an
outcome-proxy file (printed path) labels every row, agreeing with the human label on 90%
of rows, and carries the code-only baseline's answer.
"""
import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import decide  # noqa: E402


def main(argv):
    repo, rv, backend, mode, n = argv[:5]
    n = int(n)
    rnd = random.Random(int(argv[5]) if len(argv) > 5 else 7)
    rubric = decide.load_rubric(rv)
    qid = rubric["primary"]
    labels = decide.labels_of(rubric["questions"][qid])
    qhash = decide.question_hash(rubric)
    model = decide.model_for(rubric, backend, {"jev": {"transport": "typesafe"}}) or "fake-1"
    base = decide.state_base(repo)
    os.makedirs(os.path.join(base, "decisions"), exist_ok=True)
    log = open(os.path.join(base, "decisions", "decisions.jsonl"), "a")
    lab_path = os.path.join(repo, decide.CONFIG_REL, "labels", rv + ".jsonl")
    os.makedirs(os.path.dirname(lab_path), exist_ok=True)
    labs = open(lab_path, "a")
    out_path = os.path.join(repo, "outcomes-%s-%s.jsonl" % (rv.replace("/", "_"), mode))
    outs = open(out_path, "w")
    for i in range(n):
        truth = labels[i % len(labels)]
        if mode == "degenerate":
            pick = truth if rnd.random() < 0.85 else rnd.choice(labels)
            probs = {k: (1.0 if k == pick else 0.0) for k in labels}
        else:
            raw = {k: rnd.random() * 0.2 for k in labels}
            if mode == "pass":
                raw[truth if rnd.random() < 0.85 else rnd.choice(labels)] += 0.6 + rnd.random() * 0.3
            else:
                raw[rnd.choice(labels)] += 0.6 + rnd.random() * 0.3
            tot = sum(raw.values())
            probs = {k: round(v / tot, 6) for k, v in raw.items()}
            fix = round(1.0 - sum(probs.values()), 6)
            top = max(probs, key=probs.get)
            probs[top] = round(probs[top] + fix, 6)
        top = max(probs, key=probs.get)
        nlab = len(labels)
        conf = (probs[top] - 1.0 / nlab) / (1.0 - 1.0 / nlab)
        did = "d-fx%s%05d" % (mode[:2], i)
        state = {"changed_paths": ["src/f%d.py" % i], "changed_lines": i, "changed_files": 1, "task_tags": []} \
            if "changed_paths" in rubric["state"]["allow"] else {"tags": ["t%d" % (i % 7)], "paths": ["src/f%d" % i]}
        row = {"decision_id": did, "ts": "2026-10-08T00:00:00Z", "rubric_version": rv, "question_hash": qhash,
               "backend": backend, "model_requested": model, "model_resolved": model, "scored": True,
               "answers": {qid: {"type": "choice", "choice": top, "probabilities": probs, "confidence": conf,
                                 "uncertain": False, "verdict": top}},
               "verdict": top, "state": state, "state_hash": decide.sha(state), "untrusted_sent": []}
        log.write(json.dumps(row, sort_keys=True) + "\n")
        if i % 10 < 7:
            labs.write(json.dumps({"decision_id": did, "label": truth, "source": "human"}) + "\n")
        proxy = truth if i % 10 != 3 else labels[(labels.index(truth) + 1) % nlab]
        baseline = truth if rnd.random() < 0.5 else rnd.choice(labels)
        outs.write(json.dumps({"decision_id": did, "label": proxy, "source": "outcome-proxy", "baseline": baseline}) + "\n")
    print(out_path)


if __name__ == "__main__":
    main(sys.argv[1:])
