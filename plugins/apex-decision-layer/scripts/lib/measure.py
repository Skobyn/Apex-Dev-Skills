"""The measurement job (spec 2026-10-08 §8): label, corpus, measure, replay. python3 stdlib.

  apex-decide label   --rubric R --decision D --label L [--note TEXT] [--source human|outcome-proxy] [--repo DIR]
  apex-decide corpus  --rubric R [--outcomes FILE] [--out FILE] [--repo DIR]
  apex-decide measure --rubric R --backend B [--corpus FILE] [--out FILE] [--lock] [--json] [--repo DIR]
  apex-decide replay  (--rubric R --backend B | --all) [--dry-run] [--json] [--repo DIR]

Labels live in the consumer repo (.claude/apex-decision-layer/labels/<rubric>.jsonl,
committed, decision Q5); calibration records in .claude/apex-decision-layer/calibration/.
Every write is refused while an apex-scope-loop ACTIVE run lock is held, so an agent
cannot write its own ground truth or calibration (spec §8.4, §10.2).

measure never writes a calibration record unless --lock is given and the kill
criterion passes; it then prints the record's digest for a human to add to the
config's calibration_lock, which is what makes the record count (§8.4).
"""
import json
import math
import os
import time

MIN_N = 100                 # labelled rows per question (kill criterion)
MIN_POSITIVES = 10          # per acted-on label
MIN_AUROC, MIN_LIFT = 0.6, 0.08
PROXY_AGREEMENT, PROXY_SAMPLE = 0.8, 20
DEGENERATE_DISTINCT = 3     # fewer distinct scores than this: AUROC measures little
COVERAGE_AT = (0.3, 0.5, 0.7)
SWEEP = tuple(round(0.1 * i, 1) for i in range(1, 10))
REPLAY_SAMPLE = 50
DRIFT_TOLERANCE = 0.25
SOURCES = ("human", "outcome-proxy")


class Refused(Exception):
    pass


# ------------------------------------------------------------------- helpers ----

def _args(argv, flags, switches=()):
    out, i = {k: None for k in flags}, 0
    out.update({k: False for k in switches})
    while i < len(argv):
        a = argv[i]
        if a in flags:
            if i + 1 >= len(argv):
                raise D.Usage("%s needs a value" % a)
            out[a] = argv[i + 1]
            i += 2
        elif a in switches:
            out[a] = True
            i += 1
        else:
            raise D.Usage("unknown argument %r" % a)
    return out


def _need(a, *keys):
    for k in keys:
        if not a.get(k):
            raise D.Usage("%s is required" % k)


def active_lock(repo):
    return os.path.exists(os.path.join(D.state_base(repo), "ACTIVE", "owner.json"))


def refuse_if_active(repo, what):
    if active_lock(repo):
        raise Refused("%s refused: an apex-scope-loop ACTIVE run lock is held (labels and calibration are written "
                      "by a human between runs, never during one)" % what)


def labels_path(repo, rv):
    return os.path.join(repo, D.CONFIG_REL, "labels", rv + ".jsonl")


def record_path(repo, rv, backend):
    return os.path.join(repo, D.CONFIG_REL, "calibration", rv, backend + ".json")


def read_jsonl(path):
    rows = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if isinstance(r, dict):
                    rows.append(r)
    except OSError:
        pass
    return rows


def append_jsonl(path, row):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(row, sort_keys=True, ensure_ascii=True) + "\n")


def decision_rows(repo, rv):
    d = D.decisions_dir(repo)
    rows = read_jsonl(os.path.join(d, "decisions.jsonl")) if d else []
    return [r for r in rows if r.get("rubric_version") == rv]


def primary_labels(rubric):
    return D.labels_of(rubric["questions"][rubric["primary"]])


def measure_cfg(rubric):
    m = rubric.get("measure") or {}
    labs = primary_labels(rubric)
    return {"acted_on": [x for x in m.get("acted_on") or labs if x in labs],
            "order": [x for x in m.get("order") or [] if x in labs],
            "false_tighten_budget": m.get("false_tighten_budget", 10),
            "false_loosen_budget": m.get("false_loosen_budget", 0)}


# --------------------------------------------------------------------- label ----

def cmd_label(argv):
    a = _args(argv, ("--rubric", "--decision", "--label", "--note", "--source", "--repo"))
    _need(a, "--rubric", "--decision", "--label")
    repo = D.repo_root(a["--repo"])
    rubric = D.load_rubric(a["--rubric"])
    src = a["--source"] or "human"
    if src not in SOURCES:
        raise D.Usage("--source must be human or outcome-proxy")
    if a["--label"] not in primary_labels(rubric):
        raise D.Usage("label %r is not one of %s" % (a["--label"], primary_labels(rubric)))
    if not any(r.get("decision_id") == a["--decision"] for r in decision_rows(repo, a["--rubric"])):
        raise D.Usage("no %s decision %s in this repository's decision log" % (a["--rubric"], a["--decision"]))
    refuse_if_active(repo, "label")
    row = {"decision_id": a["--decision"], "label": a["--label"], "source": src, "ts": D.now_iso()}
    if a["--note"]:
        row["note"] = a["--note"]
    append_jsonl(labels_path(repo, a["--rubric"]), row)
    print("LABEL %s %s=%s (%s) -> %s" % (a["--rubric"], a["--decision"], a["--label"], src,
                                         os.path.relpath(labels_path(repo, a["--rubric"]), repo)))
    return 0


# -------------------------------------------------------------------- corpus ----

def label_index(repo, rv, outcomes=None):
    """decision_id -> {"human": label, "outcome-proxy": label}; the latest of each source wins."""
    idx = {}
    rows = read_jsonl(labels_path(repo, rv)) + (read_jsonl(outcomes) if outcomes else [])
    for r in rows:
        src = r.get("source", "outcome-proxy" if outcomes else "human")
        if r.get("decision_id") and r.get("label") is not None and src in SOURCES:
            idx.setdefault(r["decision_id"], {})[src] = str(r["label"])
            if r.get("baseline") is not None:
                idx[r["decision_id"]]["baseline"] = str(r["baseline"])
    return idx


def build_corpus(repo, rubric, rv, outcomes=None):
    """One row per scored answer (primary and shadow), joined with its labels by decision id."""
    qid = rubric["primary"]
    idx = label_index(repo, rv, outcomes)
    out = []
    for r in decision_rows(repo, rv):
        if not r.get("scored") or not isinstance(r.get("answers"), dict) or qid not in r["answers"]:
            continue
        key = r.get("shadow_of") or r.get("decision_id")
        lab = idx.get(key, {})
        a = r["answers"][qid]
        out.append({"decision_id": r.get("decision_id"), "shadow_of": r.get("shadow_of"), "rubric_version": rv,
                    "question_hash": r.get("question_hash"), "backend": r.get("backend"),
                    "model_resolved": r.get("model_resolved"), "probabilities": a.get("probabilities"),
                    "verdict": a.get("verdict"), "confidence": a.get("confidence"),
                    "untrusted_text": bool(r.get("untrusted_sent")), "state_hash": r.get("state_hash"),
                    "state": r.get("state"), "human": lab.get("human"), "outcome_proxy": lab.get("outcome-proxy"),
                    "baseline": lab.get("baseline")})
    return out


def cmd_corpus(argv):
    a = _args(argv, ("--rubric", "--outcomes", "--out", "--repo"))
    _need(a, "--rubric")
    repo = D.repo_root(a["--repo"])
    rubric = D.load_rubric(a["--rubric"])
    rows = build_corpus(repo, rubric, a["--rubric"], a["--outcomes"])
    text = "".join(json.dumps(r, sort_keys=True, ensure_ascii=True) + "\n" for r in rows)
    if a["--out"]:
        with open(a["--out"], "w", encoding="utf-8") as f:
            f.write(text)
        labelled = sum(1 for r in rows if r["human"] or r["outcome_proxy"])
        print("CORPUS %s: %d rows (%d labelled) -> %s" % (a["--rubric"], len(rows), labelled, a["--out"]))
    else:
        sys_stdout(text)
    return 0


def sys_stdout(text):
    import sys
    sys.stdout.write(text)


# ------------------------------------------------------------------- metrics ----

def auroc(scores, ys):
    """Mann-Whitney AUROC with ties counted half. None without both classes."""
    pos = [s for s, y in zip(scores, ys) if y]
    neg = [s for s, y in zip(scores, ys) if not y]
    if not pos or not neg:
        return None
    ranked = sorted((s, i) for i, s in enumerate(scores))
    ranks = [0.0] * len(scores)
    i = 0
    while i < len(ranked):
        j = i
        while j + 1 < len(ranked) and ranked[j + 1][0] == ranked[i][0]:
            j += 1
        for k in range(i, j + 1):
            ranks[ranked[k][1]] = (i + j) / 2.0 + 1
        i = j + 1
    rpos = sum(r for r, y in zip(ranks, ys) if y)
    n1, n2 = len(pos), len(neg)
    return (rpos - n1 * (n1 + 1) / 2.0) / (n1 * n2)


def hanley_mcneil(a, n1, n2):
    """95% CI (Hanley & McNeil 1982)."""
    if a is None or not n1 or not n2:
        return None
    q1, q2 = a / (2 - a), 2 * a * a / (1 + a)
    var = (a * (1 - a) + (n1 - 1) * (q1 - a * a) + (n2 - 1) * (q2 - a * a)) / (n1 * n2)
    se = math.sqrt(max(var, 0.0))
    return [round(max(0.0, a - 1.96 * se), 4), round(min(1.0, a + 1.96 * se), 4)]


def brier(rows, labels):
    if not rows:
        return None
    return sum(sum((float(r["probabilities"].get(k, 0.0)) - (1.0 if r["label"] == k else 0.0)) ** 2 for k in labels)
               for r in rows) / len(rows)


def ece(rows, bins=10):
    """10-bin expected calibration error on the top label's probability."""
    if not rows:
        return None
    acc = [[] for _ in range(bins)]
    for r in rows:
        p = max(r["probabilities"].values())
        acc[min(bins - 1, int(p * bins))].append((p, 1.0 if r["verdict"] == r["label"] else 0.0))
    n = len(rows)
    return sum(len(b) / n * abs(sum(p for p, _ in b) / len(b) - sum(c for _, c in b) / len(b)) for b in acc if b)


def per_label(rows, labels, score):
    out = {}
    for k in labels:
        ys = [r["label"] == k for r in rows]
        ss = [score(r, k) for r in rows]
        a = auroc(ss, ys)
        n1 = sum(ys)
        out[k] = {"auroc": None if a is None else round(a, 4), "positives": n1, "distinct_scores": len(set(ss)),
                  "ci": hanley_mcneil(a, n1, len(ys) - n1),
                  "degenerate": a is not None and len(set(ss)) < DEGENERATE_DISTINCT}
    return out


def macro(pl, keys, field="auroc"):
    xs = [pl[k][field] for k in keys if pl.get(k) and pl[k][field] is not None]
    return round(sum(xs) / len(xs), 4) if xs else None


def macro_ci(pl, keys):
    cis = [pl[k]["ci"] for k in keys if pl.get(k) and pl[k]["ci"]]
    if not cis:
        return None
    return [round(sum(c[0] for c in cis) / len(cis), 4), round(sum(c[1] for c in cis) / len(cis), 4)]


def sweep(rows, mc):
    order = {k: i for i, k in enumerate(mc["order"])}
    out = []
    for t in SWEEP:
        cov = [r for r in rows if (r["confidence"] or 0) >= t]
        ft = fl = 0
        for r in cov:
            if r["verdict"] in order and r["label"] in order:
                ft += order[r["verdict"]] > order[r["label"]]
                fl += order[r["verdict"]] < order[r["label"]]
        per100 = (lambda x: round(100.0 * x / len(rows), 2)) if rows else (lambda x: None)
        out.append({"min_confidence": t, "coverage": round(len(cov) / len(rows), 4) if rows else None,
                    "precision": round(sum(r["verdict"] == r["label"] for r in cov) / len(cov), 4) if cov else None,
                    "false_tighten_per_100": per100(ft), "false_loosen_per_100": per100(fl)})
    ok = [s for s in out if s["false_tighten_per_100"] is not None and s["false_tighten_per_100"] <= mc["false_tighten_budget"]
          and s["false_loosen_per_100"] <= mc["false_loosen_budget"]]
    return out, (ok[0]["min_confidence"] if ok else None)


def measure_rows(corpus, backend, rubric):
    """Labelled rows for one backend, with the label sources the agreement rule allows."""
    labels = primary_labels(rubric)
    mine = [dict(r) for r in corpus if r.get("backend") == backend and isinstance(r.get("probabilities"), dict)
            and set(r["probabilities"]) == set(labels)]
    both = [r for r in mine if r.get("human") and r.get("outcome_proxy")]
    agree = (sum(r["human"] == r["outcome_proxy"] for r in both) / len(both)) if both else None
    proxy_ok = bool(both) and len(both) >= PROXY_SAMPLE and agree >= PROXY_AGREEMENT
    rows, sources = [], {"human": 0, "outcome-proxy": 0}
    for r in mine:
        lab, src = (r["human"], "human") if r.get("human") else ((r["outcome_proxy"], "outcome-proxy")
                                                                  if proxy_ok and r.get("outcome_proxy") else (None, None))
        if lab in labels:
            r["label"], r["label_source"] = lab, src
            rows.append(r)
            sources[src] += 1
    rule = {"sample": len(both), "agreement": None if agree is None else round(agree, 4), "proxy_counts": proxy_ok,
            "answers": len(mine), "with_human": sum(1 for r in mine if r.get("human")),
            "with_proxy": sum(1 for r in mine if r.get("outcome_proxy")),
            "rule": "outcome-proxy labels count only when >= %d rows carry both labels and agree >= %.1f"
                    % (PROXY_SAMPLE, PROXY_AGREEMENT)}
    return rows, sources, rule


def measure(corpus, rubric, rv, backend, qhash):
    labels = primary_labels(rubric)
    mc = measure_cfg(rubric)
    rows, sources, rule = measure_rows(corpus, backend, rubric)
    rows = [r for r in rows if r.get("question_hash") == qhash]
    if not rule["proxy_counts"] and rule["with_proxy"]:
        rule["why_not"] = ("%d rows carry both labels (need >= %d with agreement >= %.1f)"
                           % (rule["sample"], PROXY_SAMPLE, PROXY_AGREEMENT))
    models = sorted({str(r.get("model_resolved")) for r in rows})
    rep = {"rubric_version": rv, "question_hash": qhash, "backend": backend, "question": rubric["primary"],
           "measured_at": D.now_iso(), "n": len(rows), "label_sources": sources, "proxy_rule": rule,
           "models_resolved": models, "acted_on": mc["acted_on"], "criterion": {
               "min_n": MIN_N, "min_positives": MIN_POSITIVES, "min_auroc": MIN_AUROC, "min_lift": MIN_LIFT}}
    score = lambda r, k: float(r["probabilities"].get(k, 0.0))  # noqa: E731
    pl = per_label(rows, labels, score)
    base_rows = [r for r in rows if r.get("baseline") in labels]
    bpl = per_label(base_rows, labels, lambda r, k: 1.0 if r["baseline"] == k else 0.0)
    rep.update(per_label=pl, auroc=macro(pl, mc["acted_on"]), auroc_ci=macro_ci(pl, mc["acted_on"]),
               auroc_all_labels=macro(pl, labels), baseline_auroc=macro(bpl, mc["acted_on"]),
               baseline_n=len(base_rows), brier=None if not rows else round(brier(rows, labels), 4),
               ece=None if not rows else round(ece(rows), 4),
               coverage={str(t): {"coverage": round(sum((r["confidence"] or 0) >= t for r in rows) / len(rows), 4),
                                  "precision": (lambda c: round(sum(r["verdict"] == r["label"] for r in c) / len(c), 4)
                                                if c else None)([r for r in rows if (r["confidence"] or 0) >= t])}
                         for t in COVERAGE_AT} if rows else {})
    rep["sweep"], rep["recommended_min_confidence"] = sweep(rows, mc)
    arms = {"code-only baseline": rep["baseline_auroc"],
            "backend, structured fields": macro(per_label([r for r in rows if not r.get("untrusted_text")], labels, score),
                                                mc["acted_on"]),
            "backend, with untrusted text": macro(per_label([r for r in rows if r.get("untrusted_text")], labels, score),
                                                  mc["acted_on"])}
    rep["ablation"] = arms
    # Status, most basic first.
    reasons = []
    if len(rows) < MIN_N:
        rep["status"] = "insufficient n"
        reasons.append("%d labelled rows < %d" % (len(rows), MIN_N))
    else:
        few = [k for k in mc["acted_on"] if pl[k]["positives"] < MIN_POSITIVES]
        degen = [k for k in mc["acted_on"] if pl[k]["degenerate"]]
        if few:
            rep["status"] = "insufficient n"
            reasons.append("acted-on labels with < %d positives: %s" % (MIN_POSITIVES, ", ".join(few)))
        elif degen:
            rep["status"] = "degenerate"
            reasons.append("too few distinct scores (< %d) for %s: AUROC measures little (near-one-hot answers, "
                           "Phase 0 spike 6); not counted toward the kill criterion" % (DEGENERATE_DISTINCT, ", ".join(degen)))
        elif len(models) != 1:
            rep["status"] = "fails kill criterion"
            reasons.append("rows span more than one resolved model: %s" % ", ".join(models))
        else:
            a, ci, b = rep["auroc"], rep["auroc_ci"], rep["baseline_auroc"]
            if a is None or a < MIN_AUROC:
                reasons.append("AUROC %s < %.2f" % (a, MIN_AUROC))
            if b is None:
                reasons.append("no code-only baseline answers in the corpus")
            else:
                if a is not None and a - b < MIN_LIFT:
                    reasons.append("lift %.4f over the baseline %.4f < %.2f" % (a - b, b, MIN_LIFT))
                if not ci or ci[0] <= b:
                    reasons.append("CI lower bound %s not above the baseline %.4f" % (ci and ci[0], b))
            rep["status"] = "fails kill criterion" if reasons else "passes kill criterion"
    rep["reasons"] = reasons
    rep["passed"] = rep["status"] == "passes kill criterion"
    return rep, rows


def cmd_measure(argv):
    a = _args(argv, ("--rubric", "--backend", "--corpus", "--outcomes", "--out", "--repo"), ("--lock", "--json"))
    _need(a, "--rubric", "--backend")
    repo = D.repo_root(a["--repo"])
    rv, backend = a["--rubric"], a["--backend"]
    rubric = D.load_rubric(rv)
    qhash = D.question_hash(rubric)
    corpus = read_jsonl(a["--corpus"]) if a["--corpus"] else build_corpus(repo, rubric, rv, a["--outcomes"])
    rep, rows = measure(corpus, rubric, rv, backend, qhash)
    if a["--lock"]:
        refuse_if_active(repo, "measure --lock")
        if rubric.get("seeded"):
            rep["lock"] = "not written: %s is a seeded rubric with no consumer (%s)" % (rv, rubric["seeded"]["consumer"])
        elif not rep["passed"]:
            rep["lock"] = "not written: %s" % rep["status"]
        else:
            rep["lock"] = write_record(repo, rubric, rv, backend, rep, rows)
    if a["--out"]:
        with open(a["--out"], "w", encoding="utf-8") as f:
            json.dump(rep, f, indent=1, sort_keys=True)
            f.write("\n")
    if a["--json"]:
        print(json.dumps(rep, indent=1, sort_keys=True))
    else:
        print_report(rep)
    return 0


def print_report(rep):
    f = lambda v: "-" if v is None else v  # noqa: E731
    print("MEASURE %s %s: %s (n=%d; human %d, outcome-proxy %d)" % (rep["rubric_version"], rep["backend"], rep["status"],
                                                                    rep["n"], rep["label_sources"]["human"],
                                                                    rep["label_sources"]["outcome-proxy"]))
    for r in rep["reasons"]:
        print("MEASURE_REASON: %s" % r)
    print("MEASURE_AUROC: %s CI %s (acted-on %s); baseline %s (n=%d); all labels %s" % (
        f(rep["auroc"]), f(rep["auroc_ci"]), ",".join(rep["acted_on"]), f(rep["baseline_auroc"]), rep["baseline_n"],
        f(rep["auroc_all_labels"])))
    print("MEASURE_CALIBRATION: brier %s; ece(10 bins) %s (a base-rate predictor has perfect ECE: read it beside AUROC)"
          % (f(rep["brier"]), f(rep["ece"])))
    print("MEASURE_ABLATION: " + "; ".join("%s %s" % (k, f(v)) for k, v in rep["ablation"].items()))
    pr = rep["proxy_rule"]
    print("MEASURE_LABELS: %d answers from %s; %d with a human label, %d with an outcome-proxy label"
          % (pr["answers"], rep["backend"], pr["with_human"], pr["with_proxy"]))
    print("MEASURE_PROXY: %s (sample %d, agreement %s)%s" % ("counted" if pr["proxy_counts"] else "not counted", pr["sample"],
                                                          f(pr["agreement"]), "; " + pr["why_not"] if pr.get("why_not") else ""))
    print("MEASURE_THRESHOLD: recommended min_confidence %s" % f(rep["recommended_min_confidence"]))
    if rep.get("lock"):
        print("MEASURE_LOCK: %s" % (rep["lock"] if isinstance(rep["lock"], str) else rep["lock"]["detail"]))


def write_record(repo, rubric, rv, backend, rep, rows):
    """The calibration record (§8.4) and its replay sample. Not trusted until a human adds the digest."""
    sample = [{"decision_id": r["decision_id"], "state": r["state"], "probabilities": r["probabilities"]}
              for r in rows if isinstance(r.get("state"), dict)][:REPLAY_SAMPLE]
    path = record_path(repo, rv, backend)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sample_path = path[:-5] + ".replay.jsonl"
    body = "".join(json.dumps(s, sort_keys=True, ensure_ascii=True) + "\n" for s in sample).encode()
    with open(sample_path, "wb") as f:
        f.write(body)
    q = rubric["primary"]
    thr = rep["recommended_min_confidence"]
    rec = {"rubric_version": rv, "question_hash": rep["question_hash"], "backend": backend,
           "model_resolved": rep["models_resolved"][0], "measured_at": rep["measured_at"], "n": rep["n"],
           "label_sources": rep["label_sources"], "auroc": rep["auroc"], "auroc_ci": rep["auroc_ci"],
           "baseline_auroc": rep["baseline_auroc"], "ece": rep["ece"], "brier": rep["brier"],
           "thresholds": {q: {"min_confidence": thr, "measured": True}} if thr is not None else {},
           "drift": {"baseline_answers": D.sha(body), "sample": os.path.basename(sample_path), "n": len(sample),
                     "tolerance": DRIFT_TOLERANCE},
           "untrusted_text": any(r.get("untrusted_text") for r in rows), "passed": True}
    text = (json.dumps(rec, indent=1, sort_keys=True) + "\n").encode()
    with open(path, "wb") as f:
        f.write(text)
    digest = D.sha(text)
    return {"record": os.path.relpath(path, repo), "digest": digest, "replay_sample": len(sample),
            "detail": "wrote %s (replay sample %d). It is NOT trusted yet: a human adds \"%s\" to "
                      "calibration_lock in .claude/apex-decision-layer/config.json" % (os.path.relpath(path, repo),
                                                                                     len(sample), digest)}


# -------------------------------------------------------------------- replay ----

def cmd_replay(argv):
    a = _args(argv, ("--rubric", "--backend", "--repo"), ("--dry-run", "--json", "--all"))
    if a["--all"]:
        if a["--rubric"] or a["--backend"]:
            raise D.Usage("--all replays every calibration record; it takes no --rubric/--backend")
        repo = D.repo_root(a["--repo"])
        base = os.path.join(repo, D.CONFIG_REL, "calibration")
        recs = sorted((os.path.relpath(dp, base), f[:-5]) for dp, _, fs in os.walk(base) for f in fs
                      if f.endswith(".json"))
        if not recs:
            print("REPLAY: no calibration records under %s" % os.path.relpath(base, repo))
            return 0
        worst = 0
        for rv, backend in recs:
            sub = ["--rubric", rv, "--backend", backend] + [x for x in argv if x != "--all"]
            worst = max(worst, cmd_replay(sub))
        return worst
    _need(a, "--rubric", "--backend")
    repo = D.repo_root(a["--repo"])
    rv, backend = a["--rubric"], a["--backend"]
    rubric = D.load_rubric(rv)
    cfg = D.load_config(repo)
    path = record_path(repo, rv, backend)
    try:
        with open(path, encoding="utf-8") as f:
            rec = json.load(f)
    except (OSError, ValueError) as e:
        raise D.Usage("no readable calibration record at %s: %s" % (os.path.relpath(path, repo), e))
    drift = rec.get("drift") or {}
    sample_path = os.path.join(os.path.dirname(path), drift.get("sample") or "")
    try:
        with open(sample_path, "rb") as f:
            body = f.read()
    except OSError:
        body = b""
    out = {"rubric_version": rv, "backend": backend, "record": os.path.relpath(path, repo), "checked_at": D.now_iso(),
           "tolerance": float(drift.get("tolerance", DRIFT_TOLERANCE)), "rows": [], "status": "ok"}
    problems = []
    if not body or D.sha(body) != drift.get("baseline_answers"):
        problems.append("the replay sample is missing or does not match the record's baseline_answers digest")
    qhash = D.question_hash(rubric)
    sample = [json.loads(x) for x in body.decode().splitlines() if x.strip()] if body else []
    worst = 0.0
    for s in sample if not problems else []:
        req = {"rubric_version": rv, "rubric": rubric, "state": s["state"], "untrusted": [], "model": D.model_for(rubric, backend, cfg),
               "deadline": time.monotonic() + 30, "config": cfg, "state_dir": D.decisions_dir(repo)}
        try:
            st, _, untrusted = D.build_state(rubric, s["state"], cfg)
            req.update(state=st, untrusted=untrusted)
            res = D.answer(rubric, rv, qhash, backend, req, cfg, repo)
        except D.Unscored as e:
            out["rows"].append({"decision_id": s.get("decision_id"), "error": e.reason})
            problems.append("replay of %s unscored: %s" % (s.get("decision_id"), e.reason))
            continue
        p = res["answers"][rubric["primary"]]["probabilities"]
        delta = max(abs(float(p.get(k, 0)) - float(s["probabilities"].get(k, 0))) for k in set(p) | set(s["probabilities"]))
        worst = max(worst, delta)
        row = {"decision_id": s.get("decision_id"), "max_delta": round(delta, 4), "model_resolved": res["model_resolved"]}
        out["rows"].append(row)
        if res["model_resolved"] and res["model_resolved"] != rec.get("model_resolved"):
            problems.append("the backend now resolves %s, the record measured %s" % (res["model_resolved"], rec.get("model_resolved")))
    out["max_delta"] = round(worst, 4)
    if worst > out["tolerance"]:
        problems.append("max probability change %.4f > tolerance %.2f" % (worst, out["tolerance"]))
    if problems:
        out["status"] = "drift"
        out["problems"] = sorted(set(problems))
        if not a["--dry-run"]:
            refuse_if_active(repo, "replay (invalidating a record)")
            rec["invalidated"] = "%s: %s" % (out["checked_at"], "; ".join(out["problems"]))
            with open(path, "w", encoding="utf-8") as f:
                json.dump(rec, f, indent=1, sort_keys=True)
                f.write("\n")
            out["invalidated"] = True
    if a["--json"]:
        print(json.dumps(out, indent=1, sort_keys=True))
    else:
        print("REPLAY %s %s: %s (%d rows, max delta %s, tolerance %s)%s" % (
            rv, backend, out["status"], len(out["rows"]), out["max_delta"], out["tolerance"],
            "; record invalidated (its digest no longer matches calibration_lock)" if out.get("invalidated") else ""))
        for p in out.get("problems", []):
            print("REPLAY_PROBLEM: %s" % p)
    return 0 if out["status"] == "ok" else 4


# ---------------------------------------------------------------------- main ----

D = None


def run(decide_module, sub, argv):
    global D
    D = decide_module
    try:
        return {"label": cmd_label, "corpus": cmd_corpus, "measure": cmd_measure, "replay": cmd_replay}[sub](argv)
    except Refused as e:
        print("apex-decide: %s" % e, file=__import__("sys").stderr)
        return 5
    except D.Unscored as e:
        print("apex-decide: %s: %s" % (e.reason, e.detail), file=__import__("sys").stderr)
        return 2
